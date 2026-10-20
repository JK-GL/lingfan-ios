import SwiftUI

/// 虚拟遥控
///
/// 全部走 `input` 命令，不依赖任何私有协议：
///   按键   input keyevent <CODE>
///   文字   input text <内容>
///   滑动   input swipe x1 y1 x2 y2 [ms]
///   点击   input tap x y
/// 车机上 `input` 由系统提供，一般无需 root。
struct RemoteView: View {

    let device: DeviceRecord

    @State private var command = ""
    @State private var toast: String?
    @State private var sending = false
    @State private var sendingKey: String?
    @State private var customCode = ""

    private let adb = AdbService.shared

    /// 常用按键。keyCode 取自 Android KeyEvent 常量。
    ///
    /// 注意：不能用元组的 keypath（`\.0` / `\.1`）做 ForEach id，
    /// Swift 不支持对元组取 key path，会报 "key path cannot refer to tuple element"。
    struct KeyItem: Identifiable {
        let label: String
        let code: Int
        let icon: String
        var id: Int { code }
    }

    struct KeyGroup: Identifiable {
        let title: String
        let keys: [KeyItem]
        var id: String { title }
    }

    /// 按键表逐条对齐原版 RemoteKey.kt 的 RemoteKey 枚举（28 个）
    private let keyGroups: [KeyGroup] = [
        KeyGroup(title: "导航", keys: [
            KeyItem(label: "返回", code: 4, icon: "arrow.uturn.backward"),
            KeyItem(label: "主页", code: 3, icon: "house.fill"),
            KeyItem(label: "菜单", code: 82, icon: "line.3.horizontal"),
        ]),
        KeyGroup(title: "方向", keys: [
            KeyItem(label: "上", code: 19, icon: "chevron.up"),
            KeyItem(label: "下", code: 20, icon: "chevron.down"),
            KeyItem(label: "左", code: 21, icon: "chevron.left"),
            KeyItem(label: "右", code: 22, icon: "chevron.right"),
            KeyItem(label: "确定", code: 23, icon: "checkmark"),
        ]),
        KeyGroup(title: "音量", keys: [
            KeyItem(label: "音量+", code: 24, icon: "speaker.plus.fill"),
            KeyItem(label: "音量-", code: 25, icon: "speaker.minus.fill"),
            KeyItem(label: "静音", code: 164, icon: "speaker.slash.fill"),
        ]),
        KeyGroup(title: "媒体", keys: [
            KeyItem(label: "播放/暂停", code: 85, icon: "playpause.fill"),
            KeyItem(label: "上一首", code: 88, icon: "backward.fill"),
            KeyItem(label: "下一首", code: 87, icon: "forward.fill"),
        ]),
        KeyGroup(title: "电源", keys: [
            KeyItem(label: "电源", code: 26, icon: "power"),
            KeyItem(label: "休眠", code: 223, icon: "moon.fill"),
            KeyItem(label: "唤醒", code: 224, icon: "sun.max.fill"),
        ]),
        KeyGroup(title: "数字", keys: [
            KeyItem(label: "0", code: 7, icon: "0.square"),
            KeyItem(label: "1", code: 8, icon: "1.square"),
            KeyItem(label: "2", code: 9, icon: "2.square"),
            KeyItem(label: "3", code: 10, icon: "3.square"),
            KeyItem(label: "4", code: 11, icon: "4.square"),
            KeyItem(label: "5", code: 12, icon: "5.square"),
            KeyItem(label: "6", code: 13, icon: "6.square"),
            KeyItem(label: "7", code: 14, icon: "7.square"),
            KeyItem(label: "8", code: 15, icon: "8.square"),
            KeyItem(label: "9", code: 16, icon: "9.square"),
        ]),
        KeyGroup(title: "编辑", keys: [
            KeyItem(label: "退格", code: 67, icon: "delete.left.fill"),
            KeyItem(label: "回车", code: 66, icon: "return"),
            KeyItem(label: "空格", code: 62, icon: "space"),
        ]),
    ]

