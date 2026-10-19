import Foundation

/// 菱粉联动数据层
///
/// 这是这个工具的核心差异化功能：通过 `content call` 直接驱动菱粉桌面
/// （com.zzh.launcher50s）的内部 Provider，做天气 Key、语音定制、图标替换。
///
/// 协议（从原版 LingFansLinkSupport.kt 逐字提取）：
///   content call --user 0 --uri content://<authority> --method <method>
///                [--arg "<arg>"]
///                [--extra "<key>:s:<value>"]...
///
/// authority：com.zzh.launcher50s.alpha.link（新）/ com.zzh.launcher50s.link（旧）
/// 返回：Result: Bundle[{key=value, ...}]，需要自己解析（不能 JSON 解）
///
/// ⚠️ 返回值格式必须在真车机上验证。这里做了宽容解析，
/// 解析不出来时把原始输出原样展示，方便定位。
@MainActor
final class LinkStore: ObservableObject {

    static let authorityNew = "com.zzh.launcher50s.alpha.link"
    static let authorityLegacy = "com.zzh.launcher50s.link"
    static let launcherPackage = "com.zzh.launcher50s.alpha"
    static let extraTypeString = "s"

    /// 探测到的可用 authority
    @Published private(set) var authority: String?
    @Published private(set) var available = false
    @Published private(set) var probing = false

    /// 桌面版本信息
    @Published private(set) var versionInfo: [String: String] = [:]
    /// 激活状态
    @Published private(set) var activationInfo: [String: String] = [:]
    /// 天气配置
    @Published private(set) var weatherApiKey: String = ""
    @Published private(set) var weatherHost: String = ""
    /// 语音定制项
    @Published private(set) var voiceItems: [String: String] = [:]
    /// 可替换图标的 App
    @Published private(set) var appIcons: [String: String] = [:]

    /// 原始输出，用于排查格式不符
    @Published private(set) var lastRawOutput: String = ""
    @Published private(set) var busyMessage: String?
    @Published private(set) var errorMessage: String?

    var isDemo = false
    private let adb = AdbService.shared

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - 探测

    /// 探测菱粉桌面是否存在，并确定用哪个 authority
    func probe() async {
        probing = true
        errorMessage = nil
        defer { probing = false }

        if isDemo {
            authority = Self.authorityNew
            available = true
            loadDemo()
            return
        }

        // 先看包在不在
        let pkgs = await shellLines("pm list packages \(Self.launcherPackage) 2>/dev/null")
        guard pkgs.contains(where: { $0.contains(Self.launcherPackage) }) else {
            available = false
            authority = nil
            errorMessage = "未检测到菱粉桌面（\(Self.launcherPackage)）。此功能仅对菱粉定制车机有效。"
            return
        }

        // 依次试两个 authority，谁能返回非空结果就用谁
        for candidate in [Self.authorityNew, Self.authorityLegacy] {
            let out = await call(method: "getLauncherVersionInfo",
                                 authority: candidate)
            if !out.isEmpty {
                authority = candidate
                available = true
                versionInfo = out
                lastRawOutput = out.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                return
            }
        }

        // 包在但两个 authority 都无响应
        available = false
        authority = nil
        errorMessage = "菱粉桌面已安装，但 Provider 无响应。可能桌面版本过旧或未授权。"
    }

    // MARK: - 各项读取

    func loadActivation() async {
        guard let auth = authority else { return }
        busyMessage = "读取激活状态…"
        defer { busyMessage = nil }
        activationInfo = await call(method: "getActivationStatus", authority: auth)
    }

    func loadWeather() async {
        guard let auth = authority else { return }
        busyMessage = "读取天气配置…"
        defer { busyMessage = nil }
        let out = await call(method: "getWeatherApiKey", authority: auth)
        weatherApiKey = out["apiKey"] ?? ""
        weatherHost = out["host"] ?? ""
    }

    func loadVoice() async {
        guard let auth = authority else { return }
        busyMessage = "读取语音定制…"
        defer { busyMessage = nil }
        voiceItems = await call(method: "getVoiceCustomizations", authority: auth)
    }

    func loadIcons() async {
        guard let auth = authority else { return }
        busyMessage = "读取图标定制…"
        defer { busyMessage = nil }
        appIcons = await call(method: "getLaunchableAppIcons", authority: auth)
    }

    // MARK: - 各项写入

    /// 设置天气 API Key。原版要求同时带 host。
    func setWeather(apiKey: String, host: String) async -> Bool {
        guard let auth = authority else { return false }
        busyMessage = "写入天气配置…"
        defer { busyMessage = nil }

        let out = await call(
            method: "setWeatherApiKey",
            authority: auth,
            extras: [("apiKey", apiKey), ("host", host)]
        )
        if out.isEmpty {
            // 有些实现无返回，视为成功但需复核
            await loadWeather()
            return weatherApiKey == apiKey
        }
        await loadWeather()
        return weatherApiKey == apiKey
    }

