import Foundation
import IOKit.ps

/// 现在是不是在用电池（插着电源返回 false；读不到电源信息时按插电处理）
public enum PowerSource {
    public static var isOnBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }
            let state = info[kIOPSPowerSourceStateKey as String] as? String
            if state == kIOPSBatteryPowerValue as String { return true }
        }
        return false
    }
}

/// 此刻的省电条件：用不用电池、开没开低电量模式、机器热不热
public struct PowerConditions: Equatable, Sendable {
    public var onBattery: Bool
    public var lowPowerMode: Bool
    public var thermalState: ProcessInfo.ThermalState

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
    }

    public static var current: PowerConditions {
        PowerConditions(
            onBattery: PowerSource.isOnBattery, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
    }

    /// 写日志用
    public var summary: String {
        var parts = [onBattery ? String(localized: "用电池") : String(localized: "接电源")]
        if lowPowerMode { parts.append(String(localized: "低电量模式")) }
        switch thermalState {
        case .serious: parts.append(String(localized: "机器很热"))
        case .critical: parts.append(String(localized: "机器过热"))
        default: break
        }
        return parts.joined(separator: "、")
    }
}

/// 省电与性能设置
public struct PerformanceSettings: Equatable, Sendable {
    public enum BatteryMode: String, Sendable, CaseIterable {
        /// 用电池时和插电一样
        case normal
        /// 用电池时降到 15 帧
        case lowFrameRate
        /// 用电池时暂停动态壁纸
        case pause

        public var title: String {
            switch self {
            case .normal: return String(localized: "照常播放")
            case .lowFrameRate: return String(localized: "降到 15 帧")
            case .pause: return String(localized: "暂停壁纸")
            }
        }
    }

    /// 帧率上限；0 表示不限制
    public var maximumFrameRate: Int
    /// 用电池时怎么办。默认降到 15 帧：壁纸常驻后台，用电池时照常 30 帧太费电
    public var batteryMode: BatteryMode
    /// 桌面几乎被窗口盖满时暂停动态壁纸（见 `DesktopCoverage`）
    public var pausesWhenCovered: Bool
    /// 按画面变得多快在上限之下自动降帧（场景壁纸；见 SceneRenderer 的 `AdaptiveFrameRate`）
    public var adaptsFrameRate: Bool

    /// 省电时（用电池选了降帧、低电量模式、机器很热）的帧率上限
    public static let savingFrameRate = 15

    public init(
        maximumFrameRate: Int = 30, batteryMode: BatteryMode = .lowFrameRate, pausesWhenCovered: Bool = true,
        adaptsFrameRate: Bool = true
    ) {
        self.maximumFrameRate = maximumFrameRate
        self.batteryMode = batteryMode
        self.pausesWhenCovered = pausesWhenCovered
        self.adaptsFrameRate = adaptsFrameRate
    }

    /// 当前应该用的帧率上限
    public func effectiveFrameRate(onBattery: Bool) -> Int {
        effectiveFrameRate(PowerConditions(onBattery: onBattery))
    }

    /// 当前应该用的帧率上限：用电池（选了降帧）、低电量模式、机器很热时降到 15 帧（本来就更低的不动）
    public func effectiveFrameRate(_ conditions: PowerConditions) -> Int {
        let saving = (conditions.onBattery && batteryMode == .lowFrameRate) || conditions.lowPowerMode
            || conditions.thermalState == .serious || conditions.thermalState == .critical
        guard saving else { return maximumFrameRate }
        return maximumFrameRate == 0 ? Self.savingFrameRate : min(maximumFrameRate, Self.savingFrameRate)
    }

    /// 要不要把动态壁纸整个停下来，要的话给出原因：用电池时选了暂停；机器过热（系统快要降频了）
    public func pauseReason(_ conditions: PowerConditions) -> String? {
        if conditions.thermalState == .critical { return String(localized: "机器过热") }
        if conditions.onBattery, batteryMode == .pause { return String(localized: "用电池") }
        return nil
    }

    public var frameRateTitle: String {
        maximumFrameRate == 0 ? String(localized: "不限制") : String(localized: "\(maximumFrameRate) 帧")
    }
}

/// 性能设置的存储
public final class PerformanceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "performanceSettings"

    public init(defaults: UserDefaults = AppFolder.settings) {
        self.defaults = defaults
    }

    public var settings: PerformanceSettings {
        get {
            guard let raw = defaults.dictionary(forKey: key) else { return PerformanceSettings() }
            let defaultSettings = PerformanceSettings()
            return PerformanceSettings(
                maximumFrameRate: (raw["maximumFrameRate"] as? NSNumber)?.intValue ?? defaultSettings.maximumFrameRate,
                batteryMode: (raw["batteryMode"] as? String)
                    .flatMap(PerformanceSettings.BatteryMode.init(rawValue:)) ?? defaultSettings.batteryMode,
                pausesWhenCovered: (raw["pausesWhenCovered"] as? NSNumber)?.boolValue ?? defaultSettings.pausesWhenCovered,
                adaptsFrameRate: (raw["adaptsFrameRate"] as? NSNumber)?.boolValue ?? defaultSettings.adaptsFrameRate)
        }
        set {
            defaults.set(
                [
                    "maximumFrameRate": newValue.maximumFrameRate, "batteryMode": newValue.batteryMode.rawValue,
                    "pausesWhenCovered": newValue.pausesWhenCovered, "adaptsFrameRate": newValue.adaptsFrameRate,
                ],
                forKey: key)
        }
    }
}

/// 电源、低电量模式、机器温度一变就通知（原来每分钟轮询一次电源，拔掉电源后最长一分钟才降帧）
@MainActor
public final class PowerMonitor {
    private let onChange: @MainActor () -> Void
    private var runLoopSource: CFRunLoopSource?
    /// 交给 IOKit 回调的自己：回调源挂着期间一直留着（不然先被释放的话回调拿到的是野指针），`stop` 时放掉
    private var retainedSelf: Unmanaged<PowerMonitor>?
    private var observers: [NSObjectProtocol] = []

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard runLoopSource == nil, observers.isEmpty else { return }
        // 插拔电源、电量变化：IOKit 在主线程的运行循环上回调
        let retained = Unmanaged.passRetained(self)
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onChange() }
        }, retained.toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
            retainedSelf = retained
        } else {
            retained.release()
        }
        // 低电量模式、温度的通知可能从别的线程发来
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange() }
            })
        }
    }

    public func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        runLoopSource = nil
        retainedSelf?.release()
        retainedSelf = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
