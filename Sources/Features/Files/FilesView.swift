import SwiftUI
import UIKit

/// 文件管理
///
/// 路径栏 + 目录列表 + 长按操作菜单。
/// 下载的文件落到 App 的 Documents/pulled，可通过分享面板导出。
struct FilesView: View {

    let device: DeviceRecord
    @StateObject private var store = FilesStore()

    @State private var showRename = false
    @State private var showCreateFolder = false
    @State private var showDeleteConfirm = false
    @State private var target: FilesStore.Entry?
    @State private var nameInput = ""
    @State private var shareURL: URL?

    var body: some View {
        ZStack {
            MDPageBackground()

            VStack(spacing: 0) {
                pathBar

                if let busy = store.busyMessage {
                    busyBar(busy)
                }

                if let err = store.errorMessage {
                    errorBar(err)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        if store.loading && store.entries.isEmpty {
                            ProgressView("读取目录…")
                                .padding(.vertical, 80)
                        } else if store.entries.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.entries) { entry in
                                entryRow(entry)
                            }
                        }
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.vertical, 12)
                }
                .refreshable { await store.load() }
            }
        }
        .navigationTitle("文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        nameInput = ""
                        showCreateFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    Button {
                        Task { await store.load(path: "/sdcard") }
                    } label: {
                        Label("回到 /sdcard", systemImage: "sdcard")
                    }
                    Button {
                        Task { await store.load(path: "/data/local/tmp") }
                    } label: {
                        Label("打开 /data/local/tmp", systemImage: "internaldrive")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MDColor.brand)
                }
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
        .alert("重命名", isPresented: $showRename) {
            TextField("新名称", text: $nameInput)
            Button("取消", role: .cancel) {}
            Button("确定") {
                guard let t = target else { return }
                Task { _ = await store.rename(t, to: nameInput) }
            }
        }
        .alert("新建文件夹", isPresented: $showCreateFolder) {
            TextField("文件夹名称", text: $nameInput)
            Button("取消", role: .cancel) {}
            Button("创建") {
                Task { _ = await store.createFolder(named: nameInput) }
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                guard let t = target else { return }
                Task { _ = await store.delete(t) }
            }
        } message: {
            if let t = target {
                Text(t.isDir
                     ? "将递归删除目录 \(t.name) 及其全部内容，不可恢复。"
                     : "将删除文件 \(t.name)，不可恢复。")
            }
        }
    }

    // MARK: - 路径栏

    private var pathBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.goUp() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MDColor.brand)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(MDColor.brand.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)

            Text(store.currentPath)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(MDColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 0)

            Text("\(store.entries.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MDColor.textSecondary)
        }
        .padding(.horizontal, MDMetric.pagePadding)
        .padding(.vertical, 10)
    }

    private func busyBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(MDColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MDMetric.pagePadding)
        .padding(.bottom, 8)
    }

    private func errorBar(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(MDColor.warning)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(MDColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MDMetric.pagePadding)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(MDColor.textTertiary)
            Text(store.loading ? "读取中" : "空目录")
                .font(.system(size: 15))
                .foregroundStyle(MDColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    // MARK: - 行

    private func entryRow(_ entry: FilesStore.Entry) -> some View {
        Button {
            if entry.isDir {
                Task { await store.load(path: entry.path) }
            } else {
                Task { await download(entry) }
            }
        } label: {
            MDCard(padding: 12) {
                HStack(spacing: 12) {
                    Image(systemName: entry.iconName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(entry.isDir ? MDColor.file : MDColor.textSecondary)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MDColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 8) {
                            Text(entry.isDir ? "目录" : entry.sizeText)
                            Text(entry.dateText)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer(minLength: 4)

                    if entry.isDir {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MDColor.textTertiary)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(MDColor.file)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                target = entry
                nameInput = entry.name
                showRename = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            if !entry.isDir {
                Button {
                    Task { await download(entry) }
                } label: {
                    Label("下载到本机", systemImage: "arrow.down.circle")
                }
            }

            Button(role: .destructive) {
                target = entry
                showDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 下载

    private func download(_ entry: FilesStore.Entry) async {
        guard let path = await store.pull(entry) else { return }
        shareURL = URL(fileURLWithPath: path)
    }
}

// MARK: - 分享面板

/// UIActivityViewController 的 SwiftUI 包装
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        FilesView(device: .demo)
    }
}
