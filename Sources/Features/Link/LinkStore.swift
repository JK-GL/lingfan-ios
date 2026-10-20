import Foundation

/// 菱粉联动数据层
///
/// 逐行对照原版 LingFansLinkSupport.kt 实现，不做任何猜测。
///
/// 协议：content call --uri content://<authority> --method <M> [--arg x] [--extra "k:s:v"]
///
/// 四条关键规则（全部来自源码）：
///   1. 主键走 `arg`（位置参数），不是 extras
///   2. extras 只放附属字段，字段名必须精确匹配
///   3. 成功判定看返回里的 `ok` 布尔值，不是看有没有 "error" 字样
///   4. user 依次试 null → current → 0（不同 ROM 权限域不同）
final class LinkStore: ObservableObject {

    // MARK: - 常量（对齐原版 21-26 行）

    static let authorityNew = "com.zzh.launcher50s.alpha.link"
    static let authorityLegacy = "com.zzh.launcher50s.link"
    static let launcherPackage = "com.zzh.launcher50s.alpha"
    static let extraTypeString = "s"
    /// 联动功能要求的最低桌面版本（原版 LINGFANS_LINK_MIN_VERSION）
    static let minVersion = "3.1.1"

    // MARK: - 状态

    @Published private(set) var authority: String?
    @Published private(set) var available = false
    @Published private(set) var probing = false

    @Published private(set) var versionName = ""
    @Published private(set) var versionCode: Int64 = -1
    @Published private(set) var versionTooLow = false
    @Published private(set) var activated = false
    @Published private(set) var activationMessage = ""

    @Published private(set) var weatherApiKey = ""
    @Published private(set) var weatherHost = ""

    @Published private(set) var voiceItems: [String: String] = [:]
    @Published private(set) var appIcons: [String: String] = [:]

    @Published private(set) var lastRawOutput = ""
    @Published private(set) var busyMessage: String?
    @Published private(set) var errorMessage: String?

    var isDemo = false
    private let adb = AdbService.shared

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - 日志抓取（原版 LingFansLogCaptureSupport）

    @Published private(set) var logCapturing = false
    @Published private(set) var logPreview = ""
    @Published private(set) var logMessage = ""
    @Published private(set) var logExportPath: String?
    @Published private(set) var logMatchedCount = 0
    @Published private(set) var logScannedCount = 0

    /// 抓取近 3 分钟菱粉桌面相关日志。
    /// 三级回退全部在 LingFansLogCapture 里，这里只负责接 shell 和落盘。
    func captureLogs() async {
        logCapturing = true
        logMessage = ""
        logPreview = ""
        logExportPath = nil
        defer { logCapturing = false }

        if isDemo {
            let now = Date()
            let f = LingFansLog.summaryFormatter
            let start = f.string(from: now.addingTimeInterval(-180))
            let end = f.string(from: now)
            logPreview = """
            LingFans 日志抓取
            时间范围: \(start) 至 \(end)
            目标包名: \(Self.launcherPackage)
            结果摘要: 已抓到 6 条菱粉桌面相关日志
            logcat 回退: 未触发
            命中条数: 6

            10-19 20:18:04.123  4211  4250 I Launcher: voice customization loaded
            10-19 20:18:06.882  4211  4211 I Launcher: icon refresh requested
            10-19 20:18:11.201  4211  4302 D Launcher: weather api key applied
            10-19 20:18:15.640  4211  4211 I Launcher: activation status ok
            10-19 20:18:19.004  4211  4250 W Launcher: preview cache miss
            10-19 20:18:22.377  4211  4211 I Launcher: ready
            """
            logMatchedCount = 6
            logScannedCount = 4821
            logMessage = "已抓到 6 条菱粉桌面相关日志（演示）"
            return
        }

        let capture = LingFansLogCapture { [weak self] cmd in
            guard let self else { return [] }
            return await self.shellLines(cmd)
        }
        let result = await capture.run()

        logPreview = result.previewText
        logMessage = result.message
        logMatchedCount = result.matchedCount
        logScannedCount = result.scannedCount
        logExportPath = writeLogExport(result.exportText)
    }

