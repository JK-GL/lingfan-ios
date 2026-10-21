import SwiftUI

/// 根容器：5 个 Tab
///
/// 对照 HTML 原型：首页 / 应用 / 文件 / 命令 / 设置。
///
/// 与原版 Android 的差别：原版是「首页 → 控制台（9 项九宫格）→ 各功能页」的两级结构；
/// 本版把控制台拆平，功能直接落成 4 个并列 Tab + 首页 12 格快捷操作。
struct RootTabView: View {

    @StateObject private var router = TabRouter.shared
    @StateObject private var active = ActiveDevice.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $router.tab) {

            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(TabRouter.Tab.home.rawValue)

            deviceGate {
                if let device = active.connected {
                    AppsView(device: device)
                }
            }
            .tabItem { Label("应用", systemImage: "square.grid.2x2.fill") }
            .tag(TabRouter.Tab.apps.rawValue)

            deviceGate {
                if let device = active.connected {
                    FilesView(device: device)
                }
            }
            .tabItem { Label("文件", systemImage: "folder.fill") }
            .tag(TabRouter.Tab.files.rawValue)

            deviceGate {
                if let device = active.connected {
                    CommandsView(device: device)
                }
            }
            .tabItem { Label("命令", systemImage: "terminal.fill") }
            .tag(TabRouter.Tab.commands.rawValue)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(TabRouter.Tab.settings.rawValue)
        }
        .tint(MDColor.brand)
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                // 进后台停心跳，别让一堆超时调用堆在挂起前
                ConnectionKeeper.shared.suspend()
            case .active:
                // 回前台 adb server 可能已被系统回收，整条链路重建
                Task { await ConnectionKeeper.shared.resume() }
            default:
                break
            }
        }
    }

    /// 需要设备才能用的 Tab：没连设备时给出提示，而不是白屏
    @ViewBuilder
    private func deviceGate<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if active.connected != nil {
            content()
        } else {
            NotConnectedView()
        }
    }
}

/// 未连接设备时的提示页
struct NotConnectedView: View {

    @StateObject private var router = TabRouter.shared

    var body: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()

                VStack(spacing: 16) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(MDColor.textTertiary)

                    Text("还没有连接设备")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)

                    Text("先到首页连接车机，这一页才能使用")
                        .font(.system(size: 13))
                        .foregroundStyle(MDColor.textSecondary)
                        .multilineTextAlignment(.center)

                    Button {
                        router.go(.home)
                    } label: {
                        Text("去连接")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 12)
                            .background(
                                Capsule().fill(MDColor.brand)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 40)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
