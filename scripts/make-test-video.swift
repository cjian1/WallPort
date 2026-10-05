// 生成一段检查无缝循环用的测试视频（H.264，1920×1080，30 帧/秒）。
//
// 一根竖条匀速从左扫到右，每个循环恰好扫完一遍，所以循环点前后竖条的运动是连续的。
// 如果循环处有停顿、黑帧或跳帧，会看到竖条卡住、闪一下或跳一格。左下角是帧号。
//
// 用法：swift scripts/make-test-video.swift <输出.mp4> [秒数，默认 4]
//
// macOS 27 SDK 会对 AVAssetWriter 的经典接口给出弃用警告。这里有意保留经典接口，
// 让脚本在 macOS 14 到 27 上都能跑；警告不影响结果。
import AVFoundation
import CoreText
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("用法：swift scripts/make-test-video.swift <输出.mp4> [秒数]")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 4 : 4
let width = 1920
let height = 1080
let fps: Int32 = 30
let frameCount = Int(seconds * Double(fps))

try? FileManager.default.removeItem(at: output)
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
guard writer.startWriting() else { fatalError("无法开始写入：\(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

func draw(frame: Int, in context: CGContext) {
    let w = CGFloat(width)
    let h = CGFloat(height)
    context.setFillColor(CGColor(red: 0.06, green: 0.08, blue: 0.16, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // 竖条位置按帧均匀分布；越过右边界的部分从左边接上，保证运动是周期性的
    let barWidth: CGFloat = 120
    let x = CGFloat(frame) / CGFloat(frameCount) * w
    context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: x, y: 0, width: barWidth, height: h))
    if x + barWidth > w {
        context.fill(CGRect(x: x - w, y: 0, width: barWidth, height: h))
    }

    let text = NSAttributedString(string: "frame \(frame + 1) / \(frameCount)", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 56, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
    ])
    context.textPosition = CGPoint(x: 60, y: 60)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
}

for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var buffer: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool,
          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
          let pixels = buffer
    else { fatalError("无法分配像素缓冲") }

    CVPixelBufferLockBaseAddress(pixels, [])
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    draw(frame: frame, in: context)
    CVPixelBufferUnlockBaseAddress(pixels, [])
    adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
}

input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()
guard writer.status == .completed else { fatalError("写入失败：\(String(describing: writer.error))") }
print("\(output.path)：\(frameCount) 帧，\(seconds) 秒")
