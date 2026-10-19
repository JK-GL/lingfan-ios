import Foundation

/// 进程管理的数据层
///
/// 解析目标：`ps -A -o PID,USER,RSS,VSZ,STAT,NAME` 与 `dumpsys meminfo` 汇总。
/// 车机 ROM 差异大，这里对 `ps` 输出做宽松解析：
///   - 优先用带表头的 `ps -A -o ...`（含 RSS 列）
///   - 失败则退回 `ps -A`（列不固定，只能拿 PID/NAME）
final class ProcessStore: ObservableObject {

    struct Proc: Identifiable, Hashable {
        let pid: Int
        let user: String
        /// 物理内存 KB
        let rssKB: Int
        /// 虚拟内存 KB
        let vszKB: Int
        let state: String
        let name: String

        var id: Int { pid }

        /// 人类可读内存
        var rssText: String {
            if rssKB >= 1024 * 1024 { return String(format: "%.1f GB", Double(rssKB) / 1048576.0) }
            if rssKB >= 1024 { return String(format: "%.1f MB", Double(rssKB) / 1024.0) }
            return "\(rssKB) KB"
        }

        /// 是否系统进程（user 为 root/system 等）
        var isSystem: Bool {
            let u = user.lowercased()
            return u == "root" || u == "system" || u.contains("system") || u.contains("radio")
        }

        var isRunning: Bool {
            state.uppercased().hasPrefix("R")
        }
    }

    @Published private(set) var processes: [Proc] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var totalMemoryText = "--"
    @Published private(set) var usedMemoryText = "--"
    @Published private(set) var processCount = 0
    @Published private(set) var killedMessage: String?

    var isDemo = false
    private let adb = AdbService.shared
    private let maxRows = 400

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - 加载

