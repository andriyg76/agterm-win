/// Chooses one surface's background config overlay. While a program's OSC 11 color is latched the overlay restates
/// only opacity and font: a `background` key would reseed the terminal default with the program's color, so OSC 111
/// would reset to it (macOS #309).
public enum BackgroundOverlayPolicy {
    public static func watermark(oscLatch: String?, fixedBackground: String?,
                                 sessionBackground: BackgroundWatermark?) -> BackgroundWatermark? {
        guard oscLatch == nil else { return nil }
        return fixedBackground.map { BackgroundWatermark(kind: .color, colorHex: $0) } ?? sessionBackground
    }

    public static func shouldReapply(force: Bool, oscLatch: String?, watermark: BackgroundWatermark?,
                                     hasFontOverride: Bool) -> Bool {
        force || oscLatch != nil || watermark != nil || hasFontOverride
    }

    public static func overlayText(oscLatch: String?, watermark: BackgroundWatermark?, resolvedImagePath: String?,
                                   fontSize: Double?, windowOpacity: Double) -> String {
        guard oscLatch == nil else {
            return WatermarkConfig.oscBackgroundOverlayText(fontSize: fontSize, windowOpacity: windowOpacity)
        }
        return WatermarkConfig.overlayText(watermark: watermark, resolvedImagePath: resolvedImagePath,
                                           fontSize: fontSize, windowOpacity: windowOpacity)
    }
}
