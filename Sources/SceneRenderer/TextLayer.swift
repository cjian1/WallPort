import CoreGraphics
import CoreText
import Foundation
import Metal
import simd
import WallpaperFormats

/// 文字图层的贴图。用系统的 CoreText 把文字画成一张直通 alpha 的图（白字 + 覆盖度），
/// 再当普通贴图画到图层的位置上；颜色和透明度交给图层自己的 color / alpha
/// （图层着色器会把采样结果乘上去），和 WE 的行为一致。
///
/// 文字内容有脚本时（时钟就是），最多每秒问一次脚本，字符串变了才重新画、重新上传。
final class TextLayer {
    private let device: any MTLDevice
    private let font: CTFont
    /// 字号换算成画布单位后的大小
    private let pointSize: Float

    /// WE 的 pointsize 是 300 DPI 下的磅值：1 磅 = 300 / 72 ≈ 4.17 个画布单位。
    /// ~/wp 里 13 个文字对象按自身字体和字号量出的文字，和作者的文字框之比都集中在 4.17
    /// （"时间"那组框 375×165、文字 90×40，正好 4.1667），宽高一致
    static let canvasUnitsPerPoint: Float = 300.0 / 72.0

    /// 场景里引用 WE 自带（系统）字体时的前缀，例如 `systemfont_arial`
    static let systemFontPrefix = "systemfont_"

