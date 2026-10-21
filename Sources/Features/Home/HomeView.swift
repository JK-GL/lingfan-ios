import SwiftUI

/// 首页
///
/// 对照 HTML 原型的两个状态：
///   未连接 → 四格 IP + 端口下拉 + [连接][无线调试] + 自动发现 + 12 格快捷操作 + 最近动态
///   已连接 → 原地换成设备卡（CPU / 内存 / 存储 + 断开 / 刷新）+ 菱粉横条 + 同样两区
///
/// 与原版 Android 的差别：原版点「连接」后 push 进控制台九宫格；
/// 本版按定稿把控制台拆平，连接后留在首页，功能由 12 格快捷操作承载。
struct HomeView: View {

    @StateObject private var store = HomeStore()
    @StateObject private var metrics = ConsoleStore()
    @StateObject private var recent = RecentStore.shared
    @StateObject private var active = ActiveDevice.shared
    @StateObject private var router = TabRouter.shared

    @State private var path = NavigationPath()
    @State private var showPowerMenu = false
    @State private var toast: String?

    @AppStorage("default.port") private var defaultPort: String = "5557"
    @AppStorage("auto.discovery") private var autoDiscoveryStored: Bool = true

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                MDPageBackground()

                ScrollView {
                    VStack(spacing: 12) {

                        if let device = connectedDevice {
                            connectedCard(device)
                            if device.isLingFans {
                                lingFansBanner(device)
                            }
                        } else {
                            connectCard
                            if let error = store.errorMessage {
                                errorBanner(error)
                            }
                            discoverySection
                        }

                        quickActions

                        recentSection
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.bottom, 28)
                }
                .refreshable {
                    await store.refresh()
                    syncActive()
                }

