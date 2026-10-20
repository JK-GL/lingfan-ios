import SwiftUI

/// 进程管理
///
/// 按包名聚合展示：一个 App 多个进程时收在一张卡里，
/// 与原版 processList 的分组结构一致。
struct ProcessView: View {

    let device: DeviceRecord
    @StateObject private var store = ProcessStore()

    @State private var pendingKill: ProcessStore.Proc?
    @State private var forceTarget: ProcessStore.Proc?
    @State private var pendingStopGroup: ProcessStore.Group?
    @State private var showKillConfirm = false
    @State private var showStopGroupConfirm = false
    @State private var killError: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        ZStack {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    memoryCard

                    if let error = store.errorMessage {
                        noticeCard(error, tint: MDColor.warning)
                    }
                    if let msg = store.killedMessage {
                        noticeCard(msg, tint: MDColor.success)
                    }

                    if store.loading && store.groups.isEmpty {
                        ProgressView("读取进程列表…")
                            .padding(.vertical, 60)
                    } else if store.groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.groups) { group in
                            groupCard(group)
                        }
                    }
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await store.load() }
        }
        .navigationTitle("进程管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(MDColor.background, for: .navigationBar)
        .task {
            store.bind(isDemo: device.isDemo)
            await store.load()
            store.resort()
            store.startCPUMonitor()
        }
        .onDisappear { store.stopCPUMonitor() }
        .alert("停止整个应用", isPresented: $showStopGroupConfirm) {
            Button("取消", role: .cancel) { pendingStopGroup = nil }
            Button("停止", role: .destructive) {
                guard let g = pendingStopGroup else { return }
                Task { _ = await store.forceStopGroup(g) }
                pendingStopGroup = nil
            }
        } message: {
            if let g = pendingStopGroup {
                Text("将对 \(g.packageName) 执行 `am force-stop`，"
                     + "一次性回收它的 \(g.processCount) 个进程。")
            }
        }
        .alert("结束进程", isPresented: $showKillConfirm) {
            Button("取消", role: .cancel) { pendingKill = nil }
            Button("结束", role: .destructive) {
                guard let p = pendingKill else { return }
                Task {
                    if let err = await store.kill(p) {
                        killError = err
                        forceTarget = p
                    }
                    pendingKill = nil
                }
            }
        } message: {
            if let p = pendingKill {
                Text("将向 \(p.name)（PID \(p.pid)）发送 SIGTERM。\n系统进程被结束后可能导致设备重启。")
            }
        }
        .alert("结束失败", isPresented: Binding(
            get: { killError != nil },
            set: { if !$0 { killError = nil } }
        )) {
            Button("取消", role: .cancel) { killError = nil; forceTarget = nil }
            Button("强制结束 (-9)", role: .destructive) {
                guard let p = forceTarget else { return }
                Task { _ = await store.forceKill(p) }
                killError = nil
                forceTarget = nil
            }
        } message: {
            Text(killError ?? "")
        }
    }

    // MARK: - 内存概览

    private var memoryCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("内存占用")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(MDColor.textPrimary)
                        Text("已用 \(store.usedMemoryText) / 共 \(store.totalMemoryText)")
                            .font(.system(size: 13))
                            .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(store.totalProcessCount)")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(MDColor.process)
                        Text("进程 · \(store.groups.count) 应用")
                            .font(.system(size: 11))
                            .foregroundStyle(MDColor.textSecondary)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MDColor.surfaceHigh).frame(height: 8)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [MDColor.process.opacity(0.75), MDColor.process],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * store.memoryRatio), height: 8)
                    }
                }
                .frame(height: 8)

                // 排序（原版 ProcessSortType：内存占用 / CPU占用）
                HStack(spacing: 8) {
                    ForEach(ProcessStore.SortType.allCases) { type in
                        Button {
                            store.sortType = type
                            store.resort()
                        } label: {
                            Text(type.title)
                                .font(.system(size: 12, weight: store.sortType == type ? .semibold : .regular))
                                .foregroundStyle(store.sortType == type ? MDColor.process : MDColor.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(store.sortType == type
                                                   ? MDColor.process.opacity(0.12)
                                                   : MDColor.surfaceHigh)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    Text(store.sortType == .cpu ? "每秒采样" : "")
                        .font(.system(size: 10))
                        .foregroundStyle(MDColor.textTertiary)
                }
            }
        }
    }

    private func noticeCard(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tint == MDColor.success
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .padding(.top, 1)
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(MDColor.textTertiary)
            Text("没有读到应用进程")
                .font(.system(size: 15))
                .foregroundStyle(MDColor.textSecondary)
            Text("已过滤内核线程，只显示 App 进程")
                .font(.system(size: 12))
                .foregroundStyle(MDColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 应用分组卡

    private func groupCard(_ group: ProcessStore.Group) -> some View {
        let isExpanded = expanded.contains(group.id)
        let hasChildren = group.processCount > 1

        return MDCard(padding: 12) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MDColor.process.opacity(0.12))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Text(String(group.displayName.prefix(1)).uppercased())
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(MDColor.process)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MDColor.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text("\(group.processCount) 个进程")
                            if hasChildren {
                                Text(isExpanded ? "收起" : "展开")
                                    .foregroundStyle(MDColor.brand)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(group.totalRssText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(MDColor.textPrimary)

                        if group.totalCPU > 0 {
                            Text(group.totalCPUText)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(group.totalCPU > 50 ? MDColor.danger : MDColor.textSecondary)
                        }

                        HStack(spacing: 6) {
                            if let main = group.processes.first(where: { $0.isMainProcess }) {
                                Button {
                                    pendingKill = main
                                    showKillConfirm = true
                                } label: {
                                    Text("结束")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(MDColor.danger)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(MDColor.danger.opacity(0.10)))
                                }
                                .buttonStyle(.plain)
                            }

                            // 原版 ProcessInfo.kt:689 —— 按包名整组强停
                            Button {
                                pendingStopGroup = group
                                showStopGroupConfirm = true
                            } label: {
                                Text("强停")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(MDColor.process)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(MDColor.process.opacity(0.10)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard hasChildren else { return }
                    if isExpanded { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }

                if isExpanded {
                    VStack(spacing: 0) {
                        Divider()
                            .background(MDColor.outlineVariant)
                            .padding(.vertical, 8)

                        ForEach(group.processes) { proc in
                            processRow(proc)
                        }
                    }
                }
            }
        }
    }

    private func processRow(_ proc: ProcessStore.Proc) -> some View {
        HStack(spacing: 10) {
            Text(proc.isMainProcess ? "主" : "子")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(proc.isMainProcess ? MDColor.process : MDColor.textSecondary)
                .frame(width: 18, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill((proc.isMainProcess ? MDColor.process : MDColor.textSecondary).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(proc.subProcessSuffix.isEmpty ? "主进程" : proc.subProcessSuffix)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MDColor.textPrimary)
                Text("PID \(proc.pid)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MDColor.textSecondary)
            }

            Spacer(minLength: 4)

            Text(proc.rssText)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(MDColor.textSecondary)

            Button {
                pendingKill = proc
                showKillConfirm = true
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(MDColor.danger.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
    }

    /// 包名取后两段，够辨识且不占宽度
    private func shortName(_ pkg: String) -> String {
        let parts = pkg.split(separator: ".")
        guard parts.count > 2 else { return pkg }
        return parts.suffix(2).joined(separator: ".")
    }
}

#Preview {
    NavigationStack {
        ProcessView(device: .demo)
    }
}
