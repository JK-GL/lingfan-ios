import Foundation

/// App 自启动管理
///
/// 逐行对齐原版 `screens/AppStartupManager.kt`：
///
/// 从 `dumpsys package <pkg>` 里找出带 BOOT_COMPLETED 类 action 的 receiver，
/// 再用 `pm disable-user/enable --user <user> <component>` 逐个开关。
///
/// 三个关键点（全部来自源码）：
///   1. 只有 3 个 action 算自启动：BOOT_COMPLETED / LOCKED_BOOT_COMPLETED / QUICKBOOT_POWERON
///   2. 组件是否启用要读 `disabledComponents:` 段，不是看 `enabled=` 字段
///   3. user 依次试 当前用户 → current → 0，且改完必须重新 dumpsys 验证
enum AppStartup {

    static let actions: Set<String> = [
        "android.intent.action.BOOT_COMPLETED",
        "android.intent.action.LOCKED_BOOT_COMPLETED",
        "android.intent.action.QUICKBOOT_POWERON",
    ]

    /// 开关成功后返回的结果，含实际生效的 user 和命令，便于排障
    struct ToggleResult {
        let success: Bool
        let message: String
        let user: String
        let command: String
        let output: String
        let info: AppStartupInfo?
    }
}

enum AppStartupStatus {
    case unknown, loading, none, found, error
}

struct AppStartupReceiver: Identifiable, Hashable {
    let componentName: String
    let actions: [String]
    var enabled: Bool

    var id: String { componentName }

    /// `com.foo/.BootReceiver` → `BootReceiver`
    var shortName: String {
        let afterSlash = componentName.split(separator: "/").last.map(String.init) ?? componentName
        return afterSlash.split(separator: ".").last.map(String.init) ?? afterSlash
    }

    /// action 的中文短名（原版 startupActionLabel）
    var actionLabels: [String] {
        actions.map { action in
            switch action {
            case "android.intent.action.BOOT_COMPLETED": return "开机完成"
            case "android.intent.action.LOCKED_BOOT_COMPLETED": return "解锁前开机"
            case "android.intent.action.QUICKBOOT_POWERON": return "快速启动"
            default: return action.split(separator: ".").last.map(String.init) ?? action
            }
        }
    }
}

struct AppStartupInfo {
    var status: AppStartupStatus = .unknown
    var receivers: [AppStartupReceiver] = []
    var errorMessage: String = ""

    var enabledCount: Int { receivers.filter(\.enabled).count }

    var hasEnabled: Bool { enabledCount > 0 }

    /// 原版 startupSummary
    var summary: String {
        switch status {
        case .unknown, .loading: return "检测中"
        case .none: return "未发现"
        case .error: return "检测失败"
        case .found:
            return enabledCount > 0 ? "已启用 \(enabledCount) 项" : "已全部禁用"
        }
    }
}

// MARK: - 查询

extension AppStartup {

