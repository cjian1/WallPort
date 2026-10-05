import AppKit
import Foundation
import Metal
import Testing
import DesktopHost
@testable import SceneRenderer
import WallpaperFormats

/// 换壁纸时控制器要把旧画面留到新场景画出第一帧为止，所以 `SceneContent` 必须真的会在画完之后
/// 说一声。这里用一个最小的场景包（只有清屏颜色、没有图层）走完整条路：建渲染器 → 装进视图 →
/// 视图在窗口里拿到 drawable → 画出第一帧 → 回调。
@MainActor
@Suite struct SceneContentFirstFrameTests {
    /// 按 scene.pkg 的结构打成字节（和 ScenePackage 读的格式一致）
    private func package(_ files: [String: Data]) -> Data {
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
        return header + body
    }

    /// 写一个只有清屏颜色的最小场景项目（我们自己造的，不含任何 WE 内容）
    private func makeProject() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scene-content-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scene = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": []}
        """
        try package(["scene.json": Data(scene.utf8)]).write(to: folder.appendingPathComponent("scene.pkg"))
        return folder
    }

    @Test func firstFrameCallbackFiresWhenTheSceneCanDraw() async throws {
        let folder = try makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        let window = NSWindow(
            contentRect: CGRect(x: -30_000, y: -30_000, width: 320, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView = container
        // 图层要挂在窗口上才拿得到 drawable；窗口放到屏幕外，测试期间不会挡住用户
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let log = EventLog(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("first-frame-test.log"))
        let content = SceneContent(
            projectFolder: folder, assets: nil, targetSize: CGSize(width: 320, height: 200),
            label: "测试", log: log) { _ in }
        container.addSubview(content.view)
        content.view.frame = container.bounds
        defer { content.tearDown() }

        var ready = false
        content.whenReady { ready = true }
        for _ in 0..<100 where !ready {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ready, "场景画出第一帧后必须回调，否则换壁纸时旧画面会一直留着")
    }

    /// 壁纸设置里的"完整显示"：2:1 的画布放进方的窗口，场景视图按画布比例缩在正中；
    /// 同步成系统壁纸的那一帧也要带上上下的黑边（不然系统按铺满放会被放大裁掉）
    @Test func fitsWholeCanvasInsideTheWindow() async throws {
        let folder = try makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        let window = NSWindow(
            contentRect: CGRect(x: -30_000, y: -30_000, width: 320, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let log = EventLog(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fit-test.log"))
        let content = SceneContent(
            projectFolder: folder, assets: nil, targetSize: CGSize(width: 640, height: 640),
            display: SceneContent.Display(fitsWhole: true), label: "测试", log: log) { _ in }
        container.addSubview(content.view)
        content.view.frame = container.bounds
        defer { content.tearDown() }
        var ready = false
        content.whenReady { ready = true }
        for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(50)) }
        content.view.layoutSubtreeIfNeeded()
        let scene = try #require(content.view.subviews.first)
        #expect(scene.frame == CGRect(x: 0, y: 80, width: 320, height: 160), "\(scene.frame)")
        let snapshot = try #require(await content.snapshot())
        #expect(abs(Double(snapshot.width) / Double(snapshot.height) - 1) < 0.01, "系统壁纸那一帧是整块屏幕的大小")
    }
}