    /// 重置某一项语音定制
    func resetVoice(key: String) async -> Bool {
        guard let auth = authority else { return false }
        busyMessage = "重置语音定制…"
        defer { busyMessage = nil }
        _ = await call(method: "resetVoiceCustomization", authority: auth,
                       extras: [("key", key)])
        await loadVoice()
        return true
    }

    /// 重置某个 App 的图标
    func resetIcon(package: String) async -> Bool {
        guard let auth = authority else { return false }
        busyMessage = "重置图标…"
        defer { busyMessage = nil }
        _ = await call(method: "resetLaunchableAppIcon", authority: auth,
                       extras: [("package", package)])
        await loadIcons()
        return true
    }

    /// 让桌面刷新图标缓存
    func refreshIcons() async {
        guard let auth = authority else { return }
        busyMessage = "刷新图标缓存…"
        defer { busyMessage = nil }
        _ = await call(method: "refreshLaunchableAppIcons", authority: auth)
        await loadIcons()
    }

    // MARK: - 协议实现

    /// 拼 content call 命令
    ///
    /// 参数转义：单引号包裹整个 arg，内部单引号用 '\'' 处理。
    /// 原版用双引号，但 shell 里双引号仍会解释 $ 和反引号，
    /// 单引号更安全（天气 Key 里可能含特殊字符）。
    private func buildCommand(authority: String,
                              method: String,
                              arg: String?,
                              extras: [(String, String)]) -> String {
        var parts = ["content call --user 0 --uri content://\(authority) --method \(method)"]
        if let arg, !arg.isEmpty {
            parts.append("--arg \(shellQuote(arg))")
        }
        for (key, value) in extras {
            parts.append("--extra \(shellQuote("\(key):\(Self.extraTypeString):\(value)"))")
        }
        return parts.joined(separator: " ")
    }

    /// 单引号转义：把 ' 变成 '\''
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func call(method: String,
                      authority: String,
                      arg: String? = nil,
                      extras: [(String, String)] = []) async -> [String: String] {
        let cmd = buildCommand(authority: authority, method: method, arg: arg, extras: extras)
        let lines = await shellLines(cmd)
        let raw = lines.joined(separator: "\n")
        lastRawOutput = raw

        if raw.lowercased().contains("error") || raw.lowercased().contains("exception") {
            errorMessage = raw
            return [:]
        }
        return parseBundle(raw)
    }

    /// 解析 `Result: Bundle[{key=value, k2=v2}]`
    ///
    /// 不能按逗号粗暴切分 —— 值里可能含逗号（例如 JSON）。
    /// 原版的做法是跟踪 {} [] 深度，只在深度 0 且后跟空格时切。
    private func parseBundle(_ output: String) -> [String: String] {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }

        for prefix in ["Result: ", "Bundle["] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix("]") { text.removeLast() }
        if text.hasPrefix("{") { text.removeFirst() }
        if text.hasSuffix("}") { text.removeLast() }

        let body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return [:] }

        // 深度感知切分
        var parts: [String] = []
        var current = ""
        var bracket = 0
        var brace = 0
        let chars = Array(body)
        for i in 0..<chars.count {
            let c = chars[i]
            if c == "[" { bracket += 1 }
            if c == "]" { bracket = max(0, bracket - 1) }
            if c == "{" { brace += 1 }
            if c == "}" { brace = max(0, brace - 1) }

            if c == "," && bracket == 0 && brace == 0 {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next == " " {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(c)
        }
        if !current.isEmpty { parts.append(current) }

        var result: [String: String] = [:]
        for part in parts {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard let eq = item.firstIndex(of: "="), eq != item.startIndex else { continue }
            let key = String(item[item.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }

    // MARK: - 演示

    private func loadDemo() {
        versionInfo = ["version": "2.14.3", "buildType": "release", "protocol": "alpha"]
        activationInfo = ["activated": "true", "expireAt": "长期", "deviceId": "DEMO0000000001"]
        weatherApiKey = "b2f4c8e19c1d"
        weatherHost = "api.seniverse.com"
        voiceItems = [
            "wakeWord": "你好小菱",
            "ttsVoice": "女声-柔和",
            "volume": "70",
        ]
        appIcons = [
            "com.sgmw.navi": "默认",
            "com.sgmw.carradio": "自定义-1",
            "com.android.settings": "默认",
        ]
        lastRawOutput = "Result: Bundle[{version=2.14.3, buildType=release, protocol=alpha}]"
        errorMessage = nil
    }
}
