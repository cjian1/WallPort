import Foundation
import Security

/// 登录时加密密码用的 RSA（Steam 给的是十六进制的模数和指数，加密按 PKCS#1 v1.5，结果 base64）。
///
/// 这套算法原来在网页登录（`WallpaperLibrary.SteamWebAuth`，M7 用过、现在已删）里；M7.5 换成
/// 客户端协议之后挪到这一层，网页那条路已经没有了。
public enum SteamRSA {
    /// 用 Steam 给的公钥加密密码，返回 base64
    public static func encrypt(password: String, modulusHex: String, exponentHex: String) throws -> String {
        guard let modulus = Data(hex: modulusHex), let exponent = Data(hex: exponentHex) else {
            throw SteamCMError("Steam 给的公钥格式不对")
        }
        let der = DER.sequence([DER.integer(modulus), DER.integer(exponent)])
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: modulus.drop { $0 == 0 }.count * 8,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(
                key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, &error)
        else { throw SteamCMError("加密密码失败") }
        return (encrypted as Data).base64EncodedString()
    }
}

/// 最小的 DER 编码：RSA 公钥 = SEQUENCE { INTEGER 模数, INTEGER 指数 }
enum DER {
    static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty { value = Data([0]) }
        if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return Data([0x02]) + length(value.count) + value
    }

    static func sequence(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x30]) + length(body.count) + body
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

extension Data {
    init?(hex: String) {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = Self.nibble(characters[index]), let low = Self.nibble(characters[index + 1])
            else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