    var body: some View {
        ZStack {
            MDPageBackground()

            ScrollView {
                VStack(spacing: MDMetric.cardSpacing) {
                    textCard
                    ForEach(keyGroups) { group in
                        keyCard(title: group.title, keys: group.keys)
                    }
                    customCodeCard
                }
                .padding(.horizontal, MDMetric.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }

            if let toast {
                toastView(toast)
            }
        }
        .navigationTitle("虚拟遥控")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(MDColor.background, for: .navigationBar)
    }

    // MARK: - 自定义 KeyCode

    /// 原版「模拟按键」页底部的自定义 KeyCode 输入
    private var customCodeCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "number.square")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MDColor.remote)
                    Text("自定义 KeyCode")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    TextField("输入 Key Code（数字）", text: $customCode)
                        .keyboardType(.numberPad)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                                .fill(MDColor.surfaceHigh)
                        )

                    Button {
                        guard let code = Int(customCode) else { return }
                        Task { await sendKey("\(code)", code) }
                    } label: {
                        Text("发送")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                                    .fill(customCode.isEmpty ? MDColor.brand.opacity(0.35) : MDColor.brand)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(customCode.isEmpty)
                }

                Text("数字对应 Android KeyEvent 常量，例如 3=主页、4=返回、26=电源")
                    .font(.system(size: 11))
                    .foregroundStyle(MDColor.textTertiary)
            }
        }
    }

    // MARK: - 文字输入

    private var textCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MDColor.remote)
                    Text("文字输入")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MDColor.textPrimary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    TextField("要发送到车机的文字", text: $command)
                        .font(.system(size: 15))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                                .fill(MDColor.surfaceHigh)
                        )

                    Button {
                        Task { await sendText() }
                    } label: {
                        Image(systemName: sending ? "hourglass" : "paperplane.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: MDMetric.radiusField, style: .continuous)
                                    .fill(command.isEmpty ? MDColor.textTertiary : MDColor.remote)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(command.isEmpty || sending)
                }

                Text("空格需转义，中文部分车机可能不支持")
                    .font(.system(size: 11))
                    .foregroundStyle(MDColor.textTertiary)
            }
        }
    }

    // MARK: - 按键网格

    private func keyCard(title: String, keys: [KeyItem]) -> some View {
        MDCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MDColor.textSecondary)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    spacing: 10
                ) {
                    ForEach(keys) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    private func keyButton(_ key: KeyItem) -> some View {
        let isBusy = sendingKey == "\(key.code)"

        return Button {
            Task { await sendKey(key.label, key.code) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isBusy ? "hourglass" : key.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isBusy ? MDColor.textTertiary : MDColor.remote)
                    .frame(height: 22)

                Text(key.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MDColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: MDMetric.radiusButton, style: .continuous)
                    .fill(MDColor.remote.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .disabled(sendingKey != nil)
    }

    // MARK: - 浮层提示

    private func toastView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MDColor.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(MDColor.textPrimary.opacity(0.92))
                )
                .padding(.bottom, 40)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: - 执行

    private func sendKey(_ label: String, _ code: Int) async {
        guard sendingKey == nil else { return }
        sendingKey = "\(code)"

        if device.isDemo {
            try? await Task.sleep(nanoseconds: 220_000_000)
            sendingKey = nil
            showToast("已模拟按键：\(label)（演示）")
            return
        }

        let (ok, out) = await shell("input keyevent \(code)")
        sendingKey = nil
        showToast(ok && out.isEmpty ? "已发送：\(label)" : "失败：\(out.isEmpty ? "无回执" : out)")
    }

    private func sendText() async {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true

        // input text 需要把空格转义成 %s
        let escaped = text.replacingOccurrences(of: " ", with: "%s")

        if device.isDemo {
            try? await Task.sleep(nanoseconds: 220_000_000)
            sending = false
            command = ""
            showToast("已模拟输入：\(text)（演示）")
            return
        }

        let (ok, out) = await shell("input text '\(escaped)'")
        sending = false
        if ok && out.isEmpty {
            command = ""
            showToast("已发送文字")
        } else {
            showToast("失败：\(out.isEmpty ? "无回执" : out)")
        }
    }

    private func shell(_ cmd: String) async -> (Bool, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            adb.shell(cmd) { ok, out in
                cont.resume(returning: (ok, out))
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { toast = nil }
        }
    }
}

#Preview {
    NavigationStack {
        RemoteView(device: .demo)
    }
}
