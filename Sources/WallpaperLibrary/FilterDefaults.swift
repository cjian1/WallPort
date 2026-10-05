import DesktopHost
import Foundation

/// 界面上的筛选条件（工坊的类型/排序/分级/分辨率、本机壁纸的筛选）存 UserDefaults：
/// 切换页面、重启 App 都不要再回到默认值。存的是一小段 JSON，键名固定。
public enum FilterDefaults {
    public static func load<T: Decodable>(
        _ type: T.Type, key: String, defaults: UserDefaults = AppFolder.settings
    ) -> T? {
        guard let data = defaults.data(forKey: "filter." + key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func save<T: Encodable>(
        _ value: T, key: String, defaults: UserDefaults = AppFolder.settings
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: "filter." + key)
    }
}
