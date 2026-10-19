import Foundation
import Network

/// 局域网设备发现
///
/// 对应 Android 版 `LanScanner.kt` 的三条并行路径：
///   1. 网段探测：本机 /24 × [5555, 5557]，单次超时 700ms
///   2. Bonjour：`_adb-tls-connect._tcp` / `_adb-tls-pairing._tcp` / `_lingfans-link._tcp`，5s 窗口
///   3. UDP 监听：18687 端口接菱粉自定义广播，2.5s 窗口
///
/// iOS 无需 Android 的 MulticastLock——那是为了对抗 Android 省电策略，iOS 的 Bonjour 是系统级服务。
/// 首次使用会触发「本地网络」权限弹窗；用户拒绝后 Bonjour 与 UDP 都拿不到结果，
/// 只剩网段探测仍可工作（纯 TCP connect，不需要广播权限）。
@MainActor
final class LanScanner: ObservableObject {

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

    private var browsers: [NWBrowser] = []
    private var listener: NWListener?
    private var seen: Set<String> = []
    private var onFound: ((Found) -> Void)?

    /// 开始扫描。结果通过 onFound 增量回调，扫完自动停止。
    func start(onFound: @escaping (Found) -> Void) {
        stop()
        self.onFound = onFound
        seen.removeAll()

        startBonjour()
        startBroadcastListener()

        if let prefix = Self.localIPv4Prefix() {
            startSubnetProbe(prefix: prefix)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        listener?.cancel()
        listener = nil
        onFound = nil
    }

    // MARK: - ① 网段探测

    /// 取本机 WiFi 的 IPv4 前 24 位，例如 "192.168.1."
    ///
    /// 直接用 sockaddr_in 取地址，不用 getnameinfo：
    /// 后者需要正确传 sa_len，而 ifa_addr 是 UnsafeMutablePointer<sockaddr>，
    /// 在 Swift 里跨类型读长度容易踩坑；sockaddr_in 内存布局固定，更可靠。
    static func localIPv4Prefix() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var addr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = addr {
            defer { addr = current.pointee.ifa_next }

            guard let saRaw = current.pointee.ifa_addr else { continue }
            // sa_family 是 UInt8，AF_INET 是 Int32，必须统一到 Int32 再比
            guard Int32(saRaw.pointee.sa_family) == AF_INET else { continue }

            // 必须有 IFF_UP，且不能是回环
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP else { continue }
            guard (flags & IFF_LOOPBACK) == 0 else { continue }

            let sin = saRaw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            // sin_addr 是网络字节序
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
        // 508 次探测不能压在主线程上循环，整体丢到后台队列派发。
        // onFound 是 @MainActor 属性，必须在主线程取出来再传进闭包，
        // 否则后台队列访问会触发 actor 隔离编译错误。
        let cb = onFound
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for host in 1...254 {
                for port in Self.probePorts {
                    let endpoint = "\(prefix)\(host):\(port)"
                    self.probe(endpoint: endpoint, port: port, onFound: cb)
                }
            }
        }
    }

    /// 单端口探测：只判断 TCP 能否建连，不发任何 ADB 数据
    ///
    /// nonisolated：508 个 NWConnection 绝不能跑在主线程上创建。
    nonisolated private func probe(endpoint: String, port: UInt16,
                                   onFound: ((Found) -> Void)?) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let hostPart = endpoint.split(separator: ":").first.map(String.init) ?? ""

        let conn = NWConnection(
            host: NWEndpoint.Host(hostPart),
            port: nwPort,
            using: .tcp
        )

        let timeout = DispatchWorkItem { conn.cancel() }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(Self.socketTimeoutMS),
            execute: timeout
        )

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                timeout.cancel()
                conn.cancel()
                Task { @MainActor in
                    self?.emit(
                        Found(
                            endpoint: endpoint,
                            name: "ADB 设备",
                            isLingFans: false,
                            source: port == 5557 ? .probe5557 : .probe5555
                        ),
                        onFound: onFound
                    )
                }
            case .failed, .cancelled:
                timeout.cancel()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
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
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    Task { @MainActor in
                        self?.resolveBonjour(name: name, type: type, endpoint: result.endpoint)
                    }
                }
            }

            browser.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("[LanScanner] Bonjour \(type) 失败: \(error)")
                }
            }

            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)
        }

        // 到窗口时间统一收起
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.bonjourWindow) { [weak self] in
            Task { @MainActor in
                self?.browsers.forEach { $0.cancel() }
                self?.browsers.removeAll()
            }
        }
    }

    /// Bonjour 只给服务名，真实 IP 必须真连一次才能拿到。
    /// 这里用 NWConnection 到该服务，从 `.ready` 端点的 debugDescription 里解析出 IPv4。
    private func resolveBonjour(name: String, type: String, endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        var done = false

        let timeout = DispatchWorkItem {
            if !done { done = true; conn.cancel() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: timeout)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard !done else { return }
                done = true
                timeout.cancel()

                // currentPath 里能拿到远端地址
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
                Task { @MainActor in
                    self?.emit(
                        Found(
                            endpoint: "\(host):\(port)",
                            name: name,
                            isLingFans: isLingFans,
                            source: .bonjour
                        ),
                        onFound: self?.onFound
                    )
                }
            case .failed, .cancelled:
                if !done { done = true }
                timeout.cancel()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
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
            conn.start(queue: .global(qos: .utility))
            conn.receiveMessage { data, _, _, _ in
                guard let data, !data.isEmpty else { return }
                Task { @MainActor in
                    self?.parseBroadcast(data)
                }
                conn.cancel()
            }
        }

        l.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                NSLog("[LanScanner] UDP 监听失败: \(error)")
            }
        }

        l.start(queue: .global(qos: .utility))
        listener = l

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.broadcastWindow) { [weak self] in
            Task { @MainActor in
                self?.listener?.cancel()
                self?.listener = nil
            }
        }
    }

    /// 解析菱粉广播包。原版协议标识 `lf-link/1`。
    /// 包体是文本形式，形如：`lf-link/1\napp=lingfans\nip=192.168.1.30\nport=5557\nname=xxx`
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
            ),
            onFound: onFound
        )
    }

    // MARK: - 去重

    private func emit(_ found: Found, onFound: ((Found) -> Void)?) {
        guard let onFound else { return }
        // 按 endpoint 去重：同一台设备可能被三条路径都发现
        guard !seen.contains(found.endpoint) else { return }
        seen.insert(found.endpoint)
        onFound(found)
    }
}
