import Metal
import WallpaperFormats

/// 精灵图做成的动画图层（WE 把 GIF 转成的"一张大图 + 帧表"）：按场景时间挑出当前这一帧，只画那一格。
///
/// 帧表（TEXS）里每帧有所在图像的编号、显示时长和它在整张图里的像素矩形。帧多时一张 4096 放不下，
/// 后面的帧放在同一个 .tex 的第 2、3…张图像里。
struct SpriteAnimation {
    let frames: [TexFile.SpriteSheet.Frame]
    /// 第 0、1…张图像（帧的 imageIndex 指向这里）
    let images: [any MTLTexture]
    /// 每张图像的原始像素尺寸：帧坐标按帧所在的那张算（后面的图像常常比第一张小）
    let imageSizes: [SIMD2<Float>]
    /// 每帧结束的时刻（秒，从动画开头累加）
    let endTimes: [Float]

    /// 时长为 0 的帧按这么长算。GIF 里 0 延时的帧浏览器一般按 0.1 秒播放；如果当成"不占时间"直接跳过，
    /// 作者放进去的一整串帧（Akali 那张有 13 帧，连第二张图像整张）永远不会出现。WE 的确切做法待核对
    static let zeroDurationFrameTime: Float = 0.1

    init?(sheet: TexFile.SpriteSheet, images: [any MTLTexture], imageSizes: [SIMD2<Float>]) {
        guard sheet.frames.count > 1, !images.isEmpty, !imageSizes.isEmpty,
              imageSizes.allSatisfy({ $0.x > 0 && $0.y > 0 })
        else { return nil }
        frames = sheet.frames
        self.images = images
        self.imageSizes = imageSizes
        var total: Float = 0
        endTimes = sheet.frames.map { frame in
            total += frame.duration > 0 ? frame.duration : Self.zeroDurationFrameTime
            return total
        }
    }

    var duration: Float { endTimes.last ?? 0 }

    /// 一帧的尺寸（像素）：没写图层尺寸时图层就按它的大小摆
    var frameSize: SIMD2<Float> { SIMD2(frames[0].width, frames[0].height) }

    /// 这一时刻显示第几帧（循环播放）
    func frameIndex(at time: Float) -> Int {
        guard duration > 0 else { return 0 }
        let t = time.truncatingRemainder(dividingBy: duration)
        return endTimes.firstIndex { t < $0 } ?? frames.count - 1
    }

    /// 帧指向的图像编号；不存在时退回第 0 张
    private func imageIndex(of index: Int) -> Int {
        let imageIndex = frames[index].imageIndex
        return images.indices.contains(imageIndex) && imageSizes.indices.contains(imageIndex) ? imageIndex : 0
    }

    /// 这一帧要用的图像
    func image(of index: Int) -> any MTLTexture { images[imageIndex(of: index)] }

    /// 这一帧在它那张图像上的纹理坐标：左、上、右、下（v = 0 在上边）
    func uvRect(of index: Int) -> (left: Float, top: Float, right: Float, bottom: Float) {
        let frame = frames[index]
        let size = imageSizes[imageIndex(of: index)]
        return (frame.x / size.x, frame.y / size.y, (frame.x + frame.width) / size.x, (frame.y + frame.height) / size.y)
    }

    /// 把四边形（左下、右下、左上、右上）的纹理坐标换成这一帧的矩形
    func vertices(_ quad: [SIMD4<Float>], frame index: Int) -> [SIMD4<Float>] {
        let rect = uvRect(of: index)
        let uvs: [SIMD2<Float>] = [
            SIMD2(rect.left, rect.bottom), SIMD2(rect.right, rect.bottom),
            SIMD2(rect.left, rect.top), SIMD2(rect.right, rect.top),
        ]
        return zip(quad, uvs).map { vertex, uv in SIMD4(vertex.x, vertex.y, uv.x, uv.y) }
    }

    /// 特效链的输入四个角（左下、右下、左上、右上）：链子只拿这一帧那一格去算
    func corners(of index: Int) -> [SIMD2<Float>] {
        let rect = uvRect(of: index)
        return [SIMD2(rect.left, rect.bottom), SIMD2(rect.right, rect.bottom),
                SIMD2(rect.left, rect.top), SIMD2(rect.right, rect.top)]
    }
}
