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
    /// 原版 EXPIRING_BUILTIN_WEATHER_API_KEY：命中就提示即将失效
    static let expiringBuiltinKey = "3e1ecaf39ab24b20b4f0b0f39139a9b3"
    /// 原版 EXPIRING_BUILTIN_WEATHER_API_HOST
    static let expiringBuiltinHost = "ng4jabbwcx.re.qweatherapi.com"

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

    @Published private(set) var voiceSnapshot = LingFansVoiceSnapshot()
    @Published private(set) var iconSnapshot = LingFansIconSnapshot()

    var voiceItems: [LingFansVoiceItem] { voiceSnapshot.items }
    var iconItems: [LingFansIconItem] { iconSnapshot.items }

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
        let values = await request(method: "getVoiceCustomizations")
        voiceSnapshot = LingFansVoicePayload.snapshot(
            from: values,
            fallbackMessage: errorMessage ?? "读取菱粉语音配置失败"
        )
    }

    func loadIcons() async {
        let values = await request(method: "getLaunchableAppIcons")
        iconSnapshot = LingFansIconPayload.snapshot(
            from: values,
            message: errorMessage ?? "",
            method: "getLaunchableAppIcons"
        )
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

        if isDemo {
            if let i = voiceSnapshot.items.firstIndex(where: { $0.key == key }) {
                let o = voiceSnapshot.items[i]
                voiceSnapshot.items[i] = LingFansVoiceItem(key: o.key, title: o.title, path: "")
            }
            return true
        }

        let values = await request(method: "resetVoiceCustomization", arg: key, extras: [])
        let snap = LingFansVoicePayload.snapshot(
            from: values, fallbackMessage: errorMessage ?? "恢复默认语音失败"
        )
        if snap.success { voiceSnapshot = snap } else { await loadVoice() }
        return snap.success
    }

    /// 原版 318 行：arg = packageName，extras 也带 packageName
    func resetIcon(package: String) async -> Bool {
        busyMessage = "重置图标…"
        defer { busyMessage = nil }

        if isDemo {
            if let i = iconSnapshot.items.firstIndex(where: { $0.packageName == package }) {
                let o = iconSnapshot.items[i]
                iconSnapshot.items[i] = LingFansIconItem(
                    packageName: o.packageName, appLabel: o.appLabel,
                    launchActivity: o.launchActivity, hasCustomIcon: false,
                    customIconPath: "", sourceIconPath: "",
                    roundedCropEnabled: false, cornerRadiusFraction: 0,
                    assetKind: LingFansIcon.assetKindSourceSquare,
                    previewPath: "", applicationId: o.applicationId
                )
            }
            return true
        }

        let values = await request(
            method: "resetLaunchableAppIcon",
            arg: package,
            extras: [("packageName", package)]
        )
        let snapshot = LingFansIconPayload.snapshot(
            from: values, message: errorMessage ?? "", method: "resetLaunchableAppIcon"
        )
        if snapshot.success { iconSnapshot = snapshot } else { await loadIcons() }
        return snapshot.success
    }

    /// 原版 332 行：无 arg 无 extras
    func refreshIcons() async {
        busyMessage = "刷新图标缓存…"
        defer { busyMessage = nil }
        _ = await request(method: "refreshLaunchableAppIcons")
        await loadIcons()
    }

    /// 设置自定义图标。
    /// 完整链路（原版 uploadLingFansIconFile + updateLingFansLaunchableAppIcon）：
    ///   1. push 本地图片 → <iconBaseDir>/<pkg>_icon_<时间戳>.<ext>
    ///   2. chmod 644
    ///   3. ls 校验确实写进去了
    ///   4. setLaunchableAppIcon：arg=pkg，extras 五个字段全带
    func setIcon(
        package: String,
        localImagePath: String,
        rounded: Bool,
        radius: Double
    ) async -> String? {
        guard !iconSnapshot.iconBaseDir.isEmpty else {
            return "车机未返回可写入的图标目录，无法设置"
        }

        let ext = (localImagePath as NSString).pathExtension.lowercased()
        let allowed = ["png", "jpg", "jpeg", "webp", "bmp", "gif", "ico"]
        guard allowed.contains(ext) else {
            return "仅支持 png、jpg、jpeg、webp、bmp、gif、ico 图标文件"
        }
        guard FileManager.default.isReadableFile(atPath: localImagePath) else {
            return "裁剪结果文件不存在或不可读"
        }

        busyMessage = "上传图标…"
        defer { busyMessage = nil }

        if isDemo {
            if let i = iconSnapshot.items.firstIndex(where: { $0.packageName == package }) {
                let o = iconSnapshot.items[i]
                iconSnapshot.items[i] = LingFansIconItem(
                    packageName: o.packageName, appLabel: o.appLabel,
                    launchActivity: o.launchActivity, hasCustomIcon: true,
                    customIconPath: "/data/.../custom.png", sourceIconPath: "/data/.../src.png",
                    roundedCropEnabled: rounded,
                    cornerRadiusFraction: min(max(radius, 0), 0.5),
                    assetKind: LingFansIcon.assetKindSourceSquare,
                    previewPath: "", applicationId: o.applicationId
                )
            }
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let safePkg = package.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression
        )
        let fileName = "\(safePkg)_icon_\(stamp).\(ext)"

        let dir = iconSnapshot.iconBaseDir.hasSuffix("/")
            ? String(iconSnapshot.iconBaseDir.dropLast())
            : iconSnapshot.iconBaseDir
        let remotePath = "\(dir)/\(fileName)"

        // 1. 确保目录存在
        _ = await shellLines("mkdir -p \(Self.quote(dir))")

        // 2. push + 双检（失败自动清残留并重推一次）
        if let err = await pushAndVerify(localPath: localImagePath,
                                         remotePath: remotePath,
                                         label: "图标") {
            return err
        }

        // 3. 权限（车机上别的 App 要能读）
        _ = await shellLines("chmod 644 \(Self.quote(remotePath))")

        // 4. 通知车机
        busyMessage = "应用图标…"
        let values = await request(
            method: "setLaunchableAppIcon",
            arg: package,
            extras: [
                ("packageName", package),
                ("path", remotePath),
                ("roundedCropEnabled", rounded ? "true" : "false"),
                ("cornerRadiusFraction", String(format: "%.4f", min(max(radius, 0), 0.5))),
                ("assetKind", LingFansIcon.assetKindSourceSquare),
            ]
        )

        let snapshot = LingFansIconPayload.snapshot(
            from: values, message: errorMessage ?? "", method: "setLaunchableAppIcon"
        )
        if snapshot.success {
            iconSnapshot = snapshot
            return nil
        }
        await loadIcons()
        let raw = snapshot.message.isEmpty ? "设置图标失败" : snapshot.message
        return Self.friendlyMessage(raw, method: "setLaunchableAppIcon")
    }

    /// POSIX 单引号转义（原版 escapeRemotePath）
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // MARK: - 图标包导入 / 导出

    @Published private(set) var iconPackBusy = false
    @Published private(set) var iconPackMessage: String?
    @Published private(set) var iconPackExportURL: URL?

    /// 导出当前所有自定义图标为 ZIP
    func exportIconPack() async {
        iconPackBusy = true
        iconPackMessage = nil
        iconPackExportURL = nil
        defer { iconPackBusy = false }

        if isDemo {
            iconPackMessage = "演示模式不导出图标包"
            return
        }

        let result = await LingFansIconPack.export(items: iconItems) { [weak self] remote in
            await self?.pullToTemp(remote)
        }
        iconPackMessage = result.message
        iconPackExportURL = result.fileURL
    }

    /// 导入图标包并逐个应用。返回 (成功数, 失败信息)
    @discardableResult
    func importIconPack(fileURL: URL) async -> (Int, [String]) {
        iconPackBusy = true
        iconPackMessage = nil
        defer { iconPackBusy = false }

        if isDemo {
            iconPackMessage = "演示模式不导入图标包"
            return (0, [])
        }

        let read = LingFansIconPack.read(fileURL: fileURL)
        guard read.success else {
            iconPackMessage = read.message
            return (0, [read.message])
        }

        var success = 0
        var failures: [String] = []

        for entry in read.entries {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("pack_\(UUID().uuidString).png")
            do {
                try entry.pngData.write(to: tmp, options: .atomic)
            } catch {
                failures.append("\(entry.packageName)：写入临时文件失败")
                continue
            }

            if let err = await setIcon(
                package: entry.packageName,
                localImagePath: tmp.path,
                rounded: entry.roundedCropEnabled,
                radius: entry.cornerRadiusFraction
            ) {
                failures.append("\(entry.packageName)：\(err)")
            } else {
                success += 1
            }
            try? FileManager.default.removeItem(at: tmp)
        }

        iconPackMessage = "导入完成：成功 \(success) 个"
            + (failures.isEmpty ? "" : "，失败 \(failures.count) 个")
        await loadIcons()
        return (success, failures)
    }

    /// 把远程文件拉到本地临时文件，返回本地路径
    private func pullToTemp(_ remotePath: String) async -> String? {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull_\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: dest)

        _ = await runCommand(["pull", remotePath, dest.path])

        return FileManager.default.fileExists(atPath: dest.path) ? dest.path : nil
    }

    /// 原版 421 行：arg = key
    func exportVoicePreview(key: String) async -> String? {
        busyMessage = "导出语音预览…"
        defer { busyMessage = nil }
        return await fetchPreviewPath(key: key)
    }

    /// exportVoicePreview 的返回值同样是 payloadBase64，
    /// 里面才有 previewPath（原版 toVoicePreviewResult）
    private func fetchPreviewPath(key: String) async -> String? {
        let values = await request(method: "exportVoicePreview", arg: key, extras: [])
        guard let values else { return nil }
        guard let decoded = LingFansVoicePayload.decodePreview(values["payloadBase64"] ?? "") else {
            return nil
        }
        return decoded.previewPath.isEmpty ? nil : decoded.previewPath
    }

    /// 拉预览到本机，供手机端播放
    func pullVoicePreview(key: String) async -> String? {
        busyMessage = "取回预览…"
        defer { busyMessage = nil }

        if isDemo { return nil }

        guard let remote = await fetchPreviewPath(key: key) else { return nil }
        let ext = (remote as NSString).pathExtension.isEmpty
            ? "mp3" : (remote as NSString).pathExtension

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(key)_preview.\(ext)")
        try? FileManager.default.removeItem(at: dest)

        _ = await runCommand(["pull", remote, dest.path])
        return FileManager.default.fileExists(atPath: dest.path) ? dest.path : nil
    }

    /// 上传自定义语音并写入配置。
    /// 原版 uploadLingFansVoiceFile + updateLingFansVoiceCustomization：
    ///   push → chmod 644 → ls 校验 → setVoiceCustomization(arg=key, extras=[path])
    func uploadVoice(key: String, localPath: String) async -> String? {
        guard !voiceSnapshot.voiceBaseDir.isEmpty else {
            return "车机未返回可写入的语音目录"
        }

        let ext = (localPath as NSString).pathExtension.lowercased()
        guard LingFansVoice.audioExtensions.contains(ext) else {
            return "仅支持 mp3、wav、ogg、flac、aac、m4a、3gp 音频文件"
        }
        guard FileManager.default.isReadableFile(atPath: localPath) else {
            return "音频文件不可读"
        }

        busyMessage = "上传语音…"
        defer { busyMessage = nil }

        if isDemo {
            if let i = voiceSnapshot.items.firstIndex(where: { $0.key == key }) {
                let o = voiceSnapshot.items[i]
                voiceSnapshot.items[i] = LingFansVoiceItem(
                    key: o.key, title: o.title, path: "/data/voice/\(key).\(ext)"
                )
            }
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())

        let dir = voiceSnapshot.voiceBaseDir.hasSuffix("/")
            ? String(voiceSnapshot.voiceBaseDir.dropLast())
            : voiceSnapshot.voiceBaseDir
        let remotePath = "\(dir)/\(key)_\(stamp).\(ext)"

        _ = await shellLines("mkdir -p \(Self.quote(dir))")

        if let err = await pushAndVerify(localPath: localPath,
                                         remotePath: remotePath,
                                         label: "音频") {
            return err
        }

        _ = await shellLines("chmod 644 \(Self.quote(remotePath))")

        busyMessage = "写入语音配置…"
        let values = await request(
            method: "setVoiceCustomization",
            arg: key,
            extras: [("path", remotePath)]
        )
        let snap = LingFansVoicePayload.snapshot(
            from: values, fallbackMessage: errorMessage ?? "写入语音配置失败"
        )
        if snap.success {
            voiceSnapshot = snap
            return nil
        }
        await loadVoice()
        return snap.message.isEmpty ? "写入语音配置失败" : snap.message
    }

    /// 原版 431 行：arg = key
    func playVoicePreview(key: String) async -> Bool {
        busyMessage = "车机播放预览…"
        defer { busyMessage = nil }
        if isDemo { return true }
        let values = await request(method: "playVoicePreviewOnDevice", arg: key, extras: [])
        return values != nil
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
                // 上游 LingFansLinkSupport.kt:511 —— 先看退出码，非 0 直接判失败。
                // 以前用 shellLines 只能拿到文本、退出码被丢弃，
                // 于是 content call 失败时也只能在错误输出里瞎解析。
                let (exitOK, output) = await adb.shellAsync(cmd)
                let raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
                lastRawOutput = raw

                guard exitOK else {
                    lastMessage = raw.isEmpty ? "调用失败（无输出，退出码非 0）" : raw
                    continue
                }
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

    /// 走完整 adb 子命令（push / pull 这类不是 shell 的操作）
    private struct LinkCmdResult {
        let success: Bool
        let output: String
    }

    // MARK: - 错误文案（A11）

    /// 上游 `LingFansLinkSupport.kt:150-160`：车机端不支持图标相关方法时，
    /// 原始回执只是 "unsupported method xxx"，看不出是版本问题。
    private static let iconProviderMethods: Set<String> = [
        "getLaunchableAppIcons", "setLaunchableAppIcon",
        "resetLaunchableAppIcon", "refreshLaunchableAppIcons",
    ]

    private static func friendlyMessage(_ message: String, method: String) -> String {
        let lower = message.lowercased()
        if iconProviderMethods.contains(method),
           lower.contains("unsupported method"),
           lower.contains(method.lowercased()) {
            return "当前车机端菱粉桌面版本不支持图标定制，请升级车机端菱粉桌面后重试"
        }
        return message
    }

    // MARK: - 上传校验（A9 / A10）

    /// 上传后双重校验：**退出码 + 字节数**。
    ///
    /// - 退出码对齐上游 `LingFansLinkSupport.kt:414-418`：`ls` 非 0 即失败。
    ///   以前用文本排除法（只查 no such / 空），`Permission denied`、
    ///   `Read-only file system` 都会被当成成功，然后车机侧静默失败。
    /// - 字节数弥补上游靠 Kadb sync 天然保证的一致性：CLI push 在弱网下
    ///   可能「部分写入但退出码非 0、输出又不含 error/failed」，
    ///   车机拿到半张图 → 有时能解码有时不能。
    ///
    /// 返回 nil 表示通过，否则返回可读的错误描述。
    private func verifyUploadedFile(localPath: String,
                                    remotePath: String,
                                    label: String) async -> String? {
        let quoted = Self.quote(remotePath)

        // 1) 存在性 / 可读性：只看退出码
        let (lsOK, _) = await adb.shellAsync("ls \(quoted)")
        guard lsOK else {
            return "\(label)上传后校验失败：文件不存在或不可读"
        }

        // 2) 字节数必须完全一致
        // 少数老 ROM 的 stat 不支持 -c，此时不误判为失败（保留上面的退出码校验即可）
        let (statOK, statOut) = await adb.shellAsync("stat -c %s \(quoted)")
        guard statOK else { return nil }

        let remoteSize = Int64(statOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        let attrs = try? FileManager.default.attributesOfItem(atPath: localPath)
        let localSize = ((attrs?[.size] as? NSNumber)?.int64Value) ?? -1

        guard remoteSize >= 0, remoteSize == localSize else {
            return "\(label)写入不完整（本地 \(localSize) B / 远端 \(remoteSize) B）"
        }
        return nil
    }

    /// 推送 → 校验，失败时清掉残留重推一次。
    /// 返回 nil 表示成功，否则返回最后一次的错误。
    private func pushAndVerify(localPath: String,
                               remotePath: String,
                               label: String) async -> String? {
        var lastError = "\(label)上传失败"

        for attempt in 1...2 {
            let pushResult = await runCommand(["push", localPath, remotePath])
            let text = pushResult.output.lowercased()
            let pushFailed = !pushResult.success
                || text.contains("error")
                || text.contains("failed")
                || text.contains("no such")

            if !pushFailed {
                if let err = await verifyUploadedFile(localPath: localPath,
                                                      remotePath: remotePath,
                                                      label: label) {
                    lastError = err
                } else {
                    return nil
                }
            } else {
                lastError = "\(label)上传失败："
                    + pushResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // 第一次失败：清掉可能残留的半截文件，再重推一次
            if attempt == 1 {
                _ = await adb.shellAsync("rm -f \(Self.quote(remotePath))")
            }
        }
        return lastError
    }

    private func runCommand(_ args: [String]) async -> LinkCmdResult {
        await withCheckedContinuation { (cont: CheckedContinuation<LinkCmdResult, Never>) in
            adb.runAsync(args) { r in
                cont.resume(returning: LinkCmdResult(success: r.success, output: r.output))
            }
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
        voiceSnapshot = LingFansVoiceSnapshot(
            success: true,
            voiceBaseDir: "/sdcard/Android/data/com.zzh.launcher50s.alpha/files/voice",
            items: LingFansVoice.titles.map { entry in
                LingFansVoiceItem(
                    key: entry.key,
                    title: entry.title,
                    path: entry.key == "gear_d_path"
                        ? "/sdcard/Android/data/com.zzh.launcher50s.alpha/files/voice/gear_d_path_20260101_101500.mp3"
                        : ""
                )
            },
            message: "ok"
        )
        iconSnapshot = LingFansIconSnapshot(
            success: true,
            iconBaseDir: "/sdcard/Android/data/com.zzh.launcher50s.alpha/files/icons",
            iconPreviewBaseDir: "/sdcard/Android/data/com.zzh.launcher50s.alpha/files/icon_preview",
            items: [
                LingFansIconItem(
                    packageName: "com.sgmw.navi", appLabel: "高德地图",
                    launchActivity: "com.sgmw.navi.MainActivity",
                    hasCustomIcon: false, customIconPath: "", sourceIconPath: "",
                    roundedCropEnabled: false, cornerRadiusFraction: 0,
                    assetKind: LingFansIcon.assetKindSourceSquare,
                    previewPath: "", applicationId: "com.sgmw.navi"
                ),
                LingFansIconItem(
                    packageName: "com.sgmw.carradio", appLabel: "车载收音机",
                    launchActivity: "com.sgmw.carradio.MainActivity",
                    hasCustomIcon: true, customIconPath: "/data/icons/radio.png",
                    sourceIconPath: "/data/icons/radio_src.png",
                    roundedCropEnabled: true, cornerRadiusFraction: 0.22,
                    assetKind: LingFansIcon.assetKindSourceSquare,
                    previewPath: "", applicationId: "com.sgmw.carradio"
                ),
                LingFansIconItem(
                    packageName: "com.android.settings", appLabel: "设置",
                    launchActivity: "com.android.settings.Settings",
                    hasCustomIcon: false, customIconPath: "", sourceIconPath: "",
                    roundedCropEnabled: false, cornerRadiusFraction: 0,
                    assetKind: LingFansIcon.assetKindSourceSquare,
                    previewPath: "", applicationId: "com.android.settings"
                ),
            ],
            message: "ok"
        )
        lastRawOutput = "Result: Bundle[{ok=true, versionName=3.2.4, versionCode=3204}]"
        errorMessage = nil
    }
}
