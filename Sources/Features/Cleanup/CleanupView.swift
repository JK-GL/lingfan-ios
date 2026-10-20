import SwiftUI

/// 存储清理
///
/// 三段式：过滤器建议 / 已卸载残留 / 大文件。
/// 每项都能单独勾选，清理后用 du 复核实际释放量。
struct CleanupView: View {

    let device: DeviceRecord
    @StateObject private var store = CleanupStore()

    /// 选中的路径集合（跨三类共用）
    @State private var selected: Set<String> = []
    @State private var showConfirm = false
    @State private var resultMessage: String?
    @State private var expandedSuggestion: Set<String> = []

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
                        scanCard
                    } else {
                        usageSection
                        suggestionSection
                        corpseSection
                        largeFileSection
                        if hasAny { actionBar }
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
                    let freed = await store.clean(paths: selected)
                    selected.removeAll()
                    resultMessage = freed > 0
                        ? "已释放 \(fmt(freed))"
                        : "没有释放空间（可能权限不足或文件已被占用）"
                }
            }
        } message: {
            Text("将删除选中的 \(selected.count) 项，不可恢复。\n「大文件」里的内容会整文件删除，请确认不是需要保留的资料。")
        }
    }

    private var hasAny: Bool {
        !store.suggestions.isEmpty || !store.corpses.isEmpty || !store.largeFiles.isEmpty
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

    private var scanCard: some View {
        MDCard {
            VStack(spacing: 10) {
                ProgressView()
                Text(store.scanStep.isEmpty ? "扫描中…" : store.scanStep)
                    .font(.system(size: 13))
                    .foregroundStyle(MDColor.textSecondary)
                Text("逐个过滤器执行 find，车机上可能需要几十秒")
                    .font(.system(size: 11))
                    .foregroundStyle(MDColor.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private func noticeCard(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tint == MDColor.success
                  ? "checkmark.circle.fill" : "info.circle.fill")
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

    // MARK: - 占用明细（原版 QUICK_SCAN_DIRS）

    private var usageSection: some View {
        Group {
            if !store.usageItems.isEmpty {
                MDCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MDColor.info)
                            Text("存储占用")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(MDColor.textPrimary)
                            Spacer(minLength: 0)
                        }

                        let maxBytes = store.usageItems.first?.sizeBytes ?? 1
                        ForEach(store.usageItems) { item in
                            VStack(spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(MDColor.textPrimary)
                                    if item.isSensitive {
                                        Text("敏感")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(MDColor.warning)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(MDColor.warning.opacity(0.12)))
                                    }
                                    Spacer(minLength: 4)
                                    Text(item.sizeText)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(MDColor.textSecondary)
                                }

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(MDColor.surfaceHigh).frame(height: 5)
                                        Capsule()
                                            .fill(item.isSensitive ? MDColor.warning : MDColor.info)
                                            .frame(
                                                width: max(2, geo.size.width * CGFloat(Double(item.sizeBytes) / Double(max(maxBytes, 1)))),
                                                height: 5
                                            )
                                    }
                                }
                                .frame(height: 5)
                            }
                            .padding(.vertical, 2)
                        }

                        if store.usageItems.contains(where: \.isSensitive) {
                            Text("Android/data 包含应用缓存和用户数据，误删可能导致应用异常，建议优先检查「应用残留」后再处理。")
                                .font(.system(size: 10))
                                .foregroundStyle(MDColor.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 过滤器建议

    private var suggestionSection: some View {
        ForEach(store.suggestions) { s in
            suggestionCard(s)
        }
    }

    private func suggestionCard(_ s: CleanupStore.Suggestion) -> some View {
        let isExpanded = expandedSuggestion.contains(s.id)
        let allSelected = !s.targets.isEmpty && s.targets.allSatisfy { selected.contains($0.path) }

        return MDCard(padding: 12) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        toggleAll(s.targets.map { $0.path }, select: !allSelected)
                    } label: {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(allSelected ? MDColor.brand : MDColor.textTertiary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MDColor.textPrimary)
                        Text("\(s.count) 项 · \(s.source)")
                            .font(.system(size: 11))
                            .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(s.totalText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(MDColor.textPrimary)
                        if s.count > 1 {
                            Text(isExpanded ? "收起" : "展开")
                                .font(.system(size: 11))
                                .foregroundStyle(MDColor.brand)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard s.count > 1 else { return }
                    if isExpanded { expandedSuggestion.remove(s.id) }
                    else { expandedSuggestion.insert(s.id) }
                }

                if isExpanded {
                    VStack(spacing: 0) {
                        Divider().background(MDColor.outlineVariant).padding(.vertical, 8)
                        ForEach(s.targets) { t in
                            targetRow(t.path, sizeText: t.sizeText)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 已卸载残留

    private var corpseSection: some View {
        Group {
            if !store.corpses.isEmpty {
                MDCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "app.badge.checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MDColor.app)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已卸载应用残留")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(MDColor.textPrimary)
                                Text("这些应用已卸载，但数据目录还占着空间")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MDColor.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }

                        ForEach(store.corpses) { c in
                            HStack(spacing: 10) {
                                Button {
                                    toggleAll([c.path], select: !selected.contains(c.path))
                                } label: {
                                    Image(systemName: selected.contains(c.path)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(selected.contains(c.path)
                                                         ? MDColor.brand : MDColor.textTertiary)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shortPkg(c.packageName))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(MDColor.textPrimary)
                                        .lineLimit(1)
                                    Text(c.locationType)
                                        .font(.system(size: 10))
                                        .foregroundStyle(MDColor.textSecondary)
                                }

                                Spacer(minLength: 4)

                                Text(c.sizeText)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(MDColor.process)

                                // 原版排除项：忽略后不再提示
                                Button {
                                    store.ignoreCorpse(c)
                                    selected.remove(c.path)
                                } label: {
                                    Image(systemName: "eye.slash")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(MDColor.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 大文件

    private var largeFileSection: some View {
        Group {
            if !store.largeFiles.isEmpty {
                MDCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive.badge.exclamationmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MDColor.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("大文件（>200 MB）")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(MDColor.textPrimary)
                                Text("注意：这些是完整文件，不是缓存")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MDColor.warning)
                            }
                            Spacer(minLength: 0)
                        }

                        ForEach(store.largeFiles) { f in
                            HStack(spacing: 10) {
                                Button {
                                    toggleAll([f.path], select: !selected.contains(f.path))
                                } label: {
                                    Image(systemName: selected.contains(f.path)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(selected.contains(f.path)
                                                         ? MDColor.brand : MDColor.textTertiary)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(MDColor.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text((f.path as NSString).deletingLastPathComponent)
                                        .font(.system(size: 10))
                                        .foregroundStyle(MDColor.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }

                                Spacer(minLength: 4)

                                Text(f.sizeText)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(MDColor.textPrimary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 行

    private func targetRow(_ path: String, sizeText: String) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleAll([path], select: !selected.contains(path))
            } label: {
                Image(systemName: selected.contains(path)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected.contains(path) ? MDColor.brand : MDColor.textTertiary)
            }
            .buttonStyle(.plain)

            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(MDColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 4)

            Text(sizeText)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(MDColor.textPrimary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 操作栏

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("已选 \(selected.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(MDColor.textSecondary)
                Spacer()
                if !selected.isEmpty {
                    Button {
                        selected.removeAll()
                    } label: {
                        Text("清空选择")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MDColor.brand)
                    }
                    .buttonStyle(.plain)
                }
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

    // MARK: - 工具

    private func toggleAll(_ paths: [String], select: Bool) {
        if select {
            paths.forEach { selected.insert($0) }
        } else {
            paths.forEach { selected.remove($0) }
        }
    }

    private func shortPkg(_ pkg: String) -> String {
        let parts = pkg.split(separator: ".")
        return parts.count > 2 ? parts.suffix(2).joined(separator: ".") : pkg
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
