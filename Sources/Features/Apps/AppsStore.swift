import UIKit
import Foundation

/// App 管理数据层
///
/// 列表：`pm list packages -f` 拿包名与 apk 路径
/// 卸载：`pm uninstall <pkg>`（系统应用需要 root 或 `--user 0`）
/// 停用：`pm disable-user --user 0 <pkg>`（比卸载安全，可恢复）
/// 提取：`pull <apk 路径>` 到本机 Documents/pulled
///
/// 华勤 730/T527 那类强制签名通道（原版 pm install --install-force）
/// 需要先安装，本轮先做「列表 / 卸载 / 停用 / 提取」四件事。
@MainActor
final class AppsStore: ObservableObject {

    struct App: Identifiable, Hashable {
        let package: String
        let apkPath: String
        /// 是否系统应用（路径在 /system 或 /product 下）
        let isSystem: Bool
        /// 是否已停用
        let isDisabled: Bool
        /// 车机上的真实应用名（server.apk 提供），拿不到时为空
        var label: String = ""

        var id: String { package }

        /// 展示名：优先真实应用名，退回包名末段
        var displayName: String {
            if !label.isEmpty { return label }
            let last = package.split(separator: ".").last.map(String.init) ?? package
            return last.prefix(1).uppercased() + last.dropFirst()
        }
    }

    @Published private(set) var apps: [App] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var busyMessage: String?
    /// 图标内存缓存（包名 -> UIImage）
    @Published var appIcons: [String: UIImage] = [:]
    @Published var query: String = ""
    @Published private(set) var lastPulledLocalPath: String?

