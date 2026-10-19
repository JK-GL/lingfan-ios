import Foundation
import Network

/// 局域网设备发现
///
/// 对应 Android 版 `LanScanner.kt` 的三条并行路径：
///   1. 网段探测：本机 /24 × [5555, 5557]，单次超时 700ms
///   2. Bonjour：`_adb-tls-connect._tcp` / `_adb-tls-pairing._tcp` / `_lingfans-link._tcp`，5s 窗口
///   3. UDP 监听：18687 端口接菱粉自定义广播，2.5s 窗口
///
/// iOS 无需 Android 的 MulticastLock——那是为了对抗 Android 省电策略。
///
/// 并发设计（重要）：
///   全类不加 @MainActor。所有网络回调都在自己的队列上跑，
///   只有"把结果交出去"这一步用 DispatchQueue.main.async 切回主线程。
///   这样不需要在并发闭包里捕获 self，规避 Swift 5 严格并发检查的
///   "reference to captured var 'self'" 错误，也避免 508 次探测压主线程。
final class LanScanner {

    struct Found {
        let endpoint: String
        let name: String
        let isLingFans: Bool
        let source: Source

        enum Source: String {
            case probe5555 = "端口 5555"
            case probe5557 = "端口 5557"
            case bonjour = "Bonjour"
            case lingfansBroadcast = "菱粉广播"
        }
    }

    // 与原版 LanScanner.kt 保持一致的常量
    private static let socketTimeoutMS: Int = 700
    private static let bonjourWindow: TimeInterval = 5.0
    private static let broadcastWindow: TimeInterval = 2.5
    private static let broadcastPort: UInt16 = 18687
    private static let probePorts: [UInt16] = [5555, 5557]
    private static let serviceTypes = [
        "_adb-tls-connect._tcp",
        "_adb-tls-pairing._tcp",
        "_lingfans-link._tcp"
    ]

    private let queue = DispatchQueue(label: "com.lingfan.lanscan", qos: .utility)

    private var browsers: [NWBrowser] = []
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var stopped = false

    /// 主线程回调
    private var onFound: ((Found) -> Void)?
    /// 主线程去重表
    private var seen: Set<String> = []

    // 回调闭包声明成 nonisolated(unsafe) 没必要——本类无 actor 隔离，
    // 所有可变状态只在 queue 或 main 上访问，由下面的 emit 串行化。

    // MARK: - 生命周期

    func start(onFound: @escaping (Found) -> Void) {
        self.onFound = onFound
        self.seen = []
        self.stopped = false

        startBonjour()
        startBroadcastListener()

        if let prefix = Self.localIPv4Prefix() {
            startSubnetProbe(prefix: prefix)
        }
    }

    func stop() {
        stopped = true
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        onFound = nil
    }

    // MARK: - 结果汇聚（唯一的跨线程出口）

