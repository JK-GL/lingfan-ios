import SwiftUI
import UIKit
import QuickLook

/// 文件管理
///
/// 路径栏 + 目录列表 + 长按操作菜单。
/// 下载的文件落到 App 的 Documents/pulled，可通过分享面板导出。
struct FilesView: View {

    let device: DeviceRecord
    @StateObject private var store = FilesStore()

    @State private var showRename = false
    @State private var showCreateFolder = false
    @State private var createIsFolder = true
    @State private var detailEntry: FilesStore.Entry?
    /// 在本机打开（原版「在本机打开」→ 下载到缓存后预览）
    @State private var previewURL: URL?
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
                        if store.loading && store.displayEntries.isEmpty {
                            ProgressView("读取目录…")
                                .padding(.vertical, 80)
                        } else if store.displayEntries.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.displayEntries) { entry in
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
                    if let clip = store.clipboardEntry {
                        Button {
                            Task { _ = await store.paste() }
                        } label: {
                            Label(
                                "粘贴 \(clip.name)（\(store.clipboardIsCut ? "移动" : "复制")）",
                                systemImage: "doc.on.clipboard"
                            )
                        }
                        Button(role: .destructive) {
                            store.clearClipboard()
                        } label: {
                            Label("取消剪贴板", systemImage: "xmark.circle")
                        }
                        Divider()
                    }

                    Button {
                        nameInput = ""
                        createIsFolder = true
                        showCreateFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }

                    Button {
                        nameInput = ""
                        createIsFolder = false
                        showCreateFolder = true
                    } label: {
                        Label("新建文件", systemImage: "doc.badge.plus")
                    }

                    Divider()

                    Menu {
                        ForEach(FilesStore.SortOrder.allCases) { order in
                            Button {
                                store.sortOrder = order
                            } label: {
                                if store.sortOrder == order {
                                    Label(order.title, systemImage: "checkmark")
                                } else {
                                    Text(order.title)
                                }
                            }
                        }
                    } label: {
                        Label("排序：\(store.sortOrder.title)", systemImage: "arrow.up.arrow.down")
                    }

                    Button {
                        store.showHidden.toggle()
                    } label: {
                        Label(store.showHidden ? "隐藏隐藏文件" : "显示隐藏文件",
                              systemImage: store.showHidden ? "eye.slash" : "eye")
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
        .alert(createIsFolder ? "新建文件夹" : "新建文件", isPresented: $showCreateFolder) {
            TextField(createIsFolder ? "文件夹名称" : "文件名（含扩展名）", text: $nameInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("创建") {
                Task {
                    if createIsFolder {
                        _ = await store.createFolder(named: nameInput)
                    } else {
                        _ = await store.createFile(named: nameInput)
                    }
                }
            }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $detailEntry) { entry in
            FileDetailSheet(entry: entry, isPresented: Binding(
                get: { detailEntry != nil },
                set: { if !$0 { detailEntry = nil } }
            ))
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

            Text("\(store.displayEntries.count)")
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
                store.setClipboard(entry, cut: false)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }

            Button {
                store.setClipboard(entry, cut: true)
            } label: {
                Label("剪切", systemImage: "scissors")
            }

            Divider()

            Button {
                target = entry
                nameInput = entry.name
                showRename = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            if !entry.isDir {
                Button {
                    Task { await openInPlace(entry) }
                } label: {
                    Label("在本机打开", systemImage: "eye")
                }

                Button {
                    Task { await download(entry) }
                } label: {
                    Label("下载到本机", systemImage: "arrow.down.circle")
                }
            }

            Button {
                detailEntry = entry
            } label: {
                Label("文件详情", systemImage: "info.circle")
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

    /// 原版「在本机打开」：拉到本地后直接预览，不进分享面板
    private func openInPlace(_ entry: FilesStore.Entry) async {
        guard let path = await store.pull(entry) else { return }
        previewURL = URL(fileURLWithPath: path)
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

// MARK: - 文件详情

struct FileDetailSheet: View {
    let entry: FilesStore.Entry
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()
                ScrollView {
                    MDCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: entry.iconName)
                                    .font(.system(size: 26))
                                    .foregroundStyle(entry.isDir ? MDColor.file : MDColor.textSecondary)
                                Text(entry.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(MDColor.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Divider().background(MDColor.outlineVariant)

                            row("类型", entry.isDir ? "目录" : typeLabel)
                            row("大小", entry.isDir ? "—" : entry.sizeText)
                            row("权限", entry.permissions)
                            row("修改时间", entry.dateText)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("完整路径")
                                    .font(.system(size: 12))
                                    .foregroundStyle(MDColor.textSecondary)
                                Text(entry.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(MDColor.textPrimary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("文件详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(MDColor.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(MDColor.brand)
                }
            }
        }
    }

    private var typeLabel: String {
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? "文件" : "\(ext.uppercased()) 文件"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(MDColor.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MDColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    NavigationStack {
        FilesView(device: .demo)
    }
}
