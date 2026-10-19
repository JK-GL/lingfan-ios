import Foundation

/// 一台设备在列表里的展示状态
enum DeviceConnectionState: String, Codable {
    case connected
    case online
    case pairing
    case offline

    var status: DeviceStatus {
        switch self {
        case .connected: return .connected
        case .online: return .online
        case .pairing: return .pairing
        case .offline: return .offline
        }
    }
}

/// 历史设备 / 发现结果
struct DeviceRecord: Identifiable, Hashable {
    /// 稳定主键。优先 serial:<ro.serialno>，无 serial 时退回 endpoint:<ip:port>
    let id: String

    /// 展示名，通常是 adb 返回的 device model
    var name: String

    /// 当前地址 ip:port
    var endpoint: String

    var state: DeviceConnectionState

    /// 是否识别为菱粉桌面设备
    var isLingFans: Bool

    /// 最近一次连接时间
    var lastSeen: Date

    /// 主键构造：有序列号用序列号，否则用地址
    static func stableID(serial: String?, endpoint: String) -> String {
        if let serial, !serial.isEmpty {
            return "serial:\(serial)"
        }
        return "endpoint:\(endpoint)"
    }

    /// 从 endpoint 拆出 IP 与端口
    var host: String {
        endpoint.split(separator: ":").first.map(String.init) ?? endpoint
    }

    var port: String {
        let parts = endpoint.split(separator: ":")
        return parts.count > 1 ? String(parts[1]) : "5555"
    }
}

/// 常用设备属性快照
struct DeviceInfo {
    var brand: String = ""
    var model: String = ""
    var androidVersion: String = ""
    var sdk: String = ""
    var serial: String = ""
    var resolution: String = ""
    var density: String = ""
    var cpuInfo: String = ""
    var totalMem: String = ""
    var availMem: String = ""
    var totalStorage: String = ""
    var availStorage: String = ""
    var batteryLevel: String = ""
    var batteryStatus: String = ""

    var displayName: String {
        let parts = [brand, model].filter { !$0.isEmpty }
        return parts.isEmpty ? "未知设备" : parts.joined(separator: " ")
    }
}