    /// 按 WE 里的名字找 macOS 上的系统字体。名字找不到时（Windows 独有的字体）按分类退回
    static func systemFont(named name: String, size: CGFloat) -> CTFont {
        let candidates: [String] = switch name.lowercased().replacingOccurrences(of: " ", with: "") {
        case "consolas", "couriernew", "lucidaconsole", "inconsolata":
            ["Menlo", "Monaco", "Courier New"]
        case "arial", "helvetica", "segoeui", "tahoma", "verdana", "calibri":
            ["Helvetica Neue", "Arial", "Verdana"]
        case "timesnewroman", "times", "georgia", "cambria":
            ["Times New Roman", "Georgia", "Times"]
        case "comicsansms", "comicsans":
            ["Comic Sans MS", "Chalkboard", "Helvetica Neue"]
        default:
            [name, "Helvetica Neue"]
        }
        for candidate in candidates {
            let font = CTFontCreateWithName(candidate as CFString, size, nil)
            // 名字不存在时 CoreText 给一个替代字体，用实际字体名对一下，对不上就试下一个候选
            let actual = (CTFontCopyPostScriptName(font) as String).lowercased()
            let wanted = candidate.lowercased().replacingOccurrences(of: " ", with: "")
            if actual.replacingOccurrences(of: "-", with: "").contains(wanted) { return font }
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
    /// 文字框（画布单位）。第一次画的时候如果字放不下就放大（用户把字号调大时），之后固定：
    /// 渲染器按它摆放文字的四边形
    private(set) var boxSize: SIMD2<Float>
    private var isBoxFixed = false
    /// 图层自身的缩放；乘上"画布 → 像素"就是贴图该用的分辨率
    private let layerScale: Float
    /// 建当前贴图时用的"画布 → 像素"比例。目标尺寸变了（换屏幕、改缩放）要按新比例重画，
    /// 否则文字会被放大或缩小，糊成一团
    private var canvasScale: Float
    /// 画布单位 → 贴图像素
    private var resolution: Float { canvasScale * layerScale }
    private let horizontalAlign: String
    private let verticalAlign: String
    private let staticText: String
    private let script: SceneScript?
    private let mipmapQueue: (any MTLCommandQueue)?
    private var texture: LoadedTexture?
    private var currentString: String?
    private var lastCheck: Float = -.greatestFiniteMagnitude

    /// 文字随时间变化（时钟），需要持续渲染
    var isDynamic: Bool { script != nil }
    /// 脚本报的问题（诊断用）
    private(set) var problem: String?
    /// 贴图占的显存（诊断用）
    private(set) var allocatedSize = 0

    /// - Parameters:
    ///   - layerScale: 图层自身的缩放
    ///   - canvasScale: 画布单位 → 屏幕像素的比例（绘制时按当前的算，变了会重画）
    ///   - now: 取当前时间，测试里固定住
    init?(
        files: SceneFiles, content: SceneDescription.TextContent, canvasSize: SIMD2<Float>, layerScale: Float,
        canvasScale: Float, device: any MTLDevice, userProperties: Data? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.device = device
        mipmapQueue = device.makeCommandQueue()
        pointSize = max(content.pointSize, 0.25) * Self.canvasUnitsPerPoint
        guard !content.font.isEmpty else { return nil }
        if content.font.hasPrefix(Self.systemFontPrefix) {
            // WE 的编辑器里可以直接选系统字体，场景里存成 systemfont_arial 这种名字：
            // 映射到 macOS 上的同名字体，没有的（例如 Windows 才有的 consolas）退回相近的
            font = Self.systemFont(
                named: String(content.font.dropFirst(Self.systemFontPrefix.count)), size: CGFloat(pointSize))
        } else if let data = files.data(content.font),
                  let provider = CGDataProvider(data: data as CFData), let graphicsFont = CGFont(provider) {
            font = CTFontCreateWithGraphicsFont(graphicsFont, CGFloat(pointSize), nil, nil)
        } else if let substitute = CompatFonts.systemSubstitutes[content.font] {
            // 没导入 WE 素材时，WE 自带的表情字体用系统字体代替（表情由 Apple Color Emoji 补上）
            font = Self.systemFont(named: substitute, size: CGFloat(pointSize))
        } else {
            return nil
        }
        boxSize = simd_max(content.boxSize, SIMD2(1, 1))
        self.layerScale = max(layerScale, 0.01)
        self.canvasScale = max(canvasScale, 0.01)
        horizontalAlign = content.horizontalAlign
        verticalAlign = content.verticalAlign
        staticText = content.staticText
        script = content.script.flatMap { source in
            SceneScript(
                source: source, properties: content.scriptProperties,
                environment: SceneScript.Environment(
                    canvasSize: canvasSize, layerSize: content.boxSize, layerText: content.staticText,
                    userProperties: userProperties),
                now: now)
        }
        if content.script != nil, script == nil {
            problem = "文字脚本没有运行（超出宿主支持的写法，或含循环等被安全检查拦下）"
        } else if let scriptProblem = script?.problem {
            problem = "文字脚本按静态文字处理：\(scriptProblem)"
        }
    }

    /// 当前应该画的贴图。文字变了才重画；- Parameter canvasScale: 当前的画布 → 像素比例，
    /// 和建贴图时差得多（> 10%）就按新比例重画
    func texture(at sceneTime: Float, canvasScale: Float? = nil) -> LoadedTexture? {
        if let canvasScale {
            let scale = max(canvasScale, 0.01)
            if abs(scale - self.canvasScale) > self.canvasScale * 0.1 {
                self.canvasScale = scale
                if let currentString { rebuild(currentString) }
            }
        }
        let shouldAsk = script != nil && (currentString == nil || sceneTime - lastCheck >= 1 || sceneTime < lastCheck)
        if shouldAsk {
            lastCheck = sceneTime
            if let text = script?.updateText(currentString ?? staticText) {
                if text != currentString { currentString = text; rebuild(text) }
            } else {
                if let problem = script?.problem { self.problem = problem }
                if currentString == nil { currentString = staticText; rebuild(staticText) }
            }
        }
        if texture == nil {
            currentString = staticText
            rebuild(staticText)
        }
        return texture
    }

    private func rebuild(_ string: String) {
        if !isBoxFixed {
            // WE 的文字框随内容自动调整：字号调大后按需放大，以中心为准向四周扩；
            // 同时量编辑器里的静态文字，再留 10%，时钟之类的字符串以后变长也放得下
            let needed = simd_max(
                Self.measure(string, font: font, pointSize: pointSize),
                Self.measure(staticText, font: font, pointSize: pointSize)) * 1.1
            boxSize = simd_max(boxSize, needed)
            isBoxFixed = true
        }
        guard let rendered = Self.render(
            string, font: font, pointSize: pointSize, boxSize: boxSize, resolution: resolution,
            horizontalAlign: horizontalAlign, verticalAlign: verticalAlign)
        else {
            texture = makeTexture(pixels: [255, 255, 255, 0], width: 1, height: 1)
            return
        }
        texture = makeTexture(pixels: rendered.pixels, width: rendered.width, height: rendered.height)
    }

    private func makeTexture(pixels: [UInt8], width: Int, height: Int) -> LoadedTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: SceneRenderer.pixelFormat, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
        // 画出来的是白字（各通道相同），所以 BGRA / RGBA 的通道顺序在这里没有影响
        target.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
            bytesPerRow: width * 4)
        // 生成 mipmap：文字贴图被缩小显示时（目标尺寸变了、或它在屏幕上比贴图小）线性取样才不会糊
        if let queue = mipmapQueue, let commands = queue.makeCommandBuffer(),
           let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        allocatedSize = target.allocatedSize
        return LoadedTexture(
            texture: target, imageSize: boxSize, uvScale: SIMD2(1, 1), clampsUVs: true, usesNearestFiltering: false)
    }

