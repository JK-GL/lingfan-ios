import SwiftUI
import UIKit

/// 设备投屏（准实时截图轮询）
///
/// 画面区 + 控制栏 + 触摸映射说明。
/// 点击画面暂不下发触摸事件 —— 需要先拿到车机分辨率再算坐标映射，
/// 这一版只做「看」，不做「控」。
struct MirrorView: View {

    let device: DeviceRecord
    @StateObject private var store = MirrorStore()

    @State private var showFullscreen = false
    /// 画面旋转角度（原版「旋转画面」菜单项）
    @State private var rotationQuarter = 0

    var body: some View {
        ZStack {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    screenCard
                    infoCard
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("设备投屏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        rotationQuarter = (rotationQuarter + 1) % 4
                    } label: {
                        Label("旋转画面", systemImage: "rotate.right")
                    }
                    Button {
                        rotationQuarter = 0
                    } label: {
                        Label("重置方向", systemImage: "arrow.counterclockwise")
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
            store.start()
        }
        .onDisappear { store.stop() }
        .sheet(isPresented: $showFullscreen) {
            FullscreenMirror(image: store.frame, isPresented: $showFullscreen)
        }
    }

    // MARK: - 画面

    private var screenCard: some View {
        MDCard(padding: 10) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                        .fill(Color.black)

                    if let img = store.frame {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .rotationEffect(.degrees(Double(rotationQuarter) * 90))
                    } else {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text(store.running ? "正在获取画面…" : "已停止")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let img = store.frame {
                        Button {
                            showFullscreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(Circle().fill(.black.opacity(0.45)))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        if store.running { store.stop() } else { store.start() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: store.running ? "pause.fill" : "play.fill")
                                .font(.system(size: 12))
                            Text(store.running ? "暂停" : "开始")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(store.running ? MDColor.danger : MDColor.brand)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                .fill((store.running ? MDColor.danger : MDColor.brand).opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f fps", store.fps))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(MDColor.textPrimary)
                        Text("\(store.frameCount) 帧")
                            .font(.system(size: 11))
                            .foregroundStyle(MDColor.textSecondary)
                    }
                    .frame(width: 74, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - 说明

    private var infoCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MDColor.info)
                    Text("当前为截图轮询模式")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)
                }

                Text("""
                每帧通过 `screencap -p | base64` 抓取，实际帧率约 1~3 fps，\
                适合观察车机状态，不适合播放视频。

                低帧率的原因：每帧要完成一次 ADB 往返 + PNG 编码 + base64 传输（体积膨胀 33%）+ iOS 端解码。

                真正的 60fps 投屏需要 scrcpy 协议（H.264 硬件解码），\
                依赖 `adb forward` + VideoToolbox，需要真机验证后再上。
                """)
                .font(.system(size: 12))
                .foregroundStyle(MDColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                if let err = store.lastError {
                    Divider().background(MDColor.outlineVariant)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.warning)
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                    }
                }

                if store.lastFrameBytes > 0 {
                    Divider().background(MDColor.outlineVariant)
                    Text("单帧 \(store.lastFrameBytes / 1024) KB（PNG 编码后）")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MDColor.textTertiary)
                }
            }
        }
    }
}

// MARK: - 全屏查看

struct FullscreenMirror: View {
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
                } else {
                    Text("无画面")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .navigationTitle("投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
        }
    }
}

#Preview {
    NavigationStack {
        MirrorView(device: .demo)
    }
}
