import Testing
@testable import DesktopHost

/// 这些测试依赖真实的等待时间。宽限期设成 200 毫秒，"短暂遮挡"和"长时间遮挡"都留了充足余量
@MainActor
@Suite struct PlaybackGateTests {
    private final class Recorder {
        var events: [Bool] = []
    }

    private func makeGate(_ recorder: Recorder) -> PlaybackGate {
        PlaybackGate(grace: .milliseconds(200)) { playing, _ in recorder.events.append(playing) }
    }

    @Test func startsPlayingWhenVisible() {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        gate.start(reason: "载入")
        #expect(recorder.events == [true])
        #expect(gate.isPlaying)
    }

    @Test func briefOcclusionDoesNotPause() async throws {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        gate.start(reason: "载入")
        gate.setVisible(false)
        try await Task.sleep(for: .milliseconds(30))
        gate.setVisible(true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.events == [true])
    }

    @Test func longOcclusionPausesThenResumesImmediately() async throws {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        gate.start(reason: "载入")
        gate.setVisible(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.events == [true, false])
        gate.setVisible(true)
        #expect(recorder.events == [true, false, true])
    }

    @Test func userPauseIsImmediateAndSurvivesVisibilityChanges() async throws {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        gate.start(reason: "载入")
        gate.setPausedByUser(true)
        #expect(recorder.events == [true, false])
        gate.setVisible(false)
        gate.setVisible(true)
        #expect(recorder.events == [true, false])
        gate.setPausedByUser(false)
        #expect(recorder.events == [true, false, true])
    }

    @Test func startingWhileOccludedStaysPaused() {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        gate.setVisible(false)
        gate.start(reason: "载入")
        #expect(recorder.events.isEmpty)
        #expect(!gate.isPlaying)
    }

    @Test func invalidatedGateStopsCallingBack() async throws {
        let recorder = Recorder()
        let gate = makeGate(recorder)
        gate.start(reason: "载入")
        gate.setVisible(false)
        gate.invalidate()
        try await Task.sleep(for: .milliseconds(400))
        gate.setVisible(true)
        gate.setPausedByUser(true)
        #expect(recorder.events == [true])
    }
}
