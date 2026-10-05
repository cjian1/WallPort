import Metal
import Testing
@testable import SceneRenderer
@testable import WallpaperFormats

@Suite struct SpriteAnimationTests {
    private func frame(_ image: Int, _ duration: Float, _ x: Float, _ y: Float) -> TexFile.SpriteSheet.Frame {
        TexFile.SpriteSheet.Frame(imageIndex: image, duration: duration, x: x, y: y, width: 800, height: 1200)
    }

    private func animation(_ frames: [TexFile.SpriteSheet.Frame]) throws -> SpriteAnimation {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        let images = try (0..<2).map { _ in try #require(device.makeTexture(descriptor: descriptor)) }
        // 和 Akali 一样：第一张 4096×4096，第二张只有一排帧（4096×2048）
        return try #require(SpriteAnimation(
            sheet: TexFile.SpriteSheet(frames: frames), images: images,
            imageSizes: [SIMD2(4096, 4096), SIMD2(4096, 2048)]))
    }

    /// 按时长累加挑帧、循环播放；时长为 0 的帧按 0.1 秒算（和 Akali 那张的帧表一样：停 2 秒、闪一下）
    @Test func framesFollowTheirDurations() throws {
        let sprite = try animation([
            frame(0, 2.0, 0, 0), frame(0, 0.1, 800, 0), frame(0, 0, 1600, 0), frame(1, 0, 0, 0),
        ])
        #expect(abs(sprite.duration - 2.3) < 1e-5)
        #expect(sprite.frameIndex(at: 0) == 0)
        #expect(sprite.frameIndex(at: 1.99) == 0)
        #expect(sprite.frameIndex(at: 2.05) == 1)
        #expect(sprite.frameIndex(at: 2.15) == 2)
        #expect(sprite.frameIndex(at: 2.25) == 3)
        // 循环：2.3 秒以后回到第 0 帧
        #expect(sprite.frameIndex(at: 2.35) == 0)
    }

    /// 帧的纹理坐标按整张图算，后面的帧可以在第二张图像上
    @Test func framesMapToTheirCellAndImage() throws {
        let sprite = try animation([frame(0, 1, 800, 1200), frame(1, 1, 0, 0)])
        let rect = sprite.uvRect(of: 0)
        #expect(abs(rect.left - 800.0 / 4096) < 1e-6 && abs(rect.top - 1200.0 / 4096) < 1e-6)
        #expect(abs(rect.right - 1600.0 / 4096) < 1e-6 && abs(rect.bottom - 2400.0 / 4096) < 1e-6)
        #expect(sprite.image(of: 1) === sprite.images[1])
        // 第二张图像只有 2048 高：帧的 v 按 2048 算，不然画面会被竖着拉长
        let second = sprite.uvRect(of: 1)
        #expect(abs(second.bottom - 1200.0 / 2048) < 1e-6 && abs(second.right - 800.0 / 4096) < 1e-6)
        #expect(sprite.frameSize == SIMD2(800, 1200))
        // 四边形（左下、右下、左上、右上）换上这一格的纹理坐标，位置不变
        let quad: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1), SIMD4(1, 0, 1, 1), SIMD4(0, 1, 0, 0), SIMD4(1, 1, 1, 0)]
        let vertices = sprite.vertices(quad, frame: 0)
        #expect(vertices[0] == SIMD4(0, 0, rect.left, rect.bottom))
        #expect(vertices[3] == SIMD4(1, 1, rect.right, rect.top))
    }

    /// 只有一帧的精灵图不算动画
    @Test func singleFrameIsNotAnimated() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        let image = try #require(device.makeTexture(descriptor: descriptor))
        #expect(SpriteAnimation(
            sheet: TexFile.SpriteSheet(frames: [frame(0, 1, 0, 0)]), images: [image], imageSizes: [SIMD2(4096, 4096)]) == nil)
    }
}
