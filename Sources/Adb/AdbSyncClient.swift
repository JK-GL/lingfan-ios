import Foundation

/// 直接用 AOSP sync 协议列目录的客户端。
///
/// 为什么需要它：
/// libadb 只导出了 `adb_commandline_porting`（CLI 入口），
/// `sync_ls` / `sync_stat` / `adb_open` 全是内部链接（符号表里是 `__ZL`），
/// Swift 层根本调不到。而 CLI 的 `ls -al` 输出是给人看的文本，
/// 要靠列位去猜「权限 / 链接数 / 属主 / 属组 / 大小 / 日期 / 名称」，
/// 中文名、含空格名、软链接、Toybox 缺列都会翻车。
///
/// sync 协议是公开规范（AOSP `SYNC.TXT`）：LIST 返回的 DENT 包里
/// mode / size / mtime / namelen 全是 32 位小端整数，一个字段都不用猜。
///
/// 连接方式：本机 adb server（in-process，127.0.0.1:<serverPort>）
///   → `host:transport:<serial>` → `sync:` → 二进制包
/// 全程独立 socket，不经过 AdbBridge 的全局递归锁，
/// 所以拉目录时其他页面的 adb 命令不会被堵住。
final class AdbSyncClient {

    struct RawEntry {
        let name: String
        let mode: UInt32
        let size: UInt64
        let mtime: UInt64

        /// `S_IFMT` 判断，比看首字符可靠
        var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
        var isSymlink: Bool { (mode & 0o170000) == 0o120000 }
    }

    enum SyncError: Error, CustomStringConvertible {
        case socket(String)
        case server(String)
        case malformed(String)

        var description: String {
            switch self {
            case .socket(let m): return "sync socket: \(m)"
            case .server(let m): return "sync fail: \(m)"
            case .malformed(let m): return "sync malformed: \(m)"
            }
        }
    }

    private let serial: String
    private let port: UInt16
    private var fd: Int32 = -1

    init(serial: String, port: UInt16) {
        self.serial = serial
        self.port = port
    }

    deinit {
        close()
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: - 建链

    func connect() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SyncError.socket("socket() 失败 errno=\(errno)")
        }

        // 15 秒收发超时：设备掉线时不至于把整个页面永久挂住
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            throw SyncError.socket("连接 127.0.0.1:\(port) 失败 errno=\(errno)（adb server 可能未启动）")
        }

        // 切到指定设备
        try sendService("host:transport:\(serial)")
        try expectOkay()
        // 切到 sync 模式
        try sendService("sync:")
        try expectOkay()
    }

    /// adb 服务请求：4 位十六进制长度 + 服务名
    private func sendService(_ service: String) throws {
        let body = Array(service.utf8)
        var packet = Array(String(format: "%04x", body.count).utf8)
        packet.append(contentsOf: body)
        try writeAll(packet)
    }

    private func expectOkay() throws {
        let status = try readExactly(4)
        if status == Array("OKAY".utf8) { return }
        if status == Array("FAIL".utf8) {
            let len = Int(le32(try readExactly(4)))
            let msg = len > 0 ? try readExactly(len) : []
            throw SyncError.server(String(decoding: msg, as: UTF8.self))
        }
        throw SyncError.malformed("期望 OKAY/FAIL，实际收到 \(String(decoding: status, as: UTF8.self))")
    }

    // MARK: - LIST

    /// 列目录。返回的条目已去掉 `.` 与 `..`。
    func list(_ path: String) throws -> [RawEntry] {
        let pathBytes = Array(path.utf8)
        var packet = Array("LIST".utf8)
        packet.append(contentsOf: le32Bytes(UInt32(pathBytes.count)))
        packet.append(contentsOf: pathBytes)
        try writeAll(packet)

        var entries: [RawEntry] = []
        while true {
            let id = try readExactly(4)
            let len = Int(le32(try readExactly(4)))

            if id == Array("DENT".utf8) {
                guard len >= 16 else {
                    throw SyncError.malformed("DENT 长度异常 len=\(len)")
                }
                let body = try readExactly(len)
                let mode = le32(Array(body[0..<4]))
                let size = le32(Array(body[4..<8]))
                let mtime = le32(Array(body[8..<12]))
                let nameLen = Int(le32(Array(body[12..<16])))
                let end = min(body.count, 16 + nameLen)
                let name = String(decoding: body[16..<end], as: UTF8.self)
                if !name.isEmpty && name != "." && name != ".." {
                    entries.append(RawEntry(name: name,
                                            mode: mode,
                                            size: UInt64(size),
                                            mtime: UInt64(mtime)))
                }
            } else if id == Array("DONE".utf8) || id == Array("DONT".utf8) {
                if len > 0 { _ = try readExactly(len) }
                break
            } else if id == Array("FAIL".utf8) {
                let body = len > 0 ? try readExactly(len) : []
                throw SyncError.server(String(decoding: body, as: UTF8.self))
            } else {
                if len > 0 { _ = try readExactly(len) }
                throw SyncError.malformed("未知包 \(String(decoding: id, as: UTF8.self)) len=\(len)")
            }
        }
        return entries
    }

    // MARK: - 字节工具

    private func writeAll(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.write(fd, base, buf.count)
            }
            if n <= 0 { throw SyncError.socket("写入失败 errno=\(errno)") }
            offset += n
        }
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if n <= 0 { throw SyncError.socket("读取失败 errno=\(errno)") }
            got += n
        }
        return out
    }

    private func le32Bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff),
         UInt8((v >> 8) & 0xff),
         UInt8((v >> 16) & 0xff),
         UInt8((v >> 24) & 0xff)]
    }

    private func le32(_ b: [UInt8]) -> UInt32 {
        guard b.count >= 4 else { return 0 }
        return UInt32(b[0])
            | (UInt32(b[1]) << 8)
            | (UInt32(b[2]) << 16)
            | (UInt32(b[3]) << 24)
    }

    // MARK: - 展示辅助

    /// `mode` → `drwxrwx--x` 形式的权限串
    static func permissionString(_ mode: UInt32) -> String {
        var s: String
        switch mode & 0o170000 {
        case 0o040000: s = "d"      // 目录
        case 0o120000: s = "l"      // 软链接
        case 0o020000: s = "c"      // 字符设备
        case 0o060000: s = "b"      // 块设备
        case 0o010000: s = "p"      // FIFO
        case 0o140000: s = "s"      // socket
        default:       s = "-"      // 普通文件
        }
        let bits: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        for (mask, ch) in bits {
            s.append((mode & mask) != 0 ? ch : "-")
        }
        return s
    }

    /// `mtime` → `MM-dd HH:mm`
    static func dateText(_ mtime: UInt64) -> String {
        guard mtime > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(mtime)))
    }
}
