import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Uses Carbon hot keys, which need no
/// Accessibility permission and swallow the key combination globally.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a virtual key code such as `kVK_ANSI_2`
    ///   - modifiers: Carbon modifier mask such as `cmdKey | shiftKey`
    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.installHandlerIfNeeded()
        id = HotKey.nextID
        HotKey.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x464C_5459), id: id) // "FLTY"
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else { return nil }
        HotKey.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            HotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
