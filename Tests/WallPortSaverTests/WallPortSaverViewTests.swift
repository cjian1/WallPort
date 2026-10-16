import AppKit
import ImageIO
import Testing
@testable import WallPortSaver

/// 屏保显示的是系统壁纸同步写下的最新截图：屏保启动时壁坞会马上重截一张，屏保那边要换上它；
/// 停下以后不再每秒读文件夹（legacyScreenSaver 停了进程也常常留着）
@MainActor
@Suite struct WallPortSaverViewTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallPortSaverViewTests-\(UUID().uuidString)", isDirectory: true)
    private let key = "TEST-DISPLAY"

    /// 按同步的命名规则写一张 4×4 的纯色 JPEG
    @discardableResult
    private func writeFrame(stamp: Int, red: CGFloat, green: CGFloat) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let file = directory.appendingPathComponent("\(key)-\(stamp).jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    private func makeView() throws -> WallPortSaverView {
        let view = try #require(WallPortSaverView(frame: NSRect(x: 0, y: 0, width: 160, height: 100), isPreview: false))
        view.framesDirectory = directory
        view.displayKeyOverride = key
        return view
    }

    /// 显示出来的那张图的颜色（取中间一个像素），用来确认换上的确实是新截图
    private func shownColor(_ view: WallPortSaverView) throws -> (red: UInt8, green: UInt8) {
        let contents = try #require(view.imageLayer.contents)
        let image = contents as! CGImage
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1])
    }

    @Test func showsTheLatestFrameAndSwitchesToANewerOne() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFrame(stamp: 1, red: 1, green: 0)
        let view = try makeView()
        view.startAnimation()
        defer { view.stopAnimation() }
        #expect(view.shownFile?.lastPathComponent == "\(key)-1.jpg")
        #expect(try shownColor(view).red > 200)

        // 屏保启动后壁坞按此刻的画面重截了一张（旧的那张随后删掉）
        try writeFrame(stamp: 2, red: 0, green: 1)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(key)-1.jpg"))
        view.animateOneFrame()
        #expect(view.shownFile?.lastPathComponent == "\(key)-2.jpg")
        let color = try shownColor(view)
        #expect(color.green > 200 && color.red < 60)
    }

    /// 新截图读不出来（写到一半、坏文件）：留着现在这张，不变黑
    @Test func keepsThePictureWhenTheNewFileIsUnreadable() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFrame(stamp: 1, red: 1, green: 0)
        let view = try makeView()
        view.startAnimation()
        defer { view.stopAnimation() }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("\(key)-5.jpg").path, contents: Data("不是图片".utf8))
        view.animateOneFrame()
        #expect(view.shownFile?.lastPathComponent == "\(key)-1.jpg")
        #expect(view.imageLayer.contents != nil)
    }

    @Test func stopsLookingOnceStopped() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFrame(stamp: 1, red: 1, green: 0)
        let view = try makeView()
        view.startAnimation()
        view.stopAnimation()
        try writeFrame(stamp: 2, red: 0, green: 1)
        view.animateOneFrame()
        #expect(view.shownFile?.lastPathComponent == "\(key)-1.jpg")
    }

    /// 别的屏的截图不拿来用（真在屏保里跑时，这块屏没有截图就退回它自己的系统壁纸）
    @Test func otherDisplaysFramesAreNotUsed() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFrame(stamp: 1, red: 1, green: 0)
        let view = try makeView()
        view.displayKeyOverride = "ANOTHER-DISPLAY"
        view.startAnimation()
        defer { view.stopAnimation() }
        #expect(view.shownFile == nil)
        #expect(view.imageLayer.contents == nil)
    }
}
