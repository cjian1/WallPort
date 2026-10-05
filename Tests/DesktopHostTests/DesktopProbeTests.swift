import CoreGraphics
import Testing
@testable import DesktopHost

private let ourPID: pid_t = 100
private let wallpaperPID: pid_t = 200
private let finderPID: pid_t = 300
private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let desktopLayer = Int(CGWindowLevelForKey(.desktopWindow))
private let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

private func window(
    _ number: Int, pid: pid_t, layer: Int, bounds: CGRect = screen
) -> DesktopProbe.WindowEntry {
    DesktopProbe.WindowEntry(number: number, ownerName: "P\(pid)", ownerPID: pid, layer: layer, bounds: bounds)
}

@Suite struct DesktopProbeTests {
    @Test func missingWhenNotInList() {
        let list = [window(2, pid: wallpaperPID, layer: desktopLayer)]
        #expect(DesktopProbe.status(of: 1, in: list) == .missing)
    }

    @Test func onScreenWhenInFrontOfSystemWallpaper() {
        let list = [
            window(3, pid: finderPID, layer: iconLayer),
            window(1, pid: ourPID, layer: desktopLayer),
            window(2, pid: wallpaperPID, layer: desktopLayer),
        ]
        #expect(DesktopProbe.status(of: 1, in: list) == .onScreen)
    }

    @Test func coveredWhenSystemWallpaperIsInFrontOnSameLayer() {
        let wallpaper = window(2, pid: wallpaperPID, layer: desktopLayer)
        let list = [wallpaper, window(1, pid: ourPID, layer: desktopLayer)]
        #expect(DesktopProbe.status(of: 1, in: list) == .covered(by: wallpaper))
    }

    @Test func higherLayerWindowInFrontIsNotCovering() {
        // 桌面图标本来就应该在上面
        let list = [window(3, pid: finderPID, layer: iconLayer), window(1, pid: ourPID, layer: desktopLayer)]
        #expect(DesktopProbe.status(of: 1, in: list) == .onScreen)
    }

    @Test func smallSameLayerWindowIsNotCovering() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 200)
        let list = [window(2, pid: wallpaperPID, layer: desktopLayer, bounds: small), window(1, pid: ourPID, layer: desktopLayer)]
        #expect(DesktopProbe.status(of: 1, in: list) == .onScreen)
    }

    @Test func ourOwnWindowsNeverCoverEachOther() {
        let list = [window(5, pid: ourPID, layer: desktopLayer), window(1, pid: ourPID, layer: desktopLayer)]
        #expect(DesktopProbe.status(of: 1, in: list) == .onScreen)
    }

    @Test func wallpaperOnAnotherDisplayIsNotCovering() {
        let other = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let list = [window(2, pid: wallpaperPID, layer: desktopLayer, bounds: other), window(1, pid: ourPID, layer: desktopLayer)]
        #expect(DesktopProbe.status(of: 1, in: list) == .onScreen)
    }

    @Test func overlaysListHigherNonIconWindowsInFront() {
        let backdrop = window(4, pid: wallpaperPID, layer: desktopLayer + 1)
        let list = [
            window(3, pid: finderPID, layer: iconLayer),
            backdrop,
            window(1, pid: ourPID, layer: desktopLayer),
            window(2, pid: wallpaperPID, layer: desktopLayer - 1),
        ]
        #expect(DesktopProbe.overlays(above: 1, in: list) == [backdrop])
        // 同层的遮挡归 status 管，不算在这里
        #expect(DesktopProbe.status(of: 1, in: list) == .onScreen)
    }

    @Test func overlaysIgnoreWindowsOnOtherDisplays() {
        let other = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let list = [window(4, pid: wallpaperPID, layer: desktopLayer + 1, bounds: other), window(1, pid: ourPID, layer: desktopLayer)]
        #expect(DesktopProbe.overlays(above: 1, in: list).isEmpty)
    }

    @Test func layerNamesAreRelativeToDesktopAndIcons() {
        #expect(DesktopProbe.layerName(desktopLayer) == "桌面层")
        #expect(DesktopProbe.layerName(desktopLayer + 1) == "桌面层+1")
        #expect(DesktopProbe.layerName(desktopLayer - 1) == "桌面层-1")
        #expect(DesktopProbe.layerName(iconLayer) == "图标层")
        #expect(DesktopProbe.layerName(iconLayer - 1) == "图标层-1")
    }
}
