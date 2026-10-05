import CryptoKit
import DesktopHost
import Foundation
import IOKit
import Security

/// 登录会话存哪儿。**默认存文件**：`~/Library/Application Support/MacWallpaper/steam-session.json`，
/// 权限 0600、内容用"这台机器"的密钥加密（AES-GCM）。
///
/// 为什么不默认用钥匙串：钥匙串每次换构建签名（开发阶段临时签名就是每次）都可能弹系统授权，
/// 没人点就一直卡着；而且用户可能不想把 Steam 令牌交给系统钥匙串管。
///
/// 这个方案保护什么、不保护什么（写在注释里，免得以后被误解）：
/// - 保护：别的用户读不到（0600）；文件被拷走、进备份、被 `cat` 一眼看到都不泄密（密文里不解出令牌）；
/// - **不**保护：能在这台机器上以你身份跑代码的程序——机器密钥是算出来的，它也能算。
///   要更强的保护只有两条路：钥匙串（`.keychain` 后端），或者每次启动重新登录。
public struct SteamCMSessionStore: Sendable {
    public enum Backend: Sendable, Equatable {
        /// 加密文件（默认）
        case file
        /// macOS 钥匙串
        case keychain
    }

    private let backend: Backend
    private let service: String
    private let directory: URL

    public init(
        backend: Backend = .file, service: String = "WallPort Steam 会话", directory: URL? = nil
    ) {
        self.backend = backend
        self.service = service
        self.directory = directory ?? AppFolder.data
    }

    /// 会话文件的位置（`--backend file` 时）
    public var fileURL: URL { directory.appendingPathComponent("steam-session.json") }

    // MARK: - 读写

    public func load() -> SteamCMSession? {
        switch backend {
        case .file: return loadFromFile()
        case .keychain: return loadFromKeychain()
        }
    }

    public func save(_ session: SteamCMSession) {
        switch backend {
        case .file: saveToFile(session)
        case .keychain: saveToKeychain(session)
        }
    }

    public func clear() {
        switch backend {
        case .file: try? FileManager.default.removeItem(at: fileURL)
        case .keychain: clearKeychain()
        }
    }

    // MARK: - 文件后端

    private func loadFromFile() -> SteamCMSession? {
        guard let data = try? Data(contentsOf: fileURL), data.count > 4,
              data.prefix(4) == Self.magic
        else { return nil }
        let sealed = Data(data.dropFirst(4))
        if let session = Self.open(sealed, key: Self.machineKey(salt: service)) { return session }
        // 旧版本的密钥：机器 UUID 没读出来、退回用了主机名（见 `legacyMachineKey`）。能解开就换成新密钥存一遍
        for key in Self.legacyMachineKeys(salt: service) {
            if let session = Self.open(sealed, key: key) {
                saveToFile(session)
                return session
            }
        }
        // 机器换了、文件被改过、密钥不匹配：当作没登录，让用户重新登录就行
        return nil
    }

    private static func open(_ sealed: Data, key: SymmetricKey) -> SteamCMSession? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return try? JSONDecoder().decode(SteamCMSession.self, from: plain)
    }

    private func saveToFile(_ session: SteamCMSession) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // 目录可能早就存在（以前是别的权限）：显式收紧一次
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let plain = try JSONEncoder().encode(session)
            let box = try AES.GCM.seal(plain, using: Self.machineKey(salt: service))
            guard let combined = box.combined else { return }
            var data = Data(Self.magic)
            data.append(combined)
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            // 不进备份（Time Machine / iCloud）——令牌是本机用的东西
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            // 存不下就算了：登录这次还有效，下次要重新登录
        }
    }

    private static let magic = Data("WPS1".utf8)

    /// "这台机器"的密钥：由机器标识（IOPlatformUUID）+ 用途串算出来。
    /// 注意这是**混淆级别的保护**，能在这台机器上跑代码的人也能算出来（见类型注释）
    static func machineKey(salt: String) -> SymmetricKey {
        key(seed: machineIdentifier() + "|" + salt)
    }

    /// 机器标识必须**每次都一样**：IOPlatformUUID；读不到时用用户名 + 主目录（也不会变）。
    /// 不能用 `ProcessInfo.hostName`：它要做名字解析，同一台机器上一会儿是 `xxx.local`、一会儿是 IPv6 临时地址的
    /// 反向解析名（2026-09-29 实测连续 6 次得到 3 个不同的值），密钥跟着变，会话文件就时而解不开
    static func machineIdentifier() -> String {
        if let uuid = platformUUID() { return uuid }
        return NSUserName() + "|" + NSHomeDirectory()
    }

    /// 2026-09-29 之前的写法：把 IOPlatformUUID 当成 Data 读（它其实是字符串）永远读不到，于是一直用的是
    /// "主机名 + 用户名"。读旧文件时用当前能解析到的主机名试一次，解开了就换成新密钥
    static func legacyMachineKeys(salt: String) -> [SymmetricKey] {
        var names = [ProcessInfo.processInfo.hostName]
        if let local = Host.current().name, !names.contains(local) { names.append(local) }
        return names.map { key(seed: $0 + NSUserName() + "|" + salt) }
    }

    private static func key(seed: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        // 属性是 CFString（不是 CFData）
        guard let uuid = value?.takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return uuid
    }

    // MARK: - 钥匙串后端（想用更强的保护时选它）

    private var keychainQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: "cm-session",
        ]
    }

    private func loadFromKeychain() -> SteamCMSession? {
        var query = keychainQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(SteamCMSession.self, from: data)
    }

    private func saveToKeychain(_ session: SteamCMSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        clearKeychain()
        var item = keychainQuery
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func clearKeychain() {
        SecItemDelete(keychainQuery as CFDictionary)
    }
}
