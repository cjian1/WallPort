import CoreGraphics
import CoreText
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 系统自带字体，测试只读它，不进仓库
private let systemFont = URL(fileURLWithPath: "/System/Library/Fonts/Monaco.ttf")

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

/// 读出某一点的颜色（renderImage 的格式是 BGRX，小端）
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

/// 数一块区域里亮起来的像素（文字是白字，背景是黑的）
private func brightPixels(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> Int {
    var count = 0
    for row in y..<(y + height) {
        for column in x..<(x + width) where pixel(image, column, row).max()! > 100 { count += 1 }
    }
    return count
}

/// 语料里那种时钟脚本的写法（自己写的，不含 WE 内容）
private let clockScript = """
'use strict';
export var scriptProperties = createScriptProperties()
    .addCheckbox({ name: 'use24hFormat', value: true })
    .addText({ name: 'delimiter', value: ':' })
    .finish();

export function update(value) {
    const now = new Date();
    let hours = now.getHours();
    if (!scriptProperties.use24hFormat) {
        hours = hours % 12 || 12;
    }
    hours = ('0' + hours).slice(-2);
    const minutes = ('0' + now.getMinutes()).slice(-2);
    return hours + scriptProperties.delimiter + minutes;
}
"""

private func date(hour: Int, minute: Int, second: Int = 0) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 28
    components.hour = hour
    components.minute = minute
    components.second = second
    return Calendar.current.date(from: components)!
}

private func properties(_ text: String) -> Data { Data(text.utf8) }

@Suite struct TextScriptTests {
    @Test func clockScriptUsesTheCurrentTime() throws {
        let script = try #require(SceneScript(
            source: clockScript, properties: nil, environment: .init(), now: { date(hour: 15, minute: 5) }))
        #expect(script.updateText("00:00") == "15:05")
    }

    /// 场景里的用户属性覆盖脚本声明的默认值
    @Test func scriptPropertiesOverrideTheDefaults() throws {
        let script = try #require(SceneScript(
            source: clockScript, properties: properties(#"{"use24hFormat": false, "delimiter": "-"}"#),
            environment: .init(layerText: "00:00"), now: { date(hour: 15, minute: 5) }))
        #expect(script.updateText("00:00") == "03-05")
    }

    /// 有的脚本不返回值，而是直接写 thisLayer.text
    @Test func scriptMayWriteThisLayerText() throws {
        let source = "export function update(value) { thisLayer.text = '-' + (1 + 1) + '-'; }"
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        #expect(script.updateText("") == "-2-")
    }

    /// 死循环靠执行时限终止，而不是靠静态检查：刻意绕过关键字检查的写法也挡得住，
    /// 超时一次的脚本停用，之后不再白等
    @Test func infiniteLoopsAreTerminatedByTheTimeLimit() throws {
        try #require(SceneScript.hasTimeLimit)
        let start = Date()
        // 载入时就想死循环的脚本被时限终止：实例留着（带着原因），但什么都不做
        let stranded = try #require(SceneScript(source: "while (true) {}", properties: nil, environment: .init()))
        #expect(stranded.problem?.contains("载入失败") == true, "得到 \(stranded.problem ?? "nil")")
        #expect(stranded.updateText("") == nil)
        let disguised = """
        export function update(value) { (() => {}).constructor('wh' + 'ile (true) {}')(); return value; }
        """
        let script = try #require(SceneScript(source: disguised, properties: nil, environment: .init()))
        #expect(script.updateText("x") == nil)
        #expect(script.problem?.contains("停用") == true)
        #expect(script.updateText("x") == nil)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    /// 有了执行时限，正常的循环照样能跑；宿主没有网络之类的接口，调用它只会报错
    @Test func ordinaryLoopsRunAndHostHasNoNetwork() throws {
        try #require(SceneScript.hasTimeLimit)
        let loop = "export function update(value) { let s = ''; for (let i = 0; i < 3; i++) s += i; return s; }"
        #expect(try #require(SceneScript(source: loop, properties: nil, environment: .init())).updateText("") == "012")
        let network = try #require(SceneScript(
            source: "export function update() { return fetch('https://example.com'); }", properties: nil,
            environment: .init()))
        #expect(network.updateText("") == nil)
        #expect(network.problem != nil)
    }

    /// 取不到执行时限时退回的静态检查：注释里的循环不算
    @Test func fallbackStaticCheckIgnoresComments() {
        #expect(!SceneScript.isSafe("while (true) {}"))
        #expect(!SceneScript.isSafe("export function update(){ return eval('1'); }"))
        #expect(SceneScript.isSafe("/* for (;;) {} */\nexport function update(value) { return value + '!'; }"))
    }

    /// 脚本抛异常时返回 nil，让调用方退回编辑器里的静态文字
    @Test func failingScriptReturnsNil() throws {
        let source = "export function update(value) { return notDefinedAnywhere('x'); }"
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        #expect(script.updateText("静态") == nil)
        #expect(script.problem != nil)
    }
}

