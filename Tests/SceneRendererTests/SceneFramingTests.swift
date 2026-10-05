import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 按 scene.pkg 的结构把文件打成包
private func makePackage(_ files: [String: Data]) throws -> ScenePackage {
    var header = Data()
    func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
    u32(8)
    header += Data("PKGV0001".utf8)
    u32(files.count)
    var body = Data()
    for (name, data) in files.sorted(by: { $0.key < $1.key }) {
        u32(name.utf8.count)
        header += Data(name.utf8)
        u32(body.count)
        u32(data.count)
        body += data
    }
    return try ScenePackage(data: header + body)
}

/// 读出某个像素的 RGB（renderImage 的格式是 BGRX，小端）
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

/// 作者把画布留得比内容大（3681810302：画布 4000×2650、背景 4000×2508，顶上一条什么都没有）。
/// 取景只在屏幕比例真的会露出那条空边时才动，其余情况和 WE 的铺满裁切一模一样
@Suite struct SceneFramingTests {
    private let canvas = SIMD2<Float>(4000, 2650)
    private var fill: (min: SIMD2<Float>, max: SIMD2<Float>)? {
        SceneRenderer.fillBox(canvas: canvas, content: (size: SIMD2(4000, 2508), center: SIMD2(2000, 1254)))
    }

    @Test func fillBoxIsTheCoveredPartOfTheCanvas() throws {
        let box = try #require(fill)
        #expect(box.min == SIMD2(0, 0) && box.max == SIMD2(4000, 2508))
        // 内容比画布大（视差图层常见）：盖满了，不用管
        #expect(SceneRenderer.fillBox(canvas: canvas, content: (size: SIMD2(4400, 2900), center: canvas / 2)) == nil)
        // 内容只占一小块（时钟、单张小图）：不能为了不露边放大
        #expect(SceneRenderer.fillBox(canvas: canvas, content: (size: SIMD2(1000, 500), center: canvas / 2)) == nil)
        #expect(SceneRenderer.fillBox(canvas: canvas, content: nil) == nil)
    }

    /// 3024×1964（MacBook 屏，比画布"高"）：按铺满裁切会露出顶上 115 单位的空边 → 放大到刚好不露，贴着内容框
    @Test func tallerScreenZoomsJustEnoughToHideTheStrip() {
        let target = SIMD2<Float>(3024, 1964)
        let plain = SceneRenderer.framing(canvas: canvas, center: canvas / 2, fill: nil, target: target)
        #expect(plain.center.y + plain.visible.y / 2 > 2508)            // 原来确实露边
        let framed = SceneRenderer.framing(canvas: canvas, center: canvas / 2, fill: fill, target: target)
        #expect(abs(framed.visible.y - 2508) < 0.01)
        #expect(abs(framed.center.y - 1254) < 0.01)
        #expect(abs(framed.visible.x / framed.visible.y - target.x / target.y) < 1e-4)   // 比例不变形
    }

    /// 16:9 屏：铺满裁切本来就把顶上的空边切掉了，取景和原来一模一样（和 WE 一致）
    @Test func widerScreenKeepsTheOriginalFraming() {
        let target = SIMD2<Float>(3840, 2160)
        let plain = SceneRenderer.framing(canvas: canvas, center: canvas / 2, fill: nil, target: target)
        let framed = SceneRenderer.framing(canvas: canvas, center: canvas / 2, fill: fill, target: target)
        #expect(framed.visible == plain.visible && framed.center == plain.center)
    }

    /// 空边在屏幕外、只是取景中心离空边近：只平移，不放大
    @Test func shiftsBeforeZooming() {
        // 画布 1000×1000，内容 y 从 100 起；横屏（2:1）看到的是中间 500 高的一条（250…750），不露边
        let square = SIMD2<Float>(1000, 1000)
        let box = SceneRenderer.fillBox(canvas: square, content: (size: SIMD2(1000, 900), center: SIMD2(500, 550)))
        let wide = SceneRenderer.framing(canvas: square, center: square / 2, fill: box, target: SIMD2(2000, 1000))
        #expect(wide.visible == SIMD2(1000, 500) && wide.center == SIMD2(500, 500))
        // 竖屏（1:2）看到整个高度 → 会露出下面 100：放大
        let tall = SceneRenderer.framing(canvas: square, center: square / 2, fill: box, target: SIMD2(1000, 2000))
        #expect(abs(tall.visible.y - 900) < 0.01 && abs(tall.center.y - 550) < 0.01)
    }

