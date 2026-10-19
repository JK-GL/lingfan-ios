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
            ? "pm disable-user --user 0 \(app.package) 2>&1"
            : "pm enable \(app.package) 2>&1"
        let lines = await shellLines(cmd)
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        if text.contains("new state") || text.isEmpty || text.contains("enabled") {
            if let i = apps.firstIndex(where: { $0.package == app.package }) {
                let o = apps[i]
                apps[i] = App(package: o.package, apkPath: o.apkPath,
                              isSystem: o.isSystem, isDisabled: disabled)
            }
            return nil
        }
        return "操作失败：\(text)"
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
