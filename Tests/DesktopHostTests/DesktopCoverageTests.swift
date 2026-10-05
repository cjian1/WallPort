import CoreGraphics
import Testing
@testable import DesktopHost

/// 桌面被窗口挡住了多少：几乎盖满时当作看不见，动态壁纸暂停
@Suite struct DesktopCoverageTests {
    /// 显示器去掉菜单栏和程序坞以后的区域（全局坐标，y 向下）
    let region = CGRect(x: 0, y: 25, width: 1512, height: 890)

    @Test func noWindowsMeansFullyVisible() {
        #expect(DesktopCoverage.uncoveredFraction(of: region, windows: []) == 1)
        // 别的显示器上的窗口不算
        #expect(DesktopCoverage.uncoveredFraction(of: region, windows: [CGRect(x: 2000, y: 0, width: 800, height: 600)]) == 1)
    }

    /// 窗口放大到铺满（系统的遮挡通知还当它"可见"，因为菜单栏后面透着一条桌面）
    @Test func maximizedWindowCoversTheDesktop() {
        let maximized = CGRect(x: 0, y: 25, width: 1512, height: 890)
        #expect(DesktopCoverage.uncoveredFraction(of: region, windows: [maximized]) == 0)
        // 左右并排、中间留一道缝：缝不算露出来
        let left = CGRect(x: 0, y: 25, width: 750, height: 890)
        let right = CGRect(x: 762, y: 25, width: 750, height: 890)
        #expect(DesktopCoverage.uncoveredFraction(of: region, windows: [left, right]) < DesktopCoverage.visibleThreshold)
    }

    /// 只盖住一半、或者留着一大块：照常播放
    @Test func partlyCoveredDesktopStaysVisible() {
        let half = CGRect(x: 0, y: 25, width: 756, height: 890)
        let fraction = DesktopCoverage.uncoveredFraction(of: region, windows: [half])
        #expect(abs(fraction - 0.5) < 0.05)
        let large = CGRect(x: 100, y: 100, width: 1200, height: 700)
        #expect(DesktopCoverage.uncoveredFraction(of: region, windows: [large]) > DesktopCoverage.visibleThreshold)
    }
}
