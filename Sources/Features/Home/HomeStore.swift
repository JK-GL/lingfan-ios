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
            errorMessage = nil
        } else {
            errorMessage = message
        }
    }

    /// 连上后读取设备名与序列号，用于生成稳定主键
    private func readIdentity(endpoint: String) async -> (name: String, serial: String, isLingFans: Bool) {
        async let brandLines = adbShellLines("getprop ro.product.brand")
        async let modelLines = adbShellLines("getprop ro.product.model")
        async let serialLines = adbShellLines("getprop ro.serialno")
        async let launcherLines = adbShellLines("pm list packages com.zzh.launcher50s")

        let brand = (await brandLines).first ?? ""
        let model = (await modelLines).first ?? ""
        let serial = (await serialLines).first ?? ""
        let launcher = await launcherLines

        let name = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
        let isLingFans = launcher.contains { $0.contains("com.zzh.launcher50s") }

        return (name.isEmpty ? endpoint : name, serial, isLingFans)
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
    /// iOS 侧没有 NsdManager，改用两种手段：
    ///   1. 本机网段 /24 全段探测 5555 / 5557 / 5556
    ///   2. 后续可加 NWBrowser 找 `_adb._tcp` 与 `_lingfans-link._tcp`
    func scan() async {
        isScanning = true
        defer { isScanning = false }

        // TODO: 接入 LanScanner（NWBrowser + 端口探测）
        // 先留空，等协议层验证通过后再补
    }

    /// 刷新：重连已记录的在线设备并更新状态
    func refresh() async {
        await scan()
    }
}
