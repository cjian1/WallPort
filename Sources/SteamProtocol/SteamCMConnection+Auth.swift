import Foundation

/// 在 CM 上跑整条认证会话（未登录的服务调用，EMsg 9804）。见 `CMAuthSession` 的说明。
extension SteamCMConnection {
    /// 第一步：拿账号的 RSA 公钥（不需要凭据）
    public func passwordRSAPublicKey(
        accountName: String, timeout: Duration = .seconds(20)
    ) async throws -> (modulus: String, exponent: String, timestamp: UInt64) {
        let body = try await callUnauthenticated(
            SteamServiceCall.method("Authentication.GetPasswordRSAPublicKey"),
            request: CMAuthSession.passwordRSAPublicKeyRequest(accountName: accountName), timeout: timeout)
        guard let key = CMAuthSession.publicKey(from: body) else {
            throw SteamCMError("Steam 没有给出 \(accountName) 的公钥（账号名可能不对）")
        }
        return key
    }

    /// 第二步：提交账号密码开始认证会话。`encryptedPassword` 是 `SteamRSA.encrypt` 的结果
    public func beginAuthSession(
        accountName: String, encryptedPassword: String, timestamp: UInt64,
        platformType: UInt32 = 1, websiteID: String = "Unknown", deviceName: String = "WallPort (Mac)",
        machineID: [UInt8]? = nil, timeout: Duration = .seconds(30)
    ) async throws -> CMAuthSession.Pending {
        let body = try await callUnauthenticated(
            SteamServiceCall.method("Authentication.BeginAuthSessionViaCredentials"),
            request: CMAuthSession.beginAuthSessionRequest(
                accountName: accountName, encryptedPassword: encryptedPassword, timestamp: timestamp,
                platformType: platformType, websiteID: websiteID, deviceName: deviceName,
                machineID: machineID),
            timeout: timeout)
        guard let pending = CMAuthSession.pending(from: body, accountName: accountName) else {
            throw SteamCMError("Steam 的登录回应看不懂（字段号 \(body.fieldNumbers)）")
        }
        return pending
    }

    /// 第三步（需要验证码时）：提交邮件 / 手机令牌上的验证码
    public func submitGuardCode(
        _ code: String, type: Int, to pending: CMAuthSession.Pending, timeout: Duration = .seconds(20)
    ) async throws {
        _ = try await callUnauthenticated(
            SteamServiceCall.method("Authentication.UpdateAuthSessionWithSteamGuardCode"),
            request: CMAuthSession.guardCodeRequest(
                clientID: pending.clientID, steamID: pending.steamID, code: code, codeType: type),
            timeout: timeout)
    }

    /// 第四步：轮询登录状态。好了返回令牌，还没好返回 nil
    public func pollAuthSession(
        _ pending: inout CMAuthSession.Pending, timeout: Duration = .seconds(20)
    ) async throws -> CMAuthSession.Tokens? {
        let body = try await callUnauthenticated(
            SteamServiceCall.method("Authentication.PollAuthSessionStatus"),
            request: CMAuthSession.pollRequest(clientID: pending.clientID, requestID: pending.requestID),
            timeout: timeout)
        if let newClientID = CMAuthSession.newClientID(from: body) { pending.clientID = newClientID }
        if let newURL = CMAuthSession.newChallengeURL(from: body) { pending.challengeURL = newURL }
        return CMAuthSession.tokens(from: body, accountName: pending.accountName)
    }

    /// 另一条路：手机扫码确认（不用密码）。返回会话状态和要画成二维码的 `challenge_url`；
    /// 之后的轮询还是走 `pollAuthSession`
    public func beginAuthSessionViaQR(
        platformType: UInt32 = 1, websiteID: String = "Unknown", deviceName: String = "WallPort (Mac)",
        timeout: Duration = .seconds(30)
    ) async throws -> (pending: CMAuthSession.Pending, challengeURL: String) {
        let body = try await callUnauthenticated(
            SteamServiceCall.method("Authentication.BeginAuthSessionViaQR"),
            request: CMAuthSession.qrAuthSessionRequest(
                platformType: platformType, websiteID: websiteID, deviceName: deviceName),
            timeout: timeout)
        guard let result = CMAuthSession.qrPending(from: body) else {
            throw SteamCMError("扫码登录的回应看不懂（字段号 \(body.fieldNumbers)）")
        }
        return result
    }
}