@Suite struct TextLayerTests {
    private func files() throws -> SceneFiles {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let font = try Data(contentsOf: systemFont)
        return SceneFiles(package: try makePackage(["scene.json": Data("{}".utf8), "Monaco.ttf": font]), assets: nil)
    }

    private func content(script: String? = nil, text: String = "88:88") -> SceneDescription.TextContent {
        SceneDescription.TextContent(
            font: "Monaco.ttf", pointSize: 20, boxSize: SIMD2(60, 30), horizontalAlign: "center",
            verticalAlign: "center", staticText: text, script: script, scriptProperties: nil)
    }

    /// 时钟：字符串变了才重新画贴图
    @Test func clockTextRebuildsWhenTheStringChanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = "export function update(value) { return String(new Date().getSeconds()); }"
        var seconds = 10
        let layer = try #require(TextLayer(
            files: try files(), content: content(script: source), canvasSize: SIMD2(100, 50), layerScale: 1, canvasScale: 1,
            device: device,
            now: { Date(timeIntervalSince1970: Double(seconds)) }))
        #expect(layer.isDynamic)
        let first = try #require(layer.texture(at: 0))
        // 一秒内不重画：还是同一张贴图
        #expect(ObjectIdentifier(layer.texture(at: 0.5)!.texture as AnyObject)
            == ObjectIdentifier(first.texture as AnyObject))
        seconds = 11
        let second = try #require(layer.texture(at: 1))
        #expect(ObjectIdentifier(second.texture as AnyObject) != ObjectIdentifier(first.texture as AnyObject))
    }

    /// 字号按 300 DPI 的磅值换算：字号 12 的等宽字"88"约 2 × 0.6 × 12 × 300/72 ≈ 60 个画布单位宽。
    /// 以前直接把字号当画布单位用，同样的字只有约 14 宽
    @Test func pointSizeIsConvertedFromPoints() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let content = SceneDescription.TextContent(
            font: "Monaco.ttf", pointSize: 12, boxSize: SIMD2(300, 100), horizontalAlign: "center",
            verticalAlign: "center", staticText: "88", script: nil, scriptProperties: nil)
        let layer = try #require(TextLayer(
            files: try files(), content: content, canvasSize: SIMD2(300, 100), layerScale: 1, canvasScale: 1, device: device))
        let texture = try #require(layer.texture(at: 0)).texture
        #expect(texture.width == 300 && texture.height == 100)
        var pixels = [UInt8](repeating: 0, count: 300 * 100 * 4)
        texture.getBytes(&pixels, bytesPerRow: 300 * 4, from: MTLRegionMake2D(0, 0, 300, 100), mipmapLevel: 0)
        var columns = Set<Int>()
        for y in 0..<100 {
            for x in 0..<300 where pixels[(y * 300 + x) * 4 + 3] > 64 { columns.insert(x) }
        }
        let inkWidth = (columns.max() ?? 0) - (columns.min() ?? 0)
        #expect(inkWidth > 45 && inkWidth < 70, "墨迹宽 \(inkWidth)")
    }

    /// 用户把字号调大、作者的框放不下时，框按需放大（以中心为准），不截掉文字
    @Test func boxGrowsWhenTextNoLongerFits() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let content = SceneDescription.TextContent(
            font: "Monaco.ttf", pointSize: 40, boxSize: SIMD2(60, 30), horizontalAlign: "center",
            verticalAlign: "center", staticText: "88:88", script: nil, scriptProperties: nil)
        let layer = try #require(TextLayer(
            files: try files(), content: content, canvasSize: SIMD2(1000, 500), layerScale: 1, canvasScale: 1, device: device))
        let texture = try #require(layer.texture(at: 0)).texture
        // 5 个等宽字 × 0.6 × 40 × 300/72 ≈ 500 宽，一行约 200 高
        #expect(layer.boxSize.x > 450 && layer.boxSize.y > 150)
        #expect(texture.width == Int(layer.boxSize.x.rounded()))
        // 框够大时不动
        let roomy = try #require(TextLayer(
            files: try files(), content: self.content(), canvasSize: SIMD2(1000, 500), layerScale: 1, canvasScale: 1, device: device))
        _ = roomy.texture(at: 0)
        #expect(roomy.boxSize.x >= 60)
    }

    /// 没有脚本的文字只画一次
    @Test func staticTextIsNotDynamic() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = try #require(TextLayer(
            files: try files(), content: content(), canvasSize: SIMD2(100, 50), layerScale: 1, canvasScale: 1,
            device: device))
        #expect(!layer.isDynamic)
        #expect(layer.texture(at: 0) != nil)
    }

    /// 目标尺寸变了（换屏幕、改缩放）按新比例重画，否则文字会被放大/缩小糊掉；
    /// 贴图带 mipmap，缩小显示时线性取样也不会糊成一团
    @Test func textureFollowsTheTargetScale() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = try #require(TextLayer(
            files: try files(), content: content(), canvasSize: SIMD2(100, 50), layerScale: 1, canvasScale: 1,
            device: device))
        let small = try #require(layer.texture(at: 0, canvasScale: 1)).texture
        // 框会按字号放大，所以比对"贴图 = 框 × 比例"而不是写死尺寸
        let box = layer.boxSize
        #expect(small.width == Int(box.x.rounded()) && small.height == Int(box.y.rounded()))
        #expect(small.mipmapLevelCount > 1)
        let large = try #require(layer.texture(at: 0, canvasScale: 2)).texture
        #expect(large.width == Int((box.x * 2).rounded()) && large.height == Int((box.y * 2).rounded()))
        // 比例变化不到 10% 不重画
        let same = try #require(layer.texture(at: 0, canvasScale: 2.05)).texture
        #expect(ObjectIdentifier(same as AnyObject) == ObjectIdentifier(large as AnyObject))
    }
}

