import Foundation

/// Steam 的令牌是 JWT：登录前先看清 `iss` / `aud` / `sub` 很有用
/// （CM 只接受 `iss = "steam"`、`aud` 里含 `client` 的 refresh token，见公开实现 steam-user 的检查）
public enum SteamJWT {
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// `aud` 可能是字符串也可能是数组
    public static func audiences(_ token: String) -> [String] {
        guard let aud = claims(token)?["aud"] else { return [] }
        if let single = aud as? String { return [single] }
        return aud as? [String] ?? []
    }

    /// `sub` 是 SteamID（十进制字符串）
    public static func steamID(_ token: String) -> UInt64? {
        guard let sub = claims(token)?["sub"] as? String, let value = UInt64(sub) else { return nil }
        return value
    }

    /// 一句话摘要，排查用
    public static func describe(_ token: String) -> String {
        guard let claims = claims(token) else { return "不是 JWT" }
        let issuer = claims["iss"] as? String ?? "?"
        let subject = claims["sub"] as? String ?? "?"
        let audience = audiences(token).joined(separator: ",")
        let expiry = (claims["exp"] as? NSNumber).map { "exp \($0.intValue)" } ?? "没有 exp"
        return "iss \(issuer)，aud [\(audience)]，sub \(subject)，\(expiry)"
    }
}
