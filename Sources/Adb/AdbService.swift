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
        queue.async {
            let result = AdbBridge.shared.runCommand(args)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 仅返回输出文本
    func runText(_ args: [String], completion: @escaping (String) -> Void) {
        runAsync(args) { result in
            completion(result.output)
        }
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
                        completion(true, text)
                    } else {
                        let message = "端口连通但 shell 通道不可用："
                            + (probeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               ? "设备无响应" : probeText.trimmingCharacters(in: .whitespacesAndNewlines))
                        self?.lastError = message
                        completion(false, message)
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

    func disconnect(_ endpoint: String, completion: ((Bool) -> Void)? = nil) {
        runAsync(["disconnect", endpoint]) { [weak self] result in
            if self?.connectedEndpoint == endpoint {
                self?.connectedEndpoint = nil
            }
            completion?(result.success)
        }
    }

    func disconnectAll(completion: ((Bool) -> Void)? = nil) {
        runAsync(["disconnect"]) { [weak self] result in
            self?.connectedEndpoint = nil
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
