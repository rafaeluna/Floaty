import AppKit

/// Floaty's windows never activate the app, and macOS normally ignores cursor
/// changes from background apps, which makes the crosshair and resize cursors
/// flicker back to the arrow. This asks the window server to honor them.
enum CursorControl {
    static func allowCursorChangesInBackground() {
        typealias ConnectionFunction = @convention(c) () -> Int32
        typealias SetPropertyFunction = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

        guard let handle = dlopen(nil, RTLD_NOW),
              let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let setPropertySymbol = dlsym(handle, "CGSSetConnectionProperty")
        else {
            NSLog("Floaty: background cursor control unavailable")
            return
        }
        let connection = unsafeBitCast(connectionSymbol, to: ConnectionFunction.self)()
        let setProperty = unsafeBitCast(setPropertySymbol, to: SetPropertyFunction.self)
        let status = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        NSLog("Floaty: background cursor control status \(status)")
    }
}
