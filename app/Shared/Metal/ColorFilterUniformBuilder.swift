struct ColorFilterUniforms {
    var brightness: Float = 0.0
    var contrast: Float = 1.0
    var saturation: Float = 1.0
    var sharpness: Float = 0.0
}

struct ColorFilterUniformBuilder {
    static func build(playerBridge: PlayerBridge) -> ColorFilterUniforms {
        var u = ColorFilterUniforms()
        u.brightness = playerBridge.brightness
        u.contrast = playerBridge.contrast
        u.saturation = playerBridge.saturation
        u.sharpness = playerBridge.sharpness
        return u
    }
}
