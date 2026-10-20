import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 演示数据生成器
///
/// 没有真机时，让每个功能页都能看到真实排版。
/// 所有内容本地生成，不读网络、不碰 libadb。
enum DemoContent {

    // MARK: - 截图

    /// 画一张假的车机界面截图，用于演示「截图」功能
    static func makeScreenshot() -> PlatformImage? {
        let size = CGSize(width: 1280, height: 720)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            drawCarUI(in: cg, size: size)
        }
        #elseif canImport(AppKit)
        let img = NSImage(size: size)
        img.lockFocus()
        if let cg = NSGraphicsContext.current?.cgContext {
            drawCarUI(in: cg, size: size)
        }
        img.unlockFocus()
        return img
        #else
        return nil
        #endif
    }

    #if canImport(UIKit) || canImport(AppKit)
    private static func drawCarUI(in cg: CGContext, size: CGSize) {
        // 深色车机底
        cg.setFillColor(CGColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: size))

        // 顶部状态条
        cg.setFillColor(CGColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1))
        cg.fill(CGRect(x: 0, y: size.height - 64, width: size.width, height: 64))

        // 左侧导航卡
        let side = CGRect(x: 32, y: 80, width: 260, height: size.height - 176)
        cg.setFillColor(CGColor(red: 0.11, green: 0.15, blue: 0.21, alpha: 1))
        cg.addPath(CGPath(roundedRect: side, cornerWidth: 24, cornerHeight: 24, transform: nil))
        cg.fillPath()

        // 中央地图/主区
        let main = CGRect(x: 320, y: 80, width: size.width - 352, height: size.height - 300)
        cg.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.17, alpha: 1))
        cg.addPath(CGPath(roundedRect: main, cornerWidth: 24, cornerHeight: 24, transform: nil))
        cg.fillPath()

        // 底部功能行：画 5 个圆角块
        let tileW: CGFloat = 150
        for i in 0..<5 {
            let x = 320 + CGFloat(i) * (tileW + 20)
            let r = CGRect(x: x, y: 40, width: tileW, height: 120)
            let hues: [(CGFloat, CGFloat, CGFloat)] = [
                (0.20, 0.44, 0.91), (0.15, 0.65, 0.60), (0.30, 0.69, 0.31),
                (0.61, 0.15, 0.69), (1.00, 0.60, 0.00),
            ]
            let c = hues[i % hues.count]
            cg.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.22))
            cg.addPath(CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil))
            cg.fillPath()
        }

        // 底部文字占位条
        cg.setFillColor(CGColor(red: 0.55, green: 0.60, blue: 0.68, alpha: 0.55))
        for i in 0..<6 {
            let y = size.height - 210 + CGFloat(i) * 22
            cg.fill(CGRect(x: 56, y: y, width: CGFloat(90 + (i % 3) * 50), height: 9))
        }
    }
    #endif

    // MARK: - 投屏演示帧

    /// 按相位画一帧「车机界面」，用于投屏演示。
    /// phase 递增时画面里的速度指针与进度条会动，看起来像在跑。
    static func makeMirrorFrame(phase: Double) -> PlatformImage? {
        let size = CGSize(width: 640, height: 360)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            drawMirrorFrame(in: ctx.cgContext, size: size, phase: phase)
        }
        #elseif canImport(AppKit)
        let img = NSImage(size: size)
        img.lockFocus()
        if let cg = NSGraphicsContext.current?.cgContext {
            drawMirrorFrame(in: cg, size: size, phase: phase)
        }
        img.unlockFocus()
        return img
        #else
        return nil
        #endif
    }

    #if canImport(UIKit) || canImport(AppKit)
    private static func drawMirrorFrame(in cg: CGContext, size: CGSize, phase: Double) {
        cg.setFillColor(CGColor(red: 0.04, green: 0.06, blue: 0.09, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: size))

        // 左侧导航条
        cg.setFillColor(CGColor(red: 0.09, green: 0.12, blue: 0.17, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: 92, height: size.height))

        // 中上方速度表盘
        let cx = size.width * 0.36
        let cy = size.height * 0.52
        cg.setStrokeColor(CGColor(red: 0.18, green: 0.24, blue: 0.33, alpha: 1))
        cg.setLineWidth(9)
        cg.addArc(center: CGPoint(x: cx, y: cy), radius: 68,
                  startAngle: .pi * 0.78, endAngle: .pi * 2.22, clockwise: false)
        cg.strokePath()

        // 速度指针
        let speed = 0.35 + 0.28 * sin(phase)
        let angle = Double.pi * 0.78 + (Double.pi * 1.44) * speed
        cg.setStrokeColor(CGColor(red: 0.29, green: 0.50, blue: 0.91, alpha: 1))
        cg.setLineWidth(4)
        cg.setLineCap(.round)
        cg.move(to: CGPoint(x: cx, y: cy))
        cg.addLine(to: CGPoint(x: cx + cos(angle) * 52, y: cy + sin(angle) * 52))
        cg.strokePath()

        // 右侧信息块
        for i in 0..<3 {
            let y = 58 + CGFloat(i) * 74
            cg.setFillColor(CGColor(red: 0.10, green: 0.14, blue: 0.20, alpha: 1))
            cg.addPath(CGPath(roundedRect: CGRect(x: size.width * 0.63, y: y, width: 190, height: 58),
                              cornerWidth: 12, cornerHeight: 12, transform: nil))
            cg.fillPath()

            // 内容条，随相位微微收缩，制造动态感
            let w = 150.0 * (0.72 + 0.16 * sin(phase + Double(i)))
            cg.setFillColor(CGColor(red: 0.32, green: 0.38, blue: 0.47, alpha: 0.8))
            cg.fill(CGRect(x: size.width * 0.63 + 14, y: y + 22, width: CGFloat(w), height: 7))
        }

        // 底部条
        cg.setFillColor(CGColor(red: 0.09, green: 0.12, blue: 0.17, alpha: 1))
        cg.fill(CGRect(x: 92, y: size.height - 46, width: size.width - 92, height: 46))

        // 时间指示点，随时间前进
        let dotX = 108 + CGFloat(fmod(phase * 40, Double(size.width - 140)))
        cg.setFillColor(CGColor(red: 0.29, green: 0.50, blue: 0.91, alpha: 1))
        cg.fillEllipse(in: CGRect(x: dotX, y: size.height - 30, width: 10, height: 10))
    }
    #endif

    // MARK: - 日志

    static func makeLog() -> String {
        let t = "10-20 01:23:"
        return """
        \(t)11.203  1420  1450 I ActivityManager: Start proc 8812:com.zzh.launcher50s/u0a64 for activity
        \(t)11.245  8812  8812 I Launcher: onCreate  version=2.14.3
        \(t)11.318  8812  8830 I Launcher: loadWidgets count=7
        \(t)11.402   245   312 W SurfaceFlinger: duplicate layer name: nav_bar
        \(t)11.510  8812  8830 I Launcher: applyTheme dark=true accent=#4A7FE8
        \(t)11.677  1420  1462 I ActivityManager: Start proc 8834:com.sgmw.keyless/u0a71
        \(t)11.701  8834  8834 I Keyless : BLE adapter ready, state=poweredOn
        \(t)11.744  8834  8850 I Keyless : scanning for vehicle...
        \(t)11.902  8834  8850 I Keyless : device found rssi=-58 name=SGMW-F610S
        \(t)12.010  8834  8850 I Keyless : connected, mtu=247
        \(t)12.233  1420  1440 I ActivityManager: Start proc 8851:com.sgmw.navi/u0a95
        \(t)12.301  8851  8851 I NaviApp : gps fix acquired, sats=11
        \(t)12.488   402   402 I logd    : logdr: UID=2000 GID=2000 PID=8862
        \(t)12.620  8812  8812 D Launcher: onTrimMemory level=20
        \(t)12.755  1420  1450 W ActivityManager: Slow operation: 128ms so far, now at startProcess
        \(t)12.890  8834  8850 I Keyless : unlock command sent, result=ok
        \(t)13.002  8812  8880 I Launcher: refresh weather, ttl=600s
        """
    }

    // MARK: - 文件树

    struct DemoFile: Identifiable {
        let id = UUID()
        let name: String
        let size: String
        let isDir: Bool
        let time: String
    }

    static func makeFiles(_ path: String) -> [DemoFile] {
        switch path {
        case "/sdcard":
            return [
                .init(name: "Android", size: "—", isDir: true, time: "10-18 09:12"),
                .init(name: "DCIM", size: "—", isDir: true, time: "10-20 01:10"),
                .init(name: "Download", size: "—", isDir: true, time: "10-19 22:04"),
                .init(name: "Movies", size: "—", isDir: true, time: "10-17 15:33"),
                .init(name: "Pictures", size: "—", isDir: true, time: "10-19 18:20"),
                .init(name: "bootanimation.zip", size: "4.2 MB", isDir: false, time: "10-19 20:01"),
                .init(name: "update.log", size: "128 KB", isDir: false, time: "10-20 00:58"),
            ]
        case "/sdcard/Download":
            return [
                .init(name: "lingfen-toolbox.apk", size: "18.4 MB", isDir: false, time: "10-19 21:40"),
                .init(name: "voice-pack-v3.zip", size: "46.1 MB", isDir: false, time: "10-18 14:22"),
                .init(name: "car-config.json", size: "3.1 KB", isDir: false, time: "10-19 22:04"),
            ]
        default:
            return [
                .init(name: "..", size: "—", isDir: true, time: ""),
                .init(name: "app", size: "—", isDir: true, time: "09-02 11:20"),
                .init(name: "data", size: "—", isDir: true, time: "10-20 01:05"),
                .init(name: "system", size: "—", isDir: true, time: "09-02 11:20"),
            ]
        }
    }

    // MARK: - App 列表

    struct DemoApp: Identifiable {
        let id = UUID()
        let package: String
        let label: String
        let version: String
        let isSystem: Bool
        let size: String
    }

    static func makeApps() -> [DemoApp] {
        [
            .init(package: "com.zzh.launcher50s", label: "菱粉桌面", version: "2.14.3", isSystem: true, size: "42.1 MB"),
            .init(package: "com.sgmw.keyless", label: "无感车控", version: "0.5.21.281", isSystem: false, size: "19.9 MB"),
            .init(package: "com.sgmw.navi", label: "高德车机版", version: "6.5.0", isSystem: false, size: "128 MB"),
            .init(package: "com.sgmw.carradio", label: "车载电台", version: "1.8.2", isSystem: true, size: "12.4 MB"),
            .init(package: "com.sgmw.voice", label: "语音助手", version: "3.2.1", isSystem: true, size: "36.7 MB"),
            .init(package: "com.android.settings", label: "设置", version: "9", isSystem: true, size: "24.0 MB"),
            .init(package: "com.android.systemui", label: "系统界面", version: "9", isSystem: true, size: "31.5 MB"),
        ]
    }

    // MARK: - 菱粉联动

    static func makeLauncherInfo() -> [(String, String)] {
        [
            ("桌面版本", "2.14.3"),
            ("协议版本", "alpha.link"),
            ("激活状态", "已激活"),
            ("天气 Key", "b2f****9c1"),
            ("语音定制", "3 项已启用"),
            ("图标定制", "12 个已替换"),
        ]
    }
}
