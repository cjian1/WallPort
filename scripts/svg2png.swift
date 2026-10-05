import AppKit
import WebKit
// 用 WebKit 把 SVG 画成带透明通道的 PNG（投影滤镜、渐变都支持；QuickLook 的 qlmanage 会垫白底，sips 不认 SVG）。
// 用法：swift scripts/svg2png.swift 输入.svg 输出.png 边长（点）。Retina 屏上输出的像素是边长的两倍
let args = CommandLine.arguments
let svg = try! String(contentsOfFile: args[1], encoding: .utf8)
let output = args[2]
let size = CGFloat(Double(args[3])!)
let app = NSApplication.shared
final class Loader: NSObject, WKNavigationDelegate {
    let view: WKWebView
    init(size: CGFloat) {
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.setValue(false, forKey: "drawsBackground")
        super.init()
        view.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            config.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
            webView.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    print("截图失败 \(String(describing: error))"); exit(1)
                }
                try! png.write(to: URL(fileURLWithPath: output))
                print("写好 \(output) \(rep.pixelsWide)×\(rep.pixelsHigh)")
                exit(0)
            }
        }
    }
}
let loader = Loader(size: size)
let html = """
<html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}svg{display:block;width:\(Int(size))px;height:\(Int(size))px}</style></head><body>\(svg)</body></html>
"""
loader.view.loadHTMLString(html, baseURL: nil)
app.run()
