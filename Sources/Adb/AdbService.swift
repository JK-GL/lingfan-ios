import Foundation
import Combine

/// ADB 命令执行的 Swift 封装
///
/// 底层 AdbBridge（ObjC++）直接调用 libadb 的 C 接口。
/// 这里不标记 @MainActor：真机上 adb shell 是阻塞调用，
/// 整个类被主线程隔离会让 UI 卡死。所有结果统一用 DispatchQueue.main 回调。
final class AdbService: ObservableObject {

    static let shared = AdbService()

    private let queue = DispatchQueue(label: "com.lingfan.adb", qos: .userInitiated)

    /// 当前已连接的设备 endpoint（ip:port）
    @Published private(set) var connectedEndpoint: String?

    /// 最近一次错误信息
    @Published private(set) var lastError: String?

    /// 当前设备的 adb serial（`adb devices` 第一列）。
    /// 必须记住它：adb server 同时连着多台设备时，
    /// 不带 `-s` 的 `adb shell` 会直接返回 "more than one device/emulator"，
    /// 所有页面都会读不到数据。
    private(set) var currentSerial: String?

    private init() {
        AdbBridge.shared.initializeRuntimeIfNeeded()
    }

    // MARK: - 基础执行

    /// 同步执行（串行队列上调用，不要在主线程序列化等待）
    nonisolated func run(_ args: [String]) -> AdbResult {
        AdbBridge.shared.runCommand(args)
    }

    /// 异步执行，回调保证在主线程
    func runAsync(_ args: [String], completion: @escaping (AdbResult) -> Void) {
        let finalArgs = withDevice(args)
        queue.async {
            let result = AdbBridge.shared.runCommand(finalArgs)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 仅返回输出文本
    func runText(_ args: [String], completion: @escaping (String) -> Void) {
        runAsync(args) { result in
            completion(result.output)
        }
    }

    /// 给需要指定设备的子命令补上 `-s <serial>`。
    /// connect / disconnect / devices / pair 这些全局命令不能带。
    func withDevice(_ args: [String]) -> [String] {
        guard let serial = currentSerial, !serial.isEmpty else { return args }
        guard let first = args.first else { return args }
        let global = ["connect", "disconnect", "devices", "pair", "kill-server", "start-server", "version"]
        if global.contains(first) || args.contains("-s") { return args }
        return ["-s", serial] + args
    }

    // MARK: - 连接管理

    /// 连接设备。endpoint 形如 "192.168.43.1:5557"
    ///
    /// 判定依据必须是 libadb 的真实回执（取自二进制字符串表）：
    ///   connection requested to '%s'
    ///   already connected to %s
    ///   failed to authenticate to %s   ← 密钥被设备拒绝，需重新配对
    ///   failed to connect to %s
    ///   connected to %s
    /// 注意 "failed to authenticate" 也含 "failed"，要单独区分出来给用户看得懂的提示。
    func connect(to endpoint: String, completion: @escaping (Bool, String) -> Void) {
        runAsync(["connect", endpoint]) { [weak self] result in
            let text = result.output
            let lower = text.lowercased()

            let authFailed = lower.contains("failed to authenticate")
            let ok = !authFailed
                && (lower.contains("connected to ") || lower.contains("already connected to"))

            if ok {
                // 原版 AdbConnectionManager.createVerifiedConnectionOrThrow：
                // `connected to` 只说明 socket 建起来了，必须再跑一条
                // `echo connection_test` 才算真连通（否则 shell 通道可能不可用）。
                self?.runAsync(["shell", "echo connection_test"]) { probe in
                    let probeText = probe.output
                    let probeOk = probeText.contains("connection_test")
                    if probeOk {
                        self?.connectedEndpoint = endpoint
                        self?.lastError = nil
                        // 记下 serial，后续所有 shell 都带 -s
                        self?.resolveSerial(for: endpoint) {
                            // 挂上保活：从这里开始每 20 秒一次心跳
                            ConnectionKeeper.shared.attach(endpoint: endpoint)
                            completion(true, text)
                        }
                        return
                    } else {
                        let raw = probeText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if raw.lowercased().contains("unauthorized") {
                            // 尝试 reconnect 刷新握手状态
                            self?.runAsync(["reconnect"]) { _ in }
                            let message = "设备网络已连通！请在安卓设备（手机/车机）屏幕上勾选「始终允许」并点击【允许/确定】，然后重新点击连接即可。"
                            self?.lastError = message
                            completion(false, message)
                        } else {
                            let message = "端口连通但 shell 通道不可用：" + (raw.isEmpty ? "设备无响应" : raw)
                            self?.lastError = message
                            completion(false, message)
                        }
                    }
                }
                return
            } else {
                let message: String
                if authFailed {
                    message = "设备拒绝本机密钥（未完成配对）。请点「无线配对」重新配对后再连接。"
                } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    message = "连接失败：adb 无任何输出，通常是端口不对或设备未开启网络调试。"
                } else {
                    message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self?.lastError = message
                completion(false, message)
                return
            }
        }
    }

    /// 从 `adb devices` 里找出该 endpoint 对应的 serial
    private func resolveSerial(for endpoint: String, completion: @escaping () -> Void) {
        runAsync(["devices"]) { [weak self] result in
            var found: String?
            for line in result.output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !text.hasPrefix("List of devices") else { continue }
                let parts = text.split(whereSeparator: { $0 == "\t" || $0 == " " })
                guard parts.count >= 2 else { continue }
                let serial = String(parts[0])
                // 设备状态必须是 device，offline/unauthorized 不算
                guard String(parts[1]).hasPrefix("device") else { continue }
                if serial == endpoint || serial.hasPrefix(endpoint) || endpoint.hasPrefix(serial) {
                    found = serial
                    break
                }
            }
            self?.currentSerial = found ?? endpoint
            completion()
        }
    }

    func disconnect(_ endpoint: String, completion: ((Bool) -> Void)? = nil) {
        runAsync(["disconnect", endpoint]) { [weak self] result in
            if self?.connectedEndpoint == endpoint {
                self?.connectedEndpoint = nil
                self?.currentSerial = nil
                ConnectionKeeper.shared.detach()
            }
            completion?(result.success)
        }
    }

    func disconnectAll(completion: ((Bool) -> Void)? = nil) {
        runAsync(["disconnect"]) { [weak self] result in
            self?.connectedEndpoint = nil
            self?.currentSerial = nil
            ConnectionKeeper.shared.detach()
            completion?(result.success)
        }
    }

    /// 列出已连接设备 serial
    func listDevices(completion: @escaping ([String]) -> Void) {
        runAsync(["devices"]) { result in
            var serials: [String] = []
            for line in result.output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !text.hasPrefix("List of devices") else { continue }
                let parts = text.split(separator: "\t")
                if let first = parts.first {
                    serials.append(String(first))
                }
            }
            completion(serials)
        }
    }

