import Combine
import Foundation

/// 一条最近动态
///
/// 原版 Android 没有这个区块，是本版 iOS 新增的：把「最近操作」和
/// 「连接历史」合并成一条时间线，首页一眼能看到刚才干了什么。
struct RecentItem: Identifiable, Codable, Equatable {

    enum Kind: String, Codable {
        case connect
        case screenshot
        case record
        case install
        case file
        case clean
        case link
        case shell
        case other

        /// SF Symbol 名
        var icon: String {
            switch self {
            case .connect: return "link"
            case .screenshot: return "camera.fill"
            case .record: return "record.circle"
            case .install: return "square.grid.2x2.fill"
            case .file: return "doc.fill"
            case .clean: return "trash.fill"
            case .link: return "bolt.horizontal.fill"
            case .shell: return "terminal.fill"
            case .other: return "clock.fill"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let date: Date

    init(kind: Kind, title: String, detail: String = "", date: Date = Date()) {
        self.id = "\(kind.rawValue)-\(date.timeIntervalSince1970)-\(UUID().uuidString.prefix(6))"
        self.kind = kind
        self.title = title
        self.detail = detail
        self.date = date
    }

    /// 相对时间一行：刚刚 / 09:20 / 昨天 21:12
    var timeText: String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")

        if cal.isDateInToday(date) {
            let minutes = Date().timeIntervalSince(date) / 60
            if minutes < 1 { return "刚刚" }
            if minutes < 60 { return "\(Int(minutes)) 分钟前" }
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            f.dateFormat = "HH:mm"
            return "昨天 \(f.string(from: date))"
        }
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// 最近动态存储（UserDefaults 持久化，最多 30 条）
final class RecentStore: ObservableObject {

    static let shared = RecentStore()

    @Published private(set) var items: [RecentItem] = []

    private let storageKey = "recent.items"
    private let limit = 30

    private init() {
        load()
    }

    /// 记一条。同一标题 30 秒内重复出现时只更新最后一条，避免刷屏。
    func record(_ kind: RecentItem.Kind, title: String, detail: String = "") {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.record(kind, title: title, detail: detail) }
            return
        }
        if let last = items.first,
           last.kind == kind,
           last.title == title,
           Date().timeIntervalSince(last.date) < 30 {
            items[0] = RecentItem(kind: kind, title: title, detail: detail)
            save()
            return
        }

        items.insert(RecentItem(kind: kind, title: title, detail: detail), at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        save()
    }

    func clear() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.clear() }
            return
        }
        items.removeAll()
        save()
    }

    // MARK: - 落盘

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RecentItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
