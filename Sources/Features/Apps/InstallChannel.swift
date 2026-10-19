import Foundation
import SwiftUI

/// APK 安装通道
///
/// 逐行对齐原版 `InstallChannelSupport.kt`：
///
/// 部分华勤车机 ROM（730 / T527、星光L / F610S）改过 services.jar，
/// 安装强制校验平台签名，普通 `pm install -r` 一律返回
/// `INSTALL_FAILED_VERIFICATION_FAILURE: Signature is not platform signed`。
/// 该 ROM 额外提供两个隐藏选项（`pm help` 里查不到）：
///   1. `pm caninstall <窗口>` 开一个安装时间窗
///   2. `pm install --install-force -r <apk>` 在窗口内绕过签名强校验
///
/// 🔴 关键坑：该 ROM 的 `$?` 不可靠（实测返回 `True` 这类非数字），
/// 成败只能以 stdout 是否出现 `Success` 判定，**绝不能依赖 exitCode**。
enum InstallChannel: String {
    case standard = "标准"
    case forceWindow = "强制安装通道"
}

struct InstallAttempt {
    let success: Bool
    let channel: InstallChannel
    /// 最终生效通道的原始输出
    let output: String
    /// 标准通道的原始输出（失败时对照展示）
    let standardOutput: String
    /// 是否真的切换过通道
    let switched: Bool

    var isSignatureBlocked: Bool {
        InstallHelper.hasSignatureBlockMark(standardOutput)
    }

    var forceChannelUnsupported: Bool {
        standardOutput.lowercased().contains("unknown command: caninstall")
            || output.lowercased().contains("unknown command: caninstall")
    }

    /// 组合两条通道的原始输出，供错误展开区展示
    var combinedRawOutput: String {
        var s = "[标准通道 pm install -r]\n"
        s += standardOutput.isEmpty ? "<无输出>" : standardOutput
        if switched {
            s += "\n\n[强制安装通道 pm caninstall 120 + pm install --install-force -r]\n"
            s += output.isEmpty ? "<无输出>" : output
        }
        return s
    }
}

enum InstallHelper {

    /// 强制安装通道的时间窗（秒），对齐原版
    static let forceWindow = "120"

    /// 成败判定：必须含 Success 且不含 Failure。
    /// 不看 exitCode —— 定制 ROM 返回的是 `True` 这类非数字。
    static func isSuccess(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("success") && !lower.contains("failure")
    }

    /// 只在明确的「平台签名强校验」特征下才切强制通道，
    /// 避免普通机型误用非标路径。
    static func hasSignatureBlockMark(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("install_failed_verification_failure")
            || lower.contains("not platform signed")
            || lower.contains("platform signed")
            || lower.contains("verification failure")
    }

    /// 暂存 APK 的远程路径。
    /// 原版格式：/data/local/tmp/adbtools_install_<sessionId>_<name>.apk
    static func remoteTempPath(fileName: String, sessionId: Int) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let safe = base.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        let name = safe.isEmpty ? "install_task" : safe
        return "/data/local/tmp/adbtools_install_\(sessionId)_\(name).apk"
    }
}