                if let toast {
                    toastView(toast)
                }
            }
            .navigationTitle("首页")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: HomeRoute.self) { target in
                destination(for: target)
            }
        }
        .sheet(isPresented: $store.showPairSheet) {
            PairSheet(isPresented: $store.showPairSheet) { host in
                store.inputHost = host
            }
        }
        .confirmationDialog("电源操作", isPresented: $showPowerMenu, titleVisibility: .visible) {
            Button("重启设备", role: .destructive) { runPower("reboot", "重启设备") }
            Button("关机", role: .destructive) { runPower("reboot -p", "关机") }
            Button("进入 Recovery", role: .destructive) { runPower("reboot recovery", "进入 Recovery") }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些操作会立即断开连接。")
        }
        .task {
            // 设置页的「默认端口」：首次进入且用户没改过时预填
            if store.inputPort == "5557", defaultPort != "5557" {
                store.inputPort = defaultPort
            }
            await store.loadHistory()
            if autoDiscoveryStored, store.devices.isEmpty {
                await store.scan()
                syncActive()
            }
            if let device = connectedDevice {
                bindMetrics(device)
            }
        }
        .onChange(of: store.devices) { _ in
            syncActive()
            if let device = connectedDevice {
                bindMetrics(device)
            }
        }
    }

    // MARK: - 状态同步

    private var connectedDevice: DeviceRecord? {
        store.devices.first { $0.state == .connected }
    }

    /// 把连接成功的设备写进全局，其它 Tab 靠它拿 device
    private func syncActive() {
        if let device = connectedDevice {
            active.set(device)
        } else if active.isConnected {
            active.markDisconnected()
        }
    }

    private func bindMetrics(_ device: DeviceRecord) {
        metrics.bind(device: device)
        Task {
            await metrics.startMonitoring()
            // 首页只要一次快照，拿到指标就停掉循环，避免后台持续跑 top/proc
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            metrics.stopMonitoring()
        }
    }

    // MARK: - 未连接：连接卡

    private var connectCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("手动连接")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MDColor.textSecondary)

                IPQuadField(host: $store.inputHost, port: $store.inputPort)

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await store.connectInput()
                            syncActive()
                            if let device = connectedDevice {
                                recent.record(.connect, title: "已连接 \(device.name)",
                                              detail: device.endpoint)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if store.isConnecting {
                                ProgressView().scaleEffect(0.7).tint(.white)
                            }
                            Text(store.isConnecting ? "连接中…" : "连接")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                .fill(MDColor.brand.opacity(canConnect ? 1 : 0.35))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canConnect)

                    Button {
                        store.showPairSheet = true
                    } label: {
                        Text("无线调试")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MDColor.brand)
                            .frame(width: 104, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .stroke(MDColor.brand.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var canConnect: Bool {
        !store.isConnecting && !store.inputHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 未连接：自动发现

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("自动发现")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MDColor.textSecondary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(store.isScanning ? MDColor.warning : MDColor.success)
                        .frame(width: 5, height: 5)
                    Text(store.isScanning ? "扫描中…" : "已发现 \(store.devices.count) 台")
                        .font(.system(size: 11))
                        .foregroundStyle(MDColor.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $store.autoDiscovery)
                    .labelsHidden()
                    .scaleEffect(0.82)
                    .tint(MDColor.brand)
                    .onChange(of: store.autoDiscovery) { value in
                        autoDiscoveryStored = value
                        Task { await store.setAutoDiscovery(value) }
                    }
            }
            .padding(.horizontal, 4)

            if store.devices.isEmpty {
                MDCard {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(MDColor.textTertiary)
                            Text(store.isScanning ? "正在扫描局域网…" : "没有发现设备")
                                .font(.system(size: 12))
                                .foregroundStyle(MDColor.textSecondary)
                        }
                        .padding(.vertical, 14)
                        Spacer()
                    }
                }
            } else {
                discoveryList
            }
        }
    }

    /// 自动发现列表：最多 6 行可见，超出右侧细滚动条
    private var discoveryList: some View {
        let visibleHeight: CGFloat = 6 * 56

        return ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(Array(store.devices.enumerated()), id: \.element.id) { index, device in
                    Button {
                        Task {
                            await store.tapDevice(device)
                            syncActive()
                        }
                    } label: {
                        discoveryRow(device)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.connectingEndpoint != nil)

                    if index < store.devices.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
        .frame(maxHeight: min(CGFloat(store.devices.count) * 56, visibleHeight))
        .background(
            RoundedRectangle(cornerRadius: MDMetric.cardRadius, style: .continuous)
                .fill(MDColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MDMetric.cardRadius, style: .continuous)
                .stroke(MDColor.surfaceStroke.opacity(0.06), lineWidth: 1)
        )

        .overlay(alignment: .bottom) {
            Text("重新扫描 · 共 \(store.devices.count) 台，可上下滑动")
                .font(.system(size: 11))
                .foregroundStyle(MDColor.brand)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [MDColor.surface.opacity(0), MDColor.surface],
                        startPoint: .top, endPoint: .center
                    )
                )
                .offset(y: 26)
                .onTapGesture {
                    Task {
                        await store.scan()
                        syncActive()
                    }
                }
        }
        .padding(.bottom, 26)
    }

    private func discoveryRow(_ device: DeviceRecord) -> some View {
        HStack(spacing: 11) {
            MDIconTile(
                systemName: device.isLingFans ? "car.fill" : "iphone",
                tint: device.state == .connected ? MDColor.brand : MDColor.textSecondary,
                size: 36, radius: 10
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(device.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)
                        .lineLimit(1)

                    if device.isLingFans {
                        Text("菱粉")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(MDColor.remote)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(MDColor.remote.opacity(0.13)))
                    }

                    if device.state == .pairing {
                        Text("无线配对")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(MDColor.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(MDColor.warning.opacity(0.14)))
                    }
                }

                Text(device.endpoint)
                    .font(.system(size: 11))
                    .foregroundStyle(MDColor.textSecondary)
            }

            Spacer(minLength: 6)

            if store.connectingEndpoint == device.endpoint {
                ProgressView().scaleEffect(0.7)
            } else if device.state == .pairing {
                Text("配对")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(MDColor.warning))
            } else if device.state == .connected {
                Text("已连接")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDColor.success)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(MDColor.success.opacity(0.13)))
            } else {
                Text("连接")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(MDColor.brand))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .contentShape(Rectangle())
    }

    // MARK: - 已连接：设备卡

    private func connectedCard(_ device: DeviceRecord) -> some View {
        MDCard {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    MDIconTile(
                        systemName: device.isLingFans ? "car.fill" : "iphone",
                        tint: MDColor.brand,
                        size: 44, radius: 13
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MDColor.textPrimary)
                            .lineLimit(1)
                        Text(device.endpoint)
                            .font(.system(size: 11))
                            .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer(minLength: 4)

                    Text("已连接")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MDColor.success)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(MDColor.success.opacity(0.14)))
                }

                Divider()

                HStack(spacing: 0) {
                    metricCell(
                        title: "CPU",
                        value: String(format: "%.0f%%", metrics.cpuUsage),
                        ratio: metrics.cpuUsage / 100,
                        tint: MDColor.brand
                    )
                    metricCell(
                        title: "内存",
                        value: metrics.memoryDetail,
                        ratio: metrics.memoryPercent / 100,
                        tint: MDColor.info
                    )
                    metricCell(
                        title: "存储",
                        value: String(format: "%.0f%%", metrics.storagePercent * 100),
                        ratio: metrics.storagePercent,
                        tint: MDColor.warning
                    )
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await store.disconnect(device)
                            metrics.stopMonitoring()
                            active.markDisconnected()
                            recent.record(.other, title: "已断开 \(device.name)", detail: device.endpoint)
                            flash("已断开")
                        }
                    } label: {
                        Text("断开")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MDColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .fill(MDColor.surfaceHigh)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await store.refresh()
                            syncActive()
                            flash("已刷新")
                        }
                    } label: {
                        Text("刷新")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MDColor.brand)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .fill(MDColor.brand.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func metricCell(title: String, value: String, ratio: Double, tint: Color) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(MDColor.textTertiary)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(MDColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.15))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * min(max(ratio, 0), 1)))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 菱粉横条

    private func lingFansBanner(_ device: DeviceRecord) -> some View {
        Button {
            path.append(HomeRoute.link)
        } label: {
            ZStack(alignment: .trailing) {
                LinearGradient(
                    colors: [Color(hex: 0x7C6BE0), Color(hex: 0x4A7FE8)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 120, height: 120)
                    .offset(x: 34, y: -30)

                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "bolt.horizontal.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("菱粉联动")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text("桌面 v3.2.0 · 语音 / 图标 / 天气")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.88))
                    }

                    Spacer(minLength: 6)

                    Text("进入")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.22)))
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color(hex: 0x5E60D6).opacity(0.30), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 快捷操作 12 格

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("快捷操作")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MDColor.textPrimary)
                .padding(.horizontal, 4)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(QuickAction.all) { item in
                    Button {
                        handle(item)
                    } label: {
                        VStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(item.tint.opacity(0.13))
                                .frame(width: 38, height: 38)
                                .overlay(
                                    Image(systemName: item.icon)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(item.tint)
                                )

                            Text(item.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(MDColor.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 92)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.cardRadius, style: .continuous)
                                .fill(MDColor.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MDMetric.cardRadius, style: .continuous)
                                .stroke(MDColor.surfaceStroke.opacity(0.05), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(connectedDevice == nil)
                    .opacity(connectedDevice == nil ? 0.45 : 1)
                }
            }
        }
        .padding(.top, 2)
    }

    private func handle(_ item: QuickAction) {
        guard connectedDevice != nil else {
            flash("先连接设备")
            return
        }
        switch item.kind {
        case .apps:
            router.go(.apps)
        case .files:
            router.go(.files)
        case .shell:
            router.go(.commands)
        case .power:
            showPowerMenu = true
        case .route(let target):
            path.append(target)
        }
        RecentStore.shared.record(.other, title: item.title, detail: "快捷操作")
    }

    // MARK: - 最近动态

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("最近动态")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MDColor.textPrimary)

                Spacer()

                if !recent.items.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { recent.clear() }
                    } label: {
                        Text("清空")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MDColor.brand)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            if recent.items.isEmpty {
                MDCard {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(MDColor.textTertiary)
                            Text("还没有操作记录")
                                .font(.system(size: 12))
                                .foregroundStyle(MDColor.textSecondary)
                        }
                        .padding(.vertical, 12)
                        Spacer()
                    }
                }
            } else {
                MDCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(recent.items.prefix(5).enumerated()), id: \.element.id) { index, item in
                            recentRow(item)
                            if index < min(recent.items.count, 5) - 1 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func recentRow(_ item: RecentItem) -> some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint(for: item.kind).opacity(0.12))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: item.kind.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint(for: item.kind))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MDColor.textPrimary)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(MDColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Text(item.timeText)
                .font(.system(size: 10))
                .foregroundStyle(MDColor.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func tint(for kind: RecentItem.Kind) -> Color {
        switch kind {
        case .connect: return MDColor.brand
        case .screenshot: return MDColor.tool
        case .record: return MDColor.process
        case .install: return MDColor.app
        case .file: return MDColor.file
        case .clean: return MDColor.warning
        case .link: return MDColor.remote
        case .shell: return MDColor.shell
        case .other: return MDColor.info
        }
    }

    // MARK: - 错误横幅

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MDColor.danger)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("连接失败")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MDColor.danger)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(MDColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MDColor.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                .fill(MDColor.danger.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                        .stroke(MDColor.danger.opacity(0.20), lineWidth: 1)
                )
        )
    }

    // MARK: - 工具

    private func toastView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.bottom, 40)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func flash(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { if toast == message { toast = nil } }
        }
    }

    private func runPower(_ command: String, _ title: String) {
        guard let device = connectedDevice else { return }
        Task {
            let (ok, _) = await AdbService.shared.shellAsync(command)
            RecentStore.shared.record(.other, title: "\(title)\(ok ? "已下发" : "失败")",
                                      detail: device.name)
            flash(ok ? "\(title) 已下发" : "\(title) 失败")
        }
    }

    @ViewBuilder
    private func destination(for target: HomeRoute) -> some View {
        if let device = connectedDevice {
            switch target {
            case .tools: ToolsView(device: device)
            case .process: ProcessView(device: device)
            case .remote: RemoteView(device: device)
            case .mirror: MirrorView(device: device)
            case .cleanup: CleanupView(device: device)
            case .info: InfoView(device: device)
            case .link: LinkView(device: device)
            }
        } else {
            NotConnectedView()
        }
    }
}

