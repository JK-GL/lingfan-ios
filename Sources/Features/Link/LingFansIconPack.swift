import Foundation
import UIKit

/// 图标包导入导出
///
/// 对齐原版 `LingFansIconPackSupport.kt`：
///
/// 包结构（ZIP）：
///   manifest.json
///   icons/<packageName>.png
///
/// manifest.json：
///   { "type": "lingfans_icon_pack", "version": 3,
///     "exportedAt": "yyyy-MM-dd HH:mm:ss",
///     "entries": [ { packageName, appLabel, fileName, format,
///                    roundedCropEnabled, cornerRadiusFraction, assetKind } ] }
///
/// 约束（原版常量）：
///   - 单文件上限 8 MB，整包上限 64 MB
///   - 导出统一转 PNG（100% 质量）
///   - 旧格式（assetKind=legacy_final）导出时圆角参数归零
enum LingFansIconPack {

    static let formatType = "lingfans_icon_pack"
    static let version = 3
    static let manifestName = "manifest.json"
    static let iconsDir = "icons"
    static let maxEntryBytes = 8 * 1024 * 1024
    static let maxTotalBytes = 64 * 1024 * 1024

    struct ManifestEntry {
        let packageName: String
        let appLabel: String
        let fileName: String
        let format: String
        let roundedCropEnabled: Bool
        let cornerRadiusFraction: Double
        let assetKind: String
    }

    struct ExportResult {
        let success: Bool
        let exportedCount: Int
        let skippedCount: Int
        let message: String
        let fileURL: URL?
    }

    struct ImportedEntry {
        let packageName: String
        let appLabel: String
        let fileName: String
        let pngData: Data
        let roundedCropEnabled: Bool
        let cornerRadiusFraction: Double
        let assetKind: String
    }

    struct ReadResult {
        let success: Bool
        let entries: [ImportedEntry]
        let message: String
    }

