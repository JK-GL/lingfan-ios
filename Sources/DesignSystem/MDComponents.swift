import SwiftUI

// MARK: - 玻璃材质档位

/// 卡片材质强度
///
/// 依据 Apple HIG「Materials」：
///   内容层的卡片用 **standard materials**（不是 Liquid Glass）
///   材料越厚 → 文字对比度越好；越薄 → 背景透得越多
///
/// ultraThin 只适合全屏遮罩，卡片从 thin 起。
enum MDMaterial {
    case ultraThin
    case thin
    case regular
    case thick
    case ultraThick

    var style: Material {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .ultraThick: return .ultraThickMaterial
        }
    }
}

// MARK: - 卡片

/// 玻璃卡片容器
///
/// 三段结构决定观感：
///   1. `.fill(material)`  —— 系统材质，提供磨砂透感
///   2. 顶部斜向白色渐变描边 —— **悬浮感的关键**，没有它就只是一块灰
///   3. 外阴影 —— 让卡片与背景分层
///
/// 官方 API 是 `.background(_:in:)`，一次完成「材质 + 圆角裁剪」。
/// 这里用 `RoundedRectangle().fill(material)` 是等价写法，
/// 因为还需要在同一形状上叠描边与阴影。
struct MDCard<Content: View>: View {
    var padding: CGFloat = MDMetric.cardPadding
    var material: MDMaterial = .regular
    /// 关掉材质退回纯色。长列表滚动时建议关掉。
    var glass: Bool = true
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MDMetric.cardRadius, style: .continuous)
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if glass {
                    shape
                        .fill(material.style)
                        .overlay {
                            shape.strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(MDMetric.Glass.highlight),
                                        .white.opacity(MDMetric.Glass.highlightTail)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.7
                            )
                        }
                        .shadow(
                            color: .black.opacity(MDMetric.Glass.shadow),
                            radius: MDMetric.Glass.shadowRadius,
                            y: MDMetric.Glass.shadowY
                        )
                } else {
                    shape
                        .fill(MDColor.surface)
                        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
                }
            }
    }
}

// MARK: - 页面背景

/// 统一页面背景
///
/// 为什么不是纯色：系统的 Material 模糊的是「这个 View 背后的内容」。
/// 背景若是纯色，模糊后还是纯色，玻璃就完全没有质感。
/// 这里用两层 RadialGradient 提供色差 —— 比 `Circle().blur()` 好，
/// RadialGradient 不需要离屏渲染，性能开销接近零。
struct MDPageBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            MDColor.background

            GeometryReader { geo in
                ZStack {
                    RadialGradient(
                        colors: [
                            MDColor.brand.opacity(scheme == .dark ? 0.20 : 0.12),
                            MDColor.brand.opacity(0)
                        ],
                        center: .topLeading,
                        startRadius: 10,
                        endRadius: max(geo.size.width, geo.size.height) * 0.72
                    )

                    RadialGradient(
                        colors: [
                            MDColor.file.opacity(scheme == .dark ? 0.16 : 0.09),
                            MDColor.file.opacity(0)
                        ],
                        center: .bottomTrailing,
                        startRadius: 10,
                        endRadius: max(geo.size.width, geo.size.height) * 0.66
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 彩色图标块

/// 圆角方形彩色图标块
///
/// 原版的模式是：深色图标 + 同色系 10% 透明底。
/// 深色下底色要更淡一点，否则彩色块会糊成一团。
struct MDIconTile: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = MDMetric.iconSize
    var radius: CGFloat = MDMetric.iconRadius

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint.opacity(scheme == .dark ? 0.18 : 0.10))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(tint)
            )
    }
}

// MARK: - 列表行

/// 功能入口行：图标 + 标题 + 副标题 + 右箭头
struct MDListRow<Trailing: View>: View {
    let systemName: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            MDIconTile(systemName: systemName, tint: tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MDColor.textPrimary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(MDColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing
        }
        .frame(minHeight: MDMetric.rowHeight)
    }
}

extension MDListRow where Trailing == AnyView {
    /// 默认带右箭头的版本
    init(systemName: String, tint: Color, title: String, subtitle: String) {
        self.init(systemName: systemName, tint: tint, title: title, subtitle: subtitle) {
            AnyView(
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MDColor.textTertiary)
            )
        }
    }
}

// MARK: - 按钮

/// 主按钮（实心）
struct MDPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: MDMetric.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                        .fill(enabled ? MDColor.brand : MDColor.brand.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 次要按钮（描边）
struct MDOutlineButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? MDColor.brand : MDColor.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: MDMetric.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                        .stroke(
                            MDColor.brand.opacity(enabled ? 0.45 : 0.2),
                            lineWidth: 1.2
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 状态徽章

enum DeviceStatus {
    case connected
    case online
    case pairing
    case offline

    var label: String {
        switch self {
        case .connected: return "已连接"
        case .online: return "在线"
        case .pairing: return "需配对"
        case .offline: return "离线"
        }
    }

    var foreground: Color {
        switch self {
        case .connected: return MDColor.success
        case .online: return MDColor.info
        case .pairing: return MDColor.warning
        case .offline: return MDColor.textSecondary
        }
    }

    var background: Color {
        switch self {
        case .connected: return MDColor.chipOnlineBg
        case .online: return MDColor.info.opacity(0.14)
        case .pairing: return MDColor.chipPairingBg
        case .offline: return MDColor.chipOfflineBg
        }
    }
}

struct MDStatusChip: View {
    let status: DeviceStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(status.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(status.background)
            )
    }
}

// MARK: - 页面容器

/// 统一页面容器：背景 + 滚动 + 导航栏
struct MDPage<Content: View>: View {
    let title: String
    var showBack: Bool = false
    var onBack: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    content
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showBack, let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(MDColor.textPrimary)
                    }
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(MDColor.background, for: .navigationBar)
    }
}
