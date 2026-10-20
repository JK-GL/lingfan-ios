import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var showImporter = false
    @State private var showDetail = false
    @State private var detailTarget: AppsStore.App?
    @State private var showStartup = false
    @State private var startupTarget: AppsStore.App?

    var body: some View {
        ZStack {
            MDPageBackground()

            VStack(spacing: 0) {
                searchBar

                if let busy = store.busyMessage {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text(store.installProgress ?? busy)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(MDColor.brand)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    // 安全作用域访问：从「文件」App 选的文件需要 startAccessing
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                    // 复制到沙箱，避免权限在异步途中失效
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: tmp)
                    do {
                        try FileManager.default.copyItem(at: url, to: tmp)
                    } catch {
                        actionError = "读取文件失败：\(error.localizedDescription)"
                        return
                    }
                    if let err = await store.install(localPath: tmp.path) {
                        actionError = err
                    }
                    try? FileManager.default.removeItem(at: tmp)
                }
            case .failure(let error):
                actionError = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showDetail) {
            AppDetailSheet(text: store.detailText, isPresented: $showDetail)
        }
        .sheet(isPresented: $showStartup) {
            if let app = startupTarget {
                AppStartupSheet(store: store, app: app, isPresented: $showStartup)
            }
        }
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
                            if let err = await store.launch(app) {
                                actionError = err
                            }
                        }
                    } label: {
                        Label("启动应用", systemImage: "play.circle")
                    }

                    Button {
                        detailTarget = app
                        Task {
                            await store.loadDetail(app)
                            showDetail = true
                        }
                    } label: {
                        Label("查看详情", systemImage: "info.circle")
                    }

                    Divider()

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
                        startupTarget = app
                        showStartup = true
                        Task { await store.loadStartup(app) }
                    } label: {
                        Label("自启动管理", systemImage: "power.circle")
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

// MARK: - 应用详情

struct AppDetailSheet: View {
    let text: String
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()
                ScrollView([.vertical, .horizontal]) {
                    Text(text.isEmpty ? "读取中…" : text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MDColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("应用详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(MDColor.brand)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(MDColor.brand)
                    }
                }
            }
        }
    }
}

// MARK: - 自启动管理

struct AppStartupSheet: View {
    @ObservedObject var store: AppsStore
    let app: AppsStore.App
    @Binding var isPresented: Bool

    private var info: AppStartupInfo { store.startupInfo }

    var body: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()

                ScrollView {
                    VStack(spacing: MDMetric.cardSpacing) {
                        summaryCard

                        if let msg = store.startupMessage {
                            Text(msg)
                                .font(.system(size: 12))
                                .foregroundStyle(MDColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                                        .fill(MDColor.surfaceHigh)
                                )
                        }

                        if store.startupLoading {
                            MDCard {
                                VStack(spacing: 10) {
                                    ProgressView()
                                    Text("读取组件清单…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(MDColor.textSecondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                            }
                        } else if info.status == .none {
                            emptyCard("这个应用没有监听开机广播的组件")
                        } else if info.status == .error {
                            emptyCard(info.errorMessage.isEmpty ? "检测失败" : info.errorMessage)
                        } else {
                            ForEach(info.receivers) { receiver in
                                receiverCard(receiver)
                            }
                        }
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("自启动管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(MDColor.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(MDColor.brand)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.loadStartup(app) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(MDColor.brand)
                    }
                    .disabled(store.startupLoading)
                }
            }
        }
    }

    private var summaryCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(app.displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MDColor.textPrimary)
                    .lineLimit(1)
                Text(app.package)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MDColor.textSecondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(info.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(info.hasEnabled ? MDColor.warning : MDColor.success)
                    if info.status == .found {
                        Text("· 共 \(info.receivers.count) 个组件")
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    private func receiverCard(_ receiver: AppStartupReceiver) -> some View {
        let busy = store.startupBusyComponent == receiver.componentName

        return MDCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receiver.shortName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MDColor.textPrimary)
                        .lineLimit(1)

                    Text(receiver.actionLabels.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(MDColor.textSecondary)

                    Text(receiver.componentName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MDColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if busy {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Toggle("", isOn: Binding(
                        get: { receiver.enabled },
                        set: { newValue in
                            Task {
                                await store.toggleStartup(app, receiver: receiver, enabled: newValue)
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(MDColor.app)
                }
            }
        }
    }

    private func emptyCard(_ text: String) -> some View {
        MDCard {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(MDColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    NavigationStack {
        AppsView(device: .demo)
    }
}
