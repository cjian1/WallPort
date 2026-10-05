import CryptoKit
import Foundation
import SteamProtocol

/// 探针：不靠 SteamCMD，自己从内容服务器（CDN）把创意工坊的内容下下来，并按清单拼成文件。
///
///     # 先看一枚分块对不对（分块编号就是清单里的 sha）
///     WallpaperTool steam-ugc --chunk 012a5156aae367d96212e99a5cdbe28db2c7108d /tmp/chunk.bin \
///         --depot 431960 --host steampipe.akamaized.net --key-env WALLPORT_DEPOT_KEY
///
///     # 按清单下整份内容，再和 SteamCMD 下好的那份逐字节比对
///     WallpaperTool steam-ugc "<清单>.manifest" /tmp/ugc-out \
///         --depot 431960 --host steampipe.akamaized.net --key-env WALLPORT_DEPOT_KEY \
///         --verify "/Users/me/Library/Application Support/Steam/steamapps/workshop/content/431960/3807008481"
///
/// depot 解密密钥（32 字节十六进制）建议用 `--key-env <变量名>` 从环境变量读：命令行参数别的进程
/// 用 `ps` 看得到。应用里应该走 CM 的 `GetDepotDecryptionKey`（`SteamCMConnection.depotDecryptionKey`），
/// 不落到磁盘、也不进日志。
func steamUGCProbe(_ arguments: [String]) async -> Int32 {
    var depot: UInt32 = 431_960          // Wallpaper Engine
    var hosts = ["steampipe.akamaized.net"]
    var keyHex: String?
    var keyVariable: String?
    var chunkSHA: String?
    var manifestID: UInt64?
    var requestCode: UInt64?
    var verifyDirectory: String?
    var positionals: [String] = []
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--depot":
            index += 1
            guard index < arguments.count, let value = UInt32(arguments[index]) else {
                print("--depot 后面要跟 depot 编号"); return 2
            }
            depot = value
        case "--host":
            index += 1
            guard index < arguments.count else { print("--host 后面要跟主机名"); return 2 }
            hosts = arguments[index].split(separator: ",").map(String.init)
        case "--key":
            index += 1
            guard index < arguments.count else { print("--key 后面要跟十六进制密钥"); return 2 }
            keyHex = arguments[index]
        case "--key-env":
            index += 1
            guard index < arguments.count else { print("--key-env 后面要跟变量名"); return 2 }
            keyVariable = arguments[index]
        case "--chunk":
            index += 1
            guard index < arguments.count else { print("--chunk 后面要跟分块编号"); return 2 }
            chunkSHA = arguments[index]
        case "--manifest":
            index += 1
            guard index < arguments.count, let value = UInt64(arguments[index]) else {
                print("--manifest 后面要跟清单编号"); return 2
            }
            manifestID = value
        case "--request-code":
            index += 1
            guard index < arguments.count, let value = UInt64(arguments[index]) else {
                print("--request-code 后面要跟请求码"); return 2
            }
            requestCode = value
        case "--verify":
            index += 1
            guard index < arguments.count else { print("--verify 后面要跟参考目录"); return 2 }
            verifyDirectory = arguments[index]
        default:
            if arguments[index].hasPrefix("--") {
                print("认不出的参数 \(arguments[index])")
                return 2
            }
            positionals.append(arguments[index])
        }
        index += 1
    }

    // 需要的位置参数：`--chunk` 时是"写到哪里"，`--manifest` 时是"下到哪个目录"，
    // 其余情况是"清单文件 + 输出目录"
    let manifestPath = chunkSHA == nil && manifestID == nil ? positionals.first : nil
    let outputPath = chunkSHA != nil
        ? positionals.first
        : (manifestID != nil ? positionals.first : positionals.dropFirst().first)
    let expectedCount = chunkSHA != nil ? 1 : (manifestID != nil ? 1 : 2)
    guard positionals.count == expectedCount, let outputPath else {
        print("""
            用法：
              WallpaperTool steam-ugc <清单文件> <输出目录> --depot <编号> --host <主机[,主机]> \\
                  (--key <十六进制> | --key-env <变量名>) [--verify <参考目录>]
              WallpaperTool steam-ugc --chunk <分块编号> <输出文件> --depot <编号> --host <主机> …
              WallpaperTool steam-ugc --manifest <清单编号> <输出目录> --depot <编号> --request-code <码> …
            """)
        return 2
    }
    guard let keyHex = keyHex ?? keyVariable.flatMap({ ProcessInfo.processInfo.environment[$0] }) else {
        print(keyVariable.map { "✗ 环境变量 \($0) 是空的（depot 解密密钥要 32 字节十六进制）" }
            ?? "✗ 没有 depot 解密密钥（--key 或 --key-env）")
        return 2
    }
    guard let key = hexBytes(keyHex), key.count == 32 else {
        print("✗ depot 密钥要 64 个十六进制字符（32 字节）")
        return 2
    }

    let downloader = UGCContentDownloader()
    if let chunkSHA {
        do {
            let started = Date()
            let data = try await downloader.chunk(shaHex: chunkSHA, depot: depot, hosts: hosts, depotKey: key)
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            try Data(data).write(to: URL(fileURLWithPath: outputPath))
            print("✓ 分块 \(chunkSHA.prefix(12))… 下好并解开：\(data.count) 字节，用时 \(seconds) 秒"
                + "，写入 \(outputPath)")
            return 0
        } catch {
            print("✗ 取分块失败：\(error.localizedDescription)")
            return 1
        }
    }

    let manifest: ContentManifest
    if let manifestID {
        guard let code = requestCode else {
            print("✗ 从 CDN 取清单要请求码（CM 的 ContentServerDirectory.GetManifestRequestCode）；"
                + "本机还没有登录成功的 CM 会话，先用 depotcache 里的清单文件")
            return 2
        }
        do {
            manifest = try await downloader.manifest(
                depot: depot, manifestID: manifestID, requestCode: code, hosts: hosts, depotKey: key)
        } catch {
            print("✗ 取清单失败：\(error.localizedDescription)")
            return 1
        }
    } else {
        guard let manifestPath else {
            print("✗ 要一份清单文件（或者用 --manifest 从 CDN 取）")
            return 2
        }
        do {
            manifest = try ContentManifest(data: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        } catch {
            print("✗ 读清单失败：\(error.localizedDescription)")
            return 1
        }
    }

    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    print("清单 \(manifest.manifestID)：depot \(manifest.depotID)，\(manifest.files.count) 个文件，"
        + "\(manifest.chunkCount) 个分块，共 "
        + ByteCountFormatter.string(fromByteCount: Int64(manifest.totalBytes), countStyle: .file))
    do {
        let started = Date()
        let state = try await downloader.download(manifest, to: output, hosts: hosts, depotKey: key) { state in
            if state.chunksDone % 10 == 0 || state.chunksDone == state.chunksTotal {
                print("   … \(state.chunksDone)/\(state.chunksTotal) 个分块，"
                    + ByteCountFormatter.string(fromByteCount: Int64(state.bytesDone), countStyle: .file))
            }
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        let size = ByteCountFormatter.string(fromByteCount: Int64(state.bytesDone), countStyle: .file)
        print("✓ 下完 \(state.chunksDone) 个分块、\(state.filesDone) 个文件，共 \(size)，用时 \(seconds) 秒")
    } catch {
        print("✗ 下载失败：\(error.localizedDescription)")
        return 1
    }

    guard let verifyDirectory else { return 0 }
    return verify(manifest, at: output, against: URL(fileURLWithPath: verifyDirectory, isDirectory: true))
}

/// 逐字节比对：下下来的和参考目录（SteamCMD 下好的那份）必须一模一样
private func verify(_ manifest: ContentManifest, at directory: URL, against reference: URL) -> Int32 {
    var bad = 0
    for file in manifest.files {
        let mine = directory.appendingPathComponent(file.name)
        let theirs = reference.appendingPathComponent(file.name)
        guard let a = try? Data(contentsOf: mine), let b = try? Data(contentsOf: theirs) else {
            print("   ✗ 有一边读不到：\(file.name)")
            bad += 1
            continue
        }
        let same = a == b
        let digest = Insecure.SHA1.hash(data: a).map { String(format: "%02x", $0) }.joined()
        print("   \(same ? "✓" : "✗") \(file.name)：\(a.count) 字节，SHA-1 \(digest.prefix(12))…"
            + (same ? "" : "（参考的是 \(b.count) 字节）"))
        if !same { bad += 1 }
    }
    print(bad == 0
        ? "✓ 和参考目录逐字节一致（\(manifest.files.count) 个文件）"
        : "✗ 有 \(bad) 个文件对不上")
    return bad == 0 ? 0 : 1
}

private func hexBytes(_ text: String) -> [UInt8]? {
    let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    guard characters.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var index = 0
    while index < characters.count {
        guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else { return nil }
        bytes.append(high << 4 | low)
        index += 2
    }
    return bytes
}

private func nibble(_ character: UInt8) -> UInt8? {
    switch character {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
    default: nil
    }
}
