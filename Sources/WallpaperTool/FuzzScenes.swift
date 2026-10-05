import Foundation
import Metal
import SceneRenderer
import WallpaperFormats

/// 抗坏文件测试：拿真实的场景包做各种破坏（截断、改字节、篡改 scene.json / 材质 / 贴图头），每个变体在单独的子进程里
/// 构建、渲染几帧，记下崩溃和卡死。创意工坊的壁纸是陌生人做的，一张坏壁纸不能让整个 App 崩掉。
/// 崩溃 / 卡死的变体连同子进程的输出存进输出目录（变体里是用户的壁纸内容，输出目录要放在仓库外面）。
///
///   WallpaperTool fuzz-scenes <目录> <WE 自带素材目录> <输出目录> [每个场景几个变体，默认 12] [随机种子，默认 1]
///   WallpaperTool fuzz-one <场景包> <WE 自带素材目录>        （子进程用：构建、渲染三帧，出错正常退出）
/// 环境变量 SHADER_CACHE 给一个着色器缓存目录，变体之间共用，快很多
func fuzzScenes(in directory: String, assets: String, output: String, variants: Int, seed: UInt64) -> Int32 {
    let outputURL = URL(fileURLWithPath: output, isDirectory: true)
    try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scene.pkg").path) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var random = SplitMix64(seed: seed)
    var runs = 0, crashes = 0, hangs = 0, handled = 0
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    for folder in folders {
        guard let package = try? ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg")) else { continue }
        let files = package.entries.map { ($0.name, package.contents(of: $0)) }
        for index in 0..<variants {
            let (bytes, description) = PackageMutator.mutate(files, random: &random)
            let variant = work.appendingPathComponent("\(folder.lastPathComponent)-\(index).pkg")
            guard (try? bytes.write(to: variant)) != nil else { continue }
            runs += 1
            let result = runChild(package: variant, assets: assets, timeout: 30)
            switch result.outcome {
            case .ok: break
            case .handledError: handled += 1
            case .crashed, .hung:
                if case .crashed = result.outcome { crashes += 1 } else { hangs += 1 }
                let name = "\(folder.lastPathComponent)-\(index)"
                try? FileManager.default.copyItem(at: variant, to: outputURL.appendingPathComponent("\(name).pkg"))
                try? (description + "\n\n" + result.log).write(
                    to: outputURL.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
                print("✗ \(name) \(result.outcome)：\(description)")
            }
            try? FileManager.default.removeItem(at: variant)
        }
    }
    print("变体 \(runs) 个：正常 \(runs - handled - crashes - hangs)、报错（没崩）\(handled)、崩溃 \(crashes)、卡死 \(hangs)")
    return crashes + hangs == 0 ? 0 : 1
}

func fuzzOne(package path: String, assets: String) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else { return 2 }
    do {
        let package = try ScenePackage(contentsOf: URL(fileURLWithPath: path))
        let renderer = try SceneRenderer(
            device: device, package: package, assets: URL(fileURLWithPath: assets, isDirectory: true),
            targetSize: SIMD2(640, 400),
            shaderCache: ProcessInfo.processInfo.environment["SHADER_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        for time: Float in [0, 0.5, 5] { _ = try renderer.renderImage(width: 640, height: 400, time: time) }
        print("ok")
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 3
    }
}

private enum Outcome: CustomStringConvertible {
    case ok, handledError, crashed(Int32), hung

    var description: String {
        switch self {
        case .ok: "正常"
        case .handledError: "报错"
        case .crashed(let signal): "崩溃（信号 \(signal)）"
        case .hung: "卡死"
        }
    }
}

private func runChild(package: URL, assets: String, timeout: TimeInterval) -> (outcome: Outcome, log: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["fuzz-one", package.path, assets]
    var environment = ProcessInfo.processInfo.environment
    environment["SWIFT_BACKTRACE"] = "enable=yes,interactive=no,color=no"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let collected = LockedData()
    pipe.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
    guard (try? process.run()) != nil else { return (.handledError, "启动不了子进程") }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return (.hung, collected.text)
    }
    process.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
    if process.terminationReason == .uncaughtSignal { return (.crashed(process.terminationStatus), collected.text) }
    return (process.terminationStatus == 0 ? .ok : .handledError, collected.text)
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var text: String { lock.withLock { String(decoding: data.suffix(64 * 1024), as: UTF8.self) } }
}

/// 可重复的伪随机数（同一个种子每次出同样的变体）
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 场景包的各种破坏
enum PackageMutator {
    static func mutate(_ files: [(String, Data)], random: inout SplitMix64) -> (Data, String) {
        var files = files
        var notes: [String] = []
        let roll = Int.random(in: 0..<100, using: &random)
        switch roll {
        case 0..<10:
            // 整个包截断
            let packed = pack(files)
            let length = Int.random(in: 0..<max(1, packed.count), using: &random)
            return (packed.prefix(length), "整个包截断到 \(length)/\(packed.count) 字节")
        case 10..<15:
            // 包头里的数字乱改
            var packed = pack(files)
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                let offset = Int.random(in: 0..<min(packed.count, 256), using: &random)
                packed[offset] = UInt8.random(in: 0...255, using: &random)
            }
            return (packed, "包头的字节乱改")
        default:
            break
        }
        let count = Int.random(in: 1...3, using: &random)
        for _ in 0..<count {
            let jsonIndexes = files.indices.filter { files[$0].0.hasSuffix(".json") }
            let binaryIndexes = files.indices.filter { index in
                [".tex", ".mdl"].contains { files[index].0.hasSuffix($0) }
            }
            let pickJSON = !jsonIndexes.isEmpty && (binaryIndexes.isEmpty || Int.random(in: 0..<100, using: &random) < 65)
            if pickJSON {
                // scene.json 被选中的机会大一些
                let scene = jsonIndexes.first { files[$0].0 == "scene.json" }
                let index = scene != nil && Bool.random(using: &random) ? scene! : jsonIndexes.randomElement(using: &random)!
                let (data, note) = mutateJSON(files[index].1, random: &random)
                files[index].1 = data
                notes.append("\(files[index].0)：\(note)")
            } else if let index = binaryIndexes.randomElement(using: &random) {
                let (data, note) = mutateBinary(files[index].1, random: &random)
                files[index].1 = data
                notes.append("\(files[index].0)：\(note)")
            }
        }
        return (pack(files), notes.joined(separator: "；"))
    }

    /// 按 scene.pkg 的格式打回去
    static func pack(_ files: [(String, Data)]) -> Data {
        var header = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { header.append(contentsOf: $0) } }
        u32(8)
        header += Data("PKGV0001".utf8)
        u32(files.count)
        var body = Data()
        for (name, data) in files {
            u32(name.utf8.count)
            header += Data(name.utf8)
            u32(body.count)
            u32(data.count)
            body += data
        }
        return header + body
    }

    static func mutateBinary(_ data: Data, random: inout SplitMix64) -> (Data, String) {
        var data = data
        guard !data.isEmpty else { return (data, "空文件") }
        switch Int.random(in: 0..<3, using: &random) {
        case 0:
            let length = Int.random(in: 0..<data.count, using: &random)
            return (data.prefix(length), "截断到 \(length)/\(data.count) 字节")
        case 1:
            // 文件头里的一个 32 位数改成极端值（宽、高、个数、长度多在前面）
            let values: [UInt32] = [0, 1, 0xFFFF_FFFF, 0x7FFF_FFFF, 0x8000_0000, 65536, 100_000]
            let value = values.randomElement(using: &random)!
            let offset = Int.random(in: 0..<max(1, min(data.count - 4, 96)), using: &random)
            guard data.count >= offset + 4 else { return (data, "太短") }
            withUnsafeBytes(of: value.littleEndian) { bytes in
                for (i, byte) in bytes.enumerated() { data[data.startIndex + offset + i] = byte }
            }
            return (data, "偏移 \(offset) 的 32 位数改成 \(value)")
        default:
            let flips = Int.random(in: 1...16, using: &random)
            for _ in 0..<flips {
                let offset = Int.random(in: 0..<data.count, using: &random)
                data[data.startIndex + offset] ^= UInt8.random(in: 1...255, using: &random)
            }
            return (data, "随机翻了 \(flips) 个字节")
        }
    }

    static func mutateJSON(_ data: Data, random: inout SplitMix64) -> (Data, String) {
        guard var root = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers, .fragmentsAllowed]) else {
            return mutateBinary(data, random: &random)
        }
        var paths: [[Any]] = []
        func collect(_ node: Any, _ path: [Any]) {
            guard paths.count < 4000 else { return }
            paths.append(path)
            if let dictionary = node as? [String: Any] {
                for (key, value) in dictionary { collect(value, path + [key]) }
            } else if let array = node as? [Any] {
                for (index, value) in array.enumerated() { collect(value, path + [index]) }
            }
        }
        collect(root, [])
        guard let path = paths.dropFirst().randomElement(using: &random) else { return (data, "没有可改的") }
        let replacements: [(Any?, String)] = [
            (nil, "删掉"), ("", "空字符串"), ("abc", "字符串"), (0, "0"), (-1, "-1"), (1e9, "1e9"), (-1e9, "-1e9"),
            (1e300, "1e300"), (true, "true"), (NSNull(), "null"), ([Any](), "空数组"), ([String: Any](), "空对象"),
            ("nan nan nan", "\"nan nan nan\""), ("1e30 1e30 1e30", "\"1e30 …\""), ("-5 -5", "\"-5 -5\""),
            (String(repeating: "x", count: 100_000), "十万字符的字符串"), ([1, "a", NSNull()], "杂乱数组"),
        ]
        let (value, note) = replacements.randomElement(using: &random)!
        root = set(root, at: ArraySlice(path), to: value)
        let output = (try? JSONSerialization.data(withJSONObject: root, options: [.fragmentsAllowed])) ?? data
        return (output, "\(path.map { "\($0)" }.joined(separator: ".")) 改成\(note)")
    }

    private static func set(_ node: Any, at path: ArraySlice<Any>, to value: Any?) -> Any {
        guard let first = path.first else { return value ?? NSNull() }
        if var dictionary = node as? [String: Any], let key = first as? String {
            if path.count == 1, value == nil {
                dictionary[key] = nil
            } else if let child = dictionary[key] {
                dictionary[key] = set(child, at: path.dropFirst(), to: value)
            }
            return dictionary
        }
        if var array = node as? [Any], let index = first as? Int, array.indices.contains(index) {
            if path.count == 1, value == nil {
                array.remove(at: index)
            } else {
                array[index] = set(array[index], at: path.dropFirst(), to: value)
            }
            return array
        }
        return node
    }
}
