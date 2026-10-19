import SwiftUI

/// 进程管理
///
/// 排版对照原版：顶部内存概览卡 + 进程列表（按 RSS 降序）。
/// 每行右侧是「结束」按钮，点击弹确认；不提供批量结束，避免误杀。
struct ProcessView: View {

    let device: DeviceRecord
    @StateObject private var store = ProcessStore()

    @State private var pendingKill: ProcessStore.Proc?
    @State private var showKillConfirm = false
    @State private var killError: String?

    var body: some View {
        ZStack {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    memoryCard
                    if let error = store.errorMessage {
                        errorCard(error)
                    }
                    listCard
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
        }
        .alert("结束进程", isPresented: $showKillConfirm) {
            Button("取消", role: .cancel) { pendingKill = nil }
            Button("结束", role: .destructive) {
                guard let p = pendingKill else { return }
                Task {
                    if let err = await store.kill(p) {
                        killError = err
                    }
                    pendingKill = nil
                }
            }
        } message: {
            if let p = pendingKill {
                Text("确定结束 \(p.name)（PID \(p.pid)）？\n系统进程被结束后可能导致设备重启。")
            }
        }
        .alert("结束失败", isPresented: Binding(
            get: { killError != nil },
            set: { if !$0 { killError = nil } }
        )) {
            Button("知道了", role: .cancel) { killError = nil }
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
                        Text("共 \(store.totalMemoryText)，已用 \(store.usedMemoryText)")
                            .font(.system(size: 13))
                            .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(store.processCount)")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(MDColor.process)
                        Text("个进程")
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                    }
                }

                // 内存条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(MDColor.surfaceHigh)
                            .frame(height: 8)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [MDColor.process.opacity(0.75), MDColor.process],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * memoryRatio), height: 8)
                    }
                }
                .frame(height: 8)
            }
        }
    }

    private var memoryRatio: Double {
        // 从 "2.4 GB" / "3.9 GB" 里算比例
        func gb(_ s: String) -> Double {
            Double(s.replacingOccurrences(of: " GB", with: "")) ?? 0
        }
        let total = gb(store.totalMemoryText)
        let used = gb(store.usedMemoryText)
        guard total > 0 else { return 0 }
        return min(1, used / total)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MDColor.warning)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(MDColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                .fill(MDColor.warning.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                        .stroke(MDColor.warning.opacity(0.22), lineWidth: 1)
                )
        )
    }

    // MARK: - 进程列表

    private var listCard: some View {
        VStack(spacing: 10) {
            if store.loading && store.processes.isEmpty {
                ProgressView("读取进程列表…")
                    .padding(.vertical, 60)
            } else if store.processes.isEmpty {
                emptyState
            } else {
                ForEach(store.processes) { proc in
                    procRow(proc)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(MDColor.textTertiary)
            Text("没有读到进程")
                .font(.system(size: 15))
                .foregroundStyle(MDColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func procRow(_ proc: ProcessStore.Proc) -> some View {
        MDCard(padding: 12) {
            HStack(spacing: 12) {
                // 状态点：运行中绿色，其余灰色
                Circle()
                    .fill(proc.isRunning ? MDColor.success : MDColor.textTertiary.opacity(0.5))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(proc.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MDColor.textPrimary)
                            .lineLimit(1)

                        if proc.isSystem {
                            Text("系统")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(MDColor.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(MDColor.surfaceHigh)
                                )
                        }
                    }

                    Text("PID \(proc.pid)  ·  \(proc.user)  ·  \(proc.state)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MDColor.textSecondary)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(proc.rssText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(MDColor.textPrimary)

                    Button {
                        pendingKill = proc
                        showKillConfirm = true
                    } label: {
                        Text("结束")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MDColor.danger)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(MDColor.danger.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProcessView(device: .demo)
    }
}