    static func buildFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "lingfans_icons_\(f.string(from: now)).zip"
    }

    // MARK: - 导出

    /// items 里只有 hasCustomIcon 的才导出。
    /// pull 负责把远程图标拉到本地临时文件，返回本地路径。
    static func export(
        items: [LingFansIconItem],
        pull: (String) async -> String?
    ) async -> ExportResult {
        let candidates = items.filter(\.hasCustomIcon)
        guard !candidates.isEmpty else {
            return ExportResult(success: false, exportedCount: 0, skippedCount: 0,
                                message: "当前没有可导出的自定义图标", fileURL: nil)
        }

        var zipEntries: [ZipStore.Item] = []
        var manifestEntries: [ManifestEntry] = []
        var skipped = 0
        var legacyCount = 0
        var totalBytes = 0

        for item in candidates {
            let remote = item.exportRemotePath
            guard !remote.isEmpty else { skipped += 1; continue }

            guard let localPath = await pull(remote),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)),
                  let image = UIImage(data: data) else {
                skipped += 1
                continue
            }

            // 统一转 PNG
            guard let png = image.pngData() else { skipped += 1; continue }
            guard png.count <= maxEntryBytes else { skipped += 1; continue }
            totalBytes += png.count
            guard totalBytes <= maxTotalBytes else {
                return ExportResult(success: false, exportedCount: manifestEntries.count,
                                    skippedCount: skipped,
                                    message: "图标总大小超过 64 MB 上限，已中止",
                                    fileURL: nil)
            }

            let safePkg = sanitize(item.packageName)
            guard !safePkg.isEmpty else { skipped += 1; continue }

            let entryName = "\(iconsDir)/\(safePkg).png"
            zipEntries.append(ZipStore.Item(name: entryName, data: png))

            let isLegacy = item.assetKind == LingFansIcon.assetKindLegacyFinal
            if isLegacy { legacyCount += 1 }

            manifestEntries.append(ManifestEntry(
                packageName: item.packageName,
                appLabel: item.appLabel,
                fileName: entryName,
                format: "png",
                roundedCropEnabled: isLegacy ? false : item.roundedCropEnabled,
                cornerRadiusFraction: isLegacy ? 0 : min(max(item.cornerRadiusFraction, 0), 0.5),
                assetKind: item.assetKind
            ))
        }

        guard !manifestEntries.isEmpty else {
            return ExportResult(success: false, exportedCount: 0, skippedCount: skipped,
                                message: "未能导出任何自定义图标", fileURL: nil)
        }

        // manifest 放最后写，与原版一致
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var manifest: [String: Any] = [
            "type": formatType,
            "version": version,
            "exportedAt": formatter.string(from: Date()),
        ]
        manifest["entries"] = manifestEntries.map { e -> [String: Any] in
            [
                "packageName": e.packageName,
                "appLabel": e.appLabel,
                "fileName": e.fileName,
                "format": e.format,
                "roundedCropEnabled": e.roundedCropEnabled,
                "cornerRadiusFraction": e.cornerRadiusFraction,
                "assetKind": e.assetKind,
            ]
        }

        guard let manifestData = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted]
        ) else {
            return ExportResult(success: false, exportedCount: 0, skippedCount: skipped,
                                message: "生成 manifest 失败", fileURL: nil)
        }
        zipEntries.append(ZipStore.Item(name: manifestName, data: manifestData))

        guard let zipData = ZipStore.write(zipEntries) else {
            return ExportResult(success: false, exportedCount: 0, skippedCount: skipped,
                                message: "打包 ZIP 失败", fileURL: nil)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(buildFileName())
        do {
            try zipData.write(to: url, options: .atomic)
        } catch {
            return ExportResult(success: false, exportedCount: 0, skippedCount: skipped,
                                message: "写入文件失败：\(error.localizedDescription)", fileURL: nil)
        }

        var message = "已导出 \(manifestEntries.count) 个自定义图标"
        if legacyCount > 0 { message += "，其中 \(legacyCount) 个为旧格式兼容导出" }
        if skipped > 0 { message += "，跳过 \(skipped) 个异常项" }

        return ExportResult(success: true, exportedCount: manifestEntries.count,
                            skippedCount: skipped, message: message, fileURL: url)
    }

    // MARK: - 读取

    static func read(fileURL: URL) -> ReadResult {
        guard let data = try? Data(contentsOf: fileURL) else {
            return ReadResult(success: false, entries: [], message: "无法读取文件")
        }
        guard data.count <= maxTotalBytes else {
            return ReadResult(success: false, entries: [], message: "图标包超过 64 MB 上限")
        }
        guard let files = ZipStore.read(data) else {
            return ReadResult(success: false, entries: [], message: "不是有效的 ZIP 图标包")
        }
        guard let manifestData = files[manifestName],
              let obj = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            return ReadResult(success: false, entries: [], message: "图标包缺少 manifest.json")
        }

        // type 缺省时按本格式处理（兼容早期包）
        let type = (obj["type"] as? String ?? formatType)
        guard type == formatType else {
            return ReadResult(success: false, entries: [], message: "不是菱粉图标包（type=\(type)）")
        }

        let rawEntries = obj["entries"] as? [[String: Any]] ?? []
        var result: [ImportedEntry] = []

        for raw in rawEntries {
            let pkg = (raw["packageName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let fileName = (raw["fileName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !pkg.isEmpty, !fileName.isEmpty else { continue }
            guard let png = files[fileName], !png.isEmpty else { continue }
            guard png.count <= maxEntryBytes else { continue }

            result.append(ImportedEntry(
                packageName: pkg,
                appLabel: (raw["appLabel"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                fileName: fileName,
                pngData: png,
                roundedCropEnabled: (raw["roundedCropEnabled"] as? Bool) ?? false,
                cornerRadiusFraction: min(max(
                    (raw["cornerRadiusFraction"] as? NSNumber)?.doubleValue ?? 0, 0), 0.5),
                assetKind: LingFansIcon.normalizeAssetKind(
                    (raw["assetKind"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                )
            ))
        }

        guard !result.isEmpty else {
            return ReadResult(success: false, entries: [], message: "图标包里没有可用图标")
        }
        return ReadResult(success: true, entries: result, message: "已读取 \(result.count) 个图标")
    }

    private static func sanitize(_ packageName: String) -> String {
        packageName.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression
        )
    }
}
