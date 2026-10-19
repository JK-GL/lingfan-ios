import SwiftUI

// 各功能页的占位实现。
// 协议层验证通过后逐个替换为真实实现，替换顺序见 README 的施工计划。

// MARK: - 设备信息

struct InfoView: View {
    let device: DeviceRecord
    @State private var info = DeviceInfo()
    @State private var loading = true

    var body: some View {
        MDPage(title: "设备信息") {
            if loading {
                ProgressView().padding(.vertical, 80)
            } else {
                MDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        infoRow("设备型号", info.displayName)
                        infoRow("序列号 (SN)", info.serial)
                        infoRow("Android 版本", info.androidVersion)
                        infoRow("SDK", info.sdk)
                    }
                }
                MDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("显示屏")
                        infoRow("分辨率", info.resolution)
                        infoRow("密度", info.density)
                    }
                }
                MDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("处理器")
                        infoRow("CPU", info.cpuInfo)
                    }
                }
                MDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("存储空间")
                        infoRow("内部存储", info.totalStorage)
                        infoRow("可用", info.availStorage)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(MDColor.textSecondary)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(MDColor.textSecondary)
                .frame(width: 100, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MDColor.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        let adb = AdbService.shared

        @Sendable func shell(_ c: String) async -> String {
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                adb.shellLines(c) { lines in
                    cont.resume(returning: lines.first ?? "")
                }
            }
        }

        // 顺序读取，避免 async let 在 MainActor 上的隔离冲突
        var d = DeviceInfo()
        d.brand = await shell("getprop ro.product.brand")
        d.model = await shell("getprop ro.product.model")
        d.serial = await shell("getprop ro.serialno")
        d.androidVersion = await shell("getprop ro.build.version.release")
        d.sdk = await shell("getprop ro.build.version.sdk")
        d.resolution = (await shell("wm size")).replacingOccurrences(of: "Physical size: ", with: "")
        d.density = (await shell("wm density")).replacingOccurrences(of: "Physical density: ", with: "")
        d.cpuInfo = await shell("getprop ro.board.platform")
        d.totalStorage = await shell("df -h /data 2>/dev/null | tail -1")

        info = d
        loading = false
    }
}

// MARK: - Shell

struct ShellView: View {
    let device: DeviceRecord
    @State private var command = ""
    @State private var history: [ShellEntry] = []
    @State private var running = false

    struct ShellEntry: Identifiable {
        let id = UUID()
        let command: String
        let output: String
        let success: Bool
    }

    var body: some View {
        ZStack {
            MDColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(history) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("$ \(entry.command)")
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(entry.success ? MDColor.brand : MDColor.danger)
                                    if !entry.output.isEmpty {
                                        Text(entry.output)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(MDColor.textPrimary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(MDColor.surface)
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, MDMetric.pagePadding)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: history.count) { _ in
                        if let last = history.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                // 输入栏
                HStack(spacing: 8) {
                    TextField("输入 adb shell 命令", text: $command)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MDColor.surface)
                        )

                    Button {
                        Task { await execute() }
                    } label: {
                        Image(systemName: running ? "hourglass" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(command.isEmpty ? MDColor.textTertiary : MDColor.brand)
                    }
                    .disabled(command.isEmpty || running)
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.vertical, 10)
                .background(MDColor.background)
            }
        }
        .navigationTitle("Shell执行")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func execute() async {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        running = true
        command = ""

        let (ok, output) = await withCheckedContinuation {
            (cont: CheckedContinuation<(Bool, String), Never>) in
            AdbService.shared.shell(cmd) { ok, out in
                cont.resume(returning: (ok, out))
            }
        }
        history.append(ShellEntry(command: cmd, output: output, success: ok))
        running = false
    }
}

// MARK: - 其余占位页

struct FilesView: View {
    let device: DeviceRecord
    var body: some View {
        PlaceholderPage(title: "文件管理", icon: "folder.fill",
                        tint: MDColor.file, note: "浏览 / 上传 / 下载 / 重命名远程文件")
    }
}

struct AppsView: View {
    let device: DeviceRecord
    var body: some View {
        PlaceholderPage(title: "App管理", icon: "square.grid.3x3.fill",
                        tint: MDColor.app, note: "安装 / 卸载 / 提取 APK / 冻结")
    }
}

struct MirrorView: View {
    let device: DeviceRecord
    var body: some View {
        PlaceholderPage(title: "设备投屏", icon: "airplayvideo",
                        tint: MDColor.info, note: "scrcpy 协议 + VideoToolbox 硬解")
    }
}

struct LinkView: View {
    let device: DeviceRecord
    var body: some View {
        PlaceholderPage(title: "菱粉联动", icon: "car.fill",
                        tint: MDColor.brand, note: "语音 / 图标 / 天气 / 日志定制")
    }
}

struct CleanupView: View {
    let device: DeviceRecord
    var body: some View {
        PlaceholderPage(title: "存储清理", icon: "trash.fill",
                        tint: MDColor.process, note: "扫描并清理设备冗余文件")
    }
}

/// 统一的占位页
struct PlaceholderPage: View {
    let title: String
    let icon: String
    let tint: Color
    let note: String

    var body: some View {
        ZStack {
            MDColor.background.ignoresSafeArea()
            VStack(spacing: 14) {
                MDIconTile(systemName: icon, tint: tint, size: 72, radius: 20)
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MDColor.textPrimary)
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(MDColor.textSecondary)
                Text("待实现")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MDColor.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(MDColor.textTertiary.opacity(0.12))
                    )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
