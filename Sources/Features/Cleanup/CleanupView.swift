import SwiftUI

/// 存储清理
///
/// 扫描可清理目录 → 勾选 → 清理 → 显示实际释放量。
/// 清理后用 du 复核，不靠命令回执自吹。
struct CleanupView: View {

    let device: DeviceRecord
    @StateObject private var store = CleanupStore()

    @State private var selected: Set<String> = []
    @State private var showConfirm = false
    @State private var resultMessage: String?

    var body: some View {
        ZStack {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    summaryCard

                    if let err = store.errorMessage {
                        noticeCard(err, tint: MDColor.warning)
                    }

                    if let msg = resultMessage {
                        noticeCard(msg, tint: MDColor.success)
                    }

                    if store.scanning {
                        ProgressView("扫描中…")
                            .padding(.vertical, 70)
                    } else if store.targets.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.targets) { target in
                            targetRow(target)
                        }
                        actionBar
                    }
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await store.scan() }
        }
        .navigationTitle("存储清理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(MDColor.background, for: .navigationBar)
        .task {
            store.bind(isDemo: device.isDemo)
            await store.scan()
        }
        .alert("确认清理", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                Task {
                    let freed = await store.clean(selected)
                    selected.removeAll()
                    if freed > 0 {
                        resultMessage = "已释放 \(fmt(freed))"
                    } else {
                        resultMessage = "没有释放空间（可能已被系统占用或权限不足）"
                    }
                }
            }
        } message: {
            Text("将清空 \(selected.count) 个目录的内容，目录本身保留。\n应用缓存清理后，相关 App 可能需要重新加载数据。")
        }
    }

    // MARK: - 概览

    private var summaryCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("存储清理")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(MDColor.textPrimary)
                        Text(store.storageSummary)
                            .font(.system(size: 13))
                            .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(fmt(store.totalReclaimable))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(MDColor.process)
                        Text("可清理")
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                    }
                }

                if store.freedBytes > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(MDColor.success)
                        Text("本次已释放 \(fmt(store.freedBytes))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MDColor.success)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(MDColor.textTertiary)
            Text(store.scanning ? "扫描中" : "没有可清理的目标")
                .font(.system(size: 15))
                .foregroundStyle(MDColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func noticeCard(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(MDColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }

    // MARK: - 目标行

    private func targetRow(_ target: CleanupStore.Target) -> some View {
        let isOn = selected.contains(target.path)

        return Button {
            if isOn { selected.remove(target.path) } else { selected.insert(target.path) }
        } label: {
            MDCard(padding: 12) {
                HStack(spacing: 12) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isOn ? MDColor.brand : MDColor.textTertiary)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(target.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MDColor.textPrimary)

                            riskBadge(target.risk)
                        }

                        Text(target.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MDColor.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(target.sizeText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(MDColor.textPrimary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func riskBadge(_ risk: CleanupStore.Target.Risk) -> some View {
        let tint = risk == .safe ? MDColor.success : MDColor.warning
        return Text(risk.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }

    // MARK: - 操作栏

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if selected.count == store.targets.count {
                        selected.removeAll()
                    } else {
                        selected = Set(store.targets.map { $0.path })
                    }
                } label: {
                    Text(selected.count == store.targets.count ? "取消全选" : "全选")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MDColor.brand)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("已选 \(selected.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(MDColor.textSecondary)
            }

            MDPrimaryButton(
                title: store.cleaning ? "清理中…" : "清理选中项",
                enabled: !selected.isEmpty && !store.cleaning
            ) {
                showConfirm = true
            }
        }
        .padding(.top, 4)
    }

    private func fmt(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1073741824 { return String(format: "%.2f GB", b / 1073741824) }
        if b >= 1048576 { return String(format: "%.1f MB", b / 1048576) }
        if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
        return "\(bytes) B"
    }
}

#Preview {
    NavigationStack {
        CleanupView(device: .demo)
    }
}
