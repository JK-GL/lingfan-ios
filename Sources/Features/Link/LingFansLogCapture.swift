import Foundation

/// 菱粉日志抓取
///
/// 逐条对齐原版 `link/LingFansLogCaptureSupport.kt`：
///   1. 读设备当前时间（`date '+%Y-%m-%d %H:%M:%S'`）作为时间窗右边界
///   2. 读菱粉桌面进程（ps -A -o PID,ARGS → ps -A → pidof 三级回退）
///   3. 抓 logcat 全量 dump（三条命令逐级降级）
///   4. 只保留「近 3 分钟内」且「属于菱粉进程或日志里出现包名」的行
///
/// logcat 行没有年份，所以用设备当前年补全；
/// 若补出来的时间比设备现在晚 1 分钟以上，说明跨年了，减 1 年。
enum LingFansLog {

    static let launcherPackage = "com.zzh.launcher50s.alpha"
    static let lineLimit = 8000
    /// 时间窗（分钟）
    static let windowMinutes: Double = 3

    static let deviceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let summaryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// threadtime 格式：
    /// `10-19 20:18:04.123  1234  1250 I TagName: message`
    static let lineRegex = try! NSRegularExpression(
        pattern: #"^(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEAF])\s+(.+?):\s?(.*)$"#
    )
}

struct LingFansLogEntry {
    let timestamp: Date
    let pid: Int
    let tid: Int
    let priority: String
    let tag: String
    let message: String
    let rawLine: String
}

struct LingFansLogCaptureResult {
    let entries: [LingFansLogEntry]
    let previewText: String
    let exportText: String
    let message: String
    let windowLabel: String
    let matchedCount: Int
    let scannedCount: Int
    let usedFallbackCommand: Bool
}

/// 抓取器。shell 通过闭包注入，方便在 Store 里接 AdbService。
struct LingFansLogCapture {

    typealias Shell = (String) async -> [String]

    let shell: Shell

    func run() async -> LingFansLogCaptureResult {
        let deviceNow = await readDeviceNow()
        let pids = await readProcessPIDs()
        let dump = await readLogcatDump()
        let windowStart = deviceNow.addingTimeInterval(-LingFansLog.windowMinutes * 60)

        var matched: [LingFansLogEntry] = []
        var scanned = 0

        for raw in dump.output.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            scanned += 1
            guard let entry = Self.parse(raw, deviceNow: deviceNow) else { continue }
            guard Self.isWithinWindow(entry.timestamp, start: windowStart, end: deviceNow) else { continue }
            guard Self.shouldKeep(entry, activePIDs: pids) else { continue }
            matched.append(entry)
        }

        let windowLabel = "\(LingFansLog.summaryFormatter.string(from: windowStart)) 至 "
            + LingFansLog.summaryFormatter.string(from: deviceNow)

        let message = matched.isEmpty
            ? "近 3 分钟内未抓到菱粉桌面相关日志"
            : "已抓到 \(matched.count) 条菱粉桌面相关日志"

        let exportText = Self.buildExportText(
            windowLabel: windowLabel,
            message: message,
            usedFallback: dump.usedFallback,
            entries: matched
        )

