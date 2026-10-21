import SwiftUI

/// 命令页
///
/// 对照 HTML 原型的 15 条快捷指令：
///   系统控制 5 / 网络 8 / 日志 2，外加顶部「打开 Shell」。
///
/// 原版 Android 把「显示 / 设备信息 / 截图录屏」也塞在这一页，
/// 本版按定稿把它们移出（改由首页 12 格快捷操作承载），这一页只留要敲命令的动作。
struct CommandsView: View {

    let device: DeviceRecord

    @State private var pending: CommandItem?
    @State private var runningID: String?
    @State private var output: [OutputLine] = []
    @State private var showShell = false
    @State private var showOutput = false

    private let adb = AdbService.shared

    var body: some View {
        NavigationStack {
            MDPage(title: "命令") {

                shellEntry

                ForEach(groups, id: \.self) { group in
                    groupCard(group)
                }

                if !output.isEmpty {
                    outputCard
                }
            }
            .navigationDestination(isPresented: $showShell) {
                ShellView(device: device)
            }
        }
        .alert("确认执行", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )) {
            Button("取消", role: .cancel) { pending = nil }
            Button("执行", role: .destructive) {
                if let item = pending {
                    pending = nil
                    Task { await run(item) }
                }
            }
        } message: {
            if let item = pending {
                Text("\(item.title)\n\(item.cmd)\n\n该操作无法撤销。")
            }
        }
    }

    // MARK: - 打开 Shell

    private var shellEntry: some View {
        Button {
            showShell = true
        } label: {
            MDCard {
                HStack(spacing: 14) {
                    MDIconTile(systemName: "terminal", tint: MDColor.success)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("打开 Shell")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MDColor.textPrimary)
                        Text("自由执行任意命令")
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MDColor.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 命令分组

    private var groups: [String] {
        var seen: [String] = []
        for item in Self.commands where !seen.contains(item.group) {
            seen.append(item.group)
        }
        return seen
    }

    private func groupCard(_ group: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MDColor.textSecondary)
                .padding(.leading, 4)
                .padding(.top, 4)

            MDCard(padding: 0) {
                VStack(spacing: 0) {
                    let rows = Self.commands.filter { $0.group == group }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        commandRow(item)

                        if index < rows.count - 1 {
                            Divider()
                                .padding(.leading, 62)
                        }
                    }
                }
            }
        }
    }

    private func commandRow(_ item: CommandItem) -> some View {
        Button {
            fire(item)
        } label: {
            HStack(spacing: 12) {
                MDIconTile(systemName: item.icon, tint: item.tint, size: 38, radius: 11)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(MDColor.textPrimary)

                    Text(item.cmd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MDColor.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if runningID == item.id {
                    ProgressView().scaleEffect(0.75)
                } else if item.dangerous {
                    Text("确认")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MDColor.warning)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(MDColor.warning.opacity(0.14)))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MDColor.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(runningID != nil)
    }

    // MARK: - 输出

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("执行结果")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MDColor.textSecondary)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showOutput.toggle() }
                } label: {
                    Text(showOutput ? "收起" : "展开")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MDColor.brand)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { output.removeAll() }
                } label: {
                    Text("清空")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MDColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            MDCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    let visible = showOutput ? output : Array(output.prefix(1))
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Divider() }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(line.ok ? MDColor.success : MDColor.danger)
                                    .frame(width: 6, height: 6)
                                Text(line.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(MDColor.textPrimary)
                                Spacer(minLength: 4)
                                Text(line.time)
                                    .font(.system(size: 10))
                                    .foregroundStyle(MDColor.textTertiary)
                            }

                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MDColor.textSecondary)
                                .lineLimit(showOutput ? 8 : 3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 执行

    private func fire(_ item: CommandItem) {
        if item.dangerous {
            pending = item
        } else {
            Task { await run(item) }
        }
    }

    private func run(_ item: CommandItem) async {
        runningID = item.id
        let (ok, text) = await adb.shellAsync(item.cmd)
        runningID = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? (ok ? "执行完成，无输出" : "执行失败") : trimmed

        output.insert(OutputLine(title: item.title, text: body, ok: ok), at: 0)
        if output.count > 20 {
            output.removeLast(output.count - 20)
        }

        RecentStore.shared.record(.shell, title: item.title, detail: item.cmd)

        if ok {
            // 截图 / 日志类命令同步一条动态，首页能看到
            if item.cmd.contains("logcat") {
                RecentStore.shared.record(.other, title: "已读取 Logcat", detail: "最近 200 行")
            }
        }
    }

    // MARK: - 数据

    private struct OutputLine: Identifiable {
        let id = UUID()
        let title: String
        let text: String
        let ok: Bool
        var time: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f.string(from: Date())
        }
    }

    private struct CommandItem: Identifiable {
        let id: String
        let group: String
        let title: String
        let cmd: String
        let icon: String
        let tint: Color
        let dangerous: Bool
    }

    private static let commands: [CommandItem] = [
        // 系统控制 5
        .init(id: "reboot", group: "系统控制", title: "重启设备",
              cmd: "reboot", icon: "arrow.clockwise", tint: MDColor.process, dangerous: true),
        .init(id: "poweroff", group: "系统控制", title: "关机",
              cmd: "reboot -p", icon: "power", tint: MDColor.process, dangerous: true),
        .init(id: "recovery", group: "系统控制", title: "进入 Recovery",
              cmd: "reboot recovery", icon: "arrow.triangle.2.circlepath",
              tint: MDColor.shell, dangerous: true),
        .init(id: "fastboot", group: "系统控制", title: "进入 Fastboot",
              cmd: "reboot fastboot", icon: "bolt.fill", tint: MDColor.tool, dangerous: true),
        .init(id: "bootloader", group: "系统控制", title: "进入 Bootloader",
              cmd: "reboot bootloader", icon: "gearshape.2.fill", tint: MDColor.shell, dangerous: true),

        // 网络 8
        .init(id: "wifi_on", group: "网络", title: "WiFi 开",
              cmd: "svc wifi enable", icon: "wifi", tint: MDColor.app, dangerous: false),
        .init(id: "wifi_off", group: "网络", title: "WiFi 关",
              cmd: "svc wifi disable", icon: "wifi.slash", tint: MDColor.textSecondary, dangerous: false),
        .init(id: "data_on", group: "网络", title: "移动数据 开",
              cmd: "svc data enable", icon: "antenna.radiowaves.left.and.right",
              tint: MDColor.app, dangerous: false),
        .init(id: "data_off", group: "网络", title: "移动数据 关",
              cmd: "svc data disable", icon: "antenna.radiowaves.left.and.right.slash",
              tint: MDColor.textSecondary, dangerous: false),
        .init(id: "ip", group: "网络", title: "查看 IP",
              cmd: "ip addr show wlan0", icon: "network", tint: MDColor.info, dangerous: false),
        .init(id: "wifi_info", group: "网络", title: "WiFi 信息",
              cmd: "dumpsys wifi | head -n 30", icon: "wifi.circle", tint: MDColor.info, dangerous: false),
        .init(id: "net_state", group: "网络", title: "网络状态",
              cmd: "dumpsys connectivity | head -n 30", icon: "point.3.connected.trianglepath.dotted",
              tint: MDColor.info, dangerous: false),
        .init(id: "ping", group: "网络", title: "Ping 测试",
              cmd: "ping -c 4 8.8.8.8", icon: "waveform.path.ecg", tint: MDColor.tool, dangerous: false),

        // 日志 2
        .init(id: "logcat", group: "日志", title: "查看 Logcat",
              cmd: "logcat -d -t 200", icon: "doc.text.magnifyingglass",
              tint: MDColor.shell, dangerous: false),
        .init(id: "logcat_clear", group: "日志", title: "清空 Logcat",
              cmd: "logcat -c", icon: "trash", tint: MDColor.process, dangerous: true),
    ]
}
