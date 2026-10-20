import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias MirrorImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias MirrorImage = NSImage
#endif

/// 设备投屏（准实时截图轮询版）
///
/// 为什么不是 scrcpy：scrcpy 需要
///   adb push server.jar → 启动 → 端口转发 → 解析 H.264 → VideoToolbox 解码
/// 四段链路，任意一段在 iOS 沙箱里出问题就全废，且无法在无真机时验证。
///
/// 这一版走 `screencap -p | base64` 轮询：
///   - 零协议风险，依赖的 shell 通道已验证
///   - 帧率实际约 1~3 fps（每次往返 + PNG 编码开销）
///   - 适合「看车机在做什么」，不适合视频
/// 等真机验证过 forward 之后再上 scrcpy 硬解。
///
/// 加 @MainActor：Task 继承隔离域，闭包里访问 self 的属性不会触发
/// "reference to captured var 'self' in concurrently-executing code"。
@MainActor
final class MirrorStore: ObservableObject {

    @Published private(set) var frame: MirrorImage?
    @Published private(set) var running = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var frameCount: Int = 0
    @Published private(set) var lastFrameBytes: Int = 0

    var isDemo = false
    private let adb = AdbService.shared
    private var task: Task<Void, Never>?
    private var demoPhase: Double = 0

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - 开关

    func start() {
        stop()
        running = true
        lastError = nil
        frameCount = 0

        // 原版 ScreenMirrorScreen.kt:355 —— 投屏期间强制屏幕常亮，
        // 否则车机熄屏后 screencap 拿到的是黑屏。
        if !isDemo {
            Task { [weak self] in
                _ = await self?.shellLines("svc power stayon true")
            }
        }

        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let t0 = Date()
                await self.grabOnce()
                let cost = Date().timeIntervalSince(t0)

                // 自适应间隔：抓取耗时越长，间隔越短，避免累计延迟
                let sleepSeconds = max(0.15, 0.55 - cost)
                if self.frameCount > 1 {
                    self.fps = 1.0 / (cost + sleepSeconds)
                }
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
        // 原版 ScreenMirrorScreen.kt 只设 stayon true，退出不恢复，这里保持一致
    }

    // MARK: - 单帧

    private func grabOnce() async {
        if isDemo {
            demoPhase += 0.14
            frame = DemoContent.makeMirrorFrame(phase: demoPhase)
            frameCount += 1
            return
        }

        // 彻底消灭 Base64 杂交：严格对齐全 App 统一的同构 pull 通道
        let remotePath = "/data/local/tmp/mirror_frame.png"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirror_frame.png")

        _ = await shellLines("screencap -p \(remotePath)")
        let (ok, _) = await adb.pull(remotePath: remotePath, localPath: tmp.path)

        guard ok, let data = try? Data(contentsOf: tmp), let img = MirrorImage(data: data) else {
            lastError = "拉取画面失败，请确认设备处于亮屏状态"
            return
        }
        frame = img
        frameCount += 1
        lastFrameBytes = data.count
        lastError = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }
}
