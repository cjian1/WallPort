import CoreGraphics
import Testing
@testable import DesktopHost

private func display(
    _ id: CGDirectDisplayID, x: CGFloat = 0, width: CGFloat = 1512, scale: CGFloat = 2
) -> DisplaySnapshot {
    DisplaySnapshot(id: id, name: "屏幕 \(id)", frame: CGRect(x: x, y: 0, width: width, height: 982), scale: scale)
}

@Suite struct DisplayReconcilerTests {
    @Test func firstSyncAddsEveryDisplay() {
        let changes = DisplayReconciler.changes(from: [], to: [display(1), display(2, x: 1512)])
        #expect(changes.added.map(\.id) == [1, 2])
        #expect(changes.updated.isEmpty)
        #expect(changes.removed.isEmpty)
    }

    @Test func unchangedConfigurationProducesNoChanges() {
        let displays = [display(1), display(2, x: 1512)]
        #expect(DisplayReconciler.changes(from: displays, to: displays).isEmpty)
    }

    @Test func unplugRemovesOnlyThatDisplay() {
        let changes = DisplayReconciler.changes(from: [display(1), display(2, x: 1512)], to: [display(1)])
        #expect(changes.removed == [2])
        #expect(changes.added.isEmpty)
        #expect(changes.updated.isEmpty)
    }

    @Test func replugKeepsIdentityByDisplayID() {
        // 外接屏插回来之后排在了主屏前面，仍然按 ID 对上，不应该当成两块新屏幕
        let before = [display(1), display(2, x: 1512)]
        let after = [display(2, x: 1512), display(1)]
        #expect(DisplayReconciler.changes(from: before, to: after).isEmpty)
    }

    @Test func resolutionOrScaleChangeIsAnUpdate() {
        let changes = DisplayReconciler.changes(from: [display(1)], to: [display(1, width: 1728, scale: 1)])
        #expect(changes.updated.map(\.id) == [1])
        #expect(changes.added.isEmpty)
        #expect(changes.removed.isEmpty)
    }

    @Test func rearrangementIsAnUpdate() {
        let changes = DisplayReconciler.changes(
            from: [display(1), display(2, x: 1512)],
            to: [display(1), display(2, x: -1920)])
        #expect(changes.updated.map(\.id) == [2])
    }

    @Test func duplicateIDsInInputDoNotCrash() {
        let changes = DisplayReconciler.changes(from: [display(1), display(1)], to: [display(1), display(1)])
        #expect(changes.isEmpty)
    }
}
