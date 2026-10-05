import CommonCrypto
import Foundation

/// Valve 的对称加密（内容服务器上的**分块**用它；清单只包一层压缩容器，不加密）：
///
///     [AES-ECB 加密过的 IV 16 字节][AES-CBC 密文（PKCS#7 填充）]
///
/// 也就是说，前 16 字节不是明文 IV，而是**用 depot 密钥按 AES-ECB 解出来**的 IV。这跟"IV 明文放在
/// 最前面"的常见写法只差这一步，但错了第一步就整个解不开——2026-09-29 在本机对着真实分块核对过
/// （先按公开实现（MIT 许可的 node-steam-crypto `symmetricDecrypt`）写出这一步，再用
/// `WallpaperTool steam-ugc` 和 SteamCMD 下好的内容逐字节比对）。
///
/// 密钥是 depot 解密密钥（32 字节，`GetDepotDecryptionKey` 拿），不涉及账号密码。
public enum SteamChunkCipher {
    /// 解密一段加密数据。`key` 是 depot 解密密钥（16/24/32 字节对应 AES-128/192/256）
    public static func decrypt(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard key.count == 16 || key.count == 24 || key.count == 32 else {
            throw SteamCMError("depot 密钥长度不对（\(key.count) 字节）")
        }
        guard data.count >= 32 else { throw SteamCMError("加密数据太短（\(data.count) 字节）") }
        // 第一步：前 16 字节是"被 ECB 加密的 IV"
        let iv = try crypt(.decrypt, key: key, iv: [], data: Array(data[0..<16]), padding: false, ecb: true)
        guard iv.count == 16 else { throw SteamCMError("IV 解出来不是 16 字节") }
        // 第二步：剩下的按 CBC 解，PKCS#7 填充由 CommonCrypto 去掉
        return try crypt(.decrypt, key: key, iv: iv, data: Array(data[16...]), padding: true)
    }

    /// 加密（只有测试和造夹具用得上：Steam 那边不会让我们加密）
    static func encrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]? = nil) throws -> [UInt8] {
        guard key.count == 16 || key.count == 24 || key.count == 32 else {
            throw SteamCMError("depot 密钥长度不对（\(key.count) 字节）")
        }
        let iv = iv ?? (0..<16).map { _ in UInt8.random(in: 0...255) }
        guard iv.count == 16 else { throw SteamCMError("IV 必须是 16 字节") }
        let encryptedIV = try crypt(.encrypt, key: key, iv: [], data: iv, padding: false, ecb: true)
        let body = try crypt(.encrypt, key: key, iv: iv, data: data, padding: true)
        return encryptedIV + body
    }

    private enum Operation { case encrypt, decrypt }

    private static func crypt(
        _ operation: Operation, key: [UInt8], iv: [UInt8], data: [UInt8], padding: Bool,
        ecb: Bool = false
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        // CommonCrypto 默认是 CBC，ECB 要显式打开（漏了它，"解 IV"那一步会用 CBC 解，整个就歪了）
        var options: CCOptions = ecb ? CCOptions(kCCOptionECBMode) : 0
        if padding { options |= CCOptions(kCCOptionPKCS7Padding) }
        let status = CCCrypt(
            operation == .encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            options,
            key, key.count, iv,
            data, data.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw SteamCMError("AES 失败（状态 \(status)）") }
        return Array(output[0..<moved])
    }
}

/// CRC32（IEEE，和 zlib 的一样）。Steam 的 `VSZa` 容器头尾各放一个
public enum CRC32 {
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in bytes {
            value = table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
        return value ^ 0xffff_ffff
    }

    /// 按小端写进字节流（Steam 的容器里就是这么放的）
    public static func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}
