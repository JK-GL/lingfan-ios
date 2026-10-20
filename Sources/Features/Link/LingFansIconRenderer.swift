import UIKit

/// 图标处理
///
/// 对齐原版 `LingFansIconBitmapUtils.kt`：
///   1. 解码时按目标尺寸采样，避免大图吃内存
///   2. 自动裁成正方形（居中取短边）
///   3. 需要圆角时套一层圆角遮罩，半径按「边长的百分比」算
///   4. 结果写成 PNG 缓存文件，交给 adb push
///
/// 原版还支持手动拖动/缩放裁剪框，这里做居中方形 + 可调圆角，
/// 覆盖了绝大多数车机图标的实际用法。
enum LingFansIconRenderer {

    /// 车机图标常见边长，原版按 512 处理
    static let outputSize: CGFloat = 512

    /// 读取并降采样到目标尺寸（等价原版 inSampleSize）
    static func loadDownsampled(path: String, maxSide: CGFloat = 1024) -> UIImage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let src = UIImage(data: data) else { return nil }

        let w = src.size.width, h = src.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxSide / max(w, h))
        if scale >= 1 { return src }

        let target = CGSize(width: floor(w * scale), height: floor(h * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            src.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 居中裁成正方形（原版 cropLingFansSquareBitmap）
    static func squareCrop(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        let side = min(w, h)
        let origin = CGPoint(x: (w - side) / 2, y: (h - side) / 2)

        guard let cg = image.cgImage else { return image }
        let scale = CGFloat(cg.width) / max(w, 1)
        let rect = CGRect(
            x: origin.x * scale, y: origin.y * scale,
            width: side * scale, height: side * scale
        )
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 套圆角遮罩（原版 applyLingFansRoundedMask）
    /// radiusFraction 是半径占边长的比例，原版限制在 0~0.5
    static func roundedMask(_ image: UIImage, radiusFraction: Double) -> UIImage {
        let f = min(max(radiusFraction, 0), 0.5)
        guard f > 0 else { return image }

        let side = outputSize
        let size = CGSize(width: side, height: side)
        let radius = side * CGFloat(f)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
            image.draw(in: rect)
        }
    }

    /// 完整处理：降采样 → 方形裁剪 → 缩放到输出尺寸 → 可选圆角
    static func render(path: String, rounded: Bool, radiusFraction: Double) -> UIImage? {
        guard let src = loadDownsampled(path: path) else { return nil }
        let squared = squareCrop(src)

        let side = outputSize
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            squared.draw(in: CGRect(origin: .zero, size: size))
        }

        return rounded ? roundedMask(scaled, radiusFraction: radiusFraction) : scaled
    }

    /// 写成 PNG 临时文件，返回绝对路径
    static func writePNG(_ image: UIImage, prefix: String = "lingfan_icon") -> String? {
        guard let data = image.pngData() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmssSSS"
        let name = "\(prefix)_\(formatter.string(from: Date())).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }
}
