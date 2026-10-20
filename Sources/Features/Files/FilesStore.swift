import Foundation

/// 文件管理数据层
///
/// 全部走 adb 命令，不自己实现 file_sync 协议：
///   列目录  `ls -la <path>`（解析权限/大小/时间/名称）
///   下载    `pull <远程> <本地绝对路径>`
///   上传    `push <本地绝对路径> <远程>`
///   删除    `rm -rf <path>`
///   改名    `mv <旧> <新>`
///
/// 关键约束：libadb 的 `pull` 默认目标是 `"."`（相对 cwd），
/// iOS 进程 cwd 是 `/`，不可写，会直接失败。
/// 所以**必须显式传绝对路径**，统一落到 Documents/pulled 下。
@MainActor
final class FilesStore: ObservableObject {

    struct Entry: Identifiable, Hashable {
        let name: String
        let path: String
        let isDir: Bool
        let sizeBytes: Int64
        let permissions: String
        let dateText: String

        var id: String { path }

        var sizeText: String {
            if isDir { return "—" }
            let b = Double(sizeBytes)
            if b >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", b / 1073741824) }
            if b >= 1024 * 1024 { return String(format: "%.1f MB", b / 1048576) }
            if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
            return "\(sizeBytes) B"
        }

        /// 常见文件类型的 SF Symbol
        var iconName: String {
            if isDir { return "folder.fill" }
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "apk": return "shippingbox.fill"
            case "png", "jpg", "jpeg", "webp", "gif": return "photo.fill"
            case "mp4", "mkv", "avi", "mov": return "film.fill"
            case "mp3", "wav", "ogg", "flac": return "music.note"
            case "zip", "tar", "gz", "7z", "rar": return "archivebox.fill"
            case "txt", "log", "json", "xml", "conf", "ini": return "doc.text.fill"
            case "sh", "rc": return "terminal.fill"
            default: return "doc.fill"
            }
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var currentPath: String = "/sdcard"
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var busyMessage: String?
    /// 已下载到本机的文件，供分享/预览
    @Published private(set) var lastPulledLocalPath: String?

