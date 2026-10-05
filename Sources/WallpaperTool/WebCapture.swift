import AppKit
import DesktopHost
import Foundation
import WallpaperLibrary
import WebKit
import WebWallpaper

/// 网页壁纸在给定屏幕尺寸（点）下的样子：用 App 里的 WebContent 在一个屏幕外的窗口里打开页面，
/// 等几秒后报告页面内容有没有超出视口（只显示一角的典型原因：页面按固定像素排版），并存一张截图。
///
///     WallpaperTool web-capture <项目文件夹> <输出.png> [宽 高]   # 默认 1512×982 点
@MainActor
func webCapture(folder: String, output: String, size: CGSize) async -> Int32 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let project: WallpaperProject
    do {
        project = try WallpaperProject(folder: URL(fileURLWithPath: folder, isDirectory: true))
    } catch {
        print("✗ 读不了项目：\(error.localizedDescription)")
        return 1
    }
    guard project.kind == .web, let entry = project.entry else {
        print("✗ 不是网页壁纸")
        return 1
    }
    let outputURL = URL(fileURLWithPath: output)
    let log = EventLog(fileURL: outputURL.deletingPathExtension().appendingPathExtension("log"))
    let content = WebContent(
        folder: project.folder, entry: entry, userProperties: project.userPropertiesJSON(overrides: [:]),
        allowNetwork: true, label: "web-capture", log: log)
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: .borderless,
        backing: .buffered, defer: false)
    content.view.frame = NSRect(origin: .zero, size: size)
    content.view.autoresizingMask = [.width, .height]
    window.contentView?.addSubview(content.view)
    window.orderFrontRegardless()
    content.visibilityDidChange(isVisible: true)
    defer { content.tearDown() }

    // 等页面能显示（最多 30 秒），再等几秒让脚本把画面排好
    let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        var resumed = false
        content.whenReady {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: true)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: false)
        }
    }
    guard ready else {
        print("✗ 30 秒内页面没有加载完")
        return 1
    }
    try? await Task.sleep(for: .seconds(4))
    guard let webView = content.view as? WKWebView else { return 1 }
    let metrics = """
        (() => {
          const d = document.documentElement, b = document.body || d;
          const big = [...document.querySelectorAll('canvas, img, video, div')].map(e => {
            const r = e.getBoundingClientRect();
            return {tag: e.tagName, id: String(e.id || e.className || ''), w: Math.round(r.width), h: Math.round(r.height),
                    x: Math.round(r.left), y: Math.round(r.top), pw: e.width || 0, ph: e.height || 0};
          }).filter(r => r.w * r.h > innerWidth * innerHeight * 0.3).slice(0, 8);
          // 图片没出来时看是哪张：地址、加载完没有、原始尺寸；大块元素的背景图
          const images = [...document.images].slice(0, 8).map(i => ({src: i.currentSrc || i.src, complete: i.complete,
            natural: [i.naturalWidth, i.naturalHeight]}));
          const backgrounds = [...document.querySelectorAll('body, div')].map(e => getComputedStyle(e).backgroundImage)
            .filter(v => v && v !== 'none').slice(0, 6);
          // 第一张大图从自己往上每一层的可见性（被谁盖住、透明度、隐藏）
          const chain = [];
          for (let e = document.images[0]; e; e = e.parentElement) {
            const c = getComputedStyle(e), r = e.getBoundingClientRect();
            chain.push(`${e.tagName}#${e.id || ''} op=${c.opacity} vis=${c.visibility} disp=${c.display} z=${c.zIndex} ` +
              `pos=${c.position} bg=${c.backgroundColor} filter=${c.filter} rect=${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.width)}x${Math.round(r.height)}`);
          }
          const top = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
          const topInfo = top ? `${top.tagName}#${top.id || ''}.${top.className || ''}` : '';
          return JSON.stringify({inner: [innerWidth, innerHeight], dpr: devicePixelRatio, chain, topInfo,
            visibility: document.visibilityState,
            screen: [screen.width, screen.height], scroll: [d.scrollWidth, d.scrollHeight],
            body: [b.scrollWidth, b.scrollHeight], big, images, backgrounds});
        })()
        """
    // 屏幕外的窗口里 WebKit 可能还没解码图片：截图前先让每张图解码完
    _ = try? await webView.callAsyncJavaScript(
        "await Promise.all([...document.images].map(i => i.decode().catch(() => null))); return document.visibilityState;",
        contentWorld: .page)
    let result = try? await webView.evaluateJavaScript(metrics)
    print(result as? String ?? "（读不到页面尺寸）")
    guard let image = try? await webView.takeSnapshot(configuration: nil),
          let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else {
        print("✗ 截图失败")
        return 1
    }
    try? png.write(to: outputURL)
    print("截图：\(outputURL.path)")
    return 0
}
