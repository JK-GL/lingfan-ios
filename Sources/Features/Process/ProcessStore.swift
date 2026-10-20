import Foundation

/// 进程管理的数据层
///
/// 严格对齐原版 ProcessInfo.kt:602-635：
///   ps -A -o PID,RSS,NAME        ← 只有三列，老 ROM 也支持
///   dumpsys meminfo（取 Total RAM / Free RAM）
///   kill <pid>                   ← SIGTERM，不是 -9
///
/// 关键过滤（原版第 612 行）：
///   进程名必须含 "." 且不以 "/" 开头 —— 即只保留 App 进程，
///   把内核线程（kworker、ksoftirqd 等几十个）全部滤掉。
///   没有这条过滤，列表会被噪音淹没，用户根本找不到要杀的那个 App。
@MainActor
final class ProcessStore: ObservableObject {

    struct Proc: Identifiable, Hashable {
        let pid: Int
        /// 完整进程名，例如 com.zzh.launcher50s 或 com.zzh.launcher50s:remote
        let name: String
        /// 包名（进程名冒号前）
        let packageName: String
        /// 是否主进程
        let isMainProcess: Bool
        /// 物理内存 KB（ps 的 RSS 列）
        let rssKB: Int
        /// CPU 占用百分比（/proc/stat 两次采样差值）
        var cpuUsage: Double = 0

        var id: Int { pid }

        var cpuText: String {
            String(format: "CPU %.1f%%", max(cpuUsage, 0))
        }

        /// 进程名冒号后的部分，例如 :remote
        var subProcessSuffix: String {
            guard let colon = name.firstIndex(of: ":") else { return "" }
            return String(name[colon...])
        }

        var rssText: String {
            if rssKB >= 1048576 { return String(format: "%.1f GB", Double(rssKB) / 1048576.0) }
            if rssKB >= 1024 { return String(format: "%.1f MB", Double(rssKB) / 1024.0) }
            return "\(rssKB) KB"
        }
    }

    /// 按包名聚合的进程组，与原版 processList 结构一致
    struct Group: Identifiable, Hashable {
        let packageName: String
        var processes: [Proc]
        /// 车机上的真实应用名，拿不到时为空
        var label: String = ""

        var displayName: String {
            if !label.isEmpty { return label }
            let last = packageName.split(separator: ".").last.map(String.init) ?? packageName
            return last.prefix(1).uppercased() + last.dropFirst()
        }

        var id: String { packageName }

        var totalRssKB: Int { processes.reduce(0) { $0 + $1.rssKB } }
        var totalRssText: String {
            if totalRssKB >= 1048576 { return String(format: "%.1f GB", Double(totalRssKB) / 1048576.0) }
            if totalRssKB >= 1024 { return String(format: "%.1f MB", Double(totalRssKB) / 1024.0) }
            return "\(totalRssKB) KB"
        }
        var processCount: Int { processes.count }

        /// 组内 CPU 合计，原版 coerceAtMost(100)
        var totalCPU: Double {
            min(processes.reduce(0) { $0 + $1.cpuUsage }, 100)
        }
        var totalCPUText: String {
            String(format: "CPU %.1f%%", max(totalCPU, 0))
        }
    }

    /// 排序方式（原版 ProcessSortType）
    enum SortType: String, CaseIterable, Identifiable {
        case memory, cpu
        var id: String { rawValue }
        var title: String { self == .memory ? "内存占用" : "CPU占用" }
    }

    @Published var sortType: SortType = .memory

    @Published private(set) var groups: [Group] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var totalMemoryText = "--"
    @Published private(set) var usedMemoryText = "--"
    @Published private(set) var freeMemoryText = "--"
    @Published private(set) var memoryRatio: Double = 0
    @Published private(set) var killedMessage: String?

    var isDemo = false
    private let adb = AdbService.shared

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    var totalProcessCount: Int { groups.reduce(0) { $0 + $1.processCount } }

    // MARK: - 加载

