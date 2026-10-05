import Foundation
import Testing
@testable import DesktopHost

@Suite struct PerformanceSettingsTests {
    @Test func batteryModeChangesTheEffectiveFrameRate() {
        let settings = PerformanceSettings(maximumFrameRate: 30, batteryMode: .lowFrameRate)
        #expect(settings.effectiveFrameRate(onBattery: false) == 30)
        #expect(settings.effectiveFrameRate(onBattery: true) == 15)

        let limitFree = PerformanceSettings(maximumFrameRate: 0, batteryMode: .normal)
        #expect(limitFree.effectiveFrameRate(onBattery: true) == 0, "用电池时照常播放")
        #expect(limitFree.frameRateTitle == "不限制")
        #expect(PerformanceSettings(maximumFrameRate: 60).frameRateTitle == "60 帧")
    }

    @Test func settingsRoundTripThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "PerformanceTests-\(UUID().uuidString)"))
        let store = PerformanceStore(defaults: defaults)
        #expect(store.settings == PerformanceSettings())
        store.settings = PerformanceSettings(maximumFrameRate: 60, batteryMode: .pause)
        #expect(store.settings.maximumFrameRate == 60)
        #expect(store.settings.batteryMode == .pause)
    }

    /// 低电量模式、机器很热时降到 15 帧（本来更低的不动）；过热时整个停下；用电池默认降帧
    @Test func powerSavingConditionsLowerTheFrameRate() {
        let settings = PerformanceSettings()
        #expect(settings.batteryMode == .lowFrameRate, "默认用电池时降帧")
        #expect(settings.effectiveFrameRate(PowerConditions()) == 30)
        #expect(settings.effectiveFrameRate(PowerConditions(onBattery: true)) == 15)
        #expect(settings.effectiveFrameRate(PowerConditions(lowPowerMode: true)) == 15)
        #expect(settings.effectiveFrameRate(PowerConditions(thermalState: .fair)) == 30)
        #expect(settings.effectiveFrameRate(PowerConditions(thermalState: .serious)) == 15)
        #expect(PerformanceSettings(maximumFrameRate: 10).effectiveFrameRate(PowerConditions(lowPowerMode: true)) == 10)
        #expect(PerformanceSettings(maximumFrameRate: 0).effectiveFrameRate(PowerConditions(thermalState: .serious)) == 15)
        #expect(PerformanceSettings(batteryMode: .normal).effectiveFrameRate(PowerConditions(onBattery: true)) == 30)

        #expect(settings.pauseReason(PowerConditions()) == nil)
        #expect(settings.pauseReason(PowerConditions(thermalState: .critical)) == "机器过热")
        #expect(PerformanceSettings(batteryMode: .pause).pauseReason(PowerConditions(onBattery: true)) == "用电池")
        #expect(PerformanceSettings(batteryMode: .pause).pauseReason(PowerConditions(onBattery: false)) == nil)
    }

    @Test func coverPauseSettingRoundTrips() throws {
        let name = "PerformanceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PerformanceStore(defaults: defaults)
        #expect(store.settings.pausesWhenCovered)
        store.settings = PerformanceSettings(pausesWhenCovered: false)
        #expect(!store.settings.pausesWhenCovered)
    }

    @Test func adaptiveFrameRateSettingRoundTrips() throws {
        let name = "PerformanceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PerformanceStore(defaults: defaults)
        #expect(store.settings.adaptsFrameRate, "默认开")
        store.settings = PerformanceSettings(adaptsFrameRate: false)
        #expect(!store.settings.adaptsFrameRate)
    }

    /// 读电源状态不该崩（CI 上通常读不到电池，按插电处理）
    @Test func powerSourceIsReadable() {
        _ = PowerSource.isOnBattery
    }
}
