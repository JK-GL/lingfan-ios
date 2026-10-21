import Combine
import Foundation

/// 连接保活与自动重连
///
/// 为什么要它：adbd 的无线连接空闲几十秒就会被回收，而旧实现只在 `connect()`
/// 那一刻校验过一次，之后每条命令都是一次性 CLI 调用 —— 中间没人碰连接，
/// 断了也没人知道，用户看到的就是「连上一会儿就断了」。
///
/// 这里补三件事（对照 atvTools 的 `/ping` + EchoServer 保活思路）：
///   1. 20 秒一次 `shell echo __hb` 心跳，让 adbd 侧始终有流量
///   2. 连续 3 次失败 → 指数退避重连（1/2/4/8/16 秒，最多 5 轮）
///   3. App 进后台停心跳、回前台重建链路（start-server → connect → 心跳）
final class ConnectionKeeper: ObservableObject {

    enum State: Equatable {
        /// 从未连接
        case idle
        /// 正常
        case online
        /// 重连中（第几次）
        case reconnecting(attempt: Int)
        /// 彻底失败，需要用户手动处理
        case offline(String)

        var label: String {
            switch self {
            case .idle: return "未连接"
            case .online: return "已连接"
            case .reconnecting(let n): return "重连中 \(n)/5"
            case .offline: return "已断开"
            }
        }

        var isBroken: Bool {
            switch self {
            case .reconnecting, .offline: return true
            default: return false
            }
        }
    }

    static let shared = ConnectionKeeper()

    @Published private(set) var state: State = .idle
    @Published private(set) var lastBeat: Date?

    private let adb = AdbService.shared

    private var timer: Timer?
    private var endpoint: String?

    private var failures = 0
    private var attempt = 0
    private var isReconnecting = false
    private var suspended = false

    /// 心跳间隔
    private let beatInterval: TimeInterval = 20
    /// 连续失败几次判定断线
    private let failureThreshold = 3
    /// 最多重连几轮
    private let maxAttempts = 5

    private init() {}

    // MARK: - 挂载 / 卸载

    /// 连接成功后挂上保活
    func attach(endpoint: String) {
        self.endpoint = endpoint
        failures = 0
        attempt = 0
        isReconnecting = false
        suspended = false
        setState(.online)
        scheduleTimer()
    }

    /// 主动断开
    func detach() {
        timer?.invalidate()
        timer = nil
        endpoint = nil
        failures = 0
        attempt = 0
        isReconnecting = false
        setState(.idle)
    }

    /// 进后台：停心跳。iOS 挂起进程后 Timer 本来也不走，但显式关掉更干净
    func suspend() {
        suspended = true
        timer?.invalidate()
        timer = nil
    }

    /// 回前台：adb server 可能已被系统杀掉，整条链路重建一次
    func resume() async {
        suspended = false
        guard let endpoint else { return }

        _ = await raw(["start-server"])
        let ok = await connectOnce(endpoint: endpoint)

        if ok {
            failures = 0
            attempt = 0
            isReconnecting = false
            lastBeat = Date()
            setState(.online)
        } else {
            setState(.offline("回到前台后重建连接失败"))
        }
        scheduleTimer()
    }

    // MARK: - 心跳

    private func scheduleTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            let t = Timer.scheduledTimer(withTimeInterval: self.beatInterval, repeats: true) { [weak self] _ in
                self?.beat()
            }
            t.tolerance = 3
            self.timer = t
        }
    }

    private func beat() {
        guard !suspended, !isReconnecting, let endpoint else { return }

        // 直接走 runAsync，绕过 AdbService.shellAsync 的重试，
        // 否则心跳失败会触发 repairNow，repairNow 又发心跳，绕成死循环。
        adb.runAsync(["shell", "echo __hb"]) { [weak self] result in
            guard let self else { return }

            if result.output.contains("__hb") {
                self.failures = 0
                self.lastBeat = Date()
                if self.state != .online {
                    self.setState(.online)
                }
            } else {
                self.failures += 1
                if self.failures >= self.failureThreshold {
                    self.failures = 0
                    self.beginReconnect(endpoint: endpoint, reason: result.output)
                }
            }
        }
    }

    // MARK: - 重连

    private func beginReconnect(endpoint: String, reason: String) {
        guard !isReconnecting else { return }
        isReconnecting = true
        attempt = 0
        step(endpoint: endpoint, reason: reason)
    }

    private func step(endpoint: String, reason: String) {
        guard !suspended else {
            isReconnecting = false
            return
        }

        attempt += 1
        setState(.reconnecting(attempt: attempt))

        let delay = min(pow(2.0, Double(attempt - 1)), 16)

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            self.adb.connect(to: endpoint) { ok, message in
                if ok {
                    self.isReconnecting = false
                    self.failures = 0
                    self.attempt = 0
                    self.lastBeat = Date()
                    self.setState(.online)
                } else if self.attempt < self.maxAttempts {
                    self.step(endpoint: endpoint, reason: message)
                } else {
                    self.isReconnecting = false
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.setState(.offline(text.isEmpty ? "重连失败：\(reason)" : text))
                }
            }
        }
    }

    /// 命令失败后立刻修一次链路（给 AdbService 重试用）
    func repairNow() async -> Bool {
        guard let endpoint, !isReconnecting else { return false }
        isReconnecting = true
        defer { isReconnecting = false }

        let ok = await connectOnce(endpoint: endpoint)
        if ok {
            failures = 0
            attempt = 0
            lastBeat = Date()
            setState(.online)
        }
        return ok
    }

    // MARK: - 工具

    private func connectOnce(endpoint: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            adb.connect(to: endpoint) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }

    private func raw(_ args: [String]) async -> AdbResult {
        await withCheckedContinuation { (cont: CheckedContinuation<AdbResult, Never>) in
            adb.runAsync(args) { cont.resume(returning: $0) }
        }
    }

    private func setState(_ new: State) {
        if Thread.isMainThread {
            state = new
        } else {
            DispatchQueue.main.async { self.state = new }
        }
    }
}
