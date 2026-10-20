import SwiftUI

/// 设备控制台：设备头 + 实时监控 + 功能入口列表
///
/// 对照原版 screenshots/2.jpg 与 3.jpg：
///   卡片1 设备信息（图标 / 名称 / 序号 / 断开连接）
///   卡片2 实时监控（CPU 折线 + 温度）
///   卡片3~ 内存 / 存储 双环
///   列表  设备信息 / Shell执行 / 文件管理 / App管理 / 进程管理 / 虚拟遥控 / 常用工具
struct ConsoleView: View {

    let device: DeviceRecord

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ConsoleStore()

    var body: some View {
        ZStack {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    // 原版：存储使用率 ≥ 80% 时置顶红色警告
                    if store.storagePercent >= 0.8 {
                        storageWarningCard
                    }

                    if let err = store.errorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MDColor.warning)
                                .padding(.top, 1)
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(MDColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.radiusBanner, style: .continuous)
                                .fill(MDColor.warning.opacity(0.09))
                        )
                    }
                    deviceHeader
                    monitorCard
                    memoryStorageRow
                    functionList
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("设备控制台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(MDColor.background, for: .navigationBar)
        .task {
            store.bind(device: device)
            await store.startMonitoring()
        }
        .onDisappear {
            store.stopMonitoring()
        }
    }

    // MARK: - 存储告警

    private var storageWarningCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MDColor.danger)
                .padding(.top, 1)

            Text("请注意，设备存储使用量已经超过 80%，请及时清理文件，否则会导致设备无法正常使用甚至开机失败！")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MDColor.danger)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MDMetric.cardRadius, style: .continuous)
                .fill(MDColor.danger.opacity(0.10))
        )
    }

    // MARK: - 设备头

    private var deviceHeader: some View {
        MDCard {
            HStack(spacing: 14) {
                MDIconTile(systemName: "iphone", tint: MDColor.brand, size: 56, radius: 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.displayName.isEmpty ? device.name : store.displayName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(MDColor.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        if !store.serial.isEmpty {
                            Text(store.serial)
                                .font(.system(size: 13))
                                .foregroundStyle(MDColor.textSecondary)
                        }
                        Button("断开连接") {
                            Task {
                                await store.disconnect()
                                dismiss()
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MDColor.danger)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 实时监控

    private var monitorCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("实时监控")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(MDColor.textPrimary)
                        Text("处理器负载与温度趋势")
                            .font(.system(size: 13))
                            .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("CPU \(Int(store.cpuUsage * 100))%")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MDColor.brand)
                        Text(store.temperature > 0
                             ? String(format: "%.1fC", store.temperature)
                             : "--")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MDColor.tool)
                    }
                }

                // 图例
                HStack(spacing: 18) {
                    legend(color: MDColor.brand, label: "CPU负载")
                    legend(color: MDColor.tool, label: "CPU/SoC温度")
                }

                // 折线图
                MonitorChart(
                    cpuSamples: store.cpuSamples,
                    tempSamples: store.tempSamples
                )
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                        .fill(MDColor.surfaceHigh)
                )
            }
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(MDColor.textSecondary)
        }
    }

    // MARK: - 内存 / 存储

    private var memoryStorageRow: some View {
        HStack(spacing: MDMetric.cardSpacing) {
            ringCard(
                icon: "memorychip",
                tint: MDColor.brand,
                title: "内存使用量",
                percent: store.memoryPercent,
                detail: store.memoryDetail
            )
            ringCard(
                icon: "internaldrive",
                tint: MDColor.file,
                title: "存储使用量",
                percent: store.storagePercent,
                detail: store.storageDetail
            )
        }
    }

    private func ringCard(icon: String, tint: Color, title: String,
                          percent: Double, detail: String) -> some View {
        MDCard {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)
                    Spacer(minLength: 0)
                }

                ZStack {
                    Circle()
                        .stroke(MDColor.surfaceHigh, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: max(0.001, percent))
                        .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: percent)

                    Text("\(Int(percent * 100))%")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(MDColor.textPrimary)
                }
                .frame(width: 104, height: 104)

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(MDColor.textSecondary)
            }
        }
    }

    // MARK: - 功能入口

    /// 菱粉联动只在菱粉机型上出现（原版 `if (lingFansMeta.isLingFans)`）
    private var visibleFeatures: [ConsoleFeature] {
        ConsoleFeature.allCases.filter { $0 != .link || device.isLingFans }
    }

    private var functionList: some View {
        VStack(spacing: MDMetric.cardSpacing) {
            ForEach(visibleFeatures) { feature in
                NavigationLink {
                    feature.destination(device: device)
                } label: {
                    MDCard(padding: 14) {
                        MDListRow(
                            systemName: feature.icon,
                            tint: feature.tint,
                            title: feature.title,
                            subtitle: feature.subtitle
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 功能定义

/// 与 Android 版 `DeviceControlScreen.kt:137-150` 的入口列表一一对应。
/// 顺序也照抄：菱粉联动条件置顶 → 设备信息 → Shell → 文件 → App
/// → 存储清理 → 进程 → 虚拟遥控 → 常用工具。
/// 原版没有「设备投屏」一级入口，设备镜像在「常用工具」里。
enum ConsoleFeature: String, CaseIterable, Identifiable {
    case link, info, shell, files, apps, cleanup, process, remote, tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return "设备信息"
        case .shell: return "Shell执行"
        case .files: return "文件管理"
        case .apps: return "App管理"
        case .process: return "进程管理"
        case .remote: return "虚拟遥控"
        case .tools: return "常用工具"
        case .link: return "菱粉联动"
        case .cleanup: return "存储清理"
        }
    }

    var subtitle: String {
        switch self {
        case .info: return "查看配置、电量、存储详情"
        case .shell: return "执行自定义 ADB Shell 命令"
        case .files: return "浏览、上传、下载、重命名远程文件"
        case .apps: return "安装、卸载、提取 APK、冻结"
        case .process: return "监控运行内存、结束卡死进程"
        case .remote: return "模拟按键、遥控器、输入文字"
        case .tools: return "截图、录屏、镜像、日志与电源"
        case .link: return "语音、图标、天气与日志定制"
        case .cleanup: return "扫描并清理设备冗余文件"
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .shell: return "terminal.fill"
        case .files: return "folder.fill"
        case .apps: return "square.grid.3x3.fill"
        case .process: return "cpu.fill"
        case .remote: return "av.remote.fill"
        case .tools: return "wrench.adjustable.fill"
        case .link: return "car.fill"
        case .cleanup: return "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: return MDColor.info
        case .shell: return MDColor.shell
        case .files: return MDColor.file
        case .apps: return MDColor.app
        case .process: return MDColor.process
        case .remote: return MDColor.remote
        case .tools: return MDColor.tool
        case .link: return MDColor.brand
        case .cleanup: return MDColor.process
        }
    }

    @ViewBuilder
    func destination(device: DeviceRecord) -> some View {
        switch self {
        case .info:     InfoView(device: device)
        case .shell:    ShellView(device: device)
        case .files:    FilesView(device: device)
        case .apps:     AppsView(device: device)
        case .process:  ProcessView(device: device)
        case .remote:   RemoteView(device: device)
        case .tools:    ToolsView(device: device)
        case .link:     LinkView(device: device)
        case .cleanup:  CleanupView(device: device)
        }
    }
}

// MARK: - 折线图

/// 极简 CPU / 温度双线图
struct MonitorChart: View {
    let cpuSamples: [Double]
    let tempSamples: [Double]

    private let maxSamples = 60

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                // 水平网格线 0 / 25 / 50 / 75 / 100
                ForEach(0..<5, id: \.self) { i in
                    let y = h * CGFloat(i) / 4
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(MDColor.textTertiary.opacity(0.12), lineWidth: 0.5)

                    Text("\(100 - i * 25)")
                        .font(.system(size: 9))
                        .foregroundStyle(MDColor.textTertiary)
                        .position(x: 12, y: max(8, y - 6))
                }

                line(samples: tempSamples, in: CGSize(width: w, height: h), color: MDColor.tool)
                line(samples: cpuSamples, in: CGSize(width: w, height: h), color: MDColor.brand)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private func line(samples: [Double], in size: CGSize, color: Color) -> some View {
        let points = normalized(samples)
        return ZStack {
            // 填充
            Path { p in
                guard points.count > 1 else { return }
                let step = size.width / CGFloat(max(1, maxSamples - 1))
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in points.enumerated() {
                    p.addLine(to: CGPoint(x: CGFloat(i) * step,
                                          y: size.height * (1 - CGFloat(v))))
                }
                p.addLine(to: CGPoint(x: CGFloat(points.count - 1) * step, y: size.height))
                p.closeSubpath()
            }
            .fill(color.opacity(0.08))

            // 折线
            Path { p in
                guard points.count > 1 else { return }
                let step = size.width / CGFloat(max(1, maxSamples - 1))
                p.move(to: CGPoint(x: 0, y: size.height * (1 - CGFloat(points[0]))))
                for (i, v) in points.enumerated().dropFirst() {
                    p.addLine(to: CGPoint(x: CGFloat(i) * step,
                                          y: size.height * (1 - CGFloat(v))))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    /// 把采样值夹到 0...1，并补齐到固定宽度
    private func normalized(_ samples: [Double]) -> [Double] {
        guard !samples.isEmpty else { return [] }
        return samples.map { min(1, max(0, $0)) }
    }
}

#Preview {
    NavigationStack {
        ConsoleView(device: DeviceRecord(
            id: "serial:test",
            name: "alps spm8666p2_64_car",
            endpoint: "192.168.5.3:5557",
            state: .connected,
            isLingFans: true,
            lastSeen: Date()
        ))
    }
}
