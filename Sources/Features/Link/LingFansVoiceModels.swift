import Foundation

/// 菱粉语音定制模型
///
/// 对齐原版 `LingFansLinkSupport.kt`：
/// `getVoiceCustomizations` 同样把数据放在 `payloadBase64` 里，解开是
/// `{ "voiceBaseDir": "...", "items": { "<key>": "<远程路径>", ... } }`。
///
/// 键位顺序和中文标题由客户端固定（原版 voiceItemTitles），
/// 车机只回路径，不回标题 —— 所以列表必须以这 14 个键为准，
/// 不能拿 items 字典的 key 直接遍历（顺序会乱，缺项也没法显示）。
enum LingFansVoice {

    /// 顺序必须与原版 linkedMapOf 一致
    static let titles: [(key: String, title: String)] = [
        ("gear_p_path", "P 挡语音"),
        ("gear_r_path", "R 挡语音"),
        ("gear_n_path", "N 挡语音"),
        ("gear_d_path", "D 挡语音"),
        ("door_front_left_path", "左前门开门语音"),
        ("door_front_right_path", "右前门开门语音"),
        ("door_rear_left_path", "左后门开门语音"),
        ("door_rear_right_path", "右后门开门语音"),
        ("door_tailgate_path", "后备箱开门语音"),
        ("door_close_front_left_path", "左前门关门语音"),
        ("door_close_front_right_path", "右前门关门语音"),
        ("door_close_rear_left_path", "左后门关门语音"),
        ("door_close_rear_right_path", "右后门关门语音"),
        ("door_close_tailgate_path", "后备箱关门语音"),
    ]

    /// 支持的音频扩展名（原版）
    static let audioExtensions: Set<String> = [
        "mp3", "wav", "ogg", "flac", "aac", "m4a", "3gp",
    ]
}

struct LingFansVoiceItem: Identifiable, Hashable {
    let key: String
    let title: String
    /// 车机上当前使用的音频路径，空表示用默认语音
    let path: String

    var id: String { key }

    var hasCustom: Bool { !path.isEmpty }
}

struct LingFansVoiceSnapshot {
    var success: Bool = false
    var voiceBaseDir: String = ""
    var items: [LingFansVoiceItem] = []
    var message: String = ""
}

enum LingFansVoicePayload {

    /// 解 payloadBase64 → (voiceBaseDir, items 字典)
    static func decode(_ base64: String) -> (baseDir: String, paths: [String: String])? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let baseDir = (obj["voiceBaseDir"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let itemsObj = obj["items"] as? [String: Any] ?? [:]

        var paths: [String: String] = [:]
        for (k, v) in itemsObj {
            if let s = v as? String {
                paths[k] = s.trimmingCharacters(in: .whitespaces)
            }
        }
        return (baseDir, paths)
    }

    /// 预览接口的 payload：`{title, sourceType, previewPath, activePath}`
    struct PreviewInfo {
        let title: String
        let sourceType: String
        let previewPath: String
        let activePath: String
    }

    static func decodePreview(_ base64: String) -> PreviewInfo? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return PreviewInfo(
            title: obj["title"] as? String ?? "",
            sourceType: obj["sourceType"] as? String ?? "",
            previewPath: obj["previewPath"] as? String ?? "",
            activePath: obj["activePath"] as? String ?? ""
        )
    }

    /// 用固定的 14 个键生成列表（原版逻辑）
    static func snapshot(
        from values: [String: String]?,
        fallbackMessage: String
    ) -> LingFansVoiceSnapshot {
        guard let values else {
            return LingFansVoiceSnapshot(success: false, message: fallbackMessage)
        }

        guard let decoded = decode(values["payloadBase64"] ?? "") else {
            return LingFansVoiceSnapshot(
                success: false,
                message: values["message"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? "读取菱粉语音配置失败"
            )
        }

        let items = LingFansVoice.titles.map { entry in
            LingFansVoiceItem(
                key: entry.key,
                title: entry.title,
                path: decoded.paths[entry.key] ?? ""
            )
        }

        return LingFansVoiceSnapshot(
            success: true,
            voiceBaseDir: decoded.baseDir,
            items: items,
            message: values["message"].flatMap { $0.isEmpty ? nil : $0 } ?? "ok"
        )
    }
}
