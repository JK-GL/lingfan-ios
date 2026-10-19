import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 常用工具的数据层
///
/// 全部走 shell，不依赖 file_sync：
///   截图  screencap -p 后 base64，再在 iOS 端解码成图片
///   日志  logcat -d -t N
///   重启  reboot / reboot -p
///
/// 用 base64 而不是 `adb pull` 的原因：
///   file_sync 协议在 iOS 移植版里没验证过，
///   base64 走的是标准 shell 通道，风险最低。代价是体积膨胀 33%，
///   但 1080p 截图约 200KB，完全可接受。
@MainActor
final class ToolsStore: ObservableObject {

    @Published private(set) var running = false
    @Published private(set) var lastMessage: String?
    /// 长耗时操作的进度提示（录屏、取回等），界面据此显示转圈
    @Published private(set) var busyMessage: String?
    /// 截图结果，可直接放进 Image(uiImage:)
    @Published var screenshot: PlatformImage?
    @Published private(set) var logText: String = ""
    @Published private(set) var deviceInfoText: String = ""

    var isDemo = false
    private let adb = AdbService.shared

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - 截图

    func takeScreenshot() async {
        running = true
        lastMessage = nil
        defer { running = false }

        if isDemo {
            screenshot = DemoContent.makeScreenshot()
            lastMessage = "已截取（演示）"
            return
        }

        // -p 表示 PNG 输出；base64 避免二进制走文本通道被截断
        let lines = await shellLines("screencap -p | base64")
        let b64 = lines.joined()   // 注意：不要加换行，base64 解码会失败
        guard !b64.isEmpty else {
            lastMessage = "截图失败：无输出。车机可能未授权 screencap 或屏幕被占用。"
            return
        }
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            lastMessage = "截图失败：base64 解码失败（输出可能被截断）"
            return
        }
        guard let img = PlatformImage(data: data) else {
            lastMessage = "截图失败：PNG 解码失败（\(data.count) 字节）"
            return
        }
        screenshot = img
        lastMessage = "截图成功（\(data.count / 1024) KB）"
    }

    // MARK: - 顶层窗口（对齐原版 ToolItem.kt:297）

    @Published private(set) var topWindowText: String = ""

    func loadTopWindow() async {
        busyMessage = "读取顶层窗口…"
        defer { busyMessage = nil }

        if isDemo {
            topWindowText = """
            mCurrentFocus=Window{3f2a1b com.zzh.launcher50s/com.zzh.launcher50s.MainActivity}
            mFocusedApp=AppWindowToken{9c4d2e token=Token{5a1f3b ActivityRecord{com.zzh.launcher50s/.MainActivity}}}
            """
            return
        }

        let lines = await shellLines(
            "dumpsys window displays | grep -E 'mCurrentFocus|mFocusedApp'"
        )
        topWindowText = lines.isEmpty
            ? "没有读到窗口信息（部分 ROM 限制了 dumpsys 权限）"
            : lines.joined(separator: "\n")
        lastMessage = nil
    }

    // MARK: - 屏幕录制

    @Published private(set) var recording = false
    @Published private(set) var recordingSeconds: Int = 0
    private var recordingTask: Task<Void, Never>?

    /// 用 screenrecord 录到设备临时文件，停止后拉回本机。
    /// 原版命令：screenrecord --time-limit N /data/local/tmp/screen.mp4
    func startRecording(maxSeconds: Int = 180) async {
        guard !recording else { return }

        if isDemo {
            recording = true
            recordingSeconds = 0
            recordingTask = Task { @MainActor [weak self] in
                while let self, self.recording {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    self.recordingSeconds += 1
                }
            }
            return
        }

        busyMessage = "录制中（最长 \(maxSeconds) 秒）…"
        recording = true
        recordingSeconds = 0
        lastMessage = nil

        // 后台跑 screenrecord，同时计时
        let cmd = "screenrecord --time-limit \(maxSeconds) /data/local/tmp/lingfan_rec.mp4"
        recordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 放到后台队列执行阻塞命令
            let service = AdbService.shared
            DispatchQueue.global(qos: .userInitiated).async {
                _ = service.run(["shell", cmd])
            }
            while self.recording {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                self.recordingSeconds += 1
                if self.recordingSeconds >= maxSeconds {
                    // screenrecord 到达 --time-limit 会自行结束，
                    // 这里同步把状态收掉，否则界面会一直显示「录制中」
                    self.recording = false
                    break
                }
            }
        }
        busyMessage = nil
    }

    func stopRecording() async -> String? {
        recording = false
        recordingTask?.cancel()
        recordingTask = nil

        if isDemo {
            lastMessage = "演示模式未生成视频文件"
            return nil
        }

        busyMessage = "停止录制并取回…"
        defer { busyMessage = nil }

        // screenrecord 响应 SIGINT 才会正常封盘
        _ = await shellLines("pkill -2 screenrecord")

        let dir = FilesStore.localPullDirectory()
        let dest = dir.appendingPathComponent("lingfan_rec.mp4")
        try? FileManager.default.removeItem(at: dest)

        // 给系统一点时间写完文件
        try? await Task.sleep(nanoseconds: 900_000_000)

        let result = await runCommand(["pull", "/data/local/tmp/lingfan_rec.mp4", dest.path])
        _ = await shellLines("rm -f /data/local/tmp/lingfan_rec.mp4")

        if FileManager.default.fileExists(atPath: dest.path) {
            lastPulledVideoPath = dest.path
            lastMessage = "录制完成"
            return dest.path
        }
        let alt = dest.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: alt.path) {
            try? FileManager.default.moveItem(at: alt, to: dest)
            lastPulledVideoPath = dest.path
            return dest.path
        }
        return result.output.isEmpty ? "取回视频失败：无回执" : result.output
    }

    @Published private(set) var lastPulledVideoPath: String?

    private struct ToolsCmdResult {
        let success: Bool
        let output: String
    }

    private func runCommand(_ args: [String]) async -> ToolsCmdResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ToolsCmdResult, Never>) in
            adb.runAsync(args) { r in
                cont.resume(returning: ToolsCmdResult(success: r.success, output: r.output))
            }
        }
    }

    // MARK: - 日志（持续抓取，对齐原版 ToolItem.kt toggleLogcat）

    @Published private(set) var isLogging = false
    @Published private(set) var logSeconds = 0
    @Published private(set) var lastLogPath: String?
    private var logTimerTask: Task<Void, Never>?

    var logDurationText: String {
        String(format: "%02d:%02d", logSeconds / 60, logSeconds % 60)
    }

    func toggleLogging() async {
        if isLogging {
            _ = await stopLogging()
        } else {
            await startLogging()
        }
    }

    /// 开始：先 logcat -c 清缓冲区，再后台挂 `logcat -f` 持续写设备文件。
    /// 原版就是这么做的 —— 不是定时拉快照，而是一条长命令写到 stop 为止。
    func startLogging() async {
        guard !isLogging else { return }
        lastMessage = nil
        logText = ""

        if isDemo {
            isLogging = true
            logSeconds = 0
            logTimerTask = Task { @MainActor [weak self] in
                while let self, self.isLogging {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    self.logSeconds += 1
                }
            }
            return
        }

        _ = await shellLines("logcat -c")

        // logcat -f 不会返回，必须放后台队列，否则界面直接卡死
        let service = AdbService.shared
        DispatchQueue.global(qos: .utility).async {
            _ = service.run(["shell", "logcat -f /data/local/tmp/adblog.txt"])
        }

        isLogging = true
        logSeconds = 0
        logTimerTask = Task { @MainActor [weak self] in
            while let self, self.isLogging {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                self.logSeconds += 1
            }
        }
        lastMessage = "开始抓取日志…"
    }

    /// 停止：pkill -2 让 logcat 刷盘 → pull 回本机 → 删设备文件 → 读前 10KB 预览。
    @discardableResult
    func stopLogging() async -> String? {
        isLogging = false
        logTimerTask?.cancel()
        logTimerTask = nil

        if isDemo {
            logText = DemoContent.makeLog()
            lastMessage = "演示模式未生成日志文件"
            return nil
        }

        busyMessage = "停止并取回日志…"
        defer { busyMessage = nil }

        // -2 就是 SIGINT，logcat 收到后才会把缓冲区刷进文件
        _ = await shellLines("pkill -2 -f 'logcat -f'")
        try? await Task.sleep(nanoseconds: 800_000_000)

        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let stamp = formatter.string(from: Date())

        let dest = FilesStore.localPullDirectory()
            .appendingPathComponent("log_\(stamp).txt")
        try? FileManager.default.removeItem(at: dest)

        _ = await runCommand(["pull", "/data/local/tmp/adblog.txt", dest.path])
        _ = await shellLines("rm -f /data/local/tmp/adblog.txt")

        guard FileManager.default.fileExists(atPath: dest.path) else {
            lastMessage = "取回日志失败（设备上可能没生成文件）"
            return nil
        }

        let raw = (try? String(contentsOf: dest, encoding: .utf8)) ?? ""
        if raw.count > 10_000 {
            logText = String(raw.prefix(10_000)) + "\n\n... (日志过长，仅展示前 10KB) ..."
        } else {
            logText = raw.isEmpty ? "日志是空的（可能 logcat -f 被 ROM 限制）" : raw
        }
        lastLogPath = dest.path
        lastMessage = "日志已取回"
        return dest.path
    }

    func clearLog() async {
        if isDemo { logText = ""; return }
        _ = await shellLines("logcat -c")
        logText = ""
        lastMessage = "日志已清空"
    }

    // MARK: - 设备状态快照

    func loadSnapshot() async {
        running = true
        defer { running = false }

        if isDemo {
            deviceInfoText = DemoContent.makeSnapshot()
            return
        }

        let cmd = [
            "echo '== 型号 =='",
            "getprop ro.product.model",
            "echo '== 系统 =='",
            "getprop ro.build.version.release",
            "echo '== 分辨率 =='",
            "wm size",
            "echo '== 运行时长 =='",
            "uptime",
            "echo '== 电量 =='",
            "dumpsys battery | grep -E 'level|status'",
            "echo '== 温度 =='",
            "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null",
        ].joined(separator: "; ")

        deviceInfoText = (await shellLines(cmd)).joined(separator: "\n")
    }

    // MARK: - 电源类

    func reboot(_ mode: RebootMode) async -> String? {
        if isDemo { return "演示模式不执行真实重启" }

        switch mode {
        case .normal: _ = await shellLines("reboot")
        case .recovery: _ = await shellLines("reboot recovery")
        case .bootloader: _ = await shellLines("reboot bootloader")
        case .shutdown: _ = await shellLines("reboot -p")
        }
        return nil
    }

    enum RebootMode: String, CaseIterable, Identifiable {
        case normal, recovery, bootloader, shutdown
        var id: String { rawValue }

        var title: String {
            switch self {
            case .normal: return "重启"
            case .recovery: return "重启到 Recovery"
            case .bootloader: return "重启到 Fastboot"
            case .shutdown: return "关机"
            }
        }

        var command: String {
            switch self {
            case .normal: return "reboot"
            case .recovery: return "reboot recovery"
            case .bootloader: return "reboot bootloader"
            case .shutdown: return "reboot -p"
            }
        }
    }

    // MARK: - 基础

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }
}

// MARK: - 跨平台图片类型

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif
