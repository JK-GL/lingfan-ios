import SwiftUI

/// 首页：设备连接入口 + 历史设备列表
///
/// 对照原版 screenshots/1.jpg：
///   顶部  「菱粉工具箱」+ 版本号
///   卡片1 「添加新设备」+ 分段 IP 输入 + 无线配对 / 立即连接
///   卡片2 「设备列表 (N)」+ 自动发现开关 + 刷新
///   列表  设备卡片（图标 / 名称 / 地址 / 状态徽章 / 删除按钮）
struct HomeView: View {

    @StateObject private var store = HomeStore()
    @State private var showDemo = false
    @State private var selectedDevice: DeviceRecord?

    var body: some View {
        NavigationStack {
            ZStack {
                MDPageBackground()

                ScrollView {
                    VStack(spacing: MDMetric.cardSpacing) {

                        // 顶部标题行：左标题 / 右版本
                        header

                        // 演示入口：不连真机也能预览控制台
                        demoEntry

                        // 连接错误提示
                        if let error = store.errorMessage {
                            errorBanner(error)
                        }

                        // 添加设备卡片
                        addDeviceCard

                        // 设备列表
                        deviceSection

                        // 空状态
                        if store.devices.isEmpty && !store.isScanning {
                            emptyState
                        }
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.bottom, 32)
                }
                .refreshable {
                    await store.refresh()
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: DeviceRecord.self) { device in
                ConsoleView(device: device)
            }
            .navigationDestination(isPresented: $showDemo) {
                ConsoleView(device: DeviceRecord.demo)
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedDevice != nil },
                set: { if !$0 { selectedDevice = nil } }
            )) {
                if let dev = selectedDevice {
                    ConsoleView(device: dev)
                }
            }
        }
        .sheet(isPresented: $store.showPairSheet) {
            PairSheet(isPresented: $store.showPairSheet) { host in
                store.inputHost = host
            }
        }
        .task {
            await store.loadHistory()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("菱粉工具箱")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(MDColor.textPrimary)

            Spacer()

            Text("版本: \(store.appVersion)")
                .font(.system(size: 13))
                .foregroundStyle(MDColor.textSecondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - 演示入口

    /// 预览控制台排版用。数据全部本地生成，不连接任何设备。
    private var demoEntry: some View {
        Button {
            showDemo = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MDColor.brand)

                VStack(alignment: .leading, spacing: 2) {
                    Text("预览控制台")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)
                    Text("使用演示数据，不连接真实设备")
                        .font(.system(size: 12))
                        .foregroundStyle(MDColor.textSecondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MDColor.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                    .fill(MDColor.brand.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                            .stroke(MDColor.brand.opacity(0.20), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 错误横幅

    /// 连接失败时把 adb 的原始回执展示出来，否则用户点完按钮什么都看不到。
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MDColor.danger)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("连接失败")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MDColor.danger)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(MDColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            VStack(spacing: 8) {
                // 原版连接失败对话框里的「去配对」快捷入口
                if message.contains("配对") || message.lowercased().contains("authenticate") {
                    Button {
                        store.errorMessage = nil
                        store.showPairSheet = true
                    } label: {
                        Text("去配对")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MDColor.brand)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(MDColor.brand.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    store.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MDColor.textTertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                .fill(MDColor.danger.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                        .stroke(MDColor.danger.opacity(0.22), lineWidth: 1)
                )
        )
    }

    // MARK: - 添加设备卡

    private var addDeviceCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("添加新设备")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MDColor.textSecondary)

                // 分段式 IP:端口 输入
                IPPortField(
                    host: $store.inputHost,
                    port: $store.inputPort
                )

                HStack(spacing: 12) {
                    MDOutlineButton(title: "无线配对") {
                        store.showPairSheet = true
                    }
                    MDPrimaryButton(
                        title: store.isConnecting ? "连接中…" : "立即连接",
                        enabled: !store.isConnecting && !store.inputHost.isEmpty
                    ) {
                        Task { await store.connectInput() }
                    }
                }
            }
        }
    }

    // MARK: - 设备列表

    private var deviceSection: some View {
        VStack(spacing: MDMetric.cardSpacing) {
            HStack {
                Text("设备列表 (\(store.devices.count))")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MDColor.textSecondary)

                Spacer()

                Text("自动发现")
                    .font(.system(size: 14))
                    .foregroundStyle(MDColor.textSecondary)

                Toggle("", isOn: $store.autoDiscovery)
                    .labelsHidden()
                    .tint(MDColor.brand)
                    .onChange(of: store.autoDiscovery) { newValue in
                        Task { await store.setAutoDiscovery(newValue) }
                    }

                Button {
                    Task { await store.scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(MDColor.textTertiary)
                        .rotationEffect(.degrees(store.isScanning ? 360 : 0))
                        .animation(
                            store.isScanning
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                            value: store.isScanning
                        )
                }
                .padding(.leading, 4)
            }
            .padding(.top, 8)

            ForEach(store.devices) { device in
                Button {
                    Task {
                        if let target = await store.tapDevice(device) {
                            selectedDevice = target
                        }
                    }
                } label: {
                    deviceCard(device)
                }
                .buttonStyle(.plain)
                .disabled(store.connectingEndpoint != nil)
            }
        }
    }

    private func deviceCard(_ device: DeviceRecord) -> some View {
        let isConnected = device.state == .connected

        return MDCard {
            HStack(spacing: 14) {
                // 设备图标：连接中为蓝色，离线为灰
                MDIconTile(
                    systemName: device.isLingFans ? "car.fill" : "iphone",
                    tint: isConnected ? MDColor.brand : MDColor.textSecondary
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(device.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(device.endpoint)
                            .font(.system(size: 13))
                            .foregroundStyle(MDColor.textSecondary)

                        if store.connectingEndpoint == device.endpoint {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.65)
                                Text("连接中…")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(MDColor.info)
                            }
                        } else {
                            MDStatusChip(status: device.state.status)
                        }
                    }
                }

                Spacer(minLength: 8)

                // 已连接显示 ×（断开），否则显示删除
                Button {
                    Task {
                        if isConnected {
                            await store.disconnect(device)
                        } else {
                            await store.remove(device)
                        }
                    }
                } label: {
                    Image(systemName: isConnected ? "xmark" : "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MDColor.danger)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(MDColor.danger.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: MDMetric.cardRadius, style: .continuous)
                .stroke(MDColor.brand.opacity(isConnected ? 0.18 : 0), lineWidth: 1)
        )
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(MDColor.textTertiary)
            Text("还没有设备")
                .font(.system(size: 15))
                .foregroundStyle(MDColor.textSecondary)
            Text("在上方输入车机 IP，或打开自动发现")
                .font(.system(size: 13))
                .foregroundStyle(MDColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - IP:端口 分段输入

/// 按原版形态做的分段输入：`192 . 168 . 1 . 76 : 5557`
///
/// 原版是 5 段（IP 四段 + 端口一段），点击某段会全选当前内容。
struct IPPortField: View {
    @Binding var host: String
    @Binding var port: String

    @FocusState private var focusedIndex: Int?
    @State private var segments: [String] = ["", "", "", ""]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    segmentField(index: i, text: $segments[i], width: i == 0 ? 46 : 40)
                    if i < 3 {
                        Text(".")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(MDColor.textPrimary)
                            .frame(width: 10)
                    }
                }

                Text(":")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(MDColor.textPrimary)
                    .padding(.horizontal, 2)

                segmentField(index: 4, text: $port, width: 58)
            }
            .onChange(of: segments) { new in
                host = new.joined(separator: ".")
            }
            .onAppear {
                let parts = host.split(separator: ".", omittingEmptySubsequences: false)
                for (i, p) in parts.prefix(4).enumerated() {
                    segments[i] = String(p)
                }
            }
        }
    }

    private func segmentField(index: Int, text: Binding<String>, width: CGFloat) -> some View {
        TextField("", text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .foregroundStyle(MDColor.textPrimary)
            .frame(width: width)
            .focused($focusedIndex, equals: index)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focusedIndex == index ? MDColor.brand : MDColor.textTertiary.opacity(0.5))
                    .frame(height: 1.4)
            }
    }
}

#Preview {
    HomeView()
}