    /// 导出到 Documents/pulled，供分享面板取用。
    /// 这里不用 FilesStore.localPullDirectory()：那是主线程隔离的静态方法，
    /// LinkStore 不在主 actor 上，同步调用会编译失败。
    private func writeLogExport(_ text: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pulled", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("lingfans_log_\(formatter.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - 探测

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

        let pkgs = await shellLines("pm list packages \(Self.launcherPackage) 2>/dev/null")
        guard pkgs.contains(where: { $0.contains(Self.launcherPackage) }) else {
            available = false
            errorMessage = "未检测到菱粉桌面（\(Self.launcherPackage)）。此功能仅对菱粉定制车机有效。"
            return
        }

        let info = await request(method: "getLauncherVersionInfo")
        guard let info else {
            errorMessage = "菱粉桌面已安装，但 Provider 无响应。桌面版本可能过旧。"
            return
        }

        versionName = info["versionName"] ?? ""
        versionCode = Int64(info["versionCode"] ?? "") ?? -1

        // 版本门槛：低于 3.1.1 联动接口不可用
        if !versionName.isEmpty && !Self.meetsMinimum(versionName) {
            versionTooLow = true
            errorMessage = "联动功能需要菱粉桌面 \(Self.minVersion) 及以上，当前 \(versionName)。"
        } else {
            versionTooLow = false
        }
        available = true
    }

    /// 版本比较：逐段数字对比，缺失段按 0
    static func meetsMinimum(_ version: String) -> Bool {
        let cur = version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let min = minVersion.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !cur.isEmpty, !min.isEmpty else { return false }
        for i in 0..<max(cur.count, min.count) {
            let a = i < cur.count ? cur[i] : 0
            let b = i < min.count ? min[i] : 0
            if a != b { return a > b }
        }
        return true
    }

    // MARK: - 读取

    func loadActivation() async {
        let r = await request(method: "getActivationStatus")
        guard let r else { return }
        activated = (r["activated"]?.lowercased() == "true")
        activationMessage = r["message"] ?? (activated ? "ok" : "需桌面激活")
    }

    func loadWeather() async {
        let r = await request(method: "getWeatherApiKey")
        guard let r else { return }
        weatherApiKey = (r["apiKey"] ?? "").trimmingCharacters(in: .whitespaces)
        weatherHost = (r["host"] ?? "").trimmingCharacters(in: .whitespaces)
    }

    func loadVoice() async {
        voiceItems = await request(method: "getVoiceCustomizations") ?? [:]
    }

    func loadIcons() async {
        appIcons = await request(method: "getLaunchableAppIcons") ?? [:]
    }

    // MARK: - 写入（参数与原版逐字一致）

    /// 原版 244 行：arg = apiKey，extras 只有 host
    func setWeather(apiKey: String, host: String) async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            errorMessage = "API Key 不能为空"
            return false
        }

        busyMessage = "写入天气配置…"
        defer { busyMessage = nil }

