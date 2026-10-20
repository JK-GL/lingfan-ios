import Foundation

/// 最小 ZIP 读写（store 模式，不压缩）
///
/// 为什么自己写：iOS 没有内置 ZIP API，图标包里装的是 PNG（本身已压缩），
/// 用 store 模式打包体积几乎不变，省掉一个第三方依赖。
///
/// 只实现图标包需要的子集：
///   - 写入：无压缩、无加密、无 ZIP64
///   - 读取：遍历中央目录，支持 store 和 deflate（deflate 走 zlib 解压）
enum ZipStore {

    // MARK: - 写入

    struct Item {
        let name: String
        let data: Data
    }

    static func write(_ entries: [Item]) -> Data? {
        guard !entries.isEmpty else { return nil }

        var out = Data()
        var central = Data()

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            // ---- Local file header ----
            appendU32(&out, 0x04034b50)     // signature
            appendU16(&out, 20)             // version needed
            appendU16(&out, 0)              // flags
            appendU16(&out, 0)              // compression = store
            appendU16(&out, 0)              // mod time
            appendU16(&out, 0x21)           // mod date (1980-01-01)
            appendU32(&out, crc)
            appendU32(&out, size)           // compressed size
            appendU32(&out, size)           // uncompressed size
            appendU16(&out, UInt16(nameData.count))
            appendU16(&out, 0)              // extra length
            out.append(nameData)
            out.append(entry.data)

            // ---- Central directory entry ----
            appendU32(&central, 0x02014b50)
            appendU16(&central, 20)         // version made by
            appendU16(&central, 20)         // version needed
            appendU16(&central, 0)          // flags
            appendU16(&central, 0)          // compression
            appendU16(&central, 0)          // mod time
            appendU16(&central, 0x21)       // mod date
            appendU32(&central, crc)
            appendU32(&central, size)
            appendU32(&central, size)
            appendU16(&central, UInt16(nameData.count))
            appendU16(&central, 0)          // extra
            appendU16(&central, 0)          // comment
            appendU16(&central, 0)          // disk start
            appendU16(&central, 0)          // internal attrs
            appendU32(&central, 0)          // external attrs
            appendU32(&central, offset)
            central.append(nameData)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)

        // ---- End of central directory ----
        appendU32(&out, 0x06054b50)
        appendU16(&out, 0)
        appendU16(&out, 0)
        appendU16(&out, UInt16(entries.count))
        appendU16(&out, UInt16(entries.count))
        appendU32(&out, UInt32(central.count))
        appendU32(&out, centralOffset)
        appendU16(&out, 0)

        return out
    }

    // MARK: - 读取

    /// 解出 `文件名 → 内容`。只认中央目录，忽略目录条目。
    static func read(_ data: Data) -> [String: Data]? {
        guard data.count > 22 else { return nil }

        // 找 EOCD：从尾部往前扫，最多 64KB（可能有注释）
        let maxScan = min(data.count, 65557)
        var eocdOffset: Int?
        var i = data.count - 22
        let lowerBound = data.count - maxScan
        while i >= lowerBound && i >= 0 {
            if readU32(data, i) == 0x06054b50 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { return nil }

        let totalEntries = Int(readU16(data, eocd + 10))
        let centralSize = Int(readU32(data, eocd + 12))
        let centralOffset = Int(readU32(data, eocd + 16))
        guard centralOffset >= 0, centralSize >= 0,
              centralOffset + centralSize <= data.count else { return nil }

        var result: [String: Data] = [:]
        var p = centralOffset
        var count = 0

        while count < totalEntries, p + 46 <= data.count {
            guard readU32(data, p) == 0x02014b50 else { break }

            let compression = readU16(data, p + 10)
            let compressedSize = Int(readU32(data, p + 20))
            let nameLen = Int(readU16(data, p + 28))
            let extraLen = Int(readU16(data, p + 30))
            let commentLen = Int(readU16(data, p + 32))
            let localOffset = Int(readU32(data, p + 42))

            guard p + 46 + nameLen <= data.count else { break }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""

            // 跳到本地头，读出数据段
            if !name.isEmpty, !name.hasSuffix("/"), localOffset + 30 <= data.count {
                if readU32(data, localOffset) == 0x04034b50 {
                    let lNameLen = Int(readU16(data, localOffset + 26))
                    let lExtraLen = Int(readU16(data, localOffset + 28))
                    let dataStart = localOffset + 30 + lNameLen + lExtraLen
                    let dataEnd = dataStart + compressedSize

                    if dataStart >= 0, dataEnd <= data.count {
                        let raw = data.subdata(in: dataStart..<dataEnd)
                        if compression == 0 {
                            result[name] = raw
                        } else if compression == 8, let inflated = inflate(raw) {
                            result[name] = inflated
                        }
                    }
                }
            }

            p += 46 + nameLen + extraLen + commentLen
            count += 1
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - deflate 解压

    /// 只处理 raw deflate（无 zlib 头）。失败就返回 nil，不阻塞整体读取。
    private static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        return try? (data as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - 小端读写

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return b0 | (b1 << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
