import AppKit

/// Asks the window server to blur whatever is behind a window: a plain blur
/// with no tint, unlike the system frosted-glass materials. A radius of 0 turns it off.
enum WindowBlur {
    @discardableResult
    static func set(radius: Int32, for window: NSWindow) -> Bool {
        typealias ConnectionFunction = @convention(c) () -> Int32
        typealias BlurFunction = @convention(c) (Int32, Int32, Int32) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let blurSymbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadius")
        else { return false }
        let connection = unsafeBitCast(connectionSymbol, to: ConnectionFunction.self)()
        let blur = unsafeBitCast(blurSymbol, to: BlurFunction.self)
        return blur(connection, Int32(window.windowNumber), radius) == 0
    }
}
