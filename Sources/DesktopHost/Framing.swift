import CoreGraphics

/// 壁纸画面在屏幕上的位置（图片、视频、幻灯片共用）：铺满（按大的比例放大，多出来的裁掉）或完整显示
/// （按小的比例、比例不同的方向留黑边），再乘上等比缩放。超出屏幕的方向按 `position` 选看哪一部分
/// （0 最左 / 最上，1 最右 / 最下），比屏幕小的方向居中。坐标是 AppKit 视图坐标（原点左下、y 向上）
public enum Framing {
    /// 壁纸设置里"缩放"的范围：缩小到一半、放大到两倍
    public static let scaleRange: ClosedRange<Double> = 0.5...2

    public static func frame(
        in bounds: CGRect, content: CGSize, fitsWhole: Bool, position: CGFloat, scale: CGFloat = 1
    ) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let ratio = (bounds.width / content.width, bounds.height / content.height)
        let zoom = min(max(scale, CGFloat(scaleRange.lowerBound)), CGFloat(scaleRange.upperBound))
        let factor = (fitsWhole ? min(ratio.0, ratio.1) : max(ratio.0, ratio.1)) * zoom
        let size = CGSize(width: (content.width * factor).rounded(), height: (content.height * factor).rounded())
        let spare = CGSize(width: bounds.width - size.width, height: bounds.height - size.height)
        let along = min(max(position, 0), 1)
        let x = spare.width < 0 ? spare.width * along : spare.width / 2
        // y 轴向上：position 0 要露出顶部，纵向反着挪
        let y = spare.height < 0 ? spare.height * (1 - along) : spare.height / 2
        return CGRect(
            x: bounds.minX + x.rounded(), y: bounds.minY + y.rounded(), width: size.width, height: size.height)
    }
}