    func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }

        if isDemo {
            loadDemo()
            return
        }

        // 内存统计与原版一致：dumpsys meminfo 的 Total RAM / Free RAM
        let memRaw = (await shellLines("dumpsys meminfo")).joined(separator: "\n")
        parseMemInfo(memRaw)

        // 三列格式，兼容性最好
        var psOut = await shellLines("ps -A -o PID,RSS,NAME")
        if psOut.isEmpty || !looksValid(psOut) {
            // 退一步：不带 -o（列不固定，只能尽力解析）
            psOut = await shellLines("ps -A")
        }

        AppLabelService.shared.bind()
        await AppLabelService.shared.warmupIfNeeded()

        let parsed = parsePS(psOut)
        if parsed.isEmpty {
            errorMessage = "读不到应用进程。可能设备限制了 ps 输出，或当前是 root 受限环境。"
        }
        groups = groupByPackage(parsed)
        killedMessage = nil
    }

    private func looksValid(_ rows: [String]) -> Bool {
        guard let head = rows.first?.lowercased() else { return false }
        // 表头应含 pid，且行数看起来合理
        return head.contains("pid") && rows.count > 3
    }

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }

    // MARK: - 内存（对齐原版 extractMemValue）

    /// 原版：在 dumpsys meminfo 里找含 "Total RAM" / "Free RAM" 的行，
    /// 取第一个数字串（去掉 , 和 .），单位是 KB。
    private func parseMemInfo(_ raw: String) {
        let total = extractMemValue(raw, key: "Total RAM")
        let free = extractMemValue(raw, key: "Free RAM")
        guard total > 0 else { return }

        let used = total > free ? total - free : 0
        totalMemoryText = fmtKB(Double(total))
        usedMemoryText = fmtKB(Double(used))
        freeMemoryText = fmtKB(Double(free))
        memoryRatio = Double(used) / Double(total)
    }

    private func extractMemValue(_ raw: String, key: String) -> Int64 {
        for line in raw.split(separator: "\n") {
            guard line.lowercased().contains(key.lowercased()) else { continue }
            // 取该行第一个数字串
            let digits = line.split(whereSeparator: { !$0.isNumber && $0 != "," && $0 != "." })
            if let first = digits.first {
                let cleaned = first.replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: ".", with: "")
                if let v = Int64(cleaned) { return v }
            }
        }
        return 0
    }

    private func fmtKB(_ kb: Double) -> String {
        if kb >= 1048576 { return String(format: "%.1f GB", kb / 1048576.0) }
        return String(format: "%.0f MB", kb / 1024.0)
    }

    // MARK: - PS 解析（对齐原版过滤条件）

    private func parsePS(_ rows: [String]) -> [Proc] {
        var out: [Proc] = []
        for (index, row) in rows.enumerated() {
            let t = row.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            // 跳过表头
            if index == 0 && t.lowercased().contains("pid") { continue }

            let parts = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3 else { continue }

            let name = parts.last ?? ""
            // 原版关键过滤：必须含 "." 且不以 "/" 开头 → 只有 App 进程
            guard name.contains("."), !name.hasPrefix("/") else { continue }
            guard let pid = Int(parts[0]) else { continue }

            // 三列格式：PID RSS NAME → parts[1] 是 RSS
            // 非三列格式时，从中间列里找最大的数字当 RSS，找不到记 0
            var rss = Int(parts[1]) ?? 0
            if rss == 0, parts.count > 3 {
                let candidates = parts[1..<(parts.count - 1)].compactMap { Int($0) }
                rss = candidates.max() ?? 0
            }

            let pkg = name.contains(":") ? String(name[..<name.firstIndex(of: ":")!]) : name

            out.append(Proc(
                pid: pid,
                name: name,
                packageName: pkg,
                isMainProcess: name == pkg,
                rssKB: rss
            ))
        }

        // 去重（某些 ROM 的 ps -A 会重复输出）
        var seen = Set<Int>()
        return out.filter { seen.insert($0.pid).inserted }
    }

    /// 按包名聚合，主进程排前面
    private func groupByPackage(_ procs: [Proc]) -> [Group] {
        var map: [String: [Proc]] = [:]
        for p in procs {
            map[p.packageName, default: []].append(p)
        }
        let service = AppLabelService.shared
        return map.map { pkg, list in
            Group(
                packageName: pkg,
                processes: list.sorted {
                    if $0.isMainProcess != $1.isMainProcess { return $0.isMainProcess }
                    return $0.rssKB > $1.rssKB
                },
                label: service.label(for: pkg) ?? ""
            )
        }
        .sorted { $0.totalRssKB > $1.totalRssKB }
    }

    // MARK: - 结束进程（对齐原版：kill 而非 kill -9）

    /// 原版 ProcessInfo.kt:703 用 `kill ${pid}`，即 SIGTERM。
    /// 用 -9 会跳过进程的清理逻辑，某些守护进程还会被系统立刻拉起。
    func kill(_ proc: Proc) async -> String? {
        if isDemo {
            removeLocally(proc.pid)
            killedMessage = "已结束 \(proc.name)（演示）"
            return nil
        }

        let lines = await shellLines("kill \(proc.pid) 2>&1")
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        if !text.isEmpty && (text.lowercased().contains("denied")
                             || text.lowercased().contains("no such")) {
            return "结束失败：\(text)"
        }

        // 复核：SIGTERM 后进程可能仍存活
        let check = await shellLines("ps -A -o PID | grep -w \(proc.pid)")
        if !check.isEmpty {
            return "SIGTERM 已发送，但进程 \(proc.pid) 仍在。该进程可能忽略终止信号，需要强制结束。"
        }
        removeLocally(proc.pid)
        killedMessage = "已结束 \(proc.name)"
        return nil
    }

    /// 强制结束（-9），用于上一步失败的情况
    func forceKill(_ proc: Proc) async -> String? {
        if isDemo {
            removeLocally(proc.pid)
            return nil
        }
        _ = await shellLines("kill -9 \(proc.pid) 2>&1")
        let check = await shellLines("ps -A -o PID | grep -w \(proc.pid)")
        if !check.isEmpty {
            return "强制结束仍失败。进程可能被系统守护，或 adb shell 权限不足。"
        }
        removeLocally(proc.pid)
        killedMessage = "已强制结束 \(proc.name)"
        return nil
    }

    /// 按包名整组强停（原版 ProcessInfo.kt:689 `am force-stop <pkg>`）。
    /// 比逐个 kill 干净：一次让系统回收该 App 的全部进程。
    func forceStopGroup(_ group: Group) async -> String? {
        if isDemo {
            groups.removeAll { $0.packageName == group.packageName }
            killedMessage = "已停止 \(group.packageName)（演示）"
            return nil
        }

        let lines = await shellLines("am force-stop \(group.packageName) 2>&1")
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("exception") || lower.contains("denied") {
            return "停止失败：\(text)"
        }

        // 复核：强停后不应再有同名进程
        let check = await shellLines("ps -A -o NAME | grep -c '\(group.packageName)'")
        let remaining = Int(check.joined().trimmingCharacters(in: .whitespaces)) ?? 0
        if remaining > 0 {
            return "am force-stop 已执行，但仍有 \(remaining) 个进程存活（可能是守护进程）"
        }

        groups.removeAll { $0.packageName == group.packageName }
        killedMessage = "已停止 \(group.packageName)"
        return nil
    }

    // MARK: - CPU 占用（原版 readCpuSnapshot + refreshCpuUsage）

    private var cpuTimer: Task<Void, Never>?
    private var lastResortAt: Date = .distantPast

    /// 一次采样：`/proc/stat` 总时间 + 每个 pid 的 utime+stime
    private func readCPUSnapshot(pids: [Int]) async -> (total: Int64, perPID: [Int: Int64]) {
        guard !pids.isEmpty else { return (0, [:]) }

        let pidArgs = pids.map(String.init).joined(separator: " ")
        let cmd = "cat /proc/stat; for pid in \(pidArgs); "
            + "do if [ -r /proc/$pid/stat ]; then printf 'PROC '; cat /proc/$pid/stat; fi; done"
        let lines = await shellLines(cmd)

        var total: Int64 = 0
        var perPID: [Int: Int64] = [:]

        for line in lines {
            if line.hasPrefix("cpu ") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                total = parts.dropFirst().reduce(0) { acc, p in acc + (Int64(p) ?? 0) }
                continue
            }
            guard line.hasPrefix("PROC ") else { continue }

            // comm 里可能有空格和括号，必须从最后一个 ") " 切
            let stat = String(line.dropFirst(5))
            guard let r = stat.range(of: ") ", options: .backwards) else { continue }

            let pidText = stat.split(separator: " ").first.map(String.init) ?? ""
            guard let pid = Int(pidText) else { continue }

            let tail = stat[r.upperBound...].split(separator: " ", omittingEmptySubsequences: true)
            guard tail.count > 12,
                  let utime = Int64(tail[11]),
                  let stime = Int64(tail[12]) else { continue }
            perPID[pid] = utime + stime
        }
        return (total, perPID)
    }

    /// 采样窗口 250ms，算每个进程的 CPU 占比
    private func refreshCPUUsage() async {
        let pids = groups.flatMap { $0.processes.map(\.pid) }
        guard !pids.isEmpty else { return }

        let first = await readCPUSnapshot(pids: pids)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let second = await readCPUSnapshot(pids: pids)

        let totalDelta = second.total - first.total
        guard totalDelta > 0 else { return }

        var usage: [Int: Double] = [:]
        for pid in pids {
            let a = first.perPID[pid] ?? 0
            let b = second.perPID[pid] ?? a
            let delta = max(0, b - a)
            usage[pid] = min(100, Double(delta) / Double(totalDelta) * 100)
        }

        for gi in groups.indices {
            for pi in groups[gi].processes.indices {
                let pid = groups[gi].processes[pi].pid
                if let u = usage[pid] {
                    groups[gi].processes[pi].cpuUsage = u
                }
            }
        }

        // CPU 排序时每 2 秒重排一次，避免数字跳动导致列表抖
        if sortType == .cpu, Date().timeIntervalSince(lastResortAt) >= 2 {
            lastResortAt = Date()
            resort()
        }
    }

    /// 按当前排序方式重排分组
    func resort() {
        groups.sort { a, b in
            if sortType == .cpu {
                if a.totalCPU != b.totalCPU { return a.totalCPU > b.totalCPU }
                if a.totalRssKB != b.totalRssKB { return a.totalRssKB > b.totalRssKB }
                return a.packageName < b.packageName
            } else {
                if a.totalRssKB != b.totalRssKB { return a.totalRssKB > b.totalRssKB }
                if a.totalCPU != b.totalCPU { return a.totalCPU > b.totalCPU }
                return a.packageName < b.packageName
            }
        }
    }

    /// 启动 CPU 轮询（1 秒一次）
    func startCPUMonitor() {
        stopCPUMonitor()
        guard !isDemo else { return }
        cpuTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCPUUsage()
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopCPUMonitor() {
        cpuTimer?.cancel()
        cpuTimer = nil
    }

    private func removeLocally(_ pid: Int) {
        groups = groups.compactMap { g in
            var p = g.processes
            p.removeAll { $0.pid == pid }
            guard !p.isEmpty else { return nil }
            return Group(packageName: g.packageName, processes: p)
        }
    }

    // MARK: - 演示

    private func loadDemo() {
        totalMemoryText = "3.9 GB"
        usedMemoryText = "2.4 GB"
        freeMemoryText = "1.5 GB"
        memoryRatio = 0.62

        let raw: [(Int, String, Int)] = [
            (245, "system_server", 287000),
            (512, "com.zzh.launcher50s", 342000),
            (513, "com.zzh.launcher50s:remote", 46000),
            (588, "com.sgmw.keyless", 128000),
            (455, "com.android.systemui", 186000),
            (602, "com.android.settings", 76400),
            (655, "com.sgmw.carradio", 52000),
            (701, "com.sgmw.navi", 148000),
            (712, "com.sgmw.navi:service", 32000),
            (744, "com.sgmw.voice", 36800),
            (801, "com.jingos.mediacenter", 29400),
        ]

        let procs = raw.map { pid, name, rss in
            Proc(pid: pid, name: name,
                 packageName: name.contains(":") ? String(name[..<name.firstIndex(of: ":")!]) : name,
                 isMainProcess: !name.contains(":"),
                 rssKB: rss)
        }
        groups = groupByPackage(procs)
        errorMessage = nil
    }
}
