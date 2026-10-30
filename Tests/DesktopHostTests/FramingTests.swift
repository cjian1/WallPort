import CoreGraphics
import Testing
@testable import DesktopHost

/// 图片、视频、幻灯片共用的取景：铺满 / 完整显示，再等比缩放；超出屏幕的方向按位置选看哪部分，小于屏幕的方向居中
@Suite struct FramingTests {
    private let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let wide = CGSize(width: 200, height: 100)

    @Test func scaleOneMatchesFillAndFit() {
        #expect(Framing.frame(in: screen, content: wide, fitsWhole: false, position: 0.5)
            == CGRect(x: -50, y: 0, width: 200, height: 100))
        #expect(Framing.frame(in: screen, content: wide, fitsWhole: true, position: 0.5)
            == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    /// 铺满后再缩小：比屏幕窄的方向居中、四周留黑；比例不变
    @Test func zoomingOutCentersTheSmallerPicture() {
        let frame = Framing.frame(in: screen, content: wide, fitsWhole: false, position: 0, scale: 0.5)
        #expect(frame == CGRect(x: 0, y: 25, width: 100, height: 50))
        #expect(frame.width / frame.height == wide.width / wide.height)
    }

    /// 完整显示再放大：两个方向都超出屏幕，位置 0 露出左上、1 露出右下（y 向上，所以左上是 y 最小的负值）
    @Test func zoomingInPansWithPosition() {
        let topLeft = Framing.frame(in: screen, content: wide, fitsWhole: true, position: 0, scale: 2)
        #expect(topLeft == CGRect(x: 0, y: 0, width: 200, height: 100))
        let bottomRight = Framing.frame(in: screen, content: wide, fitsWhole: false, position: 1, scale: 1.5)
        #expect(bottomRight == CGRect(x: -200, y: 0, width: 300, height: 150))
        // 露出顶部：放大后的图上沿对齐屏幕上沿
        let top = Framing.frame(in: screen, content: wide, fitsWhole: false, position: 0, scale: 1.5)
        #expect(top.maxY == 100 && top.minY == -50)
    }

    @Test func scaleIsClampedAndEmptySizesFallBackToBounds() {
        #expect(Framing.frame(in: screen, content: wide, fitsWhole: false, position: 0.5, scale: 100)
            == Framing.frame(in: screen, content: wide, fitsWhole: false, position: 0.5, scale: 2))
        #expect(Framing.frame(in: screen, content: .zero, fitsWhole: false, position: 0.5) == screen)
    }
}