@Suite struct TextRenderTests {
    /// 一个把输入整个换成绿色的特效（自己写的最小 fixture）
    private let effectFiles: [String: Data] = [
        "effects/green/effect.json": Data(#"{"passes": [{"material": "materials/green.json"}]}"#.utf8),
        "materials/green.json": Data(#"{"passes": [{"shader": "green"}]}"#.utf8),
        "shaders/green.vert": Data("""
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
        """.utf8),
        "shaders/green.frag": Data("""
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(0.0, 1.0, 0.0, c.a);
        }
        """.utf8),
    ]

    /// 字号 4 磅 ≈ 17 个画布单位（按 300/72 换算），"8888" 约 40 宽，放得进 60×30 的框
    private func scene(
        text: String, font: String = "Monaco.ttf", script: String? = nil, effects: String = "", alpha: Float = 1
    ) -> Data {
        let textValue = script.map { #"{"script": \#(jsonString($0)), "value": "\#(text)"}"# } ?? "\"\(text)\""
        return Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "text": \(textValue), "font": "\(font)", "pointsize": 4,
                      "size": "60 30", "origin": "50 25 0", "color": "1 1 1", "alpha": \(alpha),
                      "horizontalalign": "center", "verticalalign": "center"\(effects)}]}
        """.utf8)
    }

    private func count(_ image: CGImage, matching: (Int, Int, Int) -> Bool) -> Int {
        var total = 0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let rgb = pixel(image, column, row)
                if matching(Int(rgb[0]), Int(rgb[1]), Int(rgb[2])) { total += 1 }
            }
        }
        return total
    }

    private func jsonString(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self)
            .dropFirst().dropLast().description
    }

    @Test func textLayerDrawsInkInsideItsBox() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(["scene.json": scene(text: "8888")]),
            assets: systemFont.deletingLastPathComponent())
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(!renderer.needsAnimation)
        let image = try renderer.renderImage(width: 100, height: 50)
        // 文字框是 x 20…80、y 10…40；黑底上应该出现白字，而且不会涂满整块
        let ink = brightPixels(image, x: 20, y: 10, width: 60, height: 30)
        #expect(ink > 10)
        #expect(ink < 60 * 30 / 2)
        // 框外保持黑色
        #expect(brightPixels(image, x: 0, y: 0, width: 100, height: 8) == 0)
    }

    /// 时钟：脚本算文字，画面随时间变化，需要持续渲染
    @Test func clockTextIsAnimatedAndDrawn() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = "export function update(value) { return String(new Date().getHours()) + ':' + String(new Date().getMinutes()); }"
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(["scene.json": scene(text: "12:00", script: source)]),
            assets: systemFont.deletingLastPathComponent())
        #expect(renderer.needsAnimation)
        let image = try renderer.renderImage(width: 100, height: 50, time: 0)
        #expect(brightPixels(image, x: 20, y: 10, width: 60, height: 30) > 10)
    }

    /// 只有时钟会变的场景：桌面上每帧只查文字，字变了才画。判定要准：挂了特效（每帧都在变）就不算
    @Test func clockOnlyScenesRedrawOnlyWhenTheTextChanges() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        // 每问一次脚本计数加一，每问两次文字变一次
        let source = "let asked = 0; export function update(value) { asked += 1; return String(Math.floor(asked / 2)); }"
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(["scene.json": scene(text: "0", script: source)]),
            assets: systemFont.deletingLastPathComponent())
        #expect(renderer.needsAnimation)
        #expect(renderer.redrawsOnlyWhenStateChanges)
        // 建渲染器时已经问过一次、画出了 "0"
        _ = try renderer.renderImage(width: 100, height: 50, time: 0)
        #expect(!renderer.prepareFrame(at: 0.5), "不到一秒不问脚本")
        #expect(renderer.prepareFrame(at: 1), "第二次问：\"1\"，变了")
        _ = try renderer.renderImage(width: 100, height: 50, time: 1)
        #expect(!renderer.prepareFrame(at: 2), "第三次问还是 \"1\"，不用重画")
        #expect(renderer.prepareFrame(at: 3), "第四次问：\"2\"")

        var files = effectFiles
        files["scene.json"] = scene(text: "0", script: source, effects: #", "effects": [{"file": "effects/green/effect.json"}]"#)
        let withEffect = try SceneRenderer(
            device: device, package: try makePackage(files), assets: systemFont.deletingLastPathComponent())
        #expect(withEffect.needsAnimation)
        #expect(!withEffect.redrawsOnlyWhenStateChanges, "特效每帧都要算，不能只在状态变时才画")
    }

    /// 文字图层上的特效作用在文字贴图上：白字经过"全部换成绿色"的特效后应该只剩绿色
    @Test func effectsOnTextLayersApplyToTheTextTexture() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = effectFiles
        files["scene.json"] = scene(text: "8888", effects: #", "effects": [{"file": "effects/green/effect.json"}]"#)
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(files), assets: systemFont.deletingLastPathComponent())
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(renderer.renderedEffectCount == 1)
        #expect(renderer.unsupported["非图片图层上的特效"] == nil)

        let image = try renderer.renderImage(width: 100, height: 50)
        let green = count(image) { $0 < 60 && $1 > 150 && $2 < 60 }
        let white = count(image) { $0 > 150 && $1 > 150 && $2 > 150 }
        #expect(green > 10)
        #expect(white == 0)
    }

    /// 把整块都涂成不透明绿色的特效：用来验证特效链跑的尺寸（辉光类特效也是整块一起动）
    private func opaqueEffectFiles() -> [String: Data] {
        [
            "effects/opaque/effect.json": Data(#"{"passes": [{"material": "materials/opaque.json"}]}"#.utf8),
            "materials/opaque.json": Data(#"{"passes": [{"shader": "opaque"}]}"#.utf8),
            "shaders/opaque.vert": Data("""
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
            """.utf8),
            "shaders/opaque.frag": Data("""
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }
            """.utf8),
        ]
    }

    /// 文字图层的特效链在**图层自己的框**里算，缓冲是图层在屏幕上占的像素（WE 的文字图层有 padding
    /// 专门给特效留边；放到整屏里算的话辉光的射线会按整屏宽度拉长，时钟拖出长长的残影）
    @Test func textEffectsRunInTheLayerAtScreenResolution() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = opaqueEffectFiles()
        files["scene.json"] = scene(text: "8888", effects: #", "effects": [{"file": "effects/opaque/effect.json"}]"#)
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(files), assets: systemFont.deletingLastPathComponent(),
            targetSize: SIMD2(200, 100))
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        // 图层框 60×30（画布坐标），画布 100×50 放到 200×100 的屏幕上放大 2 倍：缓冲 120×60，不是整屏 200×100
        #expect(renderer.memorySummary.contains { name, _ in name.contains("特效链 120×60") })
        // 结果仍然只画在图层自己的位置上：画布 100×50 放到 200×100 的屏幕上，图层框 x 20…80、y 10…40
        let image = try renderer.renderImage(width: 200, height: 100)
        #expect(count(image) { $0 < 60 && $1 > 150 && $2 < 60 } > 10)
        #expect(pixel(image, 20, 20).max()! < 100)
        #expect(pixel(image, 180, 80).max()! < 100)
    }

    /// 文字图层的 padding：特效在"框 + 四周留边"里算，画的时候四边形也跟着外扩
    @Test func textPaddingGivesEffectsRoomAroundTheBox() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = opaqueEffectFiles()
        files["scene.json"] = scene(
            text: "8888", effects: #", "padding": 10, "effects": [{"file": "effects/opaque/effect.json"}]"#)
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(files), assets: systemFont.deletingLastPathComponent(),
            targetSize: SIMD2(200, 100))
        // (60 + 2×10) × (30 + 2×10)，放大 2 倍
        #expect(renderer.memorySummary.contains { name, _ in name.contains("特效链 160×100") })
        // 留边也画出来了：框左边缘外 5 个画布单位（屏幕 x = 2×(20 − 5) = 30）是特效涂的绿色
        let image = try renderer.renderImage(width: 200, height: 100)
        #expect(pixel(image, 32, 50)[1] > 150)
    }

    /// 文字图层的颜色和透明度在特效之前作用（WE 里辉光会把透明度加回 1，时钟透明度 0.66 字芯仍是纯白）：
    /// 特效输出不透明的绿色时，结果就是不透明的绿，不会再乘一次 0.5
    @Test func textColorIsAppliedBeforeEffects() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = opaqueEffectFiles()
        files["scene.json"] = scene(
            text: "8888", effects: #", "effects": [{"file": "effects/opaque/effect.json"}]"#, alpha: 0.5)
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(files), assets: systemFont.deletingLastPathComponent(),
            targetSize: SIMD2(200, 100))
        let image = try renderer.renderImage(width: 200, height: 100)
        #expect(pixel(image, 100, 50)[1] > 230)
    }

    /// 形状图层（光束这类 DIRECTDRAW 特效）的链也在形状自己的框里算：光在自己的四边形里淡出，
    /// 不会铺满整屏再被四边形切出硬边
    @Test func shapeEffectsRunInTheShape() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = opaqueEffectFiles()
        files["scene.json"] = Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "shape": "quad", "origin": "50 25 0", "scale": "0.5 0.25 1",
                      "effects": [{"file": "effects/opaque/effect.json"}]}]}
        """.utf8)
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(files), assets: nil, targetSize: SIMD2(200, 100))
        // 默认 128 的形状缩放成 64×32（画布），屏幕上放大 2 倍：128×64
        #expect(renderer.memorySummary.contains { name, _ in name.contains("特效链 128×64") })
        let image = try renderer.renderImage(width: 200, height: 100)
        #expect(pixel(image, 100, 50)[1] > 150)
        #expect(pixel(image, 20, 50).max()! < 60)
    }

    /// 文字图层上辉光射线通道（同时有 g_Length、g_Intensity）的强度按 WE 截图校准：乘 textGlowCalibration
    @Test func glowOnTextIsCalibratedAgainstWE() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files: [String: Data] = [
            "effects/rays/effect.json": Data(#"{"passes": [{"material": "materials/rays.json"}]}"#.utf8),
            "materials/rays.json": Data(#"{"passes": [{"shader": "rays"}]}"#.utf8),
            "shaders/rays.vert": Data("""
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
            """.utf8),
            // 把强度原样画成绿色：看得到实际传进来的 g_Intensity
            "shaders/rays.frag": Data("""
            uniform sampler2D g_Texture0;
            uniform float g_Length; // {"material":"raylength","default":0.1}
            uniform float g_Intensity; // {"material":"rayintensity","default":1}
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = vec4(0.0, g_Intensity + g_Length * 0.0, 0.0, 1.0); }
            """.utf8),
        ]
        files["scene.json"] = scene(
            text: "8888",
            effects: #", "effects": [{"file": "effects/rays/effect.json", "passes": [{"constantshadervalues": {"rayintensity": 0.8}}]}]"#)
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(files), assets: systemFont.deletingLastPathComponent(),
            targetSize: SIMD2(200, 100))
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        let image = try renderer.renderImage(width: 200, height: 100)
        // 0.8 × 0.5 = 0.4 → 约 102
        let green = Int(pixel(image, 100, 50)[1])
        #expect(abs(green - 102) <= 4, "绿色 \(green)")
    }

    /// 离屏工具（没给目标尺寸）时退回图层自己的尺寸，和以前一样
    @Test func effectsWithoutATargetSizeStillUseTheLayer() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = opaqueEffectFiles()
        files["scene.json"] = scene(text: "8888", effects: #", "effects": [{"file": "effects/opaque/effect.json"}]"#)
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(files), assets: systemFont.deletingLastPathComponent())
        #expect(renderer.memorySummary.contains { name, _ in name.contains("特效链 60×30") })
    }

    /// 时钟 + 特效：文字每秒变，特效链要跟着重算
    @Test func effectsOnClockTextFollowTheChangingString() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = effectFiles
        let source = "export function update(value) { return String(new Date().getSeconds()); }"
        files["scene.json"] = scene(
            text: "0", script: source, effects: #", "effects": [{"file": "effects/green/effect.json"}]"#)
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(files), assets: systemFont.deletingLastPathComponent())
        #expect(renderer.needsAnimation)
        for time in [Float(0), 1.5] {
            let image = try renderer.renderImage(width: 100, height: 50, time: time)
            #expect(count(image) { $0 < 60 && $1 > 150 && $2 < 60 } > 0)
        }
    }

    @Test func missingFontIsReportedAndNothingIsDrawn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device,
            package: try makePackage(["scene.json": scene(text: "88", font: "没有这个字体.ttf")]), assets: nil)
        #expect(renderer.unsupported["文字（字体读不了）"] == 1)
        let image = try renderer.renderImage(width: 100, height: 50)
        #expect(brightPixels(image, x: 0, y: 0, width: 100, height: 50) == 0)
    }
}

