import Foundation

/// 菱粉图标定制数据模型
///
/// 对齐原版 `LingFansLinkSupport.kt`：
/// `getLaunchableAppIcons` 返回的 Bundle 里，真正的数据在 `payloadBase64` ——
/// 一段 Base64 编码的 JSON，解开后是 `{iconBaseDir, iconPreviewBaseDir, items[]}`。
/// 只读顶层 key-value 拿不到任何图标，这是最容易做错的地方。
enum LingFansIcon {
    /// 素材种类：用户上传的原图（方形，由车机自己做圆角）
    static let assetKindSourceSquare = "source_square"
    /// 素材种类：旧版直接写入的成品图（已带圆角）
    static let assetKindLegacyFinal = "legacy_final"

    static func normalizeAssetKind(_ raw: String) -> String {
        raw == assetKindLegacyFinal ? assetKindLegacyFinal : assetKindSourceSquare
    }
}

struct LingFansIconItem: Identifiable, Hashable {
    let packageName: String
    let appLabel: String
    let launchActivity: String
    let hasCustomIcon: Bool
    let customIconPath: String
    let sourceIconPath: String
    let roundedCropEnabled: Bool
    let cornerRadiusFraction: Double
    let assetKind: String
    let previewPath: String
    let applicationId: String

    var id: String { packageName }

    /// 列表里显示的名字：优先 appLabel，退回包名末段
    var displayName: String {
        if !appLabel.isEmpty { return appLabel }
        return packageName.split(separator: ".").last.map(String.init) ?? packageName
    }

    /// 导出图标包时要拉的远程路径（原版逻辑）
    var exportRemotePath: String {
        if !sourceIconPath.isEmpty { return sourceIconPath }
        if assetKind == LingFansIcon.assetKindLegacyFinal && !customIconPath.isEmpty {
            return customIconPath
        }
        return ""
    }
}

struct LingFansIconSnapshot {
    var success: Bool = false
    var iconBaseDir: String = ""
    var iconPreviewBaseDir: String = ""
    var items: [LingFansIconItem] = []
    var message: String = ""
    var requiresLauncherUpgrade: Bool = false
}

// MARK: - payload 解析

enum LingFansIconPayload {

    /// 解 `payloadBase64` → `(iconBaseDir, iconPreviewBaseDir, items)`
    static func decode(_ base64: String) -> (baseDir: String, previewBaseDir: String, items: [LingFansIconItem])? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let baseDir = (obj["iconBaseDir"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let previewBaseDir = (obj["iconPreviewBaseDir"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let rawItems = obj["items"] as? [[String: Any]] ?? []

        var items: [LingFansIconItem] = []
        for raw in rawItems {
            let pkg = (raw["packageName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !pkg.isEmpty else { continue }

            let radiusRaw = (raw["cornerRadiusFraction"] as? NSNumber)?.doubleValue ?? 0
            items.append(LingFansIconItem(
                packageName: pkg,
                appLabel: (raw["appLabel"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                launchActivity: (raw["launchActivity"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                hasCustomIcon: (raw["hasCustomIcon"] as? Bool) ?? false,
                customIconPath: (raw["customIconPath"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                sourceIconPath: (raw["sourceIconPath"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                roundedCropEnabled: (raw["roundedCropEnabled"] as? Bool) ?? false,
                // 原版 coerceIn(0f, 0.5f)
                cornerRadiusFraction: min(max(radiusRaw, 0), 0.5),
                assetKind: LingFansIcon.normalizeAssetKind(
                    (raw["assetKind"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                ),
                previewPath: (raw["previewPath"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                applicationId: (raw["applicationId"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            ))
        }

        // 原版按 appLabel（空则包名）不区分大小写排序
        items.sort {
            let a = $0.appLabel.isEmpty ? $0.packageName : $0.appLabel
            let b = $1.appLabel.isEmpty ? $1.packageName : $1.appLabel
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }

        return (baseDir, previewBaseDir, items)
    }

    /// 从 request 返回的 values 里解出快照
    static func snapshot(
        from values: [String: String]?,
        message: String,
        method: String
    ) -> LingFansIconSnapshot {
        guard let values else {
            return LingFansIconSnapshot(success: false, message: message)
        }

        guard let decoded = decode(values["payloadBase64"] ?? "") else {
            // 没有 payload 可能是老版本桌面，不支持图标定制
            let upgrade = isUnsupported(values["message"] ?? message, method: method)
            return LingFansIconSnapshot(
                success: false,
                message: upgrade
                    ? "当前车机端菱粉桌面版本不支持图标定制，请升级车机端菱粉桌面后重试"
                    : (values["message"].flatMap { $0.isEmpty ? nil : $0 } ?? "读取菱粉图标配置失败"),
                requiresLauncherUpgrade: upgrade
            )
        }

        return LingFansIconSnapshot(
            success: true,
            iconBaseDir: decoded.baseDir,
            iconPreviewBaseDir: decoded.previewBaseDir,
            items: decoded.items,
            message: values["message"].flatMap { $0.isEmpty ? nil : $0 } ?? "ok"
        )
    }

    /// 原版 isUnsupportedLingFansIconMethod：只有图标四个方法才判「版本过旧」
    static func isUnsupported(_ message: String, method: String) -> Bool {
        let iconMethods = [
            "getLaunchableAppIcons",
            "setLaunchableAppIcon",
            "resetLaunchableAppIcon",
            "refreshLaunchableAppIcons",
        ]
        guard iconMethods.contains(method) else { return false }
        guard !message.isEmpty else { return false }

        let lower = message.lowercased()
        return lower.contains("unknown method")
            || lower.contains("no such method")
            || lower.contains("unsupported")
            || lower.contains("not supported")
            || lower.contains("method not found")
    }
}
