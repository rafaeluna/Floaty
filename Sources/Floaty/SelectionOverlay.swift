import AppKit

/// Full-screen transparent panels (one per display) that show the crosshair and
/// the selection rectangle, mimicking the system Cmd+Shift+4 tool. The panels
/// never activate Floaty, so the app underneath keeps its focused appearance.
@MainActor
final class SelectionOverlayController {
    /// Called with the selection in points, origin at the top-left of the screen.
    var onComplete: ((CGRect, NSScreen) -> Void)?

    private var panels: [OverlayPanel] = []

    var isActive: Bool { !panels.isEmpty }
    var windowNumbers: [Int] { panels.map(\.windowNumber) }

    func begin() {
        guard panels.isEmpty else { return }
        let mouse = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            view.targetScreen = screen
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)

            if screen.frame.contains(mouse) {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
        }
        NSCursor.crosshair.set()
    }

    func cancel() {
        end()
    }

    func finish(rect: CGRect, screen: NSScreen) {
        onComplete?(rect, screen)
    }

    func end() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
    }
}

final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView {
    weak var controller: SelectionOverlayController?
    var targetScreen: NSScreen?

    private let selectionLayer = CALayer()
    private let labelLayer = CATextLayer()

    private var anchor: CGPoint?
    private var current: CGPoint?
    private var lastDragPoint: CGPoint?
    private var spaceDown = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // A barely-there fill so the window reliably receives mouse events.
        layer?.backgroundColor = CGColor(gray: 0, alpha: 0.005)

        selectionLayer.backgroundColor = CGColor(gray: 0.62, alpha: 0.24)
        selectionLayer.borderColor = CGColor(gray: 1, alpha: 0.8)
        selectionLayer.borderWidth = 1
        selectionLayer.isHidden = true
        layer?.addSublayer(selectionLayer)

        labelLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        labelLayer.fontSize = 11
        labelLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        labelLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        labelLayer.shadowOpacity = 0.9
        labelLayer.shadowRadius = 1.5
        labelLayer.shadowOffset = .zero
        labelLayer.isHidden = true
        layer?.addSublayer(labelLayer)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        let scale = window?.backingScaleFactor ?? 2
        labelLayer.contentsScale = scale
    }

    // MARK: Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        claimKeyboard()
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        claimKeyboard()
        NSCursor.crosshair.set()
        updateLabel(at: convert(event.locationInWindow, from: nil))
    }

    /// Keeps Esc and Space working on whichever display the pointer is on.
    private func claimKeyboard() {
        guard let window, !window.isKeyWindow else { return }
        window.makeKey()
        window.makeFirstResponder(self)
    }

    // MARK: Selection

    private var selectionRect: CGRect? {
        guard let anchor, let current else { return nil }
        let rect = CGRect(
            x: min(anchor.x, current.x), y: min(anchor.y, current.y),
            width: abs(anchor.x - current.x), height: abs(anchor.y - current.y)
        )
        return rect.integral.intersection(bounds)
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        anchor = point
        current = point
        lastDragPoint = point
        refresh(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        if spaceDown, let last = lastDragPoint, let a = anchor, let c = current {
            // Holding Space moves the whole selection, like the system tool.
            let dx = point.x - last.x, dy = point.y - last.y
            anchor = CGPoint(x: a.x + dx, y: a.y + dy)
            current = CGPoint(x: c.x + dx, y: c.y + dy)
        } else {
            current = point
        }
        lastDragPoint = point
        NSCursor.crosshair.set()
        refresh(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        let rect = selectionRect
        anchor = nil
        current = nil
        guard let rect, rect.width >= 4, rect.height >= 4, let screen = targetScreen else {
            controller?.cancel()
            return
        }
        controller?.finish(rect: rect, screen: screen)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.cancel() // Esc
        case 49: spaceDown = true     // Space
        default: break
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x.rounded(), 0), bounds.width),
            y: min(max(point.y.rounded(), 0), bounds.height)
        )
    }

    // MARK: Drawing

    private func refresh(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect = selectionRect {
            selectionLayer.frame = rect
            selectionLayer.isHidden = false
        } else {
            selectionLayer.isHidden = true
        }
        CATransaction.commit()
        updateLabel(at: point)
    }

    private func updateLabel(at point: CGPoint) {
        let text: String
        if let rect = selectionRect {
            text = "\(Int(rect.width)) × \(Int(rect.height))"
        } else {
            text = "\(Int(point.x)), \(Int(point.y))"
        }

        let size = CGSize(width: 96, height: 15)
        var origin = CGPoint(x: point.x + 12, y: point.y + 12)
        if origin.x + size.width > bounds.width { origin.x = point.x - 12 - size.width }
        if origin.y + size.height > bounds.height { origin.y = point.y - 12 - size.height }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.string = text
        labelLayer.alignmentMode = origin.x < point.x ? .right : .left
        labelLayer.frame = CGRect(origin: origin, size: size)
        labelLayer.isHidden = false
        CATransaction.commit()
    }
}