    /// 排序方式（原版 SortOrder）
    enum SortOrder: String, CaseIterable, Identifiable {
        case name, type, time, size
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "按名称"
            case .type: return "按类型"
            case .time: return "按时间"
            case .size: return "按大小"
            }
        }
    }

    @Published var sortOrder: SortOrder = .name
    @Published var showHidden = false

    /// 界面实际渲染的列表：先过滤隐藏文件，再排序
    var displayEntries: [Entry] {
        var list = entries
        if !showHidden {
            list = list.filter { !$0.name.hasPrefix(".") }
        }
        return list.sorted { a, b in
            // 目录永远在前
            if a.isDir != b.isDir { return a.isDir }
            switch sortOrder {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .type:
                let ea = (a.name as NSString).pathExtension.lowercased()
                let eb = (b.name as NSString).pathExtension.lowercased()
                return ea < eb
            case .time:
                return a.dateText > b.dateText
            case .size:
                return a.sizeBytes > b.sizeBytes
            }
        }
    }

    /// 剪贴板里待粘贴的条目（原版 clipboardFile）
    @Published private(set) var clipboardEntry: Entry?
    /// 剪贴板是剪切模式还是复制模式（原版 isCutMode）
    @Published private(set) var clipboardIsCut = false

    /// 浏览历史，用于返回上级
    private(set) var history: [String] = []

    var isDemo = false
    private let adb = AdbService.shared

    func bind(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - 本机落地目录

    /// libadb 写文件的目录。必须存在且可写。
    static func localPullDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pulled", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 列目录

    func load(path: String? = nil) async {
        let target = path ?? currentPath
        loading = true
        errorMessage = nil
        defer { loading = false }

        if isDemo {
            applyDemo(path: target)
            return
        }

        // ls -la 给权限/大小/时间，比 ls -l 多隐藏文件
        let lines = await shellLines("ls -la '\(target)' 2>&1")
        let parsed = parseLS(lines, parent: target)

        if parsed.isEmpty {
            let joined = lines.joined(separator: " ").lowercased()
            if joined.contains("permission denied") {
                errorMessage = "没有权限访问 \(target)"
            } else if joined.contains("no such file") {
                errorMessage = "路径不存在：\(target)"
            } else {
                errorMessage = "读不到目录内容"
            }
            entries = []
            return
        }

        entries = parsed
        if target != currentPath {
            history.append(currentPath)
        }
        currentPath = target
    }

    func goUp() async {
        guard let prev = history.popLast() else {
            // 没有历史：手动退一级
            let parent = (currentPath as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == "/" { return }
            await load(path: parent)
            history.removeLast()
            return
        }
        await load(path: prev)
        history.removeLast()
    }

    // MARK: - ls -la 解析

    /// 典型输出：
    /// drwxrwx--x  4 root sdcard_rw  4096 2026-10-20 01:23 Android
    /// -rw-rw----  1 root sdcard_rw 4120000 2026-10-19 20:01 bootanimation.zip
    /// lrwxrwxrwx  1 root root           8 2026-10-01 10:00 sdcard -> /storage/self/primary
    private func parseLS(_ lines: [String], parent: String) -> [Entry] {
        var out: [Entry] = []
        let parentPath = parent.hasSuffix("/") ? String(parent.dropLast()) : parent

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            // 跳过 total 汇总行与错误行
            if t.hasPrefix("total ") { continue }
            if t.lowercased().contains("permission denied") { continue }

            let cols = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 7 else { continue }

            let perms = cols[0]
            guard let first = perms.first, "dl-cbps".contains(first) else { continue }

            let isLink = first == "l"
            // 对齐原版 parseRemoteFileLine：符号链接也当作目录。
            // 它本身是另一个路径的入口，应该能点进去。
            let isDir = first == "d" || isLink
            let size = Int64(cols[4]) ?? 0
            let dateText = "\(cols[5]) \(cols[6])"
            // 名称可能含空格，从第 8 列起全部拼回
            var name = cols.count > 7
                ? cols[7...].joined(separator: " ")
                : ""
            guard !name.isEmpty else { continue }

            // 跳过 . 与 ..
            if name == "." || name == ".." { continue }

            // 符号链接：名称形如 "sdcard -> /storage/..."
            if isLink, let arrow = name.range(of: " -> ") {
                name = String(name[name.startIndex..<arrow.lowerBound])
            }

            let fullPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
            out.append(Entry(
                name: name,
                path: fullPath,
                isDir: isDir,
                sizeBytes: size,
                permissions: perms,
                dateText: dateText
            ))
        }

        // 目录在前，同类按名称排序
        return out.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - 下载

    /// 下载远程文件到本机 Documents/pulled。
    /// 返回本机绝对路径。
    func pull(_ entry: Entry) async -> String? {
        guard !entry.isDir else {
            errorMessage = "目录暂不支持整体下载，请进入后逐个下载"
            return nil
        }
        busyMessage = "下载 \(entry.name)…"
        defer { busyMessage = nil }

        if isDemo {
            // 演示：生成一个占位文件
            let dir = Self.localPullDirectory()
            let dest = dir.appendingPathComponent(entry.name)
            let payload = "演示文件：\(entry.name)\n来自 \(entry.path)\n"
            try? payload.data(using: .utf8)?.write(to: dest)
            lastPulledLocalPath = dest.path
            return dest.path
        }

        // 关键：必须给绝对路径。默认 "." 在 iOS 上不可写。
        let dir = Self.localPullDirectory()
        let dest = dir.appendingPathComponent(entry.name)
        // 已存在同名文件时 pull 会追加 .1 后缀，先删掉避免歧义
        try? FileManager.default.removeItem(at: dest)

        let result = await runCommand(["pull", entry.path, dest.path])
        let text = result.output

        if FileManager.default.fileExists(atPath: dest.path) {
            lastPulledLocalPath = dest.path
            return dest.path
        }

        // 有时 adb 会把文件写到 "dest.1"
        let alt = dest.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: alt.path) {
            try? FileManager.default.moveItem(at: alt, to: dest)
            lastPulledLocalPath = dest.path
            return dest.path
        }

        errorMessage = text.isEmpty
            ? "下载失败：无回执（目标 \(dest.path)）"
            : "下载失败：\(text)"
        return nil
    }

    // MARK: - 上传

    /// 把本机文件推到远程目录
    func push(localPath: String, toRemoteDir remoteDir: String, fileName: String) async -> Bool {
        busyMessage = "上传 \(fileName)…"
        defer { busyMessage = nil }

        if isDemo {
            await loadDemoAfterChange()
            return true
        }

        let remote = remoteDir.hasSuffix("/") ? "\(remoteDir)\(fileName)" : "\(remoteDir)/\(fileName)"
        let result = await runCommand(["push", localPath, remote])
        let text = result.output

        if text.lowercased().contains("error") || text.lowercased().contains("failed") {
            errorMessage = "上传失败：\(text)"
            return false
        }

        // 原版 FileManagerScreen.kt:584 —— push 后按本机文件的权限位 chmod 远程。
        // 从「文件」App 选来的文件常是 0600，不改权限车机上别的 App 读不到。
        if let mode = Self.posixMode(of: localPath) {
            _ = await shellLines("chmod \(mode) '\(remote)' 2>&1")
        }

        await load()
        return true
    }

    /// 读本机文件的 POSIX 权限位，转成 chmod 用的八进制字符串
    private static func posixMode(of path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perm = attrs[.posixPermissions] as? NSNumber else { return nil }
        return String(format: "%03o", perm.intValue & 0o777)
    }

    // MARK: - 删除

    func delete(_ entry: Entry) async -> Bool {
        if isDemo {
            entries.removeAll { $0.path == entry.path }
            return true
        }
        let lines = await shellLines("rm -rf '\(entry.path)' 2>&1")
        let text = lines.joined(separator: " ").lowercased()
        if text.contains("denied") || text.contains("read-only") {
            errorMessage = "删除失败：\(lines.joined(separator: " "))"
            return false
        }
        await load()
        return true
    }

    // MARK: - 改名

    func rename(_ entry: Entry, to newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return false }
        // 名称里不允许出现路径分隔符
        guard !trimmed.contains("/") else {
            errorMessage = "名称不能包含 /"
            return false
        }

        let parent = (entry.path as NSString).deletingLastPathComponent
        let newPath = "\(parent)/\(trimmed)"

        if isDemo {
            if let i = entries.firstIndex(where: { $0.path == entry.path }) {
                let old = entries[i]
                entries[i] = Entry(
                    name: trimmed, path: newPath, isDir: old.isDir,
                    sizeBytes: old.sizeBytes, permissions: old.permissions,
                    dateText: old.dateText
                )
            }
            return true
        }

        let lines = await shellLines("mv '\(entry.path)' '\(newPath)' 2>&1")
        let text = lines.joined(separator: " ").lowercased()
        if text.contains("denied") || text.contains("failed") {
            errorMessage = "改名失败：\(lines.joined(separator: " "))"
            return false
        }
        await load()
        return true
    }

    // MARK: - 复制 / 剪切 / 粘贴（原版 runPaste）

    /// 把条目放进剪贴板。cut=true 是剪切，false 是复制。
    func setClipboard(_ entry: Entry, cut: Bool) {
        clipboardEntry = entry
        clipboardIsCut = cut
    }

    func clearClipboard() {
        clipboardEntry = nil
        clipboardIsCut = false
    }

    /// 粘贴到当前目录。剪切用 mv，复制用 cp -r。
    func paste() async -> Bool {
        guard let source = clipboardEntry else {
            errorMessage = "剪贴板是空的"
            return false
        }

        let dest = currentPath.hasSuffix("/")
            ? "\(currentPath)\(source.name)"
            : "\(currentPath)/\(source.name)"

        guard dest != source.path else {
            errorMessage = "源和目标是同一个位置"
            return false
        }

        if isDemo {
            if clipboardIsCut {
                entries.removeAll { $0.path == source.path }
                clipboardEntry = nil
            }
            if !entries.contains(where: { $0.path == dest }) {
                entries.insert(Entry(
                    name: source.name, path: dest, isDir: source.isDir,
                    sizeBytes: source.sizeBytes, permissions: source.permissions,
                    dateText: "刚刚"
                ), at: 0)
            }
            return true
        }

        busyMessage = clipboardIsCut ? "正在移动…" : "正在复制…"
        defer { busyMessage = nil }

        // 原版就是这么写的：不带 -p 保留属性，目录靠 -r 递归
        let cmd = clipboardIsCut
            ? "mv \"\(source.path)\" \"\(dest)\" 2>&1"
            : "cp -r \"\(source.path)\" \"\(dest)\" 2>&1"

        let lines = await shellLines(cmd)
        let text = lines.joined(separator: " ").lowercased()

        // cp / mv 成功时通常无输出；有输出基本都是错误
        if text.contains("denied") || text.contains("read-only")
            || text.contains("no such") || text.contains("failed")
            || text.contains("not permitted") || text.contains("cross-device") {
            errorMessage = (clipboardIsCut ? "移动失败：" : "复制失败：")
                + lines.joined(separator: " ")
            return false
        }

        if clipboardIsCut { clearClipboard() }
        await load()
        return true
    }

    /// 新建空文件（原版 createType = "file"）
    func createFile(named name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return false }
        let target = currentPath.hasSuffix("/")
            ? "\(currentPath)\(trimmed)"
            : "\(currentPath)/\(trimmed)"

        if isDemo {
            entries.insert(Entry(name: trimmed, path: target, isDir: false,
                                 sizeBytes: 0, permissions: "-rw-rw----",
                                 dateText: "刚刚"), at: 0)
            return true
        }

        let lines = await shellLines("touch '\(target)' 2>&1")
        let text = lines.joined(separator: " ").lowercased()
        if text.contains("denied") || text.contains("read-only") || text.contains("no such") {
            errorMessage = "新建文件失败：\(lines.joined(separator: " "))"
            return false
        }
        await load()
        return true
    }

    // MARK: - 新建文件夹

    func createFolder(named name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return false }
        let target = currentPath.hasSuffix("/")
            ? "\(currentPath)\(trimmed)"
            : "\(currentPath)/\(trimmed)"

        if isDemo {
            entries.insert(Entry(name: trimmed, path: target, isDir: true,
                                 sizeBytes: 0, permissions: "drwxrwx--x",
                                 dateText: "刚刚"), at: 0)
            return true
        }

        let lines = await shellLines("mkdir -p '\(target)' 2>&1")
        let text = lines.joined(separator: " ").lowercased()
        if text.contains("denied") || text.contains("read-only") {
            errorMessage = "新建失败：\(lines.joined(separator: " "))"
            return false
        }
        await load()
        return true
    }

    // MARK: - 基础

    private struct FilesCmdResult {
        let success: Bool
        let output: String
    }

    private func runCommand(_ args: [String]) async -> FilesCmdResult {
        await withCheckedContinuation { (cont: CheckedContinuation<FilesCmdResult, Never>) in
            adb.runAsync(args) { r in
                cont.resume(returning: FilesCmdResult(success: r.success, output: r.output))
            }
        }
    }

    private func shellLines(_ cmd: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(cmd) { cont.resume(returning: $0) }
        }
    }

    // MARK: - 演示数据

    private func applyDemo(path: String) {
        currentPath = path
        errorMessage = nil
        entries = DemoContent.makeFiles(path).map { f in
            Entry(
                name: f.name,
                path: path.hasSuffix("/") ? "\(path)\(f.name)" : "\(path)/\(f.name)",
                isDir: f.isDir,
                sizeBytes: Self.parseSize(f.size),
                permissions: f.isDir ? "drwxrwx--x" : "-rw-rw----",
                dateText: f.time
            )
        }
    }

    private func loadDemoAfterChange() async {
        applyDemo(path: currentPath)
    }

    static func parseSize(_ text: String) -> Int64 {
        let t = text.uppercased()
        func num(_ suffix: String, _ mult: Double) -> Int64? {
            guard let r = t.range(of: suffix) else { return nil }
            let head = String(t[t.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard let v = Double(head) else { return nil }
            return Int64(v * mult)
        }
        if let v = num("GB", 1073741824) { return v }
        if let v = num("MB", 1048576) { return v }
        if let v = num("KB", 1024) { return v }
        if let v = num(" B", 1) { return v }
        return Int64(t) ?? 0
    }
}