    var isDemo = false
    private let adb = AdbService.shared

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    /// 过滤后的列表
    var filtered: [App] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.package.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }

    // MARK: - 加载

    func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }

        if isDemo {
            apps = DemoContent.makeApps().map {
                App(package: $0.package, apkPath: "/system/app/\($0.label).apk",
                    isSystem: $0.isSystem, isDisabled: false)
            }
            return
        }

        // 1. 优先执行原版唯一的结构化通道：server.apk 输出 JSON（对齐原版 AppManagerHelpers.kt:201-255）
        AppLabelService.shared.bind()
        await AppLabelService.shared.warmupIfNeeded()

        var parsed: [App] = []
        let service = AppLabelService.shared

        // 如果 warmupIfNeeded 已经把全车机 package -> label 抓到了
        if !service.labels.isEmpty {
            for (pkg, label) in service.labels {
                let isSystem = pkg.hasPrefix("com.android.") || pkg.hasPrefix("android") || pkg.hasPrefix("com.google.")
                parsed.append(App(
                    package: pkg,
                    apkPath: "",
                    isSystem: isSystem,
                    isDisabled: false,
                    label: label
                ))
            }
        }

        // 2. 备选通道（如果 server.apk 因特殊 ROM 无法运行，走 pm list 兜底）
        if parsed.isEmpty {
            var lines = await shellLines("pm list packages -f 2>/dev/null")
            if lines.isEmpty {
                lines = await shellLines("pm list packages 2>/dev/null")
            }

            let disabled = Set(
                (await shellLines("pm list packages -d 2>/dev/null"))
                    .map { $0.replacingOccurrences(of: "package:", with: "") }
            )

            for line in lines {
                let raw = line.replacingOccurrences(of: "package:", with: "")
                var apkPath = ""
                var pkg = raw
                if let eq = raw.lastIndex(of: "=") {
                    apkPath = String(raw[raw.startIndex..<eq])
                    pkg = String(raw[raw.index(after: eq)...])
                }
                guard !pkg.isEmpty else { continue }

                let isSystem = apkPath.hasPrefix("/system")
                    || apkPath.hasPrefix("/product")
                    || apkPath.hasPrefix("/vendor")
                    || apkPath.hasPrefix("/oem")

                parsed.append(App(
                    package: pkg,
                    apkPath: apkPath,
                    isSystem: isSystem,
                    isDisabled: disabled.contains(pkg),
                    label: service.label(for: pkg) ?? ""
                ))
            }
        }

        if parsed.isEmpty {
            errorMessage = "读不到应用列表。请确认设备已连通。"
        }

        apps = parsed.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - 安装（对齐原版 SingleApkInstallCoordinator + InstallChannelSupport）

    @Published private(set) var installProgress: String?
    /// 安装进行中时可取消（原版 SingleApkInstallCoordinator.cancel）
    @Published private(set) var installRunning = false
    private var installCancelled = false

    func cancelInstall() {
        guard installRunning else { return }
        installCancelled = true
        installProgress = "正在取消…"
    }

    /// 安装本地 APK 文件。
    /// 完整链路：push → pm install -r → 签名拦截则 pm caninstall + --install-force → 清理暂存
    func install(localPath: String) async -> String? {
        guard FileManager.default.fileExists(atPath: localPath) else {
            return "文件不存在：\(localPath)"
        }
        let fileName = (localPath as NSString).lastPathComponent
        busyMessage = "安装 \(fileName)…"
        installProgress = nil
        installCancelled = false
        installRunning = true
        defer {
            busyMessage = nil
            installProgress = nil
            installRunning = false
            installCancelled = false
        }

        if isDemo {
            try? await Task.sleep(nanoseconds: 900_000_000)
            return "演示模式不执行真实安装"
        }

        let sessionId = Int(Date().timeIntervalSince1970) % 100000
        let remote = InstallHelper.remoteTempPath(fileName: fileName, sessionId: sessionId)

        // 1. push 到设备暂存
        installProgress = "上传 APK…"
        let pushResult = await runCommand(["push", localPath, remote])
        // push 成功输出形如 `1 file pushed, 0 skipped.`；
        // 失败才有 error / No such file / denied，按失败特征判定更稳。
        let pushText = pushResult.output.lowercased()
        let pushFailed = pushText.contains("error")
            || pushText.contains("no such")
            || pushText.contains("failed")
            || pushText.contains("permission denied")
            || pushText.contains("not found")
        if pushFailed {
            _ = await cleanupRemote(remote)
            return "上传失败：\(pushResult.output)"
        }

        // 用户中途取消：已上传的包清掉，不再安装
        if installCancelled {
            _ = await cleanupRemote(remote)
            return "已取消安装"
        }

        // 2. 标准通道
        installProgress = "标准通道安装…"
        let standard = (await shellLines("pm install -r \"\(remote)\" 2>&1"))
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if InstallHelper.isSuccess(standard) {
            _ = await cleanupRemote(remote)
            await load()
            return nil
        }

        if installCancelled {
            _ = await cleanupRemote(remote)
            return "已取消安装"
        }

        // 3. 仅当命中签名强校验时切强制通道
        var attempt = InstallAttempt(
            success: false, channel: .standard, output: standard,
            standardOutput: standard, switched: false
        )

        if InstallHelper.hasSignatureBlockMark(standard) {
            installProgress = "强制安装通道…"
            _ = await shellLines("pm caninstall \(InstallHelper.forceWindow) 2>&1")
            let forced = (await shellLines("pm install --install-force -r \"\(remote)\" 2>&1"))
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            attempt = InstallAttempt(
                success: InstallHelper.isSuccess(forced),
                channel: .forceWindow,
                output: forced,
                standardOutput: standard,
                switched: true
            )
        }

        // 4. 清理暂存（带复核，原版踩过残留 33MB 的坑）
        _ = await cleanupRemote(remote)

        if attempt.success {
            await load()
            return nil
        }

        var msg = attempt.combinedRawOutput
        if attempt.forceChannelUnsupported {
            msg += "\n\n设备不支持 pm caninstall（该命令是本定制 ROM 专有）。"
        }
        return msg.isEmpty ? "安装失败：无输出" : msg
    }

    /// 清理设备暂存 APK，带 ls 复核 + 重试。
    /// 原版注释：之前只发一条 rm -f 就当清理完成，实测在定制 ROM 上会静默失败。
    private func cleanupRemote(_ remote: String) async -> Bool {
        for _ in 0..<3 {
            _ = await shellLines("rm -f \"\(remote)\" 2>&1")
            let check = await shellLines("ls \"\(remote)\" 2>/dev/null")
            let stillThere = check.contains { $0.contains(remote) && !$0.lowercased().contains("no such") }
            if !stillThere { return true }
        }
        return false
    }

    // MARK: - 应用启动（原版 AppManagerScreen.kt:798 附近）

    func launch(_ app: App) async -> String? {
        if isDemo { return nil }
        let lines = await shellLines(
            "monkey -p \(app.package) -c android.intent.category.LAUNCHER 1 2>&1"
        )
        let text = lines.joined(separator: " ").lowercased()
        // monkey 成功时会打印 Events injected: 1
        if text.contains("no activities found") || text.contains("error") {
            return "启动失败：\(lines.joined(separator: " "))"
        }
        return nil
    }

    // MARK: - 应用详情（原版 pm path / dumpsys package）

    @Published private(set) var detailText: String = ""

    func loadDetail(_ app: App) async {
        busyMessage = "读取应用详情…"
        defer { busyMessage = nil }

        if isDemo {
            detailText = """
            版本名      \(app.isSystem ? "1.0" : "3.2.1")
            APK 大小    12.34 MB
            minSdk      28
            targetSdk   33
            首次安装    2026-09-01 10:20:31
            最后更新    2026-10-18 22:11:04
            主 Activity MainActivity
            """
            return
        }

        // 原版 fetchDetailsViaAdb：从 dumpsys 里逐字段提取，
        // 再用 `ls -nl <apkDir>` 累加所有 .apk（含 splits）算总大小。
        let dumpLines = await shellLines("dumpsys package \(app.package) 2>/dev/null")
        let dumpsys = dumpLines.joined(separator: "\n")

        guard !dumpsys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            detailText = "读不到详情（ROM 可能限制了 dumpsys package）"
            return
        }

        let vName = Self.lineAfter(dumpsys, "versionName=")
        let minSdk = Self.lineAfter(dumpsys, "minSdk=")
        let targetSdk = Self.lineAfter(dumpsys, "targetSdk=")
        let firstTime = Self.lineAfter(dumpsys, "firstInstallTime=")
        let updateTime = Self.lineAfter(dumpsys, "lastUpdateTime=")
        let mainActivity = Self.firstMatch("\(NSRegularExpression.escapedPattern(for: app.package))/[\\w\\.]+", in: dumpsys)?
            .split(separator: "/").last.map(String.init) ?? "未知"

        // APK 总大小：APK 路径的父目录下所有 .apk 累加
        var sizeText = "未知"
        let apkPath = app.apkPath.isEmpty
            ? (await shellLines("pm path \(app.package) 2>/dev/null").first?
                .replacingOccurrences(of: "package:", with: "")
                .trimmingCharacters(in: .whitespaces) ?? "")
            : app.apkPath

        if !apkPath.isEmpty {
            let dir = (apkPath as NSString).deletingLastPathComponent
            let lsLines = await shellLines("ls -nl \"\(dir)\"")
            let total = lsLines.filter { $0.contains(".apk") }.reduce(Int64(0)) { acc, line in
                let nums = line.split(separator: " ").compactMap { Int64($0) }.filter { $0 > 1000 }
                return acc + (nums.first ?? 0)
            }
            if total > 0 {
                let mb = Double(total) / 1048576
                sizeText = mb >= 1
                    ? String(format: "%.2f MB", mb)
                    : String(format: "%.2f KB", Double(total) / 1024)
            }
        }

        var out = """
        版本名      \(vName.isEmpty ? "未知" : vName)
        APK 大小    \(sizeText)
        minSdk      \(minSdk.isEmpty ? "-" : minSdk)
        targetSdk   \(targetSdk.isEmpty ? "-" : targetSdk)
        首次安装    \(firstTime.isEmpty ? "-" : firstTime)
        最后更新    \(updateTime.isEmpty ? "-" : updateTime)
        主 Activity \(mainActivity)
        """

        if !apkPath.isEmpty {
            out += "\n\nAPK 路径    \(apkPath)"
        }

        out += "\n\n== dumpsys 原始输出（前 40 行）==\n"
        out += dumpLines.prefix(40).joined(separator: "\n")

        detailText = out
    }

    /// 取 `key` 所在行 `key` 之后的部分（原版 lineAfter）
    private static func lineAfter(_ text: String, _ key: String) -> String {
        for line in text.components(separatedBy: "\n") {
            if let r = line.range(of: key) {
                return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range)
    }

    // MARK: - 强停 / 清数据（对齐原版）

    /// 原版 AppManagerScreen.kt:798：`am force-stop <pkg>`
    func forceStop(_ app: App) async -> String? {
        busyMessage = "强停 \(app.displayName)…"
        defer { busyMessage = nil }

        if isDemo { return nil }

        let lines = await shellLines("am force-stop \(app.package) 2>&1")
        let text = lines.joined(separator: " ").lowercased()
        if text.contains("error") || text.contains("permission") {
            return "强停失败：\(lines.joined(separator: " "))"
        }
        return nil
    }

    /// 原版 AppManagerScreen.kt:869：`pm clear <pkg>`
    func clearData(_ app: App) async -> String? {
        busyMessage = "清除 \(app.displayName) 数据…"
        defer { busyMessage = nil }

        if isDemo { return nil }

        let lines = await shellLines("pm clear \(app.package) 2>&1")
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if text.contains("Success") { return nil }
        return "清除失败：\(text.isEmpty ? "无回执" : text)"
    }

    // MARK: - 卸载

    func uninstall(_ app: App, keepData: Bool = false) async -> String? {
        busyMessage = "卸载 \(app.displayName)…"
        defer { busyMessage = nil }

        if isDemo {
            apps.removeAll { $0.package == app.package }
            return nil
        }

        let flag = keepData ? "-k " : ""
        let lines = await shellLines("pm uninstall \(flag)\(app.package) 2>&1")
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        if text.contains("Success") {
            apps.removeAll { $0.package == app.package }
            return nil
        }
        if text.contains("DELETE_FAILED_INTERNAL_ERROR") || text.contains("not installed") {
            return "卸载失败：\(text)。系统应用需先停用（disable-user）。"
        }
        return "卸载失败：\(text.isEmpty ? "无回执" : text)"
    }

    // MARK: - 停用 / 启用

    /// 原版 AppManagerScreen.kt:802 就是不带 --user：
    ///   `pm disable-user <pkg>` / `pm enable <pkg>`
    /// 带 user 参数的是「自启动管理」里的组件级开关，不是这里。
    func setDisabled(_ app: App, disabled: Bool) async -> String? {
        busyMessage = disabled ? "停用 \(app.displayName)…" : "启用 \(app.displayName)…"
        defer { busyMessage = nil }

        if isDemo {
            if let i = apps.firstIndex(where: { $0.package == app.package }) {
                let o = apps[i]
                apps[i] = App(package: o.package, apkPath: o.apkPath,
                              isSystem: o.isSystem, isDisabled: disabled)
            }
            return nil
        }

        let cmd = disabled
            ? "pm disable-user \(app.package) 2>&1"
            : "pm enable \(app.package) 2>&1"
        let text = (await shellLines(cmd))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let lower = text.lowercased()
        let rejected = lower.contains("unknown user")
            || lower.contains("does not exist")
            || lower.contains("error")
            || lower.contains("exception")
            || lower.contains("denied")
            || lower.contains("not allowed")

        if !rejected {
            if let i = apps.firstIndex(where: { $0.package == app.package }) {
                let o = apps[i]
                apps[i] = App(package: o.package, apkPath: o.apkPath,
                              isSystem: o.isSystem, isDisabled: disabled)
            }
            return nil
        }
        return "操作失败：\(text.isEmpty ? "无输出" : text)"
    }

    // MARK: - 自启动管理（原版 AppStartupManagementDialog）

    @Published private(set) var startupInfo = AppStartupInfo()
    @Published private(set) var startupLoading = false
    @Published private(set) var startupBusyComponent: String?
    @Published private(set) var startupMessage: String?

    func loadStartup(_ app: App) async {
        startupLoading = true
        startupMessage = nil
        startupInfo = AppStartupInfo(status: .loading)
        defer { startupLoading = false }

        if isDemo {
            startupInfo = AppStartupInfo(
                status: .found,
                receivers: [
                    AppStartupReceiver(
                        componentName: "\(app.package)/.BootReceiver",
                        actions: ["android.intent.action.BOOT_COMPLETED"],
                        enabled: true
                    ),
                    AppStartupReceiver(
                        componentName: "\(app.package)/.QuickBootReceiver",
                        actions: ["android.intent.action.QUICKBOOT_POWERON"],
                        enabled: false
                    ),
                ]
            )
            return
        }

        startupInfo = await AppStartup.load(packageName: app.package) { [weak self] cmd in
            guard let self else { return [] }
            return await self.shellLines(cmd)
        }
    }

    func toggleStartup(_ app: App, receiver: AppStartupReceiver, enabled: Bool) async {
        startupBusyComponent = receiver.componentName
        startupMessage = nil
        defer { startupBusyComponent = nil }

        if isDemo {
            if let i = startupInfo.receivers.firstIndex(where: { $0.componentName == receiver.componentName }) {
                let o = startupInfo.receivers[i]
                startupInfo.receivers[i] = AppStartupReceiver(
                    componentName: o.componentName, actions: o.actions, enabled: enabled
                )
            }
            startupMessage = enabled ? "已恢复自启动" : "已禁用自启动"
            return
        }

        let result = await AppStartup.setEnabled(
            packageName: app.package,
            receiver: receiver,
            enabled: enabled
        ) { [weak self] cmd in
            guard let self else { return [] }
            return await self.shellLines(cmd)
        }

        if let info = result.info {
            startupInfo = info
        }
        startupMessage = result.success
            ? "\(result.message)（user=\(result.user)）"
            : result.message
    }

    // MARK: - 提取 APK

    func extract(_ app: App) async -> String? {
        guard !app.apkPath.isEmpty else {
            return "这个应用没有可提取的 apk 路径（ROM 未暴露 -f 信息）"
        }
        busyMessage = "提取 \(app.displayName).apk…"
        defer { busyMessage = nil }

        let dir = FilesStore.localPullDirectory()
        let dest = dir.appendingPathComponent("\(app.package).apk")
        try? FileManager.default.removeItem(at: dest)

        if isDemo {
            let stub = "演示 APK：\(app.package)"
            try? stub.data(using: .utf8)?.write(to: dest)
            lastPulledLocalPath = dest.path
            return nil
        }

        // 同 pull：必须给绝对路径
        let result = await runCommand(["pull", app.apkPath, dest.path])
        if FileManager.default.fileExists(atPath: dest.path) {
            lastPulledLocalPath = dest.path
            return nil
        }
        let alt = dest.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: alt.path) {
            try? FileManager.default.moveItem(at: alt, to: dest)
            lastPulledLocalPath = dest.path
            return nil
        }
        return "提取失败：\(result.output.isEmpty ? "无回执" : result.output)"
    }

    // MARK: - 图标拉取（对齐原版 AppManagerScreen.kt:370）

    func loadIconIfNeeded(for package: String) {
        if appIcons[package] != nil { return }
        Task {
            if let cached = AppLabelService.shared.icon(for: package) {
                appIcons[package] = cached
                return
            }
            if let img = await AppLabelService.shared.loadIcon(for: package) {
                appIcons[package] = img
            }
        }
    }

    // MARK: - 基础

    private struct AppsCmdResult {
        let success: Bool
        let output: String
    }

    private func runCommand(_ args: [String]) async -> AppsCmdResult {
        await withCheckedContinuation { (cont: CheckedContinuation<AppsCmdResult, Never>) in
            adb.runAsync(args) { r in
                cont.resume(returning: AppsCmdResult(success: r.success, output: r.output))
            }
        }
    }

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }
}