        let r = await request(
            method: "setWeatherApiKey",
            arg: key,
            extras: [("host", h)]
        )
        await loadWeather()
        // 以回读结果为准，不信单次回执
        return weatherApiKey == key
    }

    /// 原版 273 行：arg = key，extras 为空
    func resetVoice(key: String) async -> Bool {
        busyMessage = "重置语音定制…"
        defer { busyMessage = nil }
        _ = await request(method: "resetVoiceCustomization", arg: key, extras: [])
        await loadVoice()
        return true
    }

    /// 原版 318 行：arg = packageName，extras 也带 packageName
    func resetIcon(package: String) async -> Bool {
        busyMessage = "重置图标…"
        defer { busyMessage = nil }
        _ = await request(
            method: "resetLaunchableAppIcon",
            arg: package,
            extras: [("packageName", package)]
        )
        await loadIcons()
        return true
    }

    /// 原版 332 行：无 arg 无 extras
    func refreshIcons() async {
        busyMessage = "刷新图标缓存…"
        defer { busyMessage = nil }
        _ = await request(method: "refreshLaunchableAppIcons")
        await loadIcons()
    }

    /// 原版 421 行：arg = key
    func exportVoicePreview(key: String) async -> String? {
        busyMessage = "导出语音预览…"
        defer { busyMessage = nil }
        let r = await request(method: "exportVoicePreview", arg: key, extras: [])
        return r?["path"]
    }

    /// 原版 431 行：arg = key
    func playVoicePreview(key: String) async -> Bool {
        busyMessage = "车机播放预览…"
        defer { busyMessage = nil }
        let r = await request(method: "playVoicePreviewOnDevice", arg: key, extras: [])
        return r != nil
    }

    // MARK: - 协议实现

    /// 原版 457-530 行的完整回退链
    private func request(method: String,
                         arg: String? = nil,
                         extras: [(String, String)] = []) async -> [String: String]? {
        let authorities = [Self.authorityNew, Self.authorityLegacy]
        var lastMessage = "调用菱粉联动接口失败"

        for auth in authorities {
            // 三级 user 回退：null → current → 0
            let users: [String?] = [nil, "current", "0"]
            for user in users {
                let cmd = buildCommand(authority: auth, method: method,
                                       arg: arg, extras: extras, user: user)
                let lines = await shellLines(cmd)
                let raw = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                lastRawOutput = raw

                guard !raw.isEmpty else {
                    lastMessage = "无输出"
                    continue
                }

                let values = parseBundle(raw)
                let message = values["message"].flatMap { $0.isEmpty ? nil : $0 } ?? raw

                // 成功判定：ok == true（原版 507 行）
                if values["ok"]?.lowercased() == "true" {
                    authority = auth
                    available = true
                    errorMessage = nil
                    return values
                }

                lastMessage = message

                // 只有「找不到 provider」才换 authority；
                // 其他错误（权限拒绝等）属真实失败，不该继续重试
                if !message.lowercased().contains("could not find provider") {
                    errorMessage = message
                    return nil
                }
            }
        }

        // 全部失败：区分是 provider 缺失还是别的原因
        if lastMessage.lowercased().contains("could not find provider") {
            errorMessage = "菱粉桌面 Provider 未注册。请确认桌面版本 ≥ \(Self.minVersion)。"
        } else if errorMessage == nil {
            errorMessage = lastMessage
        }
        return nil
    }

    /// 命令拼接（原版 528-560 行）
    private func buildCommand(authority: String,
                              method: String,
                              arg: String?,
                              extras: [(String, String)],
                              user: String?) -> String {
        var parts = ["content call"]
        if let user, !user.isEmpty {
            parts.append("--user \(user)")
        }
        parts.append("--uri content://\(authority)")
        parts.append("--method \(method)")

        if let arg, !arg.isEmpty {
            parts.append("--arg \(shellQuote(arg))")
        }
        for (key, value) in extras {
            parts.append("--extra \(shellQuote("\(key):\(Self.extraTypeString):\(value)"))")
        }
        return parts.joined(separator: " ")
    }

    /// 单引号转义。原版用双引号，但双引号会解释 $ 和反引号，
    /// 天气 Key 里可能含这类字符，单引号更安全。
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 解析 `Result: Bundle[{k=v, k2=v2}]`
    ///
    /// 按 {} [] 深度切分，不能粗暴 split 逗号 —— 值里可能含逗号。
    /// 原版 564-605 行就是这个算法。
    private func parseBundle(_ output: String) -> [String: String] {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }

        if text.hasPrefix("Result: ") { text.removeFirst("Result: ".count) }
        if text.hasPrefix("Bundle[") { text.removeFirst("Bundle[".count) }
        if text.hasSuffix("]") { text.removeLast() }
        if text.hasPrefix("{") { text.removeFirst() }
        if text.hasSuffix("}") { text.removeLast() }

        let body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return [:] }

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
        versionName = "3.2.4"
        versionCode = 3204
        versionTooLow = false
        activated = true
        activationMessage = "ok"
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
        lastRawOutput = "Result: Bundle[{ok=true, versionName=3.2.4, versionCode=3204}]"
        errorMessage = nil
    }
}
