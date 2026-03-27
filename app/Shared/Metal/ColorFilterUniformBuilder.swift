struct ColorFilterUniforms {
    var brightness: Float = 0.0
    var contrast: Float = 1.0
    var saturation: Float = 1.0
    var sharpness: Float = 0.0
    var debandEnabled: Float = 0.0
    var lanczosUpscaling: Float = 0.0
}

struct ColorFilterUniformBuilder {
    static func build(playerBridge: PlayerBridge) -> ColorFilterUniforms {
        var u = ColorFilterUniforms()
        u.brightness = playerBridge.brightness
        u.contrast = playerBridge.contrast
        u.saturation = playerBridge.saturation
        u.sharpness = playerBridge.sharpness
        u.debandEnabled = playerBridge.isDebandEnabled ? 1.0 : 0.0
        u.lanczosUpscaling = playerBridge.isLanczosUpscaling ? 1.0 : 0.0
        return u
    }
}
