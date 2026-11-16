import AppKit
import ApplicationServices

/// Intercepts trackpad pinch gestures system-wide so they can resize a float
/// even though Floaty is never the active app. Needs Accessibility permission;
/// until it is granted this quietly waits and installs itself once it is.
@MainActor
final class PinchTap {
    static let shared = PinchTap()

    /// Receives the pinch magnification; return true to keep the gesture from
    /// reaching the app underneath.
    var handler: ((CGFloat) -> Bool)?

    fileprivate var port: CFMachPort?
    private var timer: Timer?

    var isInstalled: Bool { port != nil }

    func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            install()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                guard AXIsProcessTrusted() else { return }
                PinchTap.shared.timer?.invalidate()
                PinchTap.shared.timer = nil
                PinchTap.shared.install()
            }
        }
    }

    private func install() {
        guard port == nil else { return }
        // 29 is the generic gesture event, 30 is magnify.
        let mask: CGEventMask = (1 << 29) | (1 << 30)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: pinchTapCallback, userInfo: nil
        ) else {
            NSLog("Floaty: could not create the pinch event tap")
            return
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        NSLog("Floaty: pinch event tap installed")
    }
}

private func pinchTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = PinchTap.shared.port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .magnify,
              let handler = PinchTap.shared.handler
        else { return pass }
        return handler(nsEvent.magnification) ? nil : pass
    }
}
