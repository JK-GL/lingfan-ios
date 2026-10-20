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
                        infoRow("平台", info.cpuInfo)
                        if !info.cpuModel.isEmpty {
                            infoRow("型号", info.cpuModel)
                        }
                    }
                }
                MDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("电量与温度")
                        infoRow("电量", info.batteryLevel.isEmpty
                               ? "—" : "\(info.batteryLevel)%")
                        infoRow("充电", info.isCharging ? "正在充电" : "未充电")
                        infoRow("屏幕亮度", info.brightness.isEmpty ? "—" : info.brightness)
                        infoRow("当前用户", info.currentUser.isEmpty ? "—" : info.currentUser)
                        if !info.shellIdentity.isEmpty {
                            infoRow("Shell 权限", info.shellIdentity.contains("uid=0")
                                    ? "root" : info.shellIdentity)
                        }
                        if !info.thermalText.isEmpty {
                            infoRow("温度", info.thermalText)
                        }
                    }
                }
                MDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("存储空间")
                        infoRow("内部存储", info.totalStorage)
                        infoRow("可用", info.availStorage)
                    }
                }
                if !info.currentFocus.isEmpty {
                    MDCard {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionTitle("当前前台")
                            Text(info.currentFocus)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(MDColor.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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

        // 对齐原版 DeviceFullInfo.kt：优先平台代号，退回落芯片厂商
        let platform = await shell("getprop ro.board.platform")
        let hardware = await shell("getprop ro.hardware")
        let socMan = await shell("getprop ro.soc.manufacturer")
        d.cpuInfo = [platform.isEmpty ? hardware : platform, socMan]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        // CPU 核心型号：从 /proc/cpuinfo 里提取第一次出现的 Hardware / model name
        let cpuRaw = await shellMultiple(
            "cat /proc/cpuinfo | grep -m1 -E 'Hardware|model name|Processor'"
        )
        d.cpuModel = cpuRaw

        d.totalStorage = await shell("df -h /data 2>/dev/null | tail -1")

        // 电量与充电状态（原版读 AC powered 判断是否在充电）
        let batLevel = await shell("dumpsys battery | grep level")
        d.batteryLevel = batLevel.split(separator: ":").last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let acPowered = await shell("dumpsys battery | grep 'AC powered'")
        d.isCharging = acPowered.lowercased().contains("true")

        // 温度：优先 thermalservice，读不到再退 thermal_zone（原版两路都有）
        var thermal = await shellMultiple("dumpsys thermalservice | grep -m3 -i 'temperature'")
        if thermal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thermal = await shellMultiple(
                "for f in /sys/class/thermal/thermal_zone*; do "
                + "type=$(cat $f/type 2>/dev/null); temp=$(cat $f/temp 2>/dev/null); "
                + "if [ -n \"$temp\" ]; then echo \"$type:$temp\"; fi; done"
            )
        }
        d.thermalText = thermal

        // 当前前台界面
        let focus = await shell(
            "dumpsys window displays | grep -E 'mCurrentFocus|mFocusedApp' | head -2"
        )
        d.currentFocus = focus

        // 系统亮度（原版 DeviceFullInfo.kt:320）
        d.brightness = await shell("settings get system screen_brightness")

        // 当前活跃用户（原版 AppStartupManager.kt:207）
        d.currentUser = await shell("am get-current-user")

        // adb shell 身份（原版 DeviceAdbLock.probeIdentity 用 `id` 判断是否 root）
        d.shellIdentity = await shell("id")

        info = d
        loading = false
    }

    /// 取多行输出，用于 cpuinfo / thermalservice 这类需要多行的场景
    private func shellMultiple(_ c: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            AdbService.shared.shellLines(c) { lines in
                cont.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}

// MARK: - Shell

struct ShellView: View {
    let device: DeviceRecord
    @State private var command = ""
    @State private var history: [ShellEntry] = []
    @State private var running = false

    /// 已执行过的命令（用于上下箭头翻历史，原版 commandHistory）
    @State private var executedCommands: [String] = []
    @State private var historyIndex = 0
    /// 快捷指令（原版 ShellShortcut）
    @State private var shortcuts: [ShellShortcut] = []
    @State private var showShortcuts = false
    @State private var showAddShortcut = false
    @State private var shortcutName = ""
    @State private var shortcutCmd = ""
    @State private var wrapsLines = true

    struct ShellShortcut: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let cmd: String
    }

    struct ShellEntry: Identifiable {
        let id = UUID()
        let command: String
        let output: String
        let success: Bool
    }

    var body: some View {
        ZStack {
            MDPageBackground()

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
                                            .lineLimit(wrapsLines ? nil : 1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                                        .fill(MDColor.surfaceHigh)
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
                    // 历史翻页（原版上下箭头）
                    VStack(spacing: 0) {
                        Button {
                            guard !executedCommands.isEmpty else { return }
                            historyIndex = max(0, historyIndex - 1)
                            if historyIndex < executedCommands.count {
                                command = executedCommands[historyIndex]
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(MDColor.textSecondary)
                                .frame(width: 26, height: 20)
                        }
                        .buttonStyle(.plain)

                        Button {
                            guard !executedCommands.isEmpty else { return }
                            if historyIndex < executedCommands.count - 1 {
                                historyIndex += 1
                                command = executedCommands[historyIndex]
                            } else {
                                historyIndex = executedCommands.count
                                command = ""
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(MDColor.textSecondary)
                                .frame(width: 26, height: 20)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField("输入 adb shell 命令", text: $command)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                                .fill(MDColor.surfaceHigh)
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
                .background(MDColor.surfaceHigh)
            }
        }
        .navigationTitle("Shell执行")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        shortcutCmd = command
                        shortcutName = ""
                        showAddShortcut = true
                    } label: {
                        Label("新建快捷指令", systemImage: "plus.circle")
                    }

                    Button {
                        showShortcuts = true
                    } label: {
                        Label("快捷指令（\(shortcuts.count)）", systemImage: "bolt.horizontal")
                    }

                    Divider()

                    Button {
                        wrapsLines.toggle()
                    } label: {
                        Label(wrapsLines ? "关闭自动换行" : "开启自动换行",
                              systemImage: "text.alignleft")
                    }

                    Button {
                        UIPasteboard.general.string = history
                            .map { "$ \($0.command)\n\($0.output)" }
                            .joined(separator: "\n\n")
                    } label: {
                        Label("复制所有日志", systemImage: "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        history.removeAll()
                    } label: {
                        Label("清空输出", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MDColor.brand)
                }
            }
        }
        .alert("新建快捷指令", isPresented: $showAddShortcut) {
            TextField("名称", text: $shortcutName)
            TextField("命令", text: $shortcutCmd)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("保存") {
                let n = shortcutName.trimmingCharacters(in: .whitespaces)
                let c = shortcutCmd.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty, !c.isEmpty else { return }
                shortcuts.append(ShellShortcut(name: n, cmd: c))
            }
        }
        .sheet(isPresented: $showShortcuts) {
            NavigationStack {
                ZStack {
                    MDPageBackground()
                    ScrollView {
                        VStack(spacing: 10) {
                            if shortcuts.isEmpty {
                                Text("还没有快捷指令")
                                    .font(.system(size: 13))
                                    .foregroundStyle(MDColor.textSecondary)
                                    .padding(.top, 40)
                            } else {
                                ForEach(shortcuts) { item in
                                    HStack(spacing: 10) {
                                        Button {
                                            command = item.cmd
                                            showShortcuts = false
                                            Task { await execute() }
                                        } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(item.name)
                                                    .font(.system(size: 14, weight: .medium))
                                                    .foregroundStyle(MDColor.textPrimary)
                                                Text(item.cmd)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(MDColor.textSecondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)

                                        Button(role: .destructive) {
                                            shortcuts.removeAll { $0.id == item.id }
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 13))
                                                .foregroundStyle(MDColor.danger)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                                            .fill(MDColor.surfaceHigh)
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, MDMetric.pagePadding)
                        .padding(.top, 12)
                    }
                }
                .navigationTitle("快捷指令")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { showShortcuts = false }
                            .foregroundStyle(MDColor.brand)
                    }
                }
            }
        }
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

        // 记进历史，供上下箭头翻
        if executedCommands.last != cmd {
            executedCommands.append(cmd)
        }
        historyIndex = executedCommands.count

        running = false
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
            MDPageBackground()
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
