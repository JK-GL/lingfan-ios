import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

/// 菱粉联动
///
/// 通过 content call 驱动菱粉桌面的内部 Provider。
/// 四项：版本/激活、天气 Key、语音定制、图标定制。
/// 原始输出始终可查，格式不符时能直接定位。
struct LinkView: View {

    let device: DeviceRecord
    @StateObject private var store = LinkStore()

    @State private var showWeatherEdit = false
    @State private var keyInput = ""
    @State private var hostInput = ""
    @State private var showRaw = false
    @State private var showLogPreview = false

    // 图标编辑（具体状态在 IconEditorSheet 内部）
    @State private var showIconEditor = false
    @State private var iconTarget: LingFansIconItem?
    @State private var showPackImporter = false

    // 语音定制
    @State private var showVoicePicker = false
    @State private var voiceUploadKey: String?
    @State private var voiceError: String?
    @State private var voicePlayingKey: String?
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        ZStack {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    statusCard

                    if store.available {
                        versionCard
                        weatherCard
                        voiceCard
                        iconCard
                        rawCard
                    } else if let err = store.errorMessage {
                        noticeCard(err, tint: MDColor.warning)
                    }

                    // 日志抓取不依赖激活（原版 requiresActivation = false），
                    // 只要连上设备就能抓，所以放在 available 判断之外。
                    logCard
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await store.probe() }
        }
        .navigationTitle("菱粉联动")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(MDColor.background, for: .navigationBar)
        .task {
            store.bind(isDemo: device.isDemo)
            await store.probe()
            guard store.available else { return }
            await store.loadActivation()
            await store.loadWeather()
            await store.loadVoice()
            await store.loadIcons()
        }
        .alert("天气 API Key", isPresented: $showWeatherEdit) {
            TextField("API Key", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Host", text: $hostInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task { _ = await store.setWeather(apiKey: keyInput, host: hostInput) }
            }
        } message: {
            Text("写入菱粉桌面的天气数据源配置。\nHost 例如 api.seniverse.com")
        }
        .sheet(isPresented: $showRaw) {
            rawSheet
        }
        .sheet(isPresented: $showLogPreview) {
            LogPreviewSheet(
                text: store.logPreview,
                exportPath: store.logExportPath,
                isPresented: $showLogPreview
            )
        }
        .sheet(isPresented: $showIconEditor) {
            if let item = iconTarget {
                IconEditorSheet(
                    store: store,
                    item: item,
                    isPresented: $showIconEditor
                )
            }
        }
        .fileImporter(
            isPresented: $showPackImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pack_import_\(UUID().uuidString).zip")
                try? FileManager.default.removeItem(at: tmp)
                do {
                    try FileManager.default.copyItem(at: url, to: tmp)
                } catch {
                    return
                }
                Task {
                    await store.importIconPack(fileURL: tmp)
                    try? FileManager.default.removeItem(at: tmp)
                }
            case .failure:
                break
            }
        }
        .fileImporter(
            isPresented: $showVoicePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let key = voiceUploadKey else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let ext = url.pathExtension.lowercased()
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voice_\(UUID().uuidString).\(ext)")
                try? FileManager.default.removeItem(at: tmp)
                do {
                    try FileManager.default.copyItem(at: url, to: tmp)
                } catch {
                    voiceError = "读取音频失败：\(error.localizedDescription)"
                    return
                }
                Task {
                    if let err = await store.uploadVoice(key: key, localPath: tmp.path) {
                        voiceError = err
                    }
                    try? FileManager.default.removeItem(at: tmp)
                }
            case .failure:
                break
            }
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MDColor.brand.opacity(0.12))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "car.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(MDColor.brand)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("菱粉桌面联动")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MDColor.textPrimary)
                        Text(store.available
                             ? "已连接 · \(store.authority ?? "")"
                             : (store.probing ? "探测中…" : "未检测到"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(store.available ? MDColor.success : MDColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    if store.probing {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Circle()
                            .fill(store.available ? MDColor.success : MDColor.textTertiary)
                            .frame(width: 9, height: 9)
                    }
                }

                if let busy = store.busyMessage {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(busy)
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func noticeCard(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(tint)
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

    // MARK: - 版本 / 激活

    private var versionCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("版本与激活", icon: "checkmark.seal.fill", tint: MDColor.app)

                if store.versionName.isEmpty {
                    Text("读取中…")
                        .font(.system(size: 13))
                        .foregroundStyle(MDColor.textSecondary)
                } else {
                    kvRow("桌面版本", store.versionName)
                    if store.versionCode > 0 {
                        kvRow("版本号", "\(store.versionCode)")
                    }
                    kvRow("最低要求", LinkStore.minVersion)

                    Divider().background(MDColor.outlineVariant)

                    HStack(spacing: 6) {
                        Image(systemName: store.activated
                              ? "checkmark.seal.fill" : "exclamationmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(store.activated ? MDColor.success : MDColor.warning)
                        Text(store.activated ? "已激活" : "未激活")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(store.activated ? MDColor.success : MDColor.warning)
                        if !store.activationMessage.isEmpty && store.activationMessage != "ok" {
                            Text(store.activationMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(MDColor.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    if store.versionTooLow {
                        Text("当前版本低于 \(LinkStore.minVersion)，部分联动功能可能不可用。")
                            .font(.system(size: 11))
                            .foregroundStyle(MDColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 天气

    private var weatherCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("天气数据源", icon: "cloud.sun.fill", tint: MDColor.info)
                    Spacer()
                    Button("修改") {
                        keyInput = store.weatherApiKey
                        hostInput = store.weatherHost
                        showWeatherEdit = true
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MDColor.brand)
                }

                kvRow("API Key", store.weatherApiKey.isEmpty ? "未配置" : maskKey(store.weatherApiKey))
                kvRow("Host", store.weatherHost.isEmpty ? "未配置" : store.weatherHost)
            }
        }
    }

    /// 遮蔽中间部分，避免整串暴露
    private func maskKey(_ key: String) -> String {
        guard key.count > 6 else { return key }
        let head = key.prefix(3)
        let tail = key.suffix(2)
        return "\(head)****\(tail)"
    }

    // MARK: - 语音

    private var voiceCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("语音定制", icon: "waveform", tint: MDColor.remote)

                if store.voiceItems.isEmpty {
                    Text(store.voiceSnapshot.message.isEmpty
                         ? "无定制项，或桌面版本不支持"
                         : store.voiceSnapshot.message)
                        .font(.system(size: 13))
                        .foregroundStyle(MDColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(store.voiceItems) { item in
                        voiceRow(item)
                    }
                }

                if let err = voiceError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(MDColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func voiceRow(_ item: LingFansVoiceItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MDColor.textPrimary)
                    .lineLimit(1)
                if item.hasCustom {
                    Text("自定义")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MDColor.remote)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(MDColor.remote.opacity(0.12)))
                }
                Spacer(minLength: 4)

                if item.hasCustom {
                    Button {
                        Task {
                            let ok = await store.playVoicePreview(key: item.key)
                            if !ok { voiceError = "车机播放失败" }
                        }
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MDColor.remote)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await playOnPhone(key: item.key) }
                } label: {
                    Image(systemName: voicePlayingKey == item.key
                          ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MDColor.brand)
                }
                .buttonStyle(.plain)

                Button {
                    voiceUploadKey = item.key
                    voiceError = nil
                    showVoicePicker = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MDColor.brand)
                }
                .buttonStyle(.plain)

                if item.hasCustom {
                    Button {
                        Task { _ = await store.resetVoice(key: item.key) }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MDColor.danger)
                    }
                    .buttonStyle(.plain)
                }
            }

            if item.hasCustom {
                Text(item.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(MDColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
    }

    /// 手机端试听：export → pull → AVAudioPlayer
    private func playOnPhone(key: String) async {
        voiceError = nil

        if voicePlayingKey == key {
            audioPlayer?.stop()
            audioPlayer = nil
            voicePlayingKey = nil
            return
        }

        audioPlayer?.stop()
        audioPlayer = nil

        guard let path = await store.pullVoicePreview(key: key) else {
            voiceError = "取回预览失败（车机可能未导出该语音）"
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            voicePlayingKey = key

            // 播完自动复位
            let duration = player.duration
            try? await Task.sleep(nanoseconds: UInt64(max(duration, 0.5) * 1_000_000_000))
            if voicePlayingKey == key {
                voicePlayingKey = nil
                audioPlayer = nil
            }
        } catch {
            voiceError = "播放失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 图标

    private var iconCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("应用图标", icon: "app.badge.fill", tint: MDColor.app)
                    Spacer()
                    Button {
                        Task { await store.refreshIcons() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MDColor.brand)
                    }
                    .buttonStyle(.plain)
                }

                if store.iconItems.isEmpty {
                    Text(store.iconSnapshot.message.isEmpty
                         ? "无可替换图标的应用"
                         : store.iconSnapshot.message)
                        .font(.system(size: 13))
                        .foregroundStyle(MDColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(store.iconItems) { item in
                        iconRow(item)
                    }
                }

                // 图标包导入 / 导出
                HStack(spacing: 10) {
                    Button {
                        showPackImporter = true
                    } label: {
                        Text("导入图标包")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MDColor.app)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .stroke(MDColor.app.opacity(0.35), lineWidth: 1.1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.iconPackBusy)

                    Button {
                        Task { await store.exportIconPack() }
                    } label: {
                        Text(store.iconPackBusy ? "处理中…" : "导出图标包")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MDColor.app)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .stroke(MDColor.app.opacity(0.35), lineWidth: 1.1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.iconPackBusy)
                }

                if let msg = store.iconPackMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(MDColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let url = store.iconPackExportURL {
                    ShareLink(item: url) {
                        Text("保存导出的图标包")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MDColor.brand)
                    }
                }
            }
        }
    }

    private func iconRow(_ item: LingFansIconItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MDColor.textPrimary)
                        .lineLimit(1)
                    if item.hasCustomIcon {
                        Text("自定义")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(MDColor.app)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(MDColor.app.opacity(0.12)))
                    }
                }
                Text(item.packageName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MDColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Button {
                iconTarget = item
                showIconEditor = true
            } label: {
                Text("设置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MDColor.brand)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(MDColor.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)

            if item.hasCustomIcon {
                Button {
                    Task { _ = await store.resetIcon(package: item.packageName) }
                } label: {
                    Text("重置")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MDColor.danger)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(MDColor.danger.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private func shortPackage(_ pkg: String) -> String {
        pkg.split(separator: ".").suffix(2).joined(separator: ".")
    }

    // MARK: - 原始输出

    // MARK: - 日志抓取

    private var logCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("日志抓取", icon: "doc.text.magnifyingglass", tint: MDColor.file)

                Text("抓取近 3 分钟内菱粉桌面相关日志（按进程 PID 与包名双重匹配）")
                    .font(.system(size: 11))
                    .foregroundStyle(MDColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !store.logMessage.isEmpty {
                    Text(store.logMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(store.logMatchedCount > 0 ? MDColor.success : MDColor.warning)
                    if store.logScannedCount > 0 {
                        Text("扫描 \(store.logScannedCount) 行 · 命中 \(store.logMatchedCount) 条")
                            .font(.system(size: 11))
                            .foregroundStyle(MDColor.textTertiary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await store.captureLogs() }
                    } label: {
                        HStack(spacing: 6) {
                            if store.logCapturing {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text(store.logCapturing ? "抓取中…" : "抓取日志")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(MDColor.file)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                .stroke(MDColor.file.opacity(0.4), lineWidth: 1.2)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.logCapturing)

                    Button {
                        showLogPreview = true
                    } label: {
                        Text("查看")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(store.logPreview.isEmpty
                                             ? MDColor.textTertiary : MDColor.textSecondary)
                            .frame(width: 76, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .stroke(MDColor.textTertiary.opacity(0.5), lineWidth: 1.2)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.logPreview.isEmpty)
                }
            }
        }
    }

    private var rawCard: some View {
        MDCard(padding: 12) {
            HStack {
                Text("原始输出")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MDColor.textSecondary)
                Spacer()
                Button("查看") { showRaw = true }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MDColor.brand)
            }
        }
    }

    private var rawSheet: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()
                ScrollView {
                    Text(store.lastRawOutput.isEmpty ? "（无输出）" : store.lastRawOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MDColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Provider 原始输出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showRaw = false }
                        .foregroundStyle(MDColor.brand)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = store.lastRawOutput
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(MDColor.brand)
                    }
                }
            }
        }
    }

    // MARK: - 通用

    private func sectionTitle(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MDColor.textPrimary)
        }
    }

    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(MDColor.textSecondary)
                .frame(width: 110, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(MDColor.textPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 图标编辑

struct IconEditorSheet: View {
    @ObservedObject var store: LinkStore
    let item: LingFansIconItem
    @Binding var isPresented: Bool

    @State private var sourcePath: String?
    @State private var original: UIImage?
    @State private var preview: UIImage?
    @State private var rounded = true
    @State private var radius: Double = 0.22
    @State private var showPicker = false
    @State private var errorMessage: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()

                ScrollView {
                    VStack(spacing: MDMetric.cardSpacing) {
                        previewCard
                        optionsCard

                        if let err = errorMessage {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(MDColor.warning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                                        .fill(MDColor.warning.opacity(0.08))
                                )
                        }

                        MDPrimaryButton(
                            title: saving ? "正在应用…" : "同步到车机",
                            enabled: sourcePath != nil && !saving
                        ) {
                            Task { await apply() }
                        }

                        Text("图标会先上传到车机的图标目录，再由菱粉桌面应用。\n原图按正方形居中裁剪，输出 512×512 PNG。")
                            .font(.system(size: 11))
                            .foregroundStyle(MDColor.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(MDColor.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(MDColor.brand)
                }
            }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    loadImage(from: url)
                case .failure(let error):
                    errorMessage = "选择图片失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 预览

    private var previewCard: some View {
        MDCard {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(MDColor.surfaceHigh)
                        .frame(width: 148, height: 148)

                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 128, height: 128)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(MDColor.textTertiary)
                            Text("未选择图片")
                                .font(.system(size: 11))
                                .foregroundStyle(MDColor.textTertiary)
                        }
                    }
                }

                Button {
                    showPicker = true
                } label: {
                    Text(sourcePath == nil ? "选择图片" : "重新选择")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MDColor.brand)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                .stroke(MDColor.brand.opacity(0.4), lineWidth: 1.2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 选项

    private var optionsCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("圆角遮罩")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MDColor.textPrimary)
                    Spacer()
                    Toggle("", isOn: $rounded)
                        .labelsHidden()
                        .tint(MDColor.app)
                        .onChange(of: rounded) { _ in regenerate() }
                }

                if rounded {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("圆角半径")
                                .font(.system(size: 13))
                                .foregroundStyle(MDColor.textSecondary)
                            Spacer()
                            Text(String(format: "%.0f%%", radius * 100))
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(MDColor.textPrimary)
                        }
                        Slider(value: $radius, in: 0...0.5, step: 0.01)
                            .tint(MDColor.app)
                            .onChange(of: radius) { _ in regenerate() }
                        Text("车机端圆形图标一般用 50%")
                            .font(.system(size: 10))
                            .foregroundStyle(MDColor.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - 行为

    private func loadImage(from url: URL) {
        errorMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let allowed = ["png", "jpg", "jpeg", "webp", "bmp", "gif", "ico"]
        guard allowed.contains(ext) else {
            errorMessage = "仅支持 png、jpg、jpeg、webp、bmp、gif、ico 图标文件"
            return
        }

        // 复制到沙箱，避免安全作用域在异步上传时失效
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingfan_icon_src_\(UUID().uuidString).\(ext)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            errorMessage = "读取图片失败：\(error.localizedDescription)"
            return
        }

        guard let img = LingFansIconRenderer.loadDownsampled(path: dest.path) else {
            errorMessage = "这张图片无法解码"
            return
        }

        sourcePath = dest.path
        original = img
        regenerate()
    }

    private func regenerate() {
        guard let path = sourcePath else { return }
        preview = LingFansIconRenderer.render(
            path: path, rounded: rounded, radiusFraction: radius
        )
    }

    private func apply() async {
        guard let path = sourcePath else { return }
        // 用处理后的 PNG 上传，车机拿到的就是最终效果
        guard let rendered = LingFansIconRenderer.render(
            path: path, rounded: rounded, radiusFraction: radius
        ), let pngPath = LingFansIconRenderer.writePNG(rendered) else {
            errorMessage = "生成图标失败"
            return
        }

        saving = true
        errorMessage = nil
        defer { saving = false }

        if let err = await store.setIcon(
            package: item.packageName,
            localImagePath: pngPath,
            rounded: rounded,
            radius: radius
        ) {
            errorMessage = err
            return
        }

        try? FileManager.default.removeItem(atPath: pngPath)
        isPresented = false
    }
}

// MARK: - 日志预览

struct LogPreviewSheet: View {
    let text: String
    let exportPath: String?
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(MDColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("菱粉日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(MDColor.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(MDColor.brand)
                }
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(MDColor.brand)
                        }
                        if let path = exportPath {
                            ShareLink(item: URL(fileURLWithPath: path)) {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(MDColor.brand)
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        LinkView(device: .demo)
    }
}
