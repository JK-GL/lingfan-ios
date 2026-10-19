import SwiftUI
import UIKit

/// Material Design 3 风格色板 —— 动态色版本
///
/// 浅色值取自 Android 原版「菱粉工具箱」真机截图逐像素采样（不是估算）。
/// 深色值按 Material 3 规范推导，层级用 surface container 五级。
///
/// 关键：**所有颜色必须是动态色**。
/// 原来写成 `static let background = Color(hex: 0xF8F9FB)` 是编译期常量，
/// 运行时不可能随 trait（深浅色）变化，`preferredColorScheme` 也救不了。
/// 必须走 `UIColor(dynamicProvider:)`，系统在 trait 变化时重新求值。
enum MDColor {

    // MARK: - 动态色构造

    /// 构造随深浅色自动切换的颜色
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgb: dark)
                : UIColor(rgb: light)
        })
    }

    // MARK: - 层级（M3 surface container）

    /// 页面底色。深色不用纯黑 —— M3 规定深色底要带一点亮，否则层级全塌。
    static let background = dynamic(light: 0xF8F9FB, dark: 0x0E1116)

    /// 卡片主体（surface container）
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A1F27)

    /// 卡片内的次级块，例如输入框、代码块
    static let surfaceHigh = dynamic(light: 0xF2F4F8, dark: 0x222A35)

    /// 浮层 / 弹窗
    static let surfaceHighest = dynamic(light: 0xE9EDF3, dark: 0x2B3441)

    /// 卡片描边（极淡）
    static let surfaceStroke = dynamic(light: 0x000000, dark: 0xFFFFFF)

    // MARK: - 文字

    /// 主文字（浅色采样 #333333）
    static let textPrimary = dynamic(light: 0x333333, dark: 0xE8EBEF)

    /// 副文字（浅色采样 #888888）
    static let textSecondary = dynamic(light: 0x888888, dark: 0xA8B0BC)

    /// 三级文字 / 箭头（浅色采样 #CDCDCD）
    static let textTertiary = dynamic(light: 0xCDCDCD, dark: 0x5C6570)

    // MARK: - 描边层

    /// 重要边界，例如输入框轮廓
    static let outline = dynamic(light: 0xCDCDCD, dark: 0x6B7480)

    /// 装饰性分隔线
    static let outlineVariant = dynamic(light: 0xE6E8EC, dark: 0x2E3742)

    // MARK: - 功能色
    //
    // 深色值不是简单调亮，而是按 M3 dark tone（约 tone 80）重新校准：
    // 原来那种饱和红 #FF5252 直接放深底上会刺眼且溢出。

    static let info    = dynamic(light: 0x2196F3, dark: 0x64B5F6)
    static let shell   = dynamic(light: 0x607D8B, dark: 0x90A4AE)
    static let file    = dynamic(light: 0x26A59A, dark: 0x4DB6AC)
    static let app     = dynamic(light: 0x4CB050, dark: 0x81C784)
    static let process = dynamic(light: 0xFF5252, dark: 0xFF8A80)
    static let remote  = dynamic(light: 0x9C27B0, dark: 0xCE93D8)
    static let tool    = dynamic(light: 0xFF9800, dark: 0xFFB74D)
    static let brand   = dynamic(light: 0x4A7FE8, dark: 0x7BA6F5)

    // MARK: - 语义色

    static let success = dynamic(light: 0x34C759, dark: 0x30D158)
    static let warning = dynamic(light: 0xFF9500, dark: 0xFFB340)
    static let danger  = dynamic(light: 0xFF3B30, dark: 0xFF6961)

    // MARK: - 徽章底色
    //
    // 深色下 0.12 太淡，几乎看不见，统一提到 0.20。

    static let chipOnlineBg  = chipBase(0x34C759)
    static let chipOfflineBg = chipBase(0x8E8E93)
    static let chipPairingBg = chipBase(0xFF9500)

    private static func chipBase(_ rgb: UInt32) -> Color {
        Color(UIColor { trait in
            let base = UIColor(rgb: rgb)
            return base.withAlphaComponent(trait.userInterfaceStyle == .dark ? 0.20 : 0.12)
        })
    }
}

// MARK: - 十六进制构造

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

extension Color {
    /// 从 0xRRGGBB 整数构造颜色（静态色，不随深浅色变化，慎用）
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - 尺寸令牌

/// 全局尺寸令牌
///
/// 原版是 Android 的 dp，这里按 iOS pt 1:1 对应（两者物理密度接近）。
/// 内层圆角原本散落在各页硬编码（10 / 12 / 14 各写一遍），
/// 统一抽成令牌，将来换风格只改这里。
enum MDMetric {

    // MARK: 圆角层级

    /// 输入框
    static let radiusField: CGFloat = 10
    /// 按钮
    static let radiusButton: CGFloat = 12
    /// 提示条 / 浮层卡片
    static let radiusBanner: CGFloat = 14
    /// 主卡片（原版 16~20，取中值）
    static let cardRadius: CGFloat = 18
    /// 弹窗
    static let radiusSheet: CGFloat = 24

    // MARK: 间距

    /// 图标方块圆角（原版约 14）
    static let iconRadius: CGFloat = 14
    /// 图标方块边长
    static let iconSize: CGFloat = 52
    /// 页面水平边距
    static let pagePadding: CGFloat = 16
    /// 卡片内边距
    static let cardPadding: CGFloat = 16
    /// 卡片之间的垂直间距
    static let cardSpacing: CGFloat = 12
    /// 列表行最小高度
    static let rowHeight: CGFloat = 76
    /// 按钮高度（原版「立即连接」约 52dp）
    static let buttonHeight: CGFloat = 52

    // MARK: 玻璃强度

    /// 玻璃高光描边的强度。这是「悬浮感」的真正来源 ——
    /// 单纯 blur 只会得到一片灰，白色渐变描边才让边缘发亮。
    enum Glass {
        /// 主卡片高光
        static let highlight: Double = 0.55
        /// 卡片高光收尾
        static let highlightTail: Double = 0.02
        /// 阴影不透明度
        static let shadow: Double = 0.07
        /// 阴影模糊半径
        static let shadowRadius: CGFloat = 14
        /// 阴影纵向偏移
        static let shadowY: CGFloat = 5
    }
}
