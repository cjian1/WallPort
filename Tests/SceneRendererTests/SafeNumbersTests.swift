import Testing
@testable import SceneRenderer

@Suite struct SafeNumbersTests {
    @Test func saturatingConversionNeverTraps() {
        #expect(Int(saturating: Float.nan) == 0)
        #expect(Int(saturating: Float.infinity) == 1 << 52)
        #expect(Int(saturating: -Float.infinity) == -(1 << 52))
        #expect(Int(saturating: Float(1e30)) == 1 << 52)
        #expect(Int(saturating: Float(3.7)) == 3)
        #expect(Int(saturating: Float(-3.7)) == -3)
        #expect(Int(saturating: Double.nan) == 0)
    }

    /// 坏的粒子参数会让位置变成 NaN / 无穷大，湍流的噪声不能因此崩掉
    @Test func particleNoiseSurvivesNonFinitePositions() {
        for bad: Float in [.nan, .infinity, -.infinity, 1e30, -1e30] {
            let value = ParticleNoise.vector(SIMD3(bad, 1, bad))
            #expect(value.x.isNaN || abs(value.x) <= 1)
        }
    }
}
