import Foundation
import UIKit

/// 应用名 / 图标获取
///
/// 对齐原版 `ProcessInfo.warmupAppLabelsIfNeeded`：
/// 原版往车机推一个 `server.apk`（assets 里的 Java 程序），
/// 用 `app_process` 跑 `com.davik.adbserver.Server`，
/// 它把每个应用的 label 以 JSON 行打到 stdout：
///     {"package":"com.sgmw.navi","label":"高德地图"}
/// 同时把图标写到 `/data/local/tmp/appicons/<pkg>.png`。
///
/// 为什么必须这么做：`pm list packages` 只给包名，
/// 车机上没有能直接读应用显示名的系统命令（aapt 通常也没装）。
@MainActor
final class AppLabelService {

    static let shared = AppLabelService()

    static let remotePath = "/data/local/tmp/server.apk"
    static let iconDir = "/data/local/tmp/appicons"
    static let command = "export CLASSPATH=/data/local/tmp/server.apk; "
        + "app_process /data/local/tmp com.davik.adbserver.Server /data/local/tmp 2>&1"

    private(set) var labels: [String: String] = [:]
    private var iconCache: [String: UIImage] = [:]
    private var warming = false
    private var warmed = false

    private let adb = AdbService.shared

    private var diskDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("appres", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func bind() {
        loadFromDisk()
    }

    // MARK: - 查询

    func label(for packageName: String) -> String? {
        let v = labels[packageName]
        return (v?.isEmpty == false) ? v : nil
    }

    func icon(for packageName: String) -> UIImage? {
        iconCache[packageName]
    }

    // MARK: - 预热

    /// 首次调用时推 server.apk 并跑一遍，把全车机的 label 抓下来。
    /// 已经有缓存就直接返回，不重复跑。
    func warmupIfNeeded() async {
        guard !warmed, !warming else { return }
        warming = true
        defer { warming = false }

        // 先看磁盘缓存够不够
        if !labels.isEmpty {
            warmed = true
            return
        }

        // 1. 确保 server.apk 在车机上
        let exists = await shell("ls \(Self.remotePath) 2>/dev/null")
        if exists.isEmpty || exists.lowercased().contains("no such") {
            guard let local = Bundle.main.path(forResource: "server", ofType: "apk") else {
                warmed = true
                return
            }
            let pushResult = await runCommand(["push", local, Self.remotePath])
            if pushResult.output.lowercased().contains("error") {
                warmed = true
                return
            }
            _ = await shell("chmod 777 \(Self.remotePath) 2>/dev/null")
        }

        // 2. 跑服务，逐行解析 JSON
        let output = await shell(Self.command)
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{") else { continue }
            guard let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pkg = obj["package"] as? String,
                  let label = obj["label"] as? String,
                  !pkg.isEmpty, !label.isEmpty else { continue }
            labels[pkg] = label
            try? label.write(
                to: diskDir.appendingPathComponent("\(pkg).txt"),
                atomically: true, encoding: .utf8
            )
        }

        warmed = true
    }

    /// 拉某个应用的图标（原版 `cat /data/local/tmp/appicons/<pkg>.png`）
    func loadIcon(for packageName: String) async -> UIImage? {
        if let cached = iconCache[packageName] { return cached }

        // 磁盘缓存
        let file = diskDir.appendingPathComponent("\(packageName).png")
        if let img = UIImage(contentsOfFile: file.path) {
            iconCache[packageName] = img
            return img
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon_\(UUID().uuidString).png")
        try? FileManager.default.removeItem(at: dest)

        let result = await runCommand([
            "pull", "\(Self.iconDir)/\(packageName).png", dest.path
        ])
        guard !result.output.lowercased().contains("error"),
              let img = UIImage(contentsOfFile: dest.path) else {
            return nil
        }
        iconCache[packageName] = img
        if let data = img.pngData() {
            try? data.write(to: file)
        }
        try? FileManager.default.removeItem(at: dest)
        return img
    }

    // MARK: - 磁盘缓存

    private func loadFromDisk() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil) else {
            return
        }
        for f in files where f.pathExtension == "txt" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let pkg = f.deletingPathExtension().lastPathComponent
            if !text.isEmpty { labels[pkg] = text }
        }
    }

    // MARK: - 基础

    private struct CmdResult {
        let success: Bool
        let output: String
    }

    private func runCommand(_ args: [String]) async -> CmdResult {
        await withCheckedContinuation { (cont: CheckedContinuation<CmdResult, Never>) in
            adb.runAsync(args) { r in
                cont.resume(returning: CmdResult(success: r.success, output: r.output))
            }
        }
    }

    private func shell(_ cmd: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0.joined(separator: "\n")) }
        }
    }
}
