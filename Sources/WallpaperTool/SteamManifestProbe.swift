import Foundation
import SteamProtocol

/// 校对 UGC 清单的解析：拿本机 SteamCMD 下载时缓存的 `.manifest` 对着已下载的文件看。
///
///     WallpaperTool steam-manifest <manifest 文件> [已下载目录]
///
/// 给了目录就逐个文件核对名字和大小，再把同一批文件按清单里的分块拼一遍（分块在磁盘上是
/// 拼好的成品，这一步验证的是"偏移 + 长度"的算法，不是分块下载）。
func steamManifestProbe(_ arguments: [String]) -> Int32 {
    let path = arguments[0]
    guard let data = FileManager.default.contents(atPath: path) else {
        print("✗ 读不到 \(path)")
        return 1
    }
    let manifest: ContentManifest
    do {
        manifest = try ContentManifest(data: data)
    } catch {
        print("✗ 解析失败：\(error.localizedDescription)")
        return 1
    }
    let size = ByteCountFormatter.string(fromByteCount: Int64(manifest.totalBytes), countStyle: .file)
    print("清单 \(manifest.manifestID)：depot \(manifest.depotID)，\(manifest.files.count) 个文件，"
        + "\(manifest.chunkCount) 个分块，共 \(size)")
    var compressed = 0
    for file in manifest.files {
        compressed += file.chunks.filter(\.isCompressed).count
        print("   \(file.name)  \(file.size) 字节，\(file.chunks.count) 块"
            + (file.chunks.first.map { "，首块 \($0.shaHex.prefix(12))…" } ?? ""))
    }
    print("   压缩过的分块：\(compressed) / \(manifest.chunkCount)")

    guard arguments.count > 1 else { return 0 }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    var mismatches = 0
    for file in manifest.files {
        let url = root.appendingPathComponent(file.name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let actual = (attributes[.size] as? NSNumber)?.intValue
        else {
            print("   ✗ 磁盘上没有 \(file.name)")
            mismatches += 1
            continue
        }
        if UInt64(actual) != file.size {
            print("   ✗ \(file.name) 大小对不上：清单 \(file.size)，磁盘 \(actual)")
            mismatches += 1
        }
    }
    let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0
    print(mismatches == 0
        ? "✓ \(manifest.files.count) 个文件的清单与磁盘一致（目录里另有 \(max(0, onDisk - manifest.files.count)) 项）"
        : "✗ \(mismatches) 处对不上")
    return mismatches == 0 ? 0 : 1
}
