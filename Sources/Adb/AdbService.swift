import Foundation
import Combine

/// ADB 命令执行的 Swift 封装
///
/// 底层是 AdbBridge（ObjC++），它直接调用 libadb 的 C 接口。
/// 所有操作都放到后台队列执行，避免阻塞主线程。
@MainActor
final class AdbService: ObservableObject {

    static let shared = AdbService()

    private let bridge = AdbBridge.shared
    private let queue = DispatchQueue(label: "com.lingfan.adb", qos: .userInitiated)

    /// 当前已连接的设备 endpoint（ip:port）
    @Published private(set) var connectedEndpoint: String?

    /// 最近一次错误信息
    @Published private(set) var lastError: String?

    private init() {
        bridge.initializeRuntimeIfNeeded()
    }

    // MARK: - 基础执行

    /// 同步执行（内部已串行化，可在后台队列反复调用）
    nonisolated func run(_ args: [String]) -> AdbResult {
        AdbBridge.shared.runCommand(args)
    }

    /// 异步执行，回调在主线程
    func runAsync(_ args: [String], completion: @escaping (AdbResult) -> Void) {
        queue.async {
            let result = AdbBridge.shared.runCommand(args)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 连接管理

    /// 连接设备。endpoint 形如 "192.168.43.1:5557"
    func connect(to endpoint: String, completion: @escaping (Bool, String) -> Void) {
        runAsync(["connect", endpoint]) { [weak self] result in
            guard let self else { return }
            let text = result.output
            // adb connect 成功时返回 "connected to ..." / "already connected to ..."
            // 但返回码不一定为 0，所以以文本判定
            let ok = text.contains("connected to") && !text.contains("failed")
            if ok {
                self.connectedEndpoint = endpoint
                self.lastError = nil
            } else {
                self.lastError = text.isEmpty ? "连接失败" : text
            }
            completion(ok, text)
        }
    }

    /// 断开指定设备
    func disconnect(_ endpoint: String, completion: ((Bool) -> Void)? = nil) {
        runAsync(["disconnect", endpoint]) { [weak self] result in
            guard let self else { return }
            if self.connectedEndpoint == endpoint {
                self.connectedEndpoint = nil
            }
            completion?(result.success)
        }
    }

    /// 断开全部
    func disconnectAll(completion: ((Bool) -> Void)? = nil) {
        runAsync(["disconnect"]) { [weak self] result in
            self?.connectedEndpoint = nil
            completion?(result.success)
        }
    }

    /// 列出已连接设备
    func listDevices(completion: @escaping ([String]) -> Void) {
        runAsync(["devices"]) { result in
            var serials: [String] = []
            for line in result.output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("List of devices") == false, !text.isEmpty else { continue }
                let parts = text.split(separator: "\t")
                if parts.count >= 2 {
                    serials.append(String(parts[0]))
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
            let ok = text.contains("Successfully paired") || text.contains("success")
            completion(ok, text)
        }
    }

    // MARK: - Shell

    /// 执行 shell 命令（有界，防止 dumpsys 之类输出爆内存）
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
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            completion(lines)
        }
    }

    // MARK: - 便捷读取设备信息

    /// 读取单个 prop
    func getProp(_ key: String, completion: @escaping (String) -> Void) {
        shellLines("getprop \(key)") { lines in
            completion(lines.first ?? "")
        }
    }

    /// 一次读取多个常用 prop，减少往返
    func getProps(_ keys: [String], completion: @escaping ([String: String]) -> Void) {
        // getprop 支持无参列出全部，但输出很大。
        // 这里按 key 逐个读，数量少时可接受；后续可改为一次性 dump 再解析。
        var result: [String: String] = [:]
        let group = DispatchGroup()
        let lock = NSLock()

        for key in keys {
            group.enter()
            shellLines("getprop \(key)") { lines in
                lock.lock()
                result[key] = lines.first ?? ""
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(result)
        }
    }
}
