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
final class ToolsStore: ObservableObject {

    @Published private(set) var running = false
    @Published private(set) var lastMessage: String?
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

    // MARK: - 日志

    func loadLog(lines count: Int = 200) async {
        running = true
        lastMessage = nil
        defer { running = false }

        if isDemo {
            logText = DemoContent.makeLog()
            return
        }

        let out = await shellLines("logcat -d -t \(count) 2>/dev/null")
        logText = out.isEmpty
            ? "没有读到日志。可能需要在车机上开启开发者选项的日志权限。"
            : out.joined(separator: "\n")
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