    /// 壁纸设置里的"画面位置"：竖的画布放到横屏上只看得到中间一条，focus 选看最上面（0）还是最下面（1）；
    /// 没被裁的方向不动
    @Test func focusPicksWhichPartOfACroppedCanvasIsVisible() {
        let tall = SIMD2<Float>(100, 200)
        let target = SIMD2<Float>(200, 100)
        let middle = SceneRenderer.framing(canvas: tall, center: tall / 2, fill: nil, target: target)
        #expect(middle.visible == SIMD2(100, 50) && middle.center == SIMD2(50, 100))
        let top = SceneRenderer.framing(canvas: tall, center: tall / 2, fill: nil, target: target, focus: SIMD2(0.5, 0))
        #expect(top.center == SIMD2(50, 175))
        let bottom = SceneRenderer.framing(canvas: tall, center: tall / 2, fill: nil, target: target, focus: SIMD2(0.5, 1))
        #expect(bottom.center == SIMD2(50, 25))
        let sideways = SceneRenderer.framing(canvas: tall, center: tall / 2, fill: nil, target: target, focus: SIMD2(0, 0.5))
        #expect(sideways.center == middle.center, "左右没被裁，左右位置不起作用")
        let region = SceneRenderer.visibleRegion(canvas: tall, target: target, focus: SIMD2(0.5, 0))
        #expect(region.min == SIMD2(0, 150) && region.max == SIMD2(100, 200))
    }

    /// 真渲染：竖画布上半红、下半蓝，横屏上铺满。画面位置选最上面看到红，选最下面看到蓝
    @Test func renderedFocusShowsTheChosenEnd() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = """
            {"general": {"orthogonalprojection": {"width": 100, "height": 200}, "clearcolor": "0 0 0"},
             "objects": [{"id": 1, "image": "models/solid.json", "origin": "50 150 0", "size": "100 100", "color": "1 0 0"},
                         {"id": 2, "image": "models/solid.json", "origin": "50 50 0", "size": "100 100", "color": "0 0 1"}]}
            """
        let package = try makePackage([
            "scene.json": Data(scene.utf8), "models/solid.json": Data(#"{"solidlayer": true}"#.utf8),
        ])
        for (focus, red) in [(Float(0), true), (Float(1), false)] {
            let renderer = try SceneRenderer(
                device: device, package: package, assets: nil, targetSize: SIMD2(200, 100), focus: SIMD2(0.5, focus))
            let image = try renderer.renderImage(width: 200, height: 100)
            let color = pixel(image, 100, 50)
            #expect(red ? color[0] > 200 && color[2] < 40 : color[2] > 200 && color[0] < 40, "focus \(focus)：\(color)")
        }
    }

    /// 完整显示：场景视图按画布比例放在容器正中，两边留黑
    @Test func fitFrameKeepsTheCanvasAspect() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(SceneContainerView.contentFrame(in: bounds, aspect: nil) == bounds)
        let portrait = SceneContainerView.contentFrame(in: bounds, aspect: 4962.0 / 7016)
        #expect(portrait.height == 982 && abs(portrait.width - 694.5) <= 1 && abs(portrait.midX - 756) <= 1)
        let wide = SceneContainerView.contentFrame(in: bounds, aspect: 8192.0 / 3840)
        #expect(wide.width == 1512 && abs(wide.height - 709) < 1 && abs(wide.midY - 491) < 1)
    }

    /// 真渲染一遍：画布 100×54、红色图层只盖住下面 100×50，清屏色是灰。
    /// 屏幕和画布同比例时原来顶上 4 行是灰的，现在第一行就是红的
    @Test func renderedFrameHasNoClearColorStrip() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = """
            {"general": {"orthogonalprojection": {"width": 100, "height": 54}, "clearcolor": "0.5 0.5 0.5"},
             "objects": [{"id": 1, "image": "models/solid.json", "origin": "50 25 0", "size": "100 50", "color": "1 0 0"}]}
            """
        let renderer = try SceneRenderer(
            device: device,
            package: try makePackage([
                "scene.json": Data(scene.utf8), "models/solid.json": Data(#"{"solidlayer": true}"#.utf8),
            ]),
            assets: nil, targetSize: SIMD2(100, 54))
        let image = try renderer.renderImage(width: 100, height: 54)
        for x in [0, 50, 99] {
            let top = pixel(image, x, 0)
            #expect(top[0] > 200 && top[1] < 40 && top[2] < 40, "顶上第一行 x=\(x) 是 \(top)")
        }
    }
}