    /// 文字占的画布尺寸：最宽的一行 × 行数乘行高（和 render 的排法一致）
    static func measure(_ string: String, font: CTFont, pointSize: Float) -> SIMD2<Float> {
        let sized = CTFontCreateCopyWithAttributes(font, CGFloat(pointSize), nil, nil)
        var widest: CGFloat = 0
        var lineHeight = CGFloat(pointSize) * 1.2
        let lines = string.components(separatedBy: "\n")
        for part in lines {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: part, attributes: [.font: sized]))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            widest = max(widest, CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)))
            lineHeight = max(lineHeight, ascent + descent + leading)
        }
        return SIMD2(Float(widest), Float(lineHeight * CGFloat(lines.count)))
    }

    /// 把文字画成白字 + 覆盖度 alpha 的位图。太大时按比例缩到 4096 以内
    static func render(
        _ string: String, font: CTFont, pointSize: Float, boxSize: SIMD2<Float>, resolution: Float,
        horizontalAlign: String, verticalAlign: String
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        let limit: Float = 4096
        let scale = max(min(resolution, limit / max(boxSize.x, 1), limit / max(boxSize.y, 1)), 0.01)
        // 框的尺寸是坏数（NaN、极大值）时上面的缩放算不准，再按上限截一次
        let width = min(Int(limit), max(1, Int(saturating: (boxSize.x * scale).rounded())))
        let height = min(Int(limit), max(1, Int(saturating: (boxSize.y * scale).rounded())))
        let fontSize = pointSize * scale

        let sized = CTFontCreateCopyWithAttributes(font, CGFloat(fontSize), nil, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: sized,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        var lines: [(line: CTLine, width: CGFloat, ascent: CGFloat)] = []
        var lineHeight = CGFloat(fontSize) * 1.2
        for part in string.components(separatedBy: "\n") {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: part, attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            lines.append((line, lineWidth, ascent))
            lineHeight = max(lineHeight, ascent + descent + leading)
        }

        let totalHeight = lineHeight * CGFloat(lines.count)
        var baseline = switch verticalAlign {
        case "top": CGFloat(height)
        case "bottom": totalHeight
        default: (CGFloat(height) + totalHeight) / 2
        }
        let alignment: CTTextAlignment = switch horizontalAlign {
        case "left": .left
        case "right": .right
        default: .center
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            // 关掉 macOS 的字体平滑：它会把笔画加粗（浅色字尤其明显），和 WE 画出来的细笔画对不上
            // （Lucy 的时钟：同一字体、同样宽度，平滑后笔画粗了将近一倍）
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            for line in lines {
                let x: CGFloat = switch alignment {
                case .left: 0
                case .right: CGFloat(width) - line.width
                default: (CGFloat(width) - line.width) / 2
                }
                context.textPosition = CGPoint(x: x, y: baseline - line.ascent)
                CTLineDraw(line.line, context)
                baseline -= lineHeight
            }
        }
        // CoreGraphics 画出来是预乘的；WE 的贴图是非预乘的，这里还原回去
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(min(255, Int(pixels[index + channel]) * 255 / alpha))
            }
        }
        return (pixels, width, height)
    }
}