    /// 拉取某个 App 的自启动 receiver 列表
    static func load(packageName: String, shell: @escaping (String) async -> [String]) async -> AppStartupInfo {
        let lines = await shell("dumpsys package \(shellQuote(packageName))")
        let dump = lines.joined(separator: "\n")
        if dump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppStartupInfo(status: .error, errorMessage: "读不到 dumpsys package 输出")
        }
        let receivers = parseReceivers(dump, packageName: packageName)
        if receivers.isEmpty {
            return AppStartupInfo(status: .none)
        }
        // 启用的排前面，同类按组件名
        let sorted = receivers.sorted {
            if $0.enabled != $1.enabled { return $0.enabled }
            return $0.componentName.lowercased() < $1.componentName.lowercased()
        }
        return AppStartupInfo(status: .found, receivers: sorted)
    }

    /// 开关一个组件。返回结果里带实际生效的 user。
    static func setEnabled(
        packageName: String,
        receiver: AppStartupReceiver,
        enabled: Bool,
        shell: @escaping (String) async -> [String]
    ) async -> ToggleResult {
        let users = await resolveUserCandidates(shell: shell)
        var lastFailure = ""

        for user in users {
            let cmd = "pm \(enabled ? "enable" : "disable-user") --user \(user) "
                + "\(shellQuote(receiver.componentName))"
            let lines = await shell(cmd)
            let output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if looksLikeFailure(output) {
                lastFailure = output.isEmpty ? "设备拒绝修改组件状态" : output
                continue
            }

            // 命令成功不代表生效，必须重新 dumpsys 验证
            let verified = await load(packageName: packageName, shell: shell)
            var verifiedEnabled = verified.receivers
                .first { $0.componentName == receiver.componentName }?.enabled
            let commandState = componentState(output)
            if verifiedEnabled != enabled, let cs = commandState, cs == enabled {
                // dumpsys 没刷新但命令回显说改了，以命令回显为准
                verifiedEnabled = cs
            }

            if verifiedEnabled == enabled {
                var finalInfo = verified
                if let i = finalInfo.receivers.firstIndex(where: { $0.componentName == receiver.componentName }),
                   finalInfo.receivers[i].enabled != enabled {
                    let old = finalInfo.receivers[i]
                    finalInfo.receivers[i] = AppStartupReceiver(
                        componentName: old.componentName,
                        actions: old.actions,
                        enabled: enabled
                    )
                }
                return ToggleResult(
                    success: true,
                    message: enabled ? "已恢复自启动" : "已禁用自启动",
                    user: user,
                    command: cmd,
                    output: output,
                    info: finalInfo
                )
            }

            lastFailure = "命令已执行但组件状态未变化"
        }

        return ToggleResult(
            success: false,
            message: lastFailure.isEmpty ? "设备未接受组件状态修改" : lastFailure,
            user: "",
            command: "",
            output: "",
            info: nil
        )
    }

    /// 原版 resolveUserCandidates：当前用户 → "current" → "0"
    static func resolveUserCandidates(shell: @escaping (String) async -> [String]) async -> [String] {
        let lines = await shell("am get-current-user")
        let raw = lines.joined(separator: " ")
        var list: [String] = []
        if let r = raw.range(of: #"\d+"#, options: .regularExpression) {
            list.append(String(raw[r]))
        }
        list.append("current")
        list.append("0")
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

// MARK: - 解析

extension AppStartup {

    static func parseReceivers(_ dumpsys: String, packageName: String) -> [AppStartupReceiver] {
        let lines = dumpsys.components(separatedBy: "\n")
        let disabled = parseDisabledComponents(lines, packageName: packageName)

        // 保持出现顺序，action 去重
        var found: [String: [String]] = [:]
        var order: [String] = []

        for (index, line) in lines.enumerated() {
            guard let action = AppStartup.actions.first(where: { line.contains($0) }) else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineIsActionOnly = (trimmed.hasSuffix(":") ? String(trimmed.dropLast()) : trimmed) == action

            let component: String?
            if lineIsActionOnly {
                component = findFollowingComponent(lines, actionIndex: index, packageName: packageName)
                    ?? findNearestComponent(lines, actionIndex: index, packageName: packageName)
            } else {
                component = findNearestComponent(lines, actionIndex: index, packageName: packageName)
                    ?? findFollowingComponent(lines, actionIndex: index, packageName: packageName)
            }
            guard let c = component else { continue }

            if found[c] == nil {
                found[c] = []
                order.append(c)
            }
            if !(found[c]?.contains(action) ?? false) {
                found[c]?.append(action)
            }
        }

        return order.map { component in
            AppStartupReceiver(
                componentName: component,
                actions: found[component] ?? [],
                enabled: !disabled.contains(normalizeComponent(component, packageName: packageName))
            )
        }
    }

    /// 读 `disabledComponents:` 段，直到遇到同缩进的另一个段或 enabledComponents / User
    static func parseDisabledComponents(_ lines: [String], packageName: String) -> Set<String> {
        var result = Set<String>()
        var inSection = false
        var sectionIndent = Int.max

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "disabledComponents:" {
                inSection = true
                sectionIndent = line.firstIndex(where: { !$0.isWhitespace })
                    .map { line.distance(from: line.startIndex, to: $0) } ?? 0
                continue
            }
            guard inSection else { continue }
            if trimmed.isEmpty { continue }

            let indent = line.firstIndex(where: { !$0.isWhitespace })
                .map { line.distance(from: line.startIndex, to: $0) } ?? 0
            if indent <= sectionIndent && trimmed.hasSuffix(":") {
                inSection = false
                continue
            }
            if trimmed == "enabledComponents:" || trimmed.hasPrefix("User ") {
                inSection = false
                continue
            }

            if let token = parseComponentToken(trimmed, packageName: packageName) {
                result.insert(token)
            }
        }
        return result
    }

    static func parseComponentToken(_ line: String, packageName: String) -> String? {
        var cleaned = line
        for marker in [" filter", " userId=", " m=", " "] {
            if let r = cleaned.range(of: marker) {
                cleaned = String(cleaned[cleaned.startIndex..<r.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        if cleaned.hasSuffix(":") { cleaned = String(cleaned.dropLast()) }
        if cleaned.isEmpty { return nil }

        if cleaned.hasPrefix("\(packageName)/") {
            return normalizeComponent(cleaned, packageName: packageName)
        }
        if cleaned.hasPrefix("\(packageName).") {
            return "\(packageName)/\(cleaned)"
        }
        return nil
    }

    /// 往上找最近的组件行（最多回看 24 行）
    static func findNearestComponent(_ lines: [String], actionIndex: Int, packageName: String) -> String? {
        let start = max(actionIndex - 24, 0)
        var i = actionIndex
        while i >= start {
            if let c = componentFromLine(lines[i], packageName: packageName) { return c }
            i -= 1
        }
        return nil
    }

    /// 往下找最近的组件行（最多看 16 行，遇到下一个 action 就停）
    static func findFollowingComponent(_ lines: [String], actionIndex: Int, packageName: String) -> String? {
        let end = min(actionIndex + 16, lines.count - 1)
        guard actionIndex + 1 <= end else { return nil }
        for i in (actionIndex + 1)...end {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let bare = trimmed.hasSuffix(":") ? String(trimmed.dropLast()) : trimmed
            if AppStartup.actions.contains(bare) { break }
            if let c = componentFromLine(lines[i], packageName: packageName) { return c }
        }
        return nil
    }

    static func componentFromLine(_ line: String, packageName: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: packageName)
        let componentPattern = "\\b\(escaped)/[A-Za-z0-9_.$]+"
        let classPattern = "\\b\(escaped)(?:\\.[A-Za-z0-9_.$]+)+"
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let c = firstMatch(componentPattern, in: trimmed) {
            return normalizeComponent(c, packageName: packageName)
        }

        // 兜底：取行尾 token
        var candidate = trimmed
        if candidate.hasSuffix(":") { candidate = String(candidate.dropLast()) }
        if let r = candidate.range(of: " ", options: .backwards) {
            candidate = String(candidate[candidate.index(after: r.lowerBound)...])
        }
        if let r = candidate.range(of: "}") {
            candidate = String(candidate[candidate.startIndex..<r.lowerBound])
        }
        candidate = candidate.trimmingCharacters(in: .whitespaces)

        if candidate.hasPrefix("\(packageName)/") {
            return normalizeComponent(candidate, packageName: packageName)
        }
        if candidate.hasPrefix("\(packageName).") {
            return "\(packageName)/\(candidate)"
        }

        if let cls = firstMatch(classPattern, in: trimmed),
           cls != packageName,
           !cls.hasPrefix("\(packageName).uid.") {
            return "\(packageName)/\(cls)"
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range)
    }

    /// `.BootReceiver` 这种相对类名要补全成 `pkg/pkg.BootReceiver`
    static func normalizeComponent(_ component: String, packageName: String) -> String {
        var clean = component.trimmingCharacters(in: .whitespaces)
        if clean.hasSuffix(":") { clean = String(clean.dropLast()) }
        guard clean.hasPrefix("\(packageName)/") else { return clean }
        let className = String(clean.dropFirst(packageName.count + 1))
        if className.hasPrefix(".") {
            return "\(packageName)/\(packageName)\(className)"
        }
        return clean
    }
}

// MARK: - 判定

extension AppStartup {

    /// 原版 looksLikeShellFailure
    static func looksLikeFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("exception")
            || lower.contains("error")
            || lower.contains("unknown option")
            || lower.contains("unknown user")
            || lower.contains("not found")
            || lower.contains("security exception")
            || lower.contains("java.lang.")
    }

    /// 从命令回显里读组件新状态
    static func componentState(_ output: String) -> Bool? {
        let lower = output.lowercased()
        if lower.contains("new state: disabled") { return false }
        if lower.contains("new state: enabled") { return true }
        if lower.contains("new state: default") { return true }
        return nil
    }

    /// 单引号包裹，内部单引号按 POSIX 规则转义
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
