extension Int {
    /// 场景数据算出来的浮点数转整数：NaN 当 0，太大太小的截到 ±2⁵²。
    /// 直接写 `Int(x)` 遇到 NaN、无穷大或超出范围的数会让整个 App 崩掉——壁纸是陌生人做的，坏文件里什么数都有
    init(saturating value: Float) {
        self.init(saturating: Double(value))
    }

    init(saturating value: Double) {
        guard !value.isNaN else {
            self = 0
            return
        }
        self = Int(Swift.min(Swift.max(value, -0x1p52), 0x1p52))
    }
}
