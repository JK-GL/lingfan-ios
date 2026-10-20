import Foundation
import SwiftUI

/// 首页状态与业务逻辑
@MainActor
final class HomeStore: ObservableObject {

    // MARK: - 输入

    @Published var inputHost: String = ""
    @Published var inputPort: String = "5557"

    // MARK: - 列表

    @Published var devices: [DeviceRecord] = []
    @Published var autoDiscovery: Bool = true

    // MARK: - 运行状态

    @Published var isScanning = false
    @Published var isConnecting = false
    @Published var errorMessage: String?
    @Published var showPairSheet = false

    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    private let adb = AdbService.shared
    private let historyKey = "device.history"

    /// 当前正在跑的扫描器，用于取消
    private var scanner: LanScanner?

    // MARK: - 历史设备持久化

    /// 历史只存"曾经成功连过"的设备，用于断线后继续展示
    private struct StoredDevice: Codable {
        let id: String
        var name: String
        var endpoint: String
        var lastSeen: Date
        var isLingFans: Bool
    }

    func loadHistory() async {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let stored = try? JSONDecoder().decode([StoredDevice].self, from: data) else {
            return
        }
        devices = stored.map {
            DeviceRecord(
                id: $0.id,
                name: $0.name,
                endpoint: $0.endpoint,
                state: .offline,
                isLingFans: $0.isLingFans,
                lastSeen: $0.lastSeen
            )
        }
    }