    /// 任意线程调用，内部切主线程去重后回调
    private func emit(_ found: Found) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            guard !self.seen.contains(found.endpoint) else { return }
            self.seen.insert(found.endpoint)
            self.onFound?(found)
        }
    }

    // MARK: - ① 网段探测

    /// 取本机 WiFi 的 IPv4 前 24 位，例如 "192.168.1."
    ///
    /// 直接用 sockaddr_in 取地址，不用 getnameinfo：
    /// 后者需要正确传 sa_len，而 ifa_addr 是 UnsafeMutablePointer<sockaddr>，
    /// 跨类型读长度容易踩坑；sockaddr_in 内存布局固定，更可靠。
    static func localIPv4Prefix() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var addr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = addr {
            defer { addr = current.pointee.ifa_next }

            guard let saRaw = current.pointee.ifa_addr else { continue }
            guard Int32(saRaw.pointee.sa_family) == AF_INET else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP else { continue }
            guard (flags & IFF_LOOPBACK) == 0 else { continue }

            let sin = saRaw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var raw = sin.sin_addr.s_addr
            let bytes = withUnsafeBytes(of: &raw) { Array($0) }
            let ip = "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"

            guard ip != "0.0.0.0", !ip.hasPrefix("169.254.") else { continue }

            if let lastDot = ip.lastIndex(of: ".") {
                return String(ip[ip.startIndex...lastDot])
            }
        }
        return nil
    }

    private func startSubnetProbe(prefix: String) {
        // 508 次探测跑在专用队列，不占主线程
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            for host in 1...254 {
                for port in Self.probePorts {
                    if self.stopped { return }
                    let endpoint = "\(prefix)\(host):\(port)"
                    self.probe(endpoint: endpoint, port: port)
                }
            }
        }
    }

    /// 单端口探测：只判断 TCP 能否建连，不发任何 ADB 数据
    private func probe(endpoint: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let hostPart = endpoint.split(separator: ":").first.map(String.init) ?? ""

        let conn = NWConnection(
            host: NWEndpoint.Host(hostPart),
            port: nwPort,
            using: .tcp
        )
        connections.append(conn)

        let timeout = DispatchWorkItem { conn.cancel() }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(Self.socketTimeoutMS),
            execute: timeout
        )

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                timeout.cancel()
                conn.cancel()
                self.emit(
                    Found(
                        endpoint: endpoint,
                        name: "ADB 设备",
                        isLingFans: false,
                        source: port == 5557 ? .probe5557 : .probe5555
                    )
                )
            case .failed, .cancelled:
                timeout.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    // MARK: - ② Bonjour

    private func startBonjour() {
        for type in Self.serviceTypes {
            let params = NWParameters()
            params.includePeerToPeer = true

            let browser = NWBrowser(
                for: .bonjour(type: type, domain: nil),
                using: params
            )

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    self.resolveBonjour(name: name, type: type, endpoint: result.endpoint)
                }
            }

            browser.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("[LanScanner] Bonjour \(type) 失败: \(error)")
                }
            }

            browser.start(queue: queue)
            browsers.append(browser)
        }

        // 到窗口时间统一收起
        queue.asyncAfter(deadline: .now() + Self.bonjourWindow) { [weak self] in
            guard let self else { return }
            self.browsers.forEach { $0.cancel() }
            self.browsers.removeAll()
        }
    }

    /// Bonjour 只给服务名，真实 IP 必须真连一次才能拿到。
    /// 用 NWConnection 连上后从 currentPath.remoteEndpoint 取 IPv4。
    private func resolveBonjour(name: String, type: String, endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connections.append(conn)

        let timeout = DispatchWorkItem { conn.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: timeout)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                timeout.cancel()

                var host = ""
                if let remote = conn.currentPath?.remoteEndpoint,
                   case let .hostPort(h, _) = remote {
                    host = "\(h)"
                    // IPv6 形如 fe80::1%en0，本地网络场景只取 IPv4
                    if host.contains(":") { host = "" }
                }
                conn.cancel()

                guard !host.isEmpty else { return }
                let isLingFans = type.contains("lingfans")
                let port = isLingFans ? 5557 : 5555
                self.emit(
                    Found(
                        endpoint: "\(host):\(port)",
                        name: name,
                        isLingFans: isLingFans,
                        source: .bonjour
                    )
                )
            case .failed, .cancelled:
                timeout.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    // MARK: - ③ 菱粉 UDP 广播

    private func startBroadcastListener() {
        guard let nwPort = NWEndpoint.Port(rawValue: Self.broadcastPort) else { return }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        guard let l = try? NWListener(using: params, on: nwPort) else {
            NSLog("[LanScanner] 无法监听 UDP \(Self.broadcastPort)")
            return
        }

        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            conn.receiveMessage { data, _, _, _ in
                guard let data, !data.isEmpty else { return }
                self.parseBroadcast(data)
                conn.cancel()
            }
            self.connections.append(conn)
        }

        l.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                NSLog("[LanScanner] UDP 监听失败: \(error)")
            }
        }

        l.start(queue: queue)
        listener = l

        queue.asyncAfter(deadline: .now() + Self.broadcastWindow) { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    /// 解析菱粉广播包。原版协议标识 `lf-link/1`。
    /// 包体形如：`lf-link/1\napp=lingfans\nip=192.168.1.30\nport=5557\nname=xxx`
    private func parseBroadcast(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        guard text.contains("lf-link/1") else { return }

        var ip = ""
        var port = "5557"
        var name = "菱粉设备"

        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "ip": ip = value
            case "port": port = value
            case "name": name = value
            default: break
            }
        }

        guard !ip.isEmpty else { return }
        emit(
            Found(
                endpoint: "\(ip):\(port)",
                name: name,
                isLingFans: true,
                source: .lingfansBroadcast
            )
        )
    }
}