/// 屏幕比例和画布比例不一样时，铺满裁切会把画布两侧（或上下）切掉，作者摆在边角的时钟会被切掉半个。
/// 文字图层整块挪进"屏幕上真正看得见的那块画布"，其余画面照旧铺满（和 WE 一致）
/// WE 的编辑器里可以直接选系统字体，场景里存成 `systemfont_阶段名`。按名字映射到 macOS 的字体；
/// Windows 独有的（consolas 等）按分类退回，不能让文字因为读不到字体就整块不画
@Suite struct SystemFontTests {
    private func resolved(_ name: String) -> String {
        (CTFontCopyPostScriptName(TextLayer.systemFont(named: name, size: 12)) as String).lowercased()
    }

    @Test func knownNamesMapToTheSameFamily() {
        #expect(resolved("arial").contains("helvetica") || resolved("arial").contains("arial"))
        #expect(resolved("timesnewroman").contains("times"))
    }

    @Test func windowsOnlyFontsFallBackToSomethingMonospaced() {
        #expect(resolved("consolas").contains("menlo") || resolved("consolas").contains("monaco"))
        #expect(resolved("comicsansms").contains("comic") || resolved("comicsansms").contains("chalkboard"))
    }

    @Test func unknownNamesStillResolveToAFont() {
        #expect(!resolved("完全没听说过的字体").isEmpty)
    }
}