/// 首页可 push 的功能页
enum HomeRoute: String, Hashable, Identifiable {
    case tools, process, remote, mirror, cleanup, info, link

    var id: String { rawValue }
}

/// 快捷操作 12 格的数据源
struct QuickAction: Identifiable {
    enum Effect {
        case apps
        case files
        case shell
        case power
        case route(HomeRoute)
    }

    let id = UUID()
    let title: String
    let icon: String
    let tint: Color
    let kind: Effect

    static let all: [QuickAction] = [
        .init(title: "安装应用", icon: "square.and.arrow.down.fill",
              tint: MDColor.app, kind: .apps),
        .init(title: "屏幕截图", icon: "camera.fill",
              tint: MDColor.tool, kind: .route(.tools)),
        .init(title: "屏幕录制", icon: "record.circle",
              tint: MDColor.process, kind: .route(.tools)),
        .init(title: "设备投屏", icon: "airplayvideo",
              tint: MDColor.remote, kind: .route(.mirror)),
        .init(title: "按键遥控", icon: "appletvremote.gen4",
              tint: MDColor.remote, kind: .route(.remote)),
        .init(title: "进程管理", icon: "list.bullet.rectangle",
              tint: MDColor.process, kind: .route(.process)),
        .init(title: "存储清理", icon: "trash.slash.fill",
              tint: MDColor.warning, kind: .route(.cleanup)),
        .init(title: "Logcat", icon: "doc.text.magnifyingglass",
              tint: MDColor.shell, kind: .shell),
        .init(title: "顶层窗口", icon: "rectangle.on.rectangle",
              tint: MDColor.info, kind: .route(.info)),
        .init(title: "性能监控", icon: "chart.line.uptrend.xyaxis",
              tint: MDColor.process, kind: .route(.tools)),
        .init(title: "电源菜单", icon: "power",
              tint: MDColor.process, kind: .power),
        .init(title: "设备信息", icon: "iphone",
              tint: MDColor.info, kind: .route(.info)),
    ]
}

