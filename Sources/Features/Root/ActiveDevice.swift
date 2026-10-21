import Combine
import Foundation

/// 当前连接设备（全局单例）
///
/// 为什么需要它：5 个 Tab 里除「首页」「设置」外的每一页都必须拿到 `DeviceRecord`
/// （它们的第一行都是 `let device: DeviceRecord`）。Tab 是平级的，没有 Nav 栈
/// 可以顺着往下传参，所以把「当前设备」提到全局。
///
/// 写入时机只有一个：`HomeStore.tapDevice` 连接成功后由 `HomeView` 写入。
@MainActor
final class ActiveDevice: ObservableObject {

    static let shared = ActiveDevice()

    /// 当前设备。`nil` = 从未连接过；`state != .connected` = 已断开
    @Published private(set) var current: DeviceRecord?

    private init() {}

    /// 已连接且有可用设备
    var connected: DeviceRecord? {
        guard let current, current.state == .connected else { return nil }
        return current
    }

    var isConnected: Bool { connected != nil }

    func set(_ device: DeviceRecord?) {
        current = device
    }

    /// 断开时不清空记录，只把状态改成 offline ——
    /// 保留是为了让「应用/文件」页在重新连接前仍记得上次连的是谁。
    func markDisconnected() {
        guard var device = current else { return }
        device.state = .offline
        current = device
    }
}

/// 跨 Tab 跳转
///
/// 首页快捷操作里「安装应用 / 文件 / Shell」这三类是切 Tab，
/// 其余是 push 全屏页。用一个共享对象驱动 `TabView(selection:)`。
@MainActor
final class TabRouter: ObservableObject {

    static let shared = TabRouter()

    @Published var tab: Int = 0

    private init() {}

    enum Tab: Int {
        case home = 0
        case apps = 1
        case files = 2
        case commands = 3
        case settings = 4
    }

    func go(_ tab: Tab) {
        self.tab = tab.rawValue
    }
}
