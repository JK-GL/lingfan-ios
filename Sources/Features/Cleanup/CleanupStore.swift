import Foundation

/// 存储清理
///
/// 逐条对齐原版 StorageCleanupScanner.kt —— 它照搬了 sdmaid-se 的过滤器体系。
///
/// 核心差异：
///   我原来只「量几个固定目录有多大」，只能整目录清空；
///   原版是「用 find 精确找出垃圾文件」，能精确定位到 LOST.DIR 里的碎片。
///
/// 九类过滤器（全部来自原版）：
///   Thumbnails / TempFiles / LogFiles / SuperfluousApks / EmptyDirectory
///   Trashed / LostDir / WindowsFiles / MacFiles / LinuxFiles / Screenshots
///
/// 外加 corpse 检测：用 `pm list packages` 对比 Android/data 下的目录，
/// 找出「已卸载应用留下的残留」—— 这是最有价值的清理能力。
final class CleanupStore: ObservableObject {

    // MARK: - 模型

    struct Target: Identifiable, Hashable {
        let path: String
        let sizeBytes: Int64
        var id: String { path }

        var sizeText: String {
            let b = Double(sizeBytes)
            if b >= 1073741824 { return String(format: "%.2f GB", b / 1073741824) }
            if b >= 1048576 { return String(format: "%.1f MB", b / 1048576) }
            if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
            return "\(sizeBytes) B"
        }
    }

    /// 一组过滤器结果
    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let detail: String
        let source: String
        var targets: [Target]

