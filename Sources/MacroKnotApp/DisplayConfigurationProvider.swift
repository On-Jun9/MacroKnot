import AppKit
import CoreGraphics
import MacroKnotCore

enum DisplayConfigurationProvider {
    static func current() -> DisplayConfiguration {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displayIDs, &count)

        let displays = displayIDs.prefix(Int(count)).map { displayID in
            let bounds = CGDisplayBounds(displayID)
            let scale = NSScreen.screens.first(where: { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == displayID
            })?.backingScaleFactor ?? 1
            return DisplayGeometry(
                id: displayID,
                origin: ScreenPoint(x: bounds.origin.x, y: bounds.origin.y),
                width: bounds.width,
                height: bounds.height,
                scale: scale
            )
        }
        return DisplayConfiguration(displays: displays)
    }
}
