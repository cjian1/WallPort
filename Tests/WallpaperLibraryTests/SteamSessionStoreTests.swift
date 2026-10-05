import CryptoKit
import Foundation
import Testing
@testable import WallpaperLibrary

/// 会话存储：默认是**加密文件**（不碰钥匙串）。这里只测文件后端——钥匙串会弹系统授权，
/// 测试里不碰它。
@Suite struct SteamSessionStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SteamSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let sample = SteamCMSession(
        accountName: "someone", steamID: "76561198419273616", refreshToken: "refresh-token-abc",
        accessToken: "access-token-xyz")

    @Test func roundTripsThroughEncryptedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SteamCMSessionStore(directory: directory)
        #expect(store.load() == nil, "还没存过，读到 nil")
        store.save(sample)
        #expect(store.load() == sample)
    }

    /// 文件里不能出现明文令牌，也不能是能直接读的 JSON
    @Test func fileIsEncryptedNotPlaintext() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SteamCMSessionStore(directory: directory)
        store.save(sample)
        let data = try Data(contentsOf: store.fileURL)
        #expect(data.prefix(4) == Data("WPS1".utf8))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("refresh-token-abc"))
        #expect(!text.contains("someone"))
        #expect(!text.contains("76561198419273616"))
    }

    /// 权限 0600（只有自己能读），目录 0700
    @Test func permissionsAreTight() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SteamCMSessionStore(directory: directory)
        store.save(sample)
        let file = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: store.fileURL.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    /// 换了机器密钥（这里用不同目录模拟"另一台机器"没有关系）时，解不开就当没登录——
    /// 不能崩、也不能把半截数据当成有效会话
    @Test func corruptedFileReadsAsNoSession() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SteamCMSessionStore(directory: directory)
        store.save(sample)
        var data = try Data(contentsOf: store.fileURL)
        data[data.count - 1] ^= 0xff                      // 改坏密文
        try data.write(to: store.fileURL)
        #expect(store.load() == nil)
        try Data("garbage".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }

    @Test func clearRemovesTheSession() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SteamCMSessionStore(directory: directory)
        store.save(sample)
        store.clear()
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// 机器密钥必须稳定：读得到 IOPlatformUUID（之前按 Data 读永远读不到，退回用会变的主机名，
    /// 会话文件时而解不开，表现成"自动退出登录"）
    @Test func machineIdentifierIsStable() {
        let identifier = SteamCMSessionStore.machineIdentifier()
        #expect(identifier.count == 36, "应当是 IOPlatformUUID（8-4-4-4-12）")
        #expect(UUID(uuidString: identifier) != nil)
        for _ in 0..<5 { #expect(SteamCMSessionStore.machineIdentifier() == identifier) }
    }

    /// 旧版本（用主机名算密钥）存的会话：还能读出来，并且读出来之后换成新密钥存一遍
    @Test func legacyFileIsMigrated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SteamCMSessionStore(directory: directory)
        let legacyKey = try #require(SteamCMSessionStore.legacyMachineKeys(salt: "WallPort Steam 会话").first)
        let box = try AES.GCM.seal(try JSONEncoder().encode(sample), using: legacyKey)
        try (Data("WPS1".utf8) + (box.combined ?? Data())).write(to: store.fileURL)
        #expect(store.load() == sample)
        // 已经换成新密钥：直接用新密钥解得开
        let data = try Data(contentsOf: store.fileURL)
        let reopened = try AES.GCM.open(
            try AES.GCM.SealedBox(combined: Data(data.dropFirst(4))),
            using: SteamCMSessionStore.machineKey(salt: "WallPort Steam 会话"))
        #expect(try JSONDecoder().decode(SteamCMSession.self, from: reopened) == sample)
    }

    /// 默认后端是文件（用户的明确要求：不放进苹果钥匙串），放在统一文件夹的 Data 里
    @Test func defaultBackendIsFile() throws {
        let store = SteamCMSessionStore()
        #expect(store.fileURL.path.hasSuffix("/WallPort/Data/steam-session.json"))
    }
}
