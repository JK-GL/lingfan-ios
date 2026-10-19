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

        var id: String { package }

        /// 展示名：取包名最后一段并首字母大写，够用且不额外调用
        var displayName: String {
            let last = package.split(separator: ".").last.map(String.init) ?? package
            return last.prefix(1).uppercased() + last.dropFirst()
        }
    }

    @Published private(set) var apps: [App] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var busyMessage: String?
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

        // 同时拿路径与包名
        var lines = await shellLines("pm list packages -f 2>/dev/null")
        if lines.isEmpty {
            // 老 ROM 可能不支持 -f
            lines = await shellLines("pm list packages 2>/dev/null")
        }

        let disabled = Set(
            (await shellLines("pm list packages -d 2>/dev/null"))
                .map { $0.replacingOccurrences(of: "package:", with: "") }
        )

        var parsed: [App] = []
        for line in lines {
            let raw = line.replacingOccurrences(of: "package:", with: "")
            // -f 格式：/data/app/xx/base.apk=com.xxx.yyy
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
                isDisabled: disabled.contains(pkg)
            ))
        }

        if parsed.isEmpty {
            errorMessage = "读不到应用列表。pm 命令可能被 ROM 限制。"
        }
        apps = parsed.sorted { $0.package < $1.package }
    }

    // MARK: - 安装（对齐原版 SingleApkInstallCoordinator + InstallChannelSupport）

    @Published private(set) var installProgress: String?

    /// 安装本地 APK 文件。
    /// 完整链路：push → pm install -r → 签名拦截则 pm caninstall + --install-force → 清理暂存
    func install(localPath: String) async -> String? {
        guard FileManager.default.fileExists(atPath: localPath) else {
            return "文件不存在：\(localPath)"
        }
        let fileName = (localPath as NSString).lastPathComponent
        busyMessage = "安装 \(fileName)…"
        installProgress = nil
        defer { busyMessage = nil; installProgress = nil }

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

        // 2. 标准通道
        installProgress = "标准通道安装…"
        let standard = (await shellLines("pm install -r \"\(remote)\" 2>&1"))
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if InstallHelper.isSuccess(standard) {
            _ = await cleanupRemote(remote)
            await load()
            return nil
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
            Package [\(app.package)]
              versionName=\(app.isSystem ? "1.0" : "3.2.1")
              versionCode=\(app.isSystem ? 1 : 3201)
              firstInstallTime=2026-09-01 10:20:31
              lastUpdateTime=2026-10-18 22:11:04
              codePath=\(app.apkPath.isEmpty ? "/data/app/..." : app.apkPath)
              dataDir=/data/user/0/\(app.package)
              flags=[ \(app.isSystem ? "SYSTEM" : "HAS_CODE" ) ]
            """
            return
        }

        var out: [String] = []
        let pathLines = await shellLines("pm path \(app.package) 2>/dev/null")
        if !pathLines.isEmpty {
            out.append("== APK 路径 ==")
            out.append(contentsOf: pathLines)
        }

        let pkgLines = await shellLines("dumpsys package \(app.package) 2>/dev/null | head -60")
        if !pkgLines.isEmpty {
            out.append("")
            out.append("== 包信息 ==")
            out.append(contentsOf: pkgLines)
        }

        detailText = out.isEmpty ? "读不到详情（ROM 可能限制了 dumpsys package）" : out.joined(separator: "\n")
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

    /// 对齐原版 resolveUserCandidates：先取真实当前用户，再依次退 "current" 和 "0"。
    /// 车机常见多用户，硬编码 --user 0 在部分机型上会 unknown user。
    private func resolveUserCandidates() async -> [String] {
        let raw = await shellLines("am get-current-user 2>/dev/null").joined(separator: " ")
        var list: [String] = []
        if let r = raw.range(of: #"\d+"#, options: .regularExpression) {
            list.append(String(raw[r]))
        }
        list.append("current")
        list.append("0")
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

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

        let users = await resolveUserCandidates()
        var lastOutput = ""

        for user in users {
            let cmd = disabled
                ? "pm disable-user --user \(user) \(app.package) 2>&1"
                : "pm enable --user \(user) \(app.package) 2>&1"
            let text = (await shellLines(cmd))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            lastOutput = text

            let lower = text.lowercased()
            let rejected = lower.contains("unknown user")
                || lower.contains("does not exist")
                || lower.contains("error")
                || lower.contains("exception")
                || lower.contains("denied")
                || lower.contains("not allowed")

            if rejected { continue }

            if let i = apps.firstIndex(where: { $0.package == app.package }) {
                let o = apps[i]
                apps[i] = App(package: o.package, apkPath: o.apkPath,
                              isSystem: o.isSystem, isDisabled: disabled)
            }
            return nil
        }

        return "操作失败：\(lastOutput.isEmpty ? "无输出" : lastOutput)"
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
