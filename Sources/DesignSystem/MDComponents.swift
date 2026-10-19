import SwiftUI

// MARK: - 卡片

/// Material 风格卡片容器
///
/// 对应原版 Compose 里的 `Card(elevation = 0.dp)` + 白底圆角。
/// 关键点：阴影必须极淡（opacity 0.04），否则会变成 iOS 那种厚重的投影。
struct MDCard<Content: View>: View {
    var padding: CGFloat = MDMetric.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MDMetric.cardRadius, style: .continuous)
                    .fill(MDColor.surface)
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
            )
    }
}

// MARK: - 彩色图标块

/// 圆形/圆角方形彩色图标块
///
/// 原版的模式是：深色图标 + 同色系 8% 透明底。
struct MDIconTile: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = MDMetric.iconSize
    var radius: CGFloat = MDMetric.iconRadius

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint.opacity(0.10))
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
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MDColor.brand.opacity(enabled ? 0.45 : 0.2), lineWidth: 1.2)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 状态徽章

enum DeviceStatus {
    case connected    // 已连接
    case online       // 在线（未连接）
    case pairing      // 需配对
    case offline      // 离线

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
        case .online: return MDColor.info.opacity(0.12)
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

/// 统一页面背景 + 滚动行为的容器
struct MDPage<Content: View>: View {
    let title: String
    var showBack: Bool = false
    var onBack: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            MDColor.background.ignoresSafeArea()

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
