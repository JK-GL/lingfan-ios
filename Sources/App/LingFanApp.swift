import SwiftUI
import UIKit

@main
struct LingFanApp: App {

    init() {
        // adb 运行时初始化放在 App 启动，避免首个连接请求时才付代价
        AdbBridge.shared.initializeRuntimeIfNeeded()

        configureNavigationBar()
    }

    /// 导航栏外观
    ///
    /// 注意：`UIColor(MDColor.background)` 是**在 init 时求值一次**的静态快照，
    /// 切成深色后导航栏会卡在浅色。必须传入会随 trait 重新求值的 UIColor。
    /// 这里靠 `UIColor { trait in ... }` 让 UIKit 自己处理。
    private func configureNavigationBar() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()

        appearance.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgb: 0x0E1116)
                : UIColor(rgb: 0xF8F9FB)
        }
        appearance.shadowColor = .clear

        let titleColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgb: 0xE8EBEF)
                : UIColor(rgb: 0x333333)
        }
        appearance.titleTextAttributes = [.foregroundColor: titleColor]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: titleColor,
            .font: UIFont.systemFont(ofSize: 28, weight: .bold)
        ]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
            // 不再固定浅色：跟随系统深浅色
        }
    }
}