/// 四格 IP + 独立端口框
///
/// 对照原型：`[192].[168].[1].[78]  [5557 ▾]`
/// 每格独立圆角背景，输满 3 位自动跳下一格，退格清空自动回上一格。
struct IPQuadField: View {

    @Binding var host: String
    @Binding var port: String

    @FocusState private var focus: Int?
    @State private var segs: [String] = ["", "", "", ""]

    private let presets = ["5555", "5556", "5557", "5558", "5037"]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { index in
                segment(index)

                if index < 3 {
                    Text(".")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MDColor.textTertiary)
                        .frame(width: 5)
                }
            }

            Spacer(minLength: 4)

            portBox
        }
        .onAppear(perform: syncFromHost)
    }

    private func segment(_ index: Int) -> some View {
        TextField("", text: binding(index))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(MDColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                    .fill(MDColor.surfaceHigh)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                    .stroke(
                        focus == index ? MDColor.brand.opacity(0.55) : Color.clear,
                        lineWidth: 1.2
                    )
            )
            .focused($focus, equals: index)
    }

    private var portBox: some View {
        Menu {
            ForEach(presets, id: \.self) { item in
                Button(item) {
                    port = item
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(port.isEmpty ? "5557" : port)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(MDColor.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MDColor.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                    .fill(MDColor.surfaceHigh)
            )
        }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: { segs[index] },
            set: { raw in
                let digits = String(raw.filter { $0.isNumber }.prefix(3))
                segs[index] = digits
                host = segs.joined(separator: ".")

                if digits.count == 3, index < 3 {
                    focus = index + 1
                } else if digits.isEmpty, index > 0 {
                    focus = index - 1
                }
            }
        )
    }

    private func syncFromHost() {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        for (index, part) in parts.prefix(4).enumerated() {
            segs[index] = String(part)
        }
    }
}