        var totalBytes: Int64 { targets.reduce(0) { $0 + $1.sizeBytes } }
        var count: Int { targets.count }
        var totalText: String {
            let b = Double(totalBytes)
            if b >= 1073741824 { return String(format: "%.2f GB", b / 1073741824) }
            if b >= 1048576 { return String(format: "%.1f MB", b / 1048576) }
            if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
            return "\(totalBytes) B"
        }
    }

    /// 已卸载应用的残留
    struct Corpse: Identifiable, Hashable {
        let packageName: String
        let path: String
        let locationType: String
        let sizeBytes: Int64
        var id: String { path }

        var sizeText: String {
            let b = Double(sizeBytes)
            if b >= 1073741824 { return String(format: "%.2f GB", b / 1073741824) }
            if b >= 1048576 { return String(format: "%.1f MB", b / 1048576) }
            if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
            return "\(sizeBytes) B"
        }
    }

    /// 大文件
    struct LargeFile: Identifiable, Hashable {
        let path: String
        let sizeBytes: Int64
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var sizeText: String {
            let b = Double(sizeBytes)
            if b >= 1073741824 { return String(format: "%.2f GB", b / 1073741824) }
            return String(format: "%.0f MB", b / 1048576)
        }
    }

    // MARK: - 状态

    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var corpses: [Corpse] = []
    @Published private(set) var largeFiles: [LargeFile] = []
    @Published private(set) var scanning = false
    @Published private(set) var cleaning = false
    @Published private(set) var scanStep = ""
    @Published private(set) var freedBytes: Int64 = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageSummary = "—"

    var isDemo = false
    private let adb = AdbService.shared

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    var totalReclaimable: Int64 {
        suggestions.reduce(0) { $0 + $1.totalBytes }
            + corpses.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - 常量（对齐原版）

    private static let androidDataPath = "/sdcard/Android/data"
    private static let largeFileThresholdKB: Int64 = 200 * 1024   // 200MB
    private static let screenshotsMinAgeDays: Int64 = 7
    private static let corpseRoots: [(String, String)] = [
        ("共享数据目录", "/sdcard/Android/data"),
        ("共享媒体目录", "/sdcard/Android/media"),
        ("OBB 目录", "/sdcard/Android/obb"),
    ]
    /// 包名正则：必须以字母开头，至少一个点
    private static let packageRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$"
    )

    // MARK: - 扫描

    func scan() async {
        scanning = true
        errorMessage = nil
        freedBytes = 0
        suggestions = []
        corpses = []
        largeFiles = []
        defer { scanning = false; scanStep = "" }

        if isDemo {
            loadDemo()
            return
        }

        scanStep = "读取存储概览…"
        await loadStorageSummary()

        // 已安装包集合 —— corpse 检测的基础
        scanStep = "读取已安装应用…"
        let installed = await queryInstalledPackages()

        var result: [Suggestion] = []

        scanStep = "扫描缩略图…"
        if let s = await scanThumbnails() { result.append(s) }

        scanStep = "扫描临时文件…"
        if let s = await scanTempFiles() { result.append(s) }

        scanStep = "扫描日志文件…"
        if let s = await scanLogFiles() { result.append(s) }

        scanStep = "扫描多余安装包…"
        if let s = await scanSuperfluousApks() { result.append(s) }

        scanStep = "扫描空目录…"
        if let s = await scanEmptyDirs() { result.append(s) }

        scanStep = "扫描回收站…"
        if let s = await scanTrashed() { result.append(s) }

        scanStep = "扫描 LOST.DIR…"
        if let s = await scanLostDir() { result.append(s) }

        scanStep = "扫描 Windows 残留…"
        if let s = await scanWindowsFiles() { result.append(s) }

        scanStep = "扫描 macOS 残留…"
        if let s = await scanMacFiles() { result.append(s) }

        scanStep = "扫描 Linux 回收站…"
        if let s = await scanLinuxFiles() { result.append(s) }

        scanStep = "扫描旧截图…"
        if let s = await scanOldScreenshots() { result.append(s) }

        scanStep = "检测已卸载应用残留…"
        let foundCorpses = await scanCorpses(installed: installed)

        scanStep = "扫描大文件…"
        let big = await scanLargeFiles()

        suggestions = result.sorted { $0.totalBytes > $1.totalBytes }
        corpses = foundCorpses
        largeFiles = big

        if suggestions.isEmpty && corpses.isEmpty && largeFiles.isEmpty {
            errorMessage = "没有发现可清理的内容，或 find 命令被 ROM 限制。"
        }
    }

    // MARK: - 各过滤器

    private func scanThumbnails() async -> Suggestion? {
        await dirSuggestion(
            id: "thumbnails",
            title: "缩略图缓存",
            detail: "路径含 .thumbnails 的目录，图片应用重建后会自动再生成",
            source: "sdmaid:ThumbnailsFilter",
            cmd: "find /sdcard -type d -name .thumbnails 2>/dev/null"
        )
    }

    private func scanTempFiles() async -> Suggestion? {
        await fileSuggestion(
            id: "temp_files",
            title: "临时文件",
            detail: "*.tmp *.temp .mmsyscache sdm_write_test-*",
            source: "sdmaid:TempFilesFilter",
            cmd: "find /sdcard -type f \\( -name '*.tmp' -o -name '*.temp' -o -name '.mmsyscache' -o -name 'sdm_write_test-*' \\) 2>/dev/null",
            exclusions: ["/backup/pending/", "/cache/recovery/"]
        )
    }

    private func scanLogFiles() async -> Suggestion? {
        await fileSuggestion(
            id: "log_files",
            title: "日志文件",
            detail: "*.log，排除了索引数据库内的日志",
            source: "sdmaid:LogFilesFilter",
            cmd: "find /sdcard -type f -name '*.log' 2>/dev/null",
            exclusions: ["/.indexeddb.leveldb/", "/t/Paths/"]
        )
    }

    private func scanSuperfluousApks() async -> Suggestion? {
        await fileSuggestion(
            id: "superfluous_apks",
            title: "多余安装包",
            detail: "*.apk *.apks，已排除 Backup / Recovery / TWRP 目录",
            source: "sdmaid:SuperfluousApksFilter",
            cmd: "find /sdcard -type f \\( -name '*.apk' -o -name '*.apks' \\) 2>/dev/null",
            exclusions: ["/backup/", "/backups/", "/recover/", "/recovery/", "/twrp/"]
        )
    }

    private func scanEmptyDirs() async -> Suggestion? {
        let paths = await find("find /sdcard -type d -empty 2>/dev/null")
        guard !paths.isEmpty else { return nil }
        // 空目录大小为 0，但条目数有意义
        let targets = paths.prefix(120).map { Target(path: $0, sizeBytes: 0) }
        return Suggestion(
            id: "empty_dirs", title: "空目录",
            detail: "没有任何内容的目录",
            source: "sdmaid:EmptyDirectoryFilter",
            targets: Array(targets)
        )
    }

    private func scanTrashed() async -> Suggestion? {
        await fileSuggestion(
            id: "trashed",
            title: "回收站文件",
            detail: "文件名以 .trashed- 开头",
            source: "sdmaid:TrashedFilter",
            cmd: "find /sdcard -type f -name '.trashed-*' 2>/dev/null"
        )
    }

    private func scanLostDir() async -> Suggestion? {
        await fileSuggestion(
            id: "lost_dir",
            title: "存储卡碎片",
            detail: "LOST.DIR 下的文件，SD 卡异常断电产生的碎片",
            source: "sdmaid:LostDirFilter",
            cmd: "find /sdcard -path '*/LOST.DIR/*' -type f 2>/dev/null"
        )
    }

    private func scanWindowsFiles() async -> Suggestion? {
        await fileSuggestion(
            id: "windows_files",
            title: "Windows 残留",
            detail: "desktop.ini thumbs.db",
            source: "sdmaid:WindowsFilesFilter",
            cmd: "find /sdcard -type f \\( -iname 'desktop.ini' -o -iname 'thumbs.db' \\) 2>/dev/null"
        )
    }

    private func scanMacFiles() async -> Suggestion? {
        await fileSuggestion(
            id: "mac_files",
            title: "macOS 残留",
            detail: "._* .Trashes .DS_Store .fseventsd .TemporaryItems",
            source: "sdmaid:MacFilesFilter",
            cmd: "find /sdcard \\( -name '._*' -o -name '.Trashes' -o -name '._.Trashes' -o -name '.spotlight' -o -name '.Spotlight-V100' -o -name '.DS_Store' -o -name '.fseventsd' -o -name '.TemporaryItems' \\) 2>/dev/null"
        )
    }

    private func scanLinuxFiles() async -> Suggestion? {
        await dirSuggestion(
            id: "linux_files",
            title: "Linux 回收站",
            detail: ".Trash / .Trash-* 目录，已排除 Android 目录",
            source: "sdmaid:LinuxFilesFilter",
            cmd: "find /sdcard -type d \\( -name '.Trash' -o -name '.Trash-*' \\) 2>/dev/null",
            exclusions: ["/android/"]
        )
    }

    private func scanOldScreenshots() async -> Suggestion? {
        let cutoff = Int(Date().timeIntervalSince1970) - Int(Self.screenshotsMinAgeDays * 24 * 3600)
        return await fileSuggestion(
            id: "old_screenshots",
            title: "旧截图",
            detail: "Pictures/Screenshots 下超过 \(Self.screenshotsMinAgeDays) 天的截图",
            source: "内置规则",
            cmd: "find /sdcard/Pictures/Screenshots -type f -not -newermt '@\(cutoff)' 2>/dev/null"
        )
    }

    // MARK: - 扫描辅助

    /// 目录型过滤器
    private func dirSuggestion(id: String, title: String, detail: String,
                               source: String, cmd: String,
                               exclusions: [String] = []) async -> Suggestion? {
        let paths = await find(cmd, exclusions: exclusions, requirePrefix: "/sdcard/")
        guard !paths.isEmpty else { return nil }
        var targets: [Target] = []
        for p in paths.prefix(80) {
            let size = await pathSize(p)
            targets.append(Target(path: p, sizeBytes: size))
        }
        guard !targets.isEmpty else { return nil }
        return Suggestion(id: id, title: title, detail: detail,
                          source: source, targets: targets)
    }

    /// 文件型过滤器
    private func fileSuggestion(id: String, title: String, detail: String,
                                source: String, cmd: String,
                                exclusions: [String] = []) async -> Suggestion? {
        let paths = await find(cmd, exclusions: exclusions, requirePrefix: "/sdcard/", limit: 120)
        guard !paths.isEmpty else { return nil }
        var targets: [Target] = []
        for p in paths {
            let size = await pathSize(p)
            if size > 0 { targets.append(Target(path: p, sizeBytes: size)) }
        }
        guard !targets.isEmpty else { return nil }
        return Suggestion(id: id, title: title, detail: detail,
                          source: source, targets: targets)
    }

    private func find(_ cmd: String, exclusions: [String] = [],
                      requirePrefix: String? = nil, limit: Int = 200) async -> [String] {
        let lines = await shellLines(cmd)
        var out: [String] = []
        var seen = Set<String>()
        for raw in lines {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if let prefix = requirePrefix, !p.hasPrefix(prefix) { continue }
            let lower = p.lowercased()
            if exclusions.contains(where: { lower.contains($0) }) { continue }
            guard seen.insert(p).inserted else { continue }
            out.append(p)
            if out.count >= limit { break }
        }
        return out
    }

    /// `du -sk` 量单个路径，返回字节
    private func pathSize(_ path: String) async -> Int64 {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        let lines = await shellLines("du -sk \"\(escaped)\" 2>/dev/null")
        guard let first = lines.first else { return 0 }
        let kbStr = first.split(separator: "\t").first
            .map(String.init)?
            .split(separator: " ").first.map(String.init) ?? ""
        return (Int64(kbStr) ?? 0) * 1024
    }

    // MARK: - 已安装包 / 残留

    private func queryInstalledPackages() async -> Set<String> {
        let lines = await shellLines("pm list packages 2>/dev/null")
        var set = Set<String>()
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("package:") else { continue }
            set.insert(String(t.dropFirst("package:".count)))
        }
        return set
    }

    private func isValidPackageName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return Self.packageRegex.firstMatch(in: name, range: range) != nil
    }

    /// corpse 检测：遍历三个根目录，找不在已安装列表里的包名目录
    private func scanCorpses(installed: Set<String>) async -> [Corpse] {
        guard !installed.isEmpty else { return [] }
        var out: [Corpse] = []

        for (locationType, root) in Self.corpseRoots {
            let lines = await shellLines(
                "find \"\(root)\" -mindepth 1 -maxdepth 1 -type d 2>/dev/null"
            )
            var seen = Set<String>()
            var candidates: [String] = []
            for l in lines {
                let p = l.trimmingCharacters(in: .whitespaces)
                guard p.hasPrefix("\(root)/") else { continue }
                let pkg = (p as NSString).lastPathComponent
                guard isValidPackageName(pkg) else { continue }
                guard !installed.contains(pkg) else { continue }
                guard seen.insert(p).inserted else { continue }
                candidates.append(p)
                if candidates.count >= 200 { break }
            }

            for path in candidates {
                let size = await pathSize(path)
                out.append(Corpse(
                    packageName: (path as NSString).lastPathComponent,
                    path: path,
                    locationType: locationType,
                    sizeBytes: size
                ))
            }
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// 大文件：du 找 /sdcard 下超过 200MB 的文件
    private func scanLargeFiles() async -> [LargeFile] {
        // -a 让 du 也输出文件；按大小降序取前 40 个
        let lines = await shellLines(
            "du -ak /sdcard 2>/dev/null | sort -rn | head -400"
        )
        var out: [LargeFile] = []
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            guard let kb = Int64(parts[0]), kb >= Self.largeFileThresholdKB else { continue }
            let path = parts[1]
            // 只保留文件，排除目录本身（du -a 会给目录也算一条）
            guard path.contains(".") else { continue }
            out.append(LargeFile(path: path, sizeBytes: kb * 1024))
            if out.count >= 40 { break }
        }
        return out
    }

    // MARK: - 存储概览

    private func loadStorageSummary() async {
        let lines = await shellLines(
            "df -k /sdcard 2>/dev/null || df -k /storage/emulated/0 2>/dev/null"
        )
        // 找含 /sdcard 或 /storage/emulated/0 的行，退而取最后一行
        var target = lines.last { $0.contains("/sdcard") || $0.contains("/storage/emulated/0") }
        if target == nil { target = lines.last }
        guard let line = target else { return }

        let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard cols.count >= 4,
              let total = Double(cols[1]),
              let used = Double(cols[2]) else { return }

        func fmt(_ kb: Double) -> String {
            kb >= 1048576 ? String(format: "%.1f GB", kb / 1048576)
                          : String(format: "%.0f MB", kb / 1024)
        }
        storageSummary = "已用 \(fmt(used)) / 共 \(fmt(total))"
    }

    // MARK: - 清理

    /// 清理选中的路径。返回实际释放字节数（du 复核后）
    func clean(paths: Set<String>) async -> Int64 {
        guard !paths.isEmpty else { return 0 }
        cleaning = true
        errorMessage = nil
        defer { cleaning = false }

        if isDemo {
            var reclaimed: Int64 = 0
            for p in paths {
                if let s = suggestions.first(where: { $0.targets.contains { $0.path == p } }),
                   let t = s.targets.first(where: { $0.path == p }) {
                    reclaimed += t.sizeBytes
                } else if let c = corpses.first(where: { $0.path == p }) {
                    reclaimed += c.sizeBytes
                } else if let f = largeFiles.first(where: { $0.path == p }) {
                    reclaimed += f.sizeBytes
                }
            }
            suggestions = suggestions.compactMap { s in
                var s2 = s
                s2.targets.removeAll { paths.contains($0.path) }
                return s2.targets.isEmpty ? nil : s2
            }
            corpses.removeAll { paths.contains($0.path) }
            largeFiles.removeAll { paths.contains($0.path) }
            freedBytes += reclaimed
            return reclaimed
        }

        var reclaimed: Int64 = 0
        for p in paths {
            let before = await pathSize(p)
            let escaped = p.replacingOccurrences(of: "\"", with: "\\\"")
            _ = await shellLines("rm -rf \"\(escaped)\" 2>&1")

            // 复核：真的删掉了吗
            let check = await shellLines("ls -d \"\(escaped)\" 2>/dev/null")
            let stillExists = check.contains { $0.contains(p) }
            if stillExists {
                errorMessage = "\(p) 删除失败（权限不足或只读）"
                continue
            }
            reclaimed += before
        }

        freedBytes += reclaimed

        // 从界面移除已清理项，并刷新概览
        suggestions = suggestions.compactMap { s in
            var s2 = s
            s2.targets.removeAll { paths.contains($0.path) }
            return s2.targets.isEmpty ? nil : s2
        }
        corpses.removeAll { paths.contains($0.path) }
        largeFiles.removeAll { paths.contains($0.path) }
        await loadStorageSummary()

        return reclaimed
    }

    // MARK: - 基础

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }

    // MARK: - 演示

    private func loadDemo() {
        storageSummary = "已用 13.9 GB / 共 32.0 GB"

        suggestions = [
            Suggestion(
                id: "thumbnails", title: "缩略图缓存",
                detail: "路径含 .thumbnails 的目录，图片应用重建后会自动再生成",
                source: "sdmaid:ThumbnailsFilter",
                targets: [
                    Target(path: "/sdcard/DCIM/.thumbnails", sizeBytes: 64 * 1048576),
                    Target(path: "/sdcard/Pictures/.thumbnails", sizeBytes: 18 * 1048576),
                ]
            ),
            Suggestion(
                id: "superfluous_apks", title: "多余安装包",
                detail: "*.apk *.apks，已排除 Backup / Recovery / TWRP 目录",
                source: "sdmaid:SuperfluousApksFilter",
                targets: [
                    Target(path: "/sdcard/Download/lingfen-toolbox.apk", sizeBytes: 18 * 1048576),
                    Target(path: "/sdcard/Download/voice-pack-v3.apk", sizeBytes: 46 * 1048576),
                    Target(path: "/sdcard/Download/navi_6.5.0.apk", sizeBytes: 128 * 1048576),
                ]
            ),
            Suggestion(
                id: "log_files", title: "日志文件",
                detail: "*.log，排除了索引数据库内的日志",
                source: "sdmaid:LogFilesFilter",
                targets: [
                    Target(path: "/sdcard/update.log", sizeBytes: 128 * 1024),
                    Target(path: "/sdcard/Download/install.log", sizeBytes: 42 * 1024),
                ]
            ),
            Suggestion(
                id: "mac_files", title: "macOS 残留",
                detail: "._* .Trashes .DS_Store .fseventsd .TemporaryItems",
                source: "sdmaid:MacFilesFilter",
                targets: [
                    Target(path: "/sdcard/.DS_Store", sizeBytes: 6 * 1024),
                    Target(path: "/sdcard/Download/.DS_Store", sizeBytes: 6 * 1024),
                ]
            ),
        ]

        corpses = [
            Corpse(packageName: "com.tencent.qqmusic", path: "/sdcard/Android/data/com.tencent.qqmusic",
                   locationType: "共享数据目录", sizeBytes: 412 * 1048576),
            Corpse(packageName: "com.baidu.map", path: "/sdcard/Android/data/com.baidu.map",
                   locationType: "共享数据目录", sizeBytes: 286 * 1048576),
            Corpse(packageName: "com.old.games", path: "/sdcard/Android/obb/com.old.games",
                   locationType: "OBB 目录", sizeBytes: 1204 * 1048576),
        ]

        largeFiles = [
            LargeFile(path: "/sdcard/Download/未命名录制.mp4", sizeBytes: 862 * 1048576),
            LargeFile(path: "/sdcard/Movies/old_trip.mp4", sizeBytes: 2140 * 1048576),
        ]

        errorMessage = nil
    }
}