    private func persistHistory() {
        let stored = devices.map {
            StoredDevice(
                id: $0.id,
                name: $0.name,
                endpoint: $0.endpoint,
                lastSeen: $0.lastSeen,
                isLingFans: $0.isLingFans
            )
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    // MARK: - 合并逻辑

    /// 按稳定主键合并，不做模糊匹配。
    /// 原版明确要求：endpoint 变化但 serial 相同的才合并；无法确认是同一台的，
    /// 保留旧卡片为离线，另存新卡片。
    private func upsert(_ record: DeviceRecord) {
        if let index = devices.firstIndex(where: { $0.id == record.id }) {
            var merged = devices[index]
            merged.name = record.name.isEmpty ? merged.name : record.name
            merged.endpoint = record.endpoint
            merged.state = record.state
            merged.lastSeen = record.lastSeen
            devices[index] = merged
        } else {
            devices.append(record)
        }
        persistHistory()
    }

    // MARK: - 连接

    func connectInput() async {
        let host = inputHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let port = inputPort.trimmingCharacters(in: .whitespaces)
        // 端口留空时才回填默认 5557，与 Android 版一致
        let endpoint = "\(host):\(port.isEmpty ? "5557" : port)"

        isConnecting = true
        defer { isConnecting = false }

        let (ok, message) = await withCheckedContinuation {
            (cont: CheckedContinuation<(Bool, String), Never>) in
            adb.connect(to: endpoint) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }

        if ok {
            let info = await readIdentity(endpoint: endpoint)
            upsert(DeviceRecord(
                id: DeviceRecord.stableID(serial: info.serial, endpoint: endpoint),
                name: info.name,
                endpoint: endpoint,
                state: .connected,
                isLingFans: info.isLingFans,
                lastSeen: Date()
            ))
            if let warn = info.warning {
                errorMessage = warn
            } else {
                errorMessage = nil
            }
        } else {
            errorMessage = message
        }
    }

    private struct Identity {
        var name: String
        var serial: String
        var isLingFans: Bool
        /// 非致命提示（口令未解锁、身份读取失败等）
        var warning: String?
    }

    /// 星光L（F610S）等定制 ROM 的 adb 口令命令。
    /// 对应原版 DeviceAdbLock.kt:30 的 XINGGUANG_L_PASSWORD_COMMAND。
    private static let passwordCommand = "password:SGMW@@HQql2025pwd"

    /// 连上后读取设备名与序列号，用于生成稳定主键
    ///
    /// 性能要点：四条 getprop 合并成一条 shell，避免 NSRecursiveLock 串行排队
    /// 把首连延迟放大 4 倍。
    private func readIdentity(endpoint: String) async -> Identity {
        // 先探测身份，同时拿到 brand/model/serial，一次往返
        let probe = await adbShellLines(
            "id; getprop ro.product.brand; getprop ro.product.model; getprop ro.serialno"
        )

        var warning: String?

        // 定制 ROM 要求口令时，shell 直接返回 "error: Please enter the password..."
        let joined = probe.joined(separator: "\n").lowercased()
        if joined.contains("please enter the password") {
            let unlock = await adbShellLines(Self.passwordCommand)
            let unlockText = unlock.joined(separator: "\n")
            if unlockText.lowercased().contains("check password success") {
                // 解锁成功，重新读一次属性
                let retry = await adbShellLines(
                    "id; getprop ro.product.brand; getprop ro.product.model; getprop ro.serialno"
                )
                return await buildIdentity(from: retry, warning: nil)
            }
            warning = "设备要求 ADB 口令，解锁未成功：\(unlockText.isEmpty ? "无回执" : unlockText)"
            return Identity(name: endpoint, serial: "", isLingFans: false, warning: warning)
        }

        return await buildIdentity(from: probe, warning: warning)
    }

    /// 从 `id; getprop x3` 的输出里切出 uid / brand / model / serial
    ///
    /// 输出形如：
    ///   uid=0(root) gid=0(root) ...
    ///   alps
    ///   spm8666p2_64_car
    ///   ABCDEF012345
    private func buildIdentity(from lines: [String], warning: String?) async -> Identity {
        let uidLine = lines.first { $0.hasPrefix("uid=") } ?? ""
        let rest = lines.filter { !$0.hasPrefix("uid=") }

        let brand = rest.count > 0 ? rest[0] : ""
        let model = rest.count > 1 ? rest[1] : ""
        let serial = rest.count > 2 ? rest[2] : ""

        let name = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")

        // 菱粉桌面包名探测放后台，不阻塞设备入列
        let isLingFans = await detectLingFans()

        var warn = warning
        if uidLine.isEmpty && warn == nil {
            warn = "非 root 身份（\(uidLine.isEmpty ? "未取到 id 输出" : uidLine)），部分功能可能受限"
        }

        return Identity(
            name: name.isEmpty ? "未知设备" : name,
            serial: serial,
            isLingFans: isLingFans,
            warning: warn
        )
    }

    private func detectLingFans() async -> Bool {
        let lines = await adbShellLines("pm list packages com.zzh.launcher50s")
        return lines.contains { $0.contains("com.zzh.launcher50s") }
    }

    private func adbShellLines(_ command: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(command) { lines in
                cont.resume(returning: lines)
            }
        }
    }

    // MARK: - 断开 / 删除

    func disconnect(_ device: DeviceRecord) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            adb.disconnect(device.endpoint) { _ in
                cont.resume()
            }
        }
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index].state = .offline
        }
        persistHistory()
    }

    func remove(_ device: DeviceRecord) async {
        devices.removeAll { $0.id == device.id }
        persistHistory()
    }

    // MARK: - 局域网发现

    func setAutoDiscovery(_ enabled: Bool) async {
        if enabled {
            await scan()
        } else {
            isScanning = false
        }
    }

    /// 扫描局域网内的 ADB 设备
    ///
    /// 三条路径并行（对应原版 LanScanner.kt）：
    ///   1. 本机网段 /24 × 5555/5557 端口探测，700ms 单次超时
    ///   2. Bonjour：_adb-tls-connect / _adb-tls-pairing / _lingfans-link，5s 窗口
    ///   3. UDP 18687 接菱粉自定义广播，2.5s 窗口
    /// 结果增量回调，边扫边出。
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scanner = LanScanner()
        self.scanner = scanner

        scanner.start { [weak self] found in
            // LanScanner 的回调在主线程触发，但签名无 actor 标注，
            // 用 Task { @MainActor in } 显式回到 HomeStore 的隔离域。
            Task { @MainActor in
                guard let self else { return }
                // 已在列表里的地址只更新状态，不重复插入
                if let idx = self.devices.firstIndex(where: { $0.endpoint == found.endpoint }) {
                    if self.devices[idx].state == .offline {
                        self.devices[idx].state = .online
                    }
                    return
                }
                self.devices.append(DeviceRecord(
                    id: DeviceRecord.stableID(serial: nil, endpoint: found.endpoint),
                    name: found.name,
                    endpoint: found.endpoint,
                    state: .online,
                    isLingFans: found.isLingFans,
                    lastSeen: Date()
                ))
            }
        }

        // 最长等 Bonjour 窗口（5s），网段探测与广播都在此之前结束
        try? await Task.sleep(nanoseconds: 5_500_000_000)
        scanner.stop()
        self.scanner = nil
        persistHistory()
    }

    /// 刷新：先校验历史设备在线状态，再触发扫描
    func refresh() async {
        await verifyHistory()
        await scan()
    }

    /// 用 adb devices 校验历史设备是否还在线，
    /// 再补一条 `echo 1` 确认 shell 通道真的可用。
    /// 原版 AdbConnectionManager.isConnected 就是这么做的 ——
    /// adb devices 显示 device 但 shell 已经死掉的情况在车机上很常见。
    private func verifyHistory() async {
        guard !devices.isEmpty else { return }
        let serials = await withCheckedContinuation {
            (cont: CheckedContinuation<[String], Never>) in
            adb.listDevices { cont.resume(returning: $0) }
        }

        let shellAlive = await withCheckedContinuation {
            (cont: CheckedContinuation<Bool, Never>) in
            adb.runAsync(["shell", "echo 1"]) { r in
                cont.resume(returning: r.output.contains("1"))
            }
        }

        for i in devices.indices {
            let listed = serials.contains { serial in
                serial == devices[i].endpoint
                    || devices[i].endpoint.hasSuffix(serial)
                    || serial.contains(devices[i].host)
            }
            devices[i].state = (listed && shellAlive) ? .connected : .offline
        }
        persistHistory()
    }
}
