import SwiftUI

/// 无线配对弹窗
///
/// 对应原版「无线配对」入口。Android 版用 NsdManager 自动找配对端口，
/// iOS 这里让用户手填，因为我们本地网络权限首次会弹窗，自动发现可能拿不到。
/// 协议层走 libadb 的 `adb pair HOST[:PORT] [CODE]`。
struct PairSheet: View {

    @Binding var isPresented: Bool
    /// 配对成功后把 endpoint 回填到首页输入框
    var onPaired: ((String) -> Void)? = nil

    @State private var address: String = ""
    @State private var code: String = ""
    @State private var isPairing = false
    @State private var resultMessage: String?
    @State private var isSuccess = false

    private let adb = AdbService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                MDColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MDMetric.cardSpacing) {
                        headerCard
                        inputCard

                        if let resultMessage {
                            resultCard(resultMessage)
                        }
                    }
                    .padding(.horizontal, MDMetric.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("无线配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isPresented = false }
                        .foregroundStyle(MDColor.brand)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(MDColor.background, for: .navigationBar)
        }
    }

    // MARK: - 说明

    private var headerCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MDIconTile(systemName: "wifi", tint: MDColor.brand, size: 44, radius: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Android 11 及以上")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MDColor.textPrimary)
                        Text("需在车机上开启「无线调试」")
                            .font(.system(size: 12))
                            .foregroundStyle(MDColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                Text("车机路径：设置 → 开发者选项 → 无线调试 → 使用配对码配对设备")
                    .font(.system(size: 12))
                    .foregroundStyle(MDColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 输入

    private var inputCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("配对地址")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MDColor.textSecondary)
                    TextField("192.168.1.30:37123", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 17, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MDColor.background)
                        )
                    Text("注意：这是配对端口，不是 5557")
                        .font(.system(size: 11))
                        .foregroundStyle(MDColor.textTertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("配对码")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MDColor.textSecondary)
                    TextField("6 位数字", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MDColor.background)
                        )
                }

                MDPrimaryButton(
                    title: isPairing ? "配对中…" : "开始配对",
                    enabled: !isPairing && !address.isEmpty && !code.isEmpty
                ) {
                    Task { await pair() }
                }
            }
        }
    }

    private func resultCard(_ message: String) -> some View {
        let tint = isSuccess ? MDColor.success : MDColor.danger
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(MDColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(tint.opacity(0.22), lineWidth: 1)
                )
        )
    }

    // MARK: - 执行

    private func pair() async {
        isPairing = true
        resultMessage = nil
        defer { isPairing = false }

        let addr = address.trimmingCharacters(in: .whitespaces)
        let pairCode = code.trimmingCharacters(in: .whitespaces)

        let (ok, text) = await withCheckedContinuation {
            (cont: CheckedContinuation<(Bool, String), Never>) in
            adb.pair(address: addr, code: pairCode) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }

        isSuccess = ok
        if ok {
            // 配对成功后，adb 通常在同一 IP 的 5555/5557 上提供调试
            let host = addr.split(separator: ":").first.map(String.init) ?? addr
            resultMessage = "配对成功。请回到首页，用 \(host):5557 连接（端口按车机实际填）。"
            onPaired?(host)
        } else {
            resultMessage = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "配对失败：无回执。请确认地址是配对端口、车机无线调试已开启。"
                : text
        }
    }
}

#Preview {
    PairSheet(isPresented: .constant(true))
}
