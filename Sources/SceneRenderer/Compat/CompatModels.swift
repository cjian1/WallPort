/// 内置图层的模型 JSON（`models/util/*.json`）。场景里合成层、纯色层、全屏层、投影层的 `image` 指向它们；
/// 壁坞只看里面的标记决定怎么画（SceneRenderer 里读 `fullscreen`、`solidlayer`、`passthrough` 的地方），
/// 所以这里只写标记
enum CompatModels {
    static let files: [String: String] = [
        "models/util/composelayer.json": #"{"passthrough": true}"#,
        "models/util/composelayer_depthtest.json": #"{"passthrough": true}"#,
        "models/util/fullscreenlayer.json": #"{"fullscreen": true, "passthrough": true}"#,
        "models/util/projectlayer.json": #"{"passthrough": true, "autosize": true, "projectlayer": true}"#,
        "models/util/solidlayer.json": #"{"solidlayer": true}"#,
        "models/util/solidlayer_depthtest.json": #"{"solidlayer": true}"#,
    ]
}
