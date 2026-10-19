import Foundation
import SwiftUI

/// 控制台状态：设备属性 + 实时监控采样
@MainActor
final class ConsoleStore: ObservableObject {

    // MARK: - 设备属性

    @Published var displayName: String = ""
    @Published var serial: String = ""
    @Published var androidVersion: String = ""

    // MARK: - 实时监控

    @Published var cpuUsage: Double = 0
    @Published var temperature: Double = 0
    @Published var cpuSamples: [Double] = []
    @Published var tempSamples: [Double] = []

    @Published var memoryPercent: Double = 0
    @Published var memoryDetail: String = "--"
    @Published var storagePercent: Double = 0
    @Published var storageDetail: String = "--"

    // MARK: - 内部

    private var endpoint: String = ""
    private var isDemo = false
    private var monitorTask: Task<Void, Never>?
    private let adb = AdbService.shared

    private let maxSamples = 60

    func bind(device: DeviceRecord) {
        endpoint = device.endpoint
        displayName = device.name
        isDemo = device.isDemo
    }

    // MARK: - 监控循环

    func startMonitoring() async {
        stopMonitoring()

        if isDemo {
            startDemoLoop()
            return
        }

        // 首轮立刻读一次基础信息
        await refreshDeviceInfo()
        await tick()

        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 秒一轮
                if Task.isCancelled { break }
                await self.tick()
            }
        }
    }

    // MARK: - 演示模式

    /// 演示数据：全部本地生成，不触碰 libadb
    private func startDemoLoop() {
        displayName = "alps spm8666p2_64_car"
        serial = "DEMO0000000001"
        androidVersion = "9"

        // 预填一段曲线，进页面就有形状，不用等 3 秒
        var cpu: [Double] = []
        var temp: [Double] = []
        for i in 0..<40 {
            let base = 0.34 + 0.16 * sin(Double(i) / 5.0)
            let noise = Double(i % 7) * 0.012
            cpu.append(max(0.05, min(0.92, base + noise)))
            let t = 47.0 + 6.0 * sin(Double(i) / 8.0 + 1.2)
            temp.append(min(1, max(0, t / 100.0)))
        }
        cpuSamples = cpu
        tempSamples = temp
        cpuUsage = cpu.last ?? 0
        temperature = (temp.last ?? 0) * 100

        memoryPercent = 0.61
        memoryDetail = "2.4 GB / 3.9 GB"
        storagePercent = 0.43
        storageDetail = "13.9 GB / 32.0 GB"

        monitorTask = Task { [weak self] in
            guard let self else { return }
            var i = 40
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                let base = 0.34 + 0.16 * sin(Double(i) / 5.0)
                let noise = Double(i % 7) * 0.012
                let v = max(0.05, min(0.92, base + noise))
                let t = min(1, max(0, (47.0 + 6.0 * sin(Double(i) / 8.0 + 1.2)) / 100.0))
                self.cpuUsage = v
                self.temperature = t * 100
                self.pushSample(v, toCPU: true)
                self.pushSample(t, toCPU: false)
                let mem = 0.55 + 0.08 * sin(Double(i) / 11.0)
                self.memoryPercent = mem
                self.memoryDetail = String(format: "%.1f GB / 3.9 GB", mem * 3.9)
                i += 1
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// 单个采样周期
    private func tick() async {
        // CPU：读 /proc/stat 两次差值算占用率
        // 车机上 top 输出格式差异大，用 /proc/stat 更稳
        if let usage = await sampleCPU() {
            cpuUsage = usage
            appendSample(&cpuSamples, usage)
        }

        // 温度：优先 SoC thermal zone
        if let temp = await sampleTemperature() {
            temperature = temp
            // 温度按 0~100°C 归一化到 0~1 供图表使用
            appendSample(&tempSamples, min(1, temp / 100.0))
        }

        await refreshMemory()
        await refreshStorage()
    }

    private func appendSample(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > maxSamples {
            array.removeFirst(array.count - maxSamples)
        }
    }

    /// 只接收值、内部改属性。
    /// 不能用 appendSample(&cpuSamples, v) 的形式：
    /// inout 指向 self 的属性同时又通过 self 调方法，会触发
    /// "Overlapping accesses to 'self'" 编译错误。
    private func pushSample(_ value: Double, toCPU: Bool) {
        if toCPU {
            cpuSamples.append(value)
            if cpuSamples.count > maxSamples {
                cpuSamples.removeFirst(cpuSamples.count - maxSamples)
            }
        } else {
            tempSamples.append(value)
            if tempSamples.count > maxSamples {
                tempSamples.removeFirst(tempSamples.count - maxSamples)
            }
        }
    }

    // MARK: - CPU

    private var lastCPUTotal: Double = 0
    private var lastCPUIdle: Double = 0

    private func sampleCPU() async -> Double? {
        let lines = await shell("cat /proc/stat | head -1")
        guard let line = lines.first else { return nil }

        // 格式：cpu  user nice system idle iowait irq softirq steal ...
        let fields = line.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard fields.count >= 4 else { return nil }

        let idle = fields[3]
        let total = fields.reduce(0, +)

        defer {
            lastCPUTotal = total
            lastCPUIdle = idle
        }

        guard lastCPUTotal > 0 else { return 0 }
        let totalDelta = total - lastCPUTotal
        let idleDelta = idle - lastCPUIdle
        guard totalDelta > 0 else { return cpuUsage }

        return max(0, min(1, (totalDelta - idleDelta) / totalDelta))
    }

    // MARK: - 温度

    private func sampleTemperature() async -> Double? {
        // 常见路径按优先级尝试，车机 ROM 差异大
        let candidates = [
            "/sys/class/thermal/thermal_zone0/temp",
            "/sys/class/thermal/thermal_zone1/temp",
            "/sys/devices/virtual/thermal/thermal_zone0/temp"
        ]

        for path in candidates {
            let lines = await shell("cat \(path) 2>/dev/null")
            if let text = lines.first, let raw = Double(text.trimmingCharacters(in: .whitespaces)) {
                // 多数平台单位是 0.001°C，也有直接给 °C 的
                return raw > 1000 ? raw / 1000.0 : raw
            }
        }
        return nil
    }

    // MARK: - 内存

    private func refreshMemory() async {
        let lines = await shell("cat /proc/meminfo")
        var totalKB: Double = 0
        var availableKB: Double = 0

        for line in lines {
            if line.hasPrefix("MemTotal:") {
                totalKB = parseKB(line)
            } else if line.hasPrefix("MemAvailable:") {
                availableKB = parseKB(line)
            }
        }

        guard totalKB > 0 else { return }
        let used = totalKB - availableKB
        memoryPercent = max(0, min(1, used / totalKB))
        memoryDetail = "\(formatGB(used)) / \(formatGB(totalKB))"
    }

    private func parseKB(_ line: String) -> Double {
        let parts = line.split(separator: " ")
        for part in parts {
            if let v = Double(part) { return v }
        }
        return 0
    }

    private func formatGB(_ kb: Double) -> String {
        let gb = kb / 1024.0 / 1024.0
        return String(format: "%.1f GB", gb)
    }

    // MARK: - 存储

    private func refreshStorage() async {
        // df -k /data 输出第二行形如：
        // /dev/block/dm-2  236000000 9600000 226000000  5% /data
        let lines = await shell("df -k /data 2>/dev/null || df -k /sdcard")
        guard lines.count >= 2 else { return }

        let cols = lines[1].split(separator: " ").map(String.init)
        guard cols.count >= 4,
              let totalKB = Double(cols[1]),
              let usedKB = Double(cols[2]), totalKB > 0 else { return }

        storagePercent = max(0, min(1, usedKB / totalKB))
        storageDetail = "\(formatGB(usedKB)) / \(formatGB(totalKB))"
    }

    // MARK: - 设备信息

    private func refreshDeviceInfo() async {
        async let brand = shellValue("getprop ro.product.brand")
        async let model = shellValue("getprop ro.product.model")
        async let sn = shellValue("getprop ro.serialno")
        async let ver = shellValue("getprop ro.build.version.release")

        let b = await brand
        let m = await model
        serial = await sn
        androidVersion = await ver

        let name = [b, m].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty {
            displayName = name
        }
    }

    private func shellValue(_ command: String) async -> String {
        await shell(command).first ?? ""
    }

    private func shell(_ command: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            adb.shellLines(command) { lines in
                cont.resume(returning: lines)
            }
        }
    }

    // MARK: - 断开

    func disconnect() async {
        stopMonitoring()
        if isDemo { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            adb.disconnect(endpoint) { _ in
                cont.resume()
            }
        }
    }
}
