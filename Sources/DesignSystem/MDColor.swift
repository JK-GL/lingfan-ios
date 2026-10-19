import SwiftUI

/// Material Design 3 风格色板
///
/// 所有颜色取自 Android 原版「菱粉工具箱」真机截图逐像素采样，
/// 不是估算值。改动前请先核对 screenshots/3.jpg。
enum MDColor {

    // MARK: - 基础层

    /// 页面底色（截图中底部空白区域采样 #F8F9FB）
    static let background = Color(hex: 0xF8F9FB)

    /// 卡片底色（卡片主体采样 #FFFFFF）
    static let surface = Color.white

    /// 卡片描边（极淡，用于深色背景下保持卡片轮廓）
    static let surfaceStroke = Color.black.opacity(0.04)

    // MARK: - 文字

    /// 主标题（采样 #333333）
    static let textPrimary = Color(hex: 0x333333)

    /// 副标题 / 说明文字（采样 #888888）
    static let textSecondary = Color(hex: 0x888888)

    /// 列表右侧箭头（采样 #CDCDCD）
    static let textTertiary = Color(hex: 0xCDCDCD)

    // MARK: - 功能色（Material 经典色）

    /// 信息 · 蓝（采样 #2196F3）
    static let info = Color(hex: 0x2196F3)

    /// Shell · 蓝灰（采样 #607D8B）
    static let shell = Color(hex: 0x607D8B)

    /// 文件 · 青（采样 #26A59A）
    static let file = Color(hex: 0x26A59A)

    /// App · 绿（采样 #4CB050）
    static let app = Color(hex: 0x4CB050)

    /// 进程 · 红（采样 #FF5252）
    static let process = Color(hex: 0xFF5252)

    /// 虚拟遥控 · 紫（采样 #9C27B0）
    static let remote = Color(hex: 0x9C27B0)

    /// 常用工具 · 橙（采样 #FF9800）
    static let tool = Color(hex: 0xFF9800)

    /// 菱粉联动 · 主色（首页「立即连接」按钮采样）
    static let brand = Color(hex: 0x4A7FE8)

    // MARK: - 语义色

    static let success = Color(hex: 0x34C759)
    static let warning = Color(hex: 0xFF9500)
    static let danger = Color(hex: 0xFF3B30)

    /// 状态徽章底色
    static let chipOnlineBg = Color(hex: 0x34C759).opacity(0.12)
    static let chipOfflineBg = Color(hex: 0x8E8E93).opacity(0.12)
    static let chipPairingBg = Color(hex: 0xFF9500).opacity(0.12)
}

extension Color {
    /// 从 0xRRGGBB 整数构造颜色
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

/// 全局尺寸令牌
///
/// 原版是 Android 的 dp，这里按 iOS pt 1:1 对应（两者物理密度接近）。
enum MDMetric {
    /// 卡片圆角（原版 16~20，取中值）
    static let cardRadius: CGFloat = 18

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
}
