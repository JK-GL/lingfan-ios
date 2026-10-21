import SwiftUI

/// 设置页
///
/// 分四块：外观 / 连接 / 数据 / 关于。
/// 全部用 `@AppStorage` 落盘，不引额外的 Store。
struct SettingsView: View {

    /// 0 = 跟随系统，1 = 浅色，2 = 深色
    @AppStorage("appearance") private var appearance: Int = 0
    /// 默认端口：首页新建连接时预填
    @AppStorage("default.port") private var defaultPort: String = "5557"
    /// 自动发现开关的持久化镜像
    @AppStorage("auto.discovery") private var autoDiscovery: Bool = true

    @StateObject private var recent = RecentStore.shared

    @State private var showClearRecent = false
    @State private var showClearHistory = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            MDPage(title: "设置") {

                appearanceCard
                connectionCard
                dataCard
                aboutCard

                if let toast {
                    Text(toast)
                        .font(.system(size: 12))
                        .foregroundStyle(MDColor.success)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .alert("清空最近动态？", isPresented: $showClearRecent) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    recent.clear()
                    flash("最近动态已清空")
                }
            } message: {
                Text("\(recent.items.count) 条记录将被删除，不影响设备连接。")
            }
            .alert("清空设备历史？", isPresented: $showClearHistory) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: "device.history")
                    flash("设备历史已清空")
                }
            } message: {
                Text("已保存的设备地址会被忘记，下次需要重新输入 IP。")
            }
        }
    }

    // MARK: - 外观

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("外观")

            MDCard {
                VStack(spacing: 14) {
                    HStack {
                        MDIconTile(systemName: "circle.lefthalf.filled",
                                   tint: MDColor.brand, size: 40, radius: 12)
                        Text("显示模式")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MDColor.textPrimary)
                        Spacer()
                    }

                    Picker("显示模式", selection: $appearance) {
                        Text("跟随系统").tag(0)
                        Text("浅色").tag(1)
                        Text("深色").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    // MARK: - 连接

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("连接")

            MDCard {
                VStack(spacing: 14) {
                    HStack {
                        MDIconTile(systemName: "network", tint: MDColor.info, size: 40, radius: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认端口")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(MDColor.textPrimary)
                            Text("首页新建连接时预填")
                                .font(.system(size: 11))
                                .foregroundStyle(MDColor.textSecondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(["5555", "5556", "5557", "5558", "5037"], id: \.self) { p in
                                Button(p) { defaultPort = p }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(defaultPort)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(MDColor.textPrimary)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(MDColor.textTertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                                    .fill(MDColor.surfaceHigh)
                            )
                        }
                    }

                    Divider()

                    HStack {
                        MDIconTile(systemName: "dot.radiowaves.left.and.right",
                                   tint: MDColor.app, size: 40, radius: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动发现")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(MDColor.textPrimary)
                            Text("进入首页时自动扫描局域网")
                                .font(.system(size: 11))
                                .foregroundStyle(MDColor.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: $autoDiscovery)
                            .labelsHidden()
                            .tint(MDColor.brand)
                    }
                }
            }
        }
    }

    // MARK: - 数据

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("数据")

            MDCard(padding: 0) {
                VStack(spacing: 0) {
                    Button {
                        showClearRecent = true
                    } label: {
                        settingRow(
                            icon: "clock.arrow.circlepath",
                            tint: MDColor.tool,
                            title: "清空最近动态",
                            detail: "\(recent.items.count) 条"
                        )
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 62)

                    Button {
                        showClearHistory = true
                    } label: {
                        settingRow(
                            icon: "externaldrive.badge.xmark",
                            tint: MDColor.process,
                            title: "清空设备历史",
                            detail: ""
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func settingRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            MDIconTile(systemName: icon, tint: tint, size: 38, radius: 11)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MDColor.textPrimary)

            Spacer()

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(MDColor.textTertiary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MDColor.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - 关于

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("关于")

            MDCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(MDColor.brand)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "car.fill")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.white)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("ADB 调试 · 菱粉联动")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(MDColor.textPrimary)
                            Text("版本 \(appVersion)")
                                .font(.system(size: 12))
                                .foregroundStyle(MDColor.textSecondary)
                        }

                        Spacer()
                    }

                    Divider()

                    aboutRow("协议层", "libadb (android-tools 35.0.2)")
                    aboutRow("无线配对", "TLS 1.3 + SPAKE2")
                    aboutRow("文件列表", "adb sync LIST 协议")
                    aboutRow("最低系统", "iOS 16.0")
                }
            }

            MDCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用提示")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)

                    tip("车机 USB 调试打开后，多数车机需要在「无线调试」里配对一次")
                    tip("星光 L (F610S) 的 adbd 口令为设备专用，连接时按提示输入")
                    tip("截图与录屏落盘在 App 沙盒，可在文件 App 里查看")
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func aboutRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 13))
                .foregroundStyle(MDColor.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(MDColor.textPrimary)
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(MDColor.textTertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(MDColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 杂项

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(MDColor.textSecondary)
            .padding(.leading, 4)
            .padding(.top, 4)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }
}