    func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }

        if isDemo {
            loadDemo()
            return
        }

        let meminfo = await shellLines("cat /proc/meminfo | head -5")
        parseMemInfo(meminfo)

        // 先试带 RSS 的格式；失败再退回裸 ps
        var rows = await shellLines("ps -A -o PID,USER,RSS,VSZ,STAT,NAME")
        if !looksLikeValidPS(rows) {
            rows = await shellLines("ps -A")
        }
        let parsed = parsePS(rows)

        if parsed.isEmpty {
            errorMessage = "无法解析进程列表。设备可能限制 ps 输出，或 adb shell 未授权。"
        }
        processes = parsed
        processCount = parsed.count
    }

    private func looksLikeValidPS(_ rows: [String]) -> Bool {
        guard let head = rows.first else { return false }
        let h = head.lowercased()
        return h.contains("pid") && (h.contains("rss") || h.contains("name"))
    }

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }

    // MARK: - 内存汇总

    private func parseMemInfo(_ lines: [String]) {
        var total = 0.0
        var avail = 0.0
        for line in lines {
            if line.hasPrefix("MemTotal:") { total = firstNumber(line) }
            if line.hasPrefix("MemAvailable:") { avail = firstNumber(line) }
        }
        guard total > 0 else { return }
        totalMemoryText = fmtKB(total)
        usedMemoryText = fmtKB(total - avail)
    }

    private func firstNumber(_ line: String) -> Double {
        for part in line.split(separator: " ") {
            if let v = Double(part) { return v }
        }
        return 0
    }

    private func fmtKB(_ kb: Double) -> String {
        String(format: "%.1f GB", kb / 1048576.0)
    }

    // MARK: - PS 解析

    /// 解析多种 ps 输出格式。
    /// 常见三种：
    ///   A) `  PID USER     RSS   VSZ STAT NAME`（带表头，最理想）
    ///   B) `USER  PID ...`（老 busybox，user 在前）
    ///   C) `u0_a123  1234  5678  123456  S  com.xxx`（无表头）
    private func parsePS(_ rows: [String]) -> [Proc] {
        guard !rows.isEmpty else { return [] }

        var startIndex = 0
        var header: [String] = []
        if let h = rows.first, h.lowercased().contains("pid") {
            header = h.lowercased().split(separator: " ").map(String.init)
            startIndex = 1
        }

        var result: [Proc] = []
        for row in rows[startIndex...] {
            let cols = row.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3 else { continue }

            if !header.isEmpty {
                if let p = parseWithHeader(cols, header) {
                    result.append(p)
                }
            } else if let p = parseWithoutHeader(cols) {
                result.append(p)
            }
            if result.count >= maxRows { break }
        }

        // 按 RSS 降序，最能看出谁吃内存
        return result.sorted { $0.rssKB > $1.rssKB }
    }

    private func parseWithHeader(_ cols: [String], _ header: [String]) -> Proc? {
        func idx(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let pidIdx = idx("pid"), pidIdx < cols.count,
              let pid = Int(cols[pidIdx]) else { return nil }

        let userIdx = idx("user")
        let rssIdx = idx("rss")
        let vszIdx = idx("vsz")
        let statIdx = idx("stat") ?? idx("s")
        // NAME 是最后一列；有些 ROM 叫 cmd 或 args
        let nameIdx = idx("name") ?? idx("cmd") ?? idx("args")
        let name = (nameIdx.map { $0 < cols.count ? cols[$0] : "" })
            ?? (cols.last ?? "")

        return Proc(
            pid: pid,
            user: userIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? "-",
            rssKB: rssIdx.flatMap { $0 < cols.count ? Int(cols[$0]) : nil } ?? 0,
            vszKB: vszIdx.flatMap { $0 < cols.count ? Int(cols[$0]) : nil } ?? 0,
            state: statIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? "?",
            name: name
        )
    }

    /// 无表头：从右往左找，最后一个非数字列当名字
    private func parseWithoutHeader(_ cols: [String]) -> Proc? {
        guard let pid = cols.compactMap({ Int($0) }).first else { return nil }
        let name = cols.last ?? ""
        guard !name.isEmpty, Int(name) == nil else { return nil }

        // 找连续的、像内存的数字
        let nums = cols.compactMap { Int($0) }
        let rss = nums.count >= 2 ? nums[1] : 0
        let vsz = nums.count >= 3 ? nums[2] : 0

        return Proc(
            pid: pid,
            user: cols.first ?? "-",
            rssKB: rss,
            vszKB: vsz,
            state: "?",
            name: name
        )
    }

    // MARK: - 结束进程

    /// 结束进程。返回 nil 表示成功，否则返回错误说明。
    func kill(_ proc: Proc) async -> String? {
        if isDemo {
            // 演示模式只在本地移除，不碰真设备
            processes.removeAll { $0.pid == proc.pid }
            processCount = processes.count
            killedMessage = "已结束 \(proc.name)（演示）"
            return nil
        }

        let lines = await shellLines("kill -9 \(proc.pid) 2>&1")
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.lowercased().contains("killed") {
            processes.removeAll { $0.pid == proc.pid }
            processCount = processes.count
            killedMessage = "已结束 \(proc.name)"
            // 复核是否真的没了
            let check = await shellLines("ps -A -o PID | grep -w \(proc.pid)")
            if !check.isEmpty {
                return "命令已执行，但进程 \(proc.pid) 仍存在（可能被守护进程重启）"
            }
            return nil
        }
        return text
    }

    // MARK: - 演示数据

    private func loadDemo() {
        totalMemoryText = "3.9 GB"
        usedMemoryText = "2.4 GB"

        let demo: [(Int, String, Int, Int, String, String)] = [
            (1, "root", 12800, 20480, "S", "init"),
            (198, "root", 24576, 40960, "S", "zygote64"),
            (245, "system", 287000, 512000, "S", "system_server"),
            (312, "system", 96400, 160000, "S", "surfaceflinger"),
            (388, "system", 41200, 88000, "S", "audioserver"),
            (402, "root", 8600, 12000, "S", "logd"),
            (455, "u0_a32", 186000, 320000, "S", "com.android.systemui"),
            (512, "u0_a64", 342000, 580000, "S", "com.zzh.launcher50s"),
            (588, "u0_a71", 128000, 240000, "S", "com.sgmw.keyless"),
            (602, "u0_a88", 76400, 150000, "S", "com.android.settings"),
            (655, "u0_a92", 52000, 98000, "S", "com.sgmw.carradio"),
            (701, "u0_a95", 34800, 72000, "S", "com.sgmw.navi"),
            (744, "u0_a101", 28900, 56000, "R", "top"),
            (780, "shell", 11200, 18000, "S", "sh"),
        ]

        processes = demo.map {
            Proc(pid: $0.0, user: $0.1, rssKB: $0.2, vszKB: $0.3,
                 state: $0.4, name: $0.5)
        }.sorted { $0.rssKB > $1.rssKB }
        processCount = processes.count
        errorMessage = nil
    }
}
