import SwiftUI

/// App 管理
///
/// 搜索 + 列表 + 长按菜单（提取 / 停用 / 卸载）。
/// 停用比卸载安全：可恢复，且对系统应用有效。
struct AppsView: View {

    let device: DeviceRecord
    @StateObject private var store = AppsStore()

    @State private var target: AppsStore.App?
    @State private var showUninstall = false
    @State private var actionError: String?
    @State private var shareURL: URL?

    var body: some View {
        ZStack {
            MDPageBackground()

            VStack(spacing: 0) {
                searchBar

                if let busy = store.busyMessage {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text(busy)
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.bottom, 8)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        if store.loading && store.apps.isEmpty {
                            ProgressView("读取应用列表…")
                                .padding(.vertical, 80)
                        } else if store.filtered.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.filtered) { app in
                                appRow(app)
                            }
                        }
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.vertical, 12)
                }
                .refreshable { await store.load() }
            }
        }
        .navigationTitle("App管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(MDColor.background, for: .navigationBar)
        .task {
            store.bind(isDemo: device.isDemo)
            await store.load()
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert("确认卸载", isPresented: $showUninstall) {
            Button("取消", role: .cancel) {}
            Button("卸载", role: .destructive) {
                guard let t = target else { return }
                Task {
                    if let err = await store.uninstall(t) { actionError = err }
                }
            }
        } message: {
            if let t = target {
                Text("将卸载 \(t.displayName)（\(t.package)）。\n系统应用通常无法直接卸载，请改用「停用」。")
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("知道了", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(MDColor.textTertiary)

            TextField("搜索包名", text: $store.query)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(MDColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                .fill(MDColor.surfaceHigh)
        )
        .padding(.horizontal, MDMetric.pagePadding)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(MDColor.textTertiary)
            Text(store.query.isEmpty ? "没有读到应用" : "没有匹配的应用")
                .font(.system(size: 15))
                .foregroundStyle(MDColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    // MARK: - 行

    private func appRow(_ app: AppsStore.App) -> some View {
        MDCard(padding: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MDColor.app.opacity(0.12))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(app.displayName.prefix(1)))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(MDColor.app)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MDColor.textPrimary)
                            .lineLimit(1)

                        if app.isSystem {
                            badge("系统", tint: MDColor.textSecondary)
                        }
                        if app.isDisabled {
                            badge("已停用", tint: MDColor.warning)
                        }
                    }

                    Text(app.package)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MDColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Menu {
                    Button {
                        Task {
                            if let err = await store.forceStop(app) {
                                actionError = err
                            }
                        }
                    } label: {
                        Label("强制停止", systemImage: "stop.circle")
                    }

                    Button {
                        Task {
                            if let err = await store.clearData(app) {
                                actionError = err
                            }
                        }
                    } label: {
                        Label("清除数据", systemImage: "trash.slash")
                    }

                    Divider()

                    Button {
                        Task {
                            if let err = await store.extract(app) {
                                actionError = err
                            } else if let p = store.lastPulledLocalPath {
                                shareURL = URL(fileURLWithPath: p)
                            }
                        }
                    } label: {
                        Label("提取 APK", systemImage: "shippingbox")
                    }

                    Button {
                        Task {
                            if let err = await store.setDisabled(app, disabled: !app.isDisabled) {
                                actionError = err
                            }
                        }
                    } label: {
                        Label(app.isDisabled ? "启用" : "停用",
                              systemImage: app.isDisabled ? "play.circle" : "pause.circle")
                    }

                    Button(role: .destructive) {
                        target = app
                        showUninstall = true
                    } label: {
                        Label("卸载", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MDColor.textTertiary)
                        .frame(width: 32, height: 32)
                }
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

#Preview {
    NavigationStack {
        AppsView(device: .demo)
    }
}