@Suite struct TextStaysInsideTheScreenTests {
    /// 一个时钟场景：文字框 60×30，摆在 origin 处
    private func edgeScene(canvas: SIMD2<Float> = SIMD2(200, 50), origin: String) -> Data {
        Data("""
        {"general": {"orthogonalprojection": {"width": \(canvas.x), "height": \(canvas.y)}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "text": "8888", "font": "Monaco.ttf", "pointsize": 4,
                      "size": "60 30", "origin": "\(origin)", "color": "1 1 1", "alpha": 1,
                      "horizontalalign": "center", "verticalalign": "center"}]}
        """.utf8)
    }

    /// 墨迹的左右边界（屏幕像素，含端），没有墨迹时返回 nil
    private func inkBounds(_ image: CGImage) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<image.height {
            for x in 0..<image.width where pixel(image, x, y).max()! > 100 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < minX ? nil : (minX, maxX, minY, maxY)
    }

    /// 画布比屏幕宽（16:9 画布放到 2:1 屏幕上）时，画布两侧会被切掉：贴右边的时钟要挪回来。
    /// 没挪以前它整个落在屏幕外面（可见区域是画布中间的 x 50…150，文字中心在 170）
    @Test func clockAtTheRightEdgeIsPulledBackIntoTheScreen() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(["scene.json": edgeScene(origin: "170 25 0")]),
            assets: systemFont.deletingLastPathComponent(), targetSize: SIMD2(100, 50))
        let image = try renderer.renderImage(width: 100, height: 50)
        let ink = try #require(inkBounds(image), "时钟被切到屏幕外面了")
        // 框挪到画布 90…150（屏幕 40…100），字在框里居中，两侧各留 10 像素
        #expect(ink.minX > 40)
        #expect(ink.maxX < 100)
        #expect(ink.minX < 70)
    }

    /// 画布比屏幕矮（往高里放）时切的是上下：贴顶边的时钟要往下挪
    @Test func clockAtTheTopEdgeIsPulledDownIntoTheScreen() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device,
            package: try makePackage(["scene.json": edgeScene(canvas: SIMD2(100, 50), origin: "50 45 0")]),
            assets: systemFont.deletingLastPathComponent(), targetSize: SIMD2(200, 50))
        let image = try renderer.renderImage(width: 200, height: 50)
        let ink = try #require(inkBounds(image), "时钟被切到屏幕外面了")
        // 可见区域是画布中间的 y 12.5…37.5；时钟的框挪到 7.5…37.5，字在框里居中
        #expect(ink.minY > 0)
        #expect(ink.maxY < 50)
        #expect(ink.minY < 25)
    }

    /// 屏幕比例和画布一样时不动：时钟留在作者摆的位置（右边那半，屏幕 x 150…190）
    @Test func clockInsideTheVisibleAreaIsNotMoved() throws {
        try #require(FileManager.default.fileExists(atPath: systemFont.path))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device, package: try makePackage(["scene.json": edgeScene(origin: "170 25 0")]),
            assets: systemFont.deletingLastPathComponent(), targetSize: SIMD2(200, 50))
        let image = try renderer.renderImage(width: 200, height: 50)
        let ink = try #require(inkBounds(image))
        #expect(ink.minX > 140)
        #expect(ink.maxX < 200)
        #expect(brightPixels(image, x: 0, y: 0, width: 120, height: 50) == 0)
    }

    /// 几何：铺满裁切后画布上真正看得见的那块
    @Test func visibleRegionIsTheCenteredCrop() {
        let wide = SceneRenderer.visibleRegion(canvas: SIMD2(200, 50), target: SIMD2(100, 50))
        #expect(wide.min == SIMD2(50, 0) && wide.max == SIMD2(150, 50))
        let tall = SceneRenderer.visibleRegion(canvas: SIMD2(100, 50), target: SIMD2(200, 50))
        #expect(tall.min == SIMD2(0, 12.5) && tall.max == SIMD2(100, 37.5))
        let same = SceneRenderer.visibleRegion(canvas: SIMD2(1920, 1080), target: SIMD2(3840, 2160))
        #expect(same.min == SIMD2(0, 0) && same.max == SIMD2(1920, 1080))
    }

    /// 几何：挪进可见区域的偏移。放得下就贴边挪，比可见区域还大就居中
    @Test func fitOffsetSlidesIntoTheRegion() {
        let region = (min: SIMD2<Float>(50, 0), max: SIMD2<Float>(150, 50))
        func offset(_ lo: SIMD2<Float>, _ hi: SIMD2<Float>) -> SIMD2<Float> {
            SceneRenderer.fitOffset(lo: lo, hi: hi, regionMin: region.min, regionMax: region.max)
        }
        // 在可见区域里：不动
        #expect(offset(SIMD2(60, 10), SIMD2(120, 40)) == SIMD2(0, 0))
        // 右边超出去：贴右边界
        #expect(offset(SIMD2(140, 10), SIMD2(200, 40)) == SIMD2(-50, 0))
        // 左边超出去：贴左边界
        #expect(offset(SIMD2(10, 10), SIMD2(70, 40)) == SIMD2(40, 0))
        // 完全在右边外面：拉到右边界
        #expect(offset(SIMD2(210, 10), SIMD2(270, 40)) == SIMD2(-120, 0))
        // 比可见区域还宽：居中
        #expect(offset(SIMD2(0, 10), SIMD2(200, 40)) == SIMD2(0, 0))
        // 上下同理
        #expect(offset(SIMD2(60, 30), SIMD2(120, 60)) == SIMD2(0, -10))
        #expect(offset(SIMD2(60, -30), SIMD2(120, 10)) == SIMD2(0, 30))
    }
}