    // MARK: - 统一标准传输契约（严格对齐原版 Adb.kt：全 App 唯一标准协议，杜绝杂交）

    /// 标准文件推送（对齐原版 Adb.push）
    func push(localPath: String, remotePath: String) async -> (ok: Bool, message: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            runAsync(["push", localPath, remotePath]) { res in
                let out = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (res.success, out))
            }
        }
    }

    /// 标准文件拉取（对齐原版 Adb.pull）
    func pull(remotePath: String, localPath: String) async -> (ok: Bool, message: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            runAsync(["pull", remotePath, localPath]) { res in
                let out = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (res.success, out))
            }
        }
    }

    /// 标准 Shell 命令异步执行（对齐原版 Adb.shell）
    func shellAsync(_ command: String) async -> (ok: Bool, output: String) {
        let first = await rawShell(command)
        if first.ok { return first }

        // 失败一次：先让 keeper 立刻修一次链路，修好了原样重试。
        // 这一步是「断线自愈」的兜底 —— 心跳 20 秒一轮，等不及心跳的场景靠它。
        if await ConnectionKeeper.shared.repairNow() {
            return await rawShell(command)
        }
        return first
    }

    /// 不做任何重试的原始 shell
    private func rawShell(_ command: String) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            runAsync(["shell", command]) { res in
                cont.resume(returning: (res.success, res.output))
            }
        }
    }

    // MARK: - 无线配对

    /// 无线配对。address 形如 "192.168.43.1:40117"，code 为 6 位配对码
    func pair(address: String, code: String, completion: @escaping (Bool, String) -> Void) {
        runAsync(["pair", address, code]) { result in
            let text = result.output
            let ok = text.contains("Successfully paired") || text.lowercased().contains("success")
            completion(ok, text)
        }
    }

    // MARK: - Shell

    func shell(_ command: String, timeout: TimeInterval = 30,
               completion: @escaping (Bool, String) -> Void) {
        runAsync(["shell", command]) { result in
            completion(result.success, result.output)
        }
    }

    /// 执行 shell 并返回非空行数组
    func shellLines(_ command: String, completion: @escaping ([String]) -> Void) {
        runAsync(["shell", command]) { result in
            let lines = result.output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            completion(lines)
        }
    }

    // MARK: - 设备属性

    func getProp(_ key: String, completion: @escaping (String) -> Void) {
        shellLines("getprop \(key)") { lines in
            completion(lines.first ?? "")
        }
    }
}
