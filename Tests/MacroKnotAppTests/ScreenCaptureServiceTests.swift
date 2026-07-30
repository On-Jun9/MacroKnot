import CoreGraphics
import Testing
@testable import MacroKnotApp

@Test
func preservesVerticalWindowOrderWhenCompositingApplicationCapture() {
    let union = CGRect(x: 100, y: 50, width: 800, height: 600)
    let upperWindow = CGRect(x: 150, y: 50, width: 300, height: 100)
    let lowerWindow = CGRect(x: 200, y: 500, width: 400, height: 150)

    let upperRect = ScreenCaptureService.compositeRect(
        for: upperWindow,
        within: union,
        scale: 2
    )
    let lowerRect = ScreenCaptureService.compositeRect(
        for: lowerWindow,
        within: union,
        scale: 2
    )

    #expect(upperRect == CGRect(x: 100, y: 1_000, width: 600, height: 200))
    #expect(lowerRect == CGRect(x: 200, y: 0, width: 800, height: 300))
    #expect(upperRect.minY > lowerRect.minY)
}
