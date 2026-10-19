import SwiftUI
import UIKit

/// 常用工具
///
/// 四块：截图（含预览与大图）、状态快照、日志、电源操作。
/// 全部走 shell，不依赖 file_sync 协议。
struct ToolsView: View {

    let device: DeviceRecord
    @StateObject private var store = ToolsStore()

    @State private var showRebootConfirm = false
    @State private var pendingReboot: ToolsStore.RebootMode = .normal
    @State private var showLog = false
    @State private var showShot = false
    @State private var videoURL: URL?

    var body: some View {
        ZStack {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    screenshotCard
                    recordCard
                    topWindowCard
                    snapshotCard
                    logCard
                    powerCard

                    if let msg = store.lastMessage {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("常用工具")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(MDColor.background, for: .navigationBar)
        .task {
            store.bind(isDemo: device.isDemo)
            await store.loadSnapshot()
        }
        .sheet(isPresented: $showLog) {
            LogSheet(text: store.logText, isPresented: $showLog)
        }
        .sheet(isPresented: $showShot) {
            ScreenshotSheet(image: store.screenshot, isPresented: $showShot)
        }
        .sheet(isPresented: Binding(
            get: { videoURL != nil },
            set: { if !$0 { videoURL = nil } }
        )) {
            if let videoURL {
                ShareSheet(items: [videoURL])
            }
        }
        .alert("确认\(pendingReboot.title)", isPresented: $showRebootConfirm) {
            Button("取消", role: .cancel) {}
            Button("执行", role: .destructive) {
                Task { _ = await store.reboot(pendingReboot) }
            }
        } message: {
            Text("车机将立即执行 `\(pendingReboot.command)`。\n重启期间连接会中断，需要重新连接。")
        }
    }

    // MARK: - 截图

    private var screenshotCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle(icon: "camera.fill", tint: MDColor.info, title: "屏幕截图")

                if let img = store.screenshot {
                    Button {
                        showShot = true
                    } label: {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 180)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                                    .stroke(MDColor.textTertiary.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    MDPrimaryButton(
                        title: store.running ? "截取中…" : "截取当前屏幕",
                        enabled: !store.running
                    ) {
                        Task { await store.takeScreenshot() }
                    }
                }

                Text("走 screencap + base64，1080p 约 200 KB")
                    .font(.system(size: 11))
                    .foregroundStyle(MDColor.textTertiary)
            }
        }
    }

    // MARK: - 屏幕录制

    private var recordCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    cardTitle(icon: "record.circle", tint: MDColor.process, title: "屏幕录制")
                    Spacer()
                    if store.recording {
                        Text(String(format: "%02d:%02d", store.recordingSeconds / 60,
                                    store.recordingSeconds % 60))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MDColor.danger)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            if store.recording {
                                if let path = await store.stopRecording() {
                                    videoURL = URL(fileURLWithPath: path)
                                }
                            } else {
                                await store.startRecording()
                            }
                        }
                    } label: {
                        Text(store.recording ? "停止并保存" : "开始录制（最长 30 秒）")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(store.recording ? .white : MDColor.process)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .fill(store.recording
                                          ? MDColor.danger
                                          : MDColor.process.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }

                Text("走 screenrecord 录制 MP4，停止后自动取回本机")
                    .font(.system(size: 11))
                    .foregroundStyle(MDColor.textTertiary)
            }
        }
    }

    // MARK: - 顶层窗口

    private var topWindowCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    cardTitle(icon: "rectangle.on.rectangle", tint: MDColor.remote,
                              title: "顶层窗口")
                    Spacer()
                    Button {
                        Task { await store.loadTopWindow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MDColor.remote)
                    }
                    .buttonStyle(.plain)
                }

                Text(store.topWindowText.isEmpty
                     ? "点击右上角刷新读取当前前台 Activity"
                     : store.topWindowText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(store.topWindowText.isEmpty
                                     ? MDColor.textTertiary : MDColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                            .fill(MDColor.surfaceHigh)
                    )
            }
        }
    }

    // MARK: - 状态快照

    private var snapshotCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    cardTitle(icon: "info.circle.fill", tint: MDColor.tool, title: "设备状态快照")
                    Spacer()
                    Button {
                        Task { await store.loadSnapshot() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MDColor.tool)
                    }
                    .buttonStyle(.plain)
                }

                Text(store.deviceInfoText.isEmpty ? "读取中…" : store.deviceInfoText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MDColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                            .fill(MDColor.surfaceHigh)
                    )
            }
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle(icon: "doc.text.magnifyingglass", tint: MDColor.shell, title: "系统日志")

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await store.loadLog()
                            if !store.logText.isEmpty { showLog = true }
                        }
                    } label: {
                        Text(store.running ? "读取中…" : "读取最近 200 行")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MDColor.shell)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .stroke(MDColor.shell.opacity(0.4), lineWidth: 1.2)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.running)

                    Button {
                        Task { await store.clearLog() }
                    } label: {
                        Text("清空")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MDColor.textSecondary)
                            .frame(width: 76, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .stroke(MDColor.textTertiary.opacity(0.5), lineWidth: 1.2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 电源

    private var powerCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle(icon: "power", tint: MDColor.process, title: "电源操作")

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                    spacing: 10
                ) {
                    ForEach(ToolsStore.RebootMode.allCases) { mode in
                        Button {
                            pendingReboot = mode
                            showRebootConfirm = true
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(mode == .shutdown || mode == .bootloader
                                                 ? MDColor.danger : MDColor.process)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                        .fill((mode == .shutdown || mode == .bootloader
                                               ? MDColor.danger : MDColor.process).opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 通用标题

    private func cardTitle(icon: String, tint: Color, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MDColor.textPrimary)
        }
    }
}

// MARK: - 日志查看

struct LogSheet: View {
    let text: String
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MDColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("系统日志")
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

// MARK: - 截图查看

struct ScreenshotSheet: View {
    let image: UIImage?
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .navigationTitle("截图预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(.white)
                }
                if let image {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
        }
    }
}

#Preview {
    NavigationStack {
        ToolsView(device: .demo)
    }
}
