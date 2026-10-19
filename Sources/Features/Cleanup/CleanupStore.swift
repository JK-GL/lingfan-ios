import Foundation

/// 存储清理数据层
///
/// 扫描思路：用 `du` 找大目录 + 已知垃圾路径白名单。
/// 不自己遍历文件树 —— 车机上几十万文件的递归会让 shell 卡死。
///
/// 分两类：
///   可安全清理  /data/local/tmp、/sdcard/Download 里的旧文件、空目录
///   需谨慎      /sdcard/Android/data 下的缓存、logcat 目录
@MainActor
final class CleanupStore: ObservableObject {

    /// 一个可清理项
    struct Target: Identifiable, Hashable {
        let path: String
        let title: String
        let detail: String
        /// 字节数，-1 表示未知
        let sizeBytes: Int64
        let risk: Risk

        var id: String { path }

        enum Risk: String {
            case safe      // 缓存、临时目录
            case careful   // 应用数据，清理后需重新登录/重新下载

            var label: String {
                switch self {
                case .safe: return "安全"
                case .careful: return "谨慎"
                }
            }
        }

        var sizeText: String {
            guard sizeBytes >= 0 else { return "未知" }
            let b = Double(sizeBytes)
            if b >= 1073741824 { return String(format: "%.2f GB", b / 1073741824) }
            if b >= 1048576 { return String(format: "%.1f MB", b / 1048576) }
            if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
            return "\(sizeBytes) B"
        }
    }

    @Published private(set) var targets: [Target] = []
    @Published private(set) var scanning = false
    @Published private(set) var cleaning = false
    @Published private(set) var freedBytes: Int64 = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageSummary = "—"

    var isDemo = false
    private let adb = AdbService.shared

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    var totalReclaimable: Int64 {
        targets.filter { $0.sizeBytes > 0 }.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - 扫描

    func scan() async {
        scanning = true
        errorMessage = nil
        freedBytes = 0
        defer { scanning = false }

        if isDemo {
            loadDemo()
            return
        }

        await loadStorageSummary()

        // 候选目录：先看存不存在，存在才算大小
        let candidates: [(String, String, Target.Risk)] = [
            ("/data/local/tmp", "临时文件目录", .safe),
            ("/sdcard/Download", "下载目录", .safe),
            ("/sdcard/Android/data", "应用数据缓存", .careful),
            ("/data/log", "系统日志目录", .safe),
            ("/cache", "系统缓存分区", .safe),
            ("/sdcard/.thumbnails", "缩略图缓存", .safe),
        ]

        var found: [Target] = []
        for (path, title, risk) in candidates {
            // -s 只输出总计，避免遍历细节刷屏
            let out = await shellLines("du -sk '\(path)' 2>/dev/null")
            guard let line = out.first else { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let kb = Int64(cols.first.map(String.init) ?? "") else { continue }
            let bytes = kb * 1024
            // 小于 1MB 的不值得列出来
            guard bytes >= 1048576 else { continue }

            found.append(Target(
                path: path,
                title: title,
                detail: path,
                sizeBytes: bytes,
                risk: risk
            ))
        }

        if found.isEmpty {
            errorMessage = "没有发现可清理的目标，或 du 命令被 ROM 限制。"
        }
        targets = found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func loadStorageSummary() async {
        let lines = await shellLines("df -k /data 2>/dev/null || df -k /sdcard")
        guard lines.count >= 2 else { return }
        let cols = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 4,
              let total = Double(cols[1]),
              let used = Double(cols[2]) else { return }

        func fmt(_ kb: Double) -> String {
            kb >= 1048576
                ? String(format: "%.1f GB", kb / 1048576)
                : String(format: "%.0f MB", kb / 1024)
        }
        storageSummary = "已用 \(fmt(used)) / 共 \(fmt(total))"
    }

    // MARK: - 清理

    /// 清理选中的目标。返回成功清理的字节数。
    func clean(_ selected: Set<String>) async -> Int64 {
        guard !selected.isEmpty else { return 0 }
        cleaning = true
        errorMessage = nil
        defer { cleaning = false }

        if isDemo {
            let reclaimed = targets
                .filter { selected.contains($0.path) }
                .reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
            targets.removeAll { selected.contains($0.path) }
            freedBytes += reclaimed
            return reclaimed
        }

        var reclaimed: Int64 = 0
        for path in selected {
            guard let t = targets.first(where: { $0.path == path }) else { continue }
            let before = t.sizeBytes

            // 只删内容不删目录本身：mkdir 目录可能被系统用于挂载
            let lines = await shellLines(
                "if [ -d '\(path)' ]; then rm -rf '\(path)'/* '\(path)'/.[!.]* 2>/dev/null; fi; echo done"
            )
            let text = lines.joined(separator: " ").lowercased()
            if text.contains("denied") || text.contains("read-only") {
                errorMessage = "\(path) 清理失败：权限不足"
                continue
            }

            // 复核：重新量一次
            let after = await shellLines("du -sk '\(path)' 2>/dev/null")
            var afterBytes: Int64 = 0
            if let line = after.first,
               let kb = Int64(line.split(separator: " ").first.map(String.init) ?? "") {
                afterBytes = kb * 1024
            }
            let diff = max(0, before - afterBytes)
            reclaimed += diff

            if let i = targets.firstIndex(where: { $0.path == path }) {
                if afterBytes < 1048576 {
                    targets.remove(at: i)
                } else {
                    let o = targets[i]
                    targets[i] = Target(path: o.path, title: o.title, detail: o.detail,
                                        sizeBytes: afterBytes, risk: o.risk)
                }
            }
        }

        freedBytes += reclaimed
        await loadStorageSummary()
        return reclaimed
    }

    // MARK: - 演示

    private func loadDemo() {
        storageSummary = "已用 13.9 GB / 共 32.0 GB"
        targets = [
            Target(path: "/data/local/tmp", title: "临时文件目录",
                   detail: "/data/local/tmp", sizeBytes: 248 * 1048576, risk: .safe),
            Target(path: "/sdcard/Download", title: "下载目录",
                   detail: "/sdcard/Download", sizeBytes: 1860 * 1048576, risk: .safe),
            Target(path: "/sdcard/Android/data", title: "应用数据缓存",
                   detail: "/sdcard/Android/data", sizeBytes: 3400 * 1048576, risk: .careful),
            Target(path: "/data/log", title: "系统日志目录",
                   detail: "/data/log", sizeBytes: 92 * 1048576, risk: .safe),
            Target(path: "/sdcard/.thumbnails", title: "缩略图缓存",
                   detail: "/sdcard/.thumbnails", sizeBytes: 64 * 1048576, risk: .safe),
        ]
    }

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }
}
