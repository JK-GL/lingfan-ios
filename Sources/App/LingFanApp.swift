import SwiftUI

@main
struct LingFanApp: App {

    init() {
        // adb 运行时初始化放在 App 启动，避免首个连接请求时才付代价
        AdbBridge.shared.initializeRuntimeIfNeeded()

        // 让导航栏与页面底色一致
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(MDColor.background)
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor(MDColor.textPrimary)
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor(MDColor.textPrimary),
            .font: UIFont.systemFont(ofSize: 28, weight: .bold)
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.light)   // 原版是浅色 Material，先固定浅色
        }
    }
}
