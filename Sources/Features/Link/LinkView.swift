import SwiftUI
import UIKit

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

                if store.versionInfo.isEmpty && store.activationInfo.isEmpty {
                    Text("读取中…")
                        .font(.system(size: 13))
                        .foregroundStyle(MDColor.textSecondary)
                } else {
                    ForEach(store.versionInfo.sorted(by: { $0.key < $1.key }), id: \.key) { kv in
                        kvRow(kv.key, kv.value)
                    }
                    if !store.activationInfo.isEmpty {
                        Divider().background(MDColor.outlineVariant)
                        ForEach(store.activationInfo.sorted(by: { $0.key < $1.key }), id: \.key) { kv in
                            kvRow(kv.key, kv.value)
                        }
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
                    Text("无定制项，或桌面版本不支持")
                        .font(.system(size: 13))
                        .foregroundStyle(MDColor.textSecondary)
                } else {
                    ForEach(store.voiceItems.sorted(by: { $0.key < $1.key }), id: \.key) { kv in
                        HStack(alignment: .top, spacing: 8) {
                            kvRow(kv.key, kv.value)
                            Button {
                                Task { _ = await store.resetVoice(key: kv.key) }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(MDColor.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
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

                if store.appIcons.isEmpty {
                    Text("无可替换图标的应用")
                        .font(.system(size: 13))
                        .foregroundStyle(MDColor.textSecondary)
                } else {
                    ForEach(store.appIcons.sorted(by: { $0.key < $1.key }), id: \.key) { kv in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortPackage(kv.key))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(MDColor.textPrimary)
                                Text(kv.value)
                                    .font(.system(size: 11))
                                    .foregroundStyle(MDColor.textSecondary)
                            }
                            Spacer(minLength: 4)
                            if kv.value != "默认" {
                                Button {
                                    Task { _ = await store.resetIcon(package: kv.key) }
                                } label: {
                                    Text("重置")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(MDColor.danger)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func shortPackage(_ pkg: String) -> String {
        pkg.split(separator: ".").suffix(2).joined(separator: ".")
    }

    // MARK: - 原始输出

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

#Preview {
    NavigationStack {
        LinkView(device: .demo)
    }
}