        return LingFansLogCaptureResult(
            entries: matched,
            previewText: Self.buildPreviewText(exportText),
            exportText: exportText,
            message: message,
            windowLabel: windowLabel,
            matchedCount: matched.count,
            scannedCount: scanned,
            usedFallbackCommand: dump.usedFallback
        )
    }

    // MARK: - 设备时间

    private func readDeviceNow() async -> Date {
        let lines = await shell("date '+%Y-%m-%d %H:%M:%S'")
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return LingFansLog.deviceFormatter.date(from: text) ?? Date()
    }

    // MARK: - 进程

    /// 三级回退：ps -A -o PID,ARGS → ps -A → pidof
    private func readProcessPIDs() async -> Set<Int> {
        let preferred = await shell("ps -A -o PID,ARGS 2>/dev/null")
        let p1 = Self.parsePIDs(preferred)
        if !p1.isEmpty { return p1 }

        let fallback = await shell("ps -A 2>/dev/null")
        let p2 = Self.parsePIDs(fallback)
        if !p2.isEmpty { return p2 }

        let pidof = await shell("pidof \(LingFansLog.launcherPackage) 2>/dev/null")
        return Set(
            pidof.joined(separator: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .compactMap { Int($0) }
        )
    }

    static func parsePIDs(_ lines: [String]) -> Set<Int> {
        var pids = Set<Int>()
        for line in lines {
            let tokens = line
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard !tokens.isEmpty else { continue }
            // pid 是第一个纯数字 token
            guard let pid = tokens.first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                  let pidValue = Int(pid) else { continue }
            // 必须能在这个进程的命令行里看到菱粉包名
            let isLingFans = tokens.contains {
                $0 == LingFansLog.launcherPackage
                    || $0.hasPrefix(LingFansLog.launcherPackage + ":")
            }
            if isLingFans { pids.insert(pidValue) }
        }
        return pids
    }

    // MARK: - logcat

    private func readLogcatDump() async -> (output: String, usedFallback: Bool) {
        let commands = [
            "logcat -d -v threadtime -b main -b system -b crash -t \(LingFansLog.lineLimit)",
            "logcat -d -v threadtime -b main -b system -b crash",
            "logcat -d -v threadtime",
        ]

        var lastOutput = ""
        for (index, cmd) in commands.enumerated() {
            let lines = await shell(cmd)
            let output = lines.joined(separator: "\n")
            lastOutput = output
            let lower = output.lowercased()
            let unsupported = lower.contains("unknown option") || lower.contains("invalid option")
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !unsupported {
                return (output, index > 0)
            }
        }
        return (lastOutput, true)
    }

    // MARK: - 解析

    static func parse(_ line: String, deviceNow: Date) -> LingFansLogEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard let m = LingFansLog.lineRegex.firstMatch(
            in: trimmed, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }

        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }

        guard let month = Int(group(1)), let day = Int(group(2)),
              let hour = Int(group(3)), let minute = Int(group(4)),
              let second = Int(group(5)), let millis = Int(group(6)),
              let pid = Int(group(7)), let tid = Int(group(8)) else { return nil }

        let priority = group(9)
        let tag = group(10).trimmingCharacters(in: .whitespaces)
        let message = group(11)

        // 用设备当前年补全，logcat 行里没有年份
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents([.year], from: deviceNow)
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        comps.nanosecond = millis * 1_000_000
        guard var ts = cal.date(from: comps) else { return nil }

        // 跨年：补出来的时间比现在还晚 1 分钟以上，说明是去年 12 月的日志
        if ts.timeIntervalSince(deviceNow) > 60 {
            ts = cal.date(byAdding: .year, value: -1, to: ts) ?? ts
        }

        return LingFansLogEntry(
            timestamp: ts, pid: pid, tid: tid, priority: priority,
            tag: tag, message: message, rawLine: line
        )
    }

    static func isWithinWindow(_ ts: Date, start: Date, end: Date) -> Bool {
        ts >= start && ts <= end.addingTimeInterval(5)
    }

    static func shouldKeep(_ entry: LingFansLogEntry, activePIDs: Set<Int>) -> Bool {
        if activePIDs.contains(entry.pid) { return true }
        let pkg = LingFansLog.launcherPackage.lowercased()
        return entry.rawLine.lowercased().contains(pkg)
            || entry.tag.lowercased().contains(pkg)
            || entry.message.lowercased().contains(pkg)
    }

    // MARK: - 输出

    static func buildPreviewText(_ text: String) -> String {
        let limit = 16 * 1024
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "\n\n... (预览已截断，导出文件保留完整内容) ..."
    }

    static func buildExportText(
        windowLabel: String,
        message: String,
        usedFallback: Bool,
        entries: [LingFansLogEntry]
    ) -> String {
        var s = ""
        s += "LingFans 日志抓取\n"
        s += "时间范围: \(windowLabel)\n"
        s += "目标包名: \(LingFansLog.launcherPackage)\n"
        s += "结果摘要: \(message)\n"
        s += "logcat 回退: \(usedFallback ? "已使用兼容命令" : "未触发")\n"
        s += "命中条数: \(entries.count)\n\n"
        if entries.isEmpty {
            s += "近 3 分钟窗口内没有匹配到日志。\n"
        } else {
            for e in entries { s += e.rawLine + "\n" }
        }
        return s.trimmingCharacters(in: .newlines)
    }
}
