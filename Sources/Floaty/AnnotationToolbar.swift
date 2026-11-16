import AppKit

/// The window that carries the annotation toolbar. It hangs off a float and
/// never takes keyboard focus, so shortcuts keep going to the float.
final class ToolbarPanel: NSPanel {
    init(toolbar: AnnotationToolbar) {
        super.init(
            contentRect: NSRect(origin: .zero, size: AnnotationToolbar.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = toolbar
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Two rows: tools on top; color, size, fill, text style, opacity, undo, and done below.
final class AnnotationToolbar: NSVisualEffectView {
    static let size = CGSize(width: 432, height: 78)

    var onTool: ((Tool) -> Void)?
    var onColor: ((RGBA) -> Void)?
    var onSize: ((Int) -> Void)?
    var onFill: (() -> Void)?
    var onTextStyle: (() -> Void)?
    var onOpacity: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDone: (() -> Void)?
    /// The pointer entered or left the toolbar.
    var onHoverChange: (() -> Void)?

    private var toolChips: [Tool: ChipView] = [:]
    private var colorChips: [(RGBA, ChipView)] = []
    private let stepper = NSView()
    private let minus = ChipView(content: .symbol("minus"), symbolSize: 11)
    private let plus = ChipView(content: .symbol("plus"), symbolSize: 11)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let fillChip = ChipView(content: .symbol("square"))
    private let textChip = ChipView(content: .symbol("textformat"))
    private let opacityChip = ChipView(content: .symbol("circle.lefthalf.filled"))

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = CGColor(gray: 1, alpha: 0.18)

        // Top row: tools.
        let tools = Tool.allCases
        let slot = (Self.size.width - 16) / CGFloat(tools.count)
        for (index, tool) in tools.enumerated() {
            let chip = ChipView(content: .symbol(tool.symbol))
            chip.frame = NSRect(x: 8 + CGFloat(index) * slot + (slot - 28) / 2, y: 42, width: 28, height: 28)
            chip.tip = "\(tool.title)  \(tool.key.uppercased())"
            chip.onClick = { [weak self] in self?.onTool?(tool) }
            addSubview(chip)
            toolChips[tool] = chip
        }

        // Bottom row: style.
        var x: CGFloat = 8
        for (index, color) in RGBA.palette.enumerated() {
            let chip = ChipView(content: .swatch(color))
            chip.frame = NSRect(x: x, y: 11, width: 22, height: 22)
            chip.tip = "Color  \(index + 1)"
            chip.onClick = { [weak self] in self?.onColor?(color) }
            addSubview(chip)
            colorChips.append((color, chip))
            x += 23
        }

        // Size: one capsule holding minus, the value, and plus.
        stepper.frame = NSRect(x: 200, y: 10, width: 76, height: 24)
        stepper.wantsLayer = true
        stepper.layer?.cornerRadius = 12
        stepper.layer?.backgroundColor = CGColor(gray: 1, alpha: 0.1)
        stepper.layer?.borderWidth = 0.5
        stepper.layer?.borderColor = CGColor(gray: 1, alpha: 0.14)
        addSubview(stepper)

        minus.cornerRadius = 11
        minus.frame = NSRect(x: 201, y: 11, width: 22, height: 22)
        minus.tip = "Smaller  ["
        minus.onClick = { [weak self] in self?.onSize?(-1) }
        plus.cornerRadius = 11
        plus.frame = NSRect(x: 253, y: 11, width: 22, height: 22)
        plus.tip = "Larger  ]"
        plus.onClick = { [weak self] in self?.onSize?(1) }

        sizeLabel.frame = NSRect(x: 223, y: 14, width: 30, height: 15)
        sizeLabel.alignment = .center
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .white

        fillChip.frame = NSRect(x: 284, y: 9, width: 26, height: 26)
        fillChip.tip = "Fill: none, tint, solid"
        fillChip.onClick = { [weak self] in self?.onFill?() }
        textChip.frame = NSRect(x: 312, y: 9, width: 26, height: 26)
        textChip.tip = "Text style"
        textChip.onClick = { [weak self] in self?.onTextStyle?() }
        opacityChip.frame = NSRect(x: 340, y: 9, width: 26, height: 26)
        opacityChip.tip = "Opacity  O"
        opacityChip.onClick = { [weak self] in self?.onOpacity?() }

        let undo = ChipView(content: .symbol("arrow.uturn.backward"))
        undo.frame = NSRect(x: 372, y: 9, width: 26, height: 26)
        undo.tip = "Undo  U"
        undo.onClick = { [weak self] in self?.onUndo?() }
        let done = ChipView(content: .symbol("checkmark"))
        done.frame = NSRect(x: 400, y: 9, width: 26, height: 26)
        done.tip = "Done"
        done.onClick = { [weak self] in self?.onDone?() }

        [minus, plus, sizeLabel, fillChip, textChip, opacityChip, undo, done].forEach(addSubview)

        let divider = NSView(frame: NSRect(x: 10, y: 38.5, width: Self.size.width - 20, height: 0.5))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = CGColor(gray: 1, alpha: 0.14)
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The float sets resize cursors at its edges; make sure the toolbar always
    // shows a plain arrow, including when the pointer arrives from the float.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways], owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        onHoverChange?()
    }
    override func mouseExited(with event: NSEvent) { onHoverChange?() }

    /// - Parameters:
    ///   - tool: the active tool
    ///   - styleTool: the tool whose style is shown (differs when a mark of another kind is selected)
    func update(tool: Tool, styleTool: Tool, style: ToolStyle, opacitySliderVisible: Bool) {
        for (candidate, chip) in toolChips { chip.isOn = candidate == tool }

        for (color, chip) in colorChips {
            chip.isOn = styleTool.usesColor && color == style.color
            chip.isEnabled = styleTool.usesColor
        }
        minus.isEnabled = styleTool.usesSize
        plus.isEnabled = styleTool.usesSize
        stepper.alphaValue = styleTool.usesSize ? 1 : 0.4
        sizeLabel.stringValue = styleTool.usesSize ? "\(Int(style.size))" : "–"
        sizeLabel.alphaValue = styleTool.usesSize ? 1 : 0.3
        let sizeName = styleTool == .text ? "text" : "line"
        minus.tip = "Smaller \(sizeName)  ["
        plus.tip = "Larger \(sizeName)  ]"

        fillChip.isEnabled = styleTool.usesFill
        switch style.fill {
        case .none: fillChip.content = .symbol("square"); fillChip.tip = "Fill: none"
        case .tint: fillChip.content = .symbol("square.lefthalf.filled"); fillChip.tip = "Fill: tint"
        case .solid: fillChip.content = .symbol("square.fill"); fillChip.tip = "Fill: solid"
        }
        textChip.isEnabled = styleTool.usesTextStyle
        switch style.textStyle {
        case .plain: textChip.content = .symbol("textformat"); textChip.tip = "Text style: plain"
        case .shadow: textChip.content = .symbol("shadow"); textChip.tip = "Text style: drop shadow"
        case .outline: textChip.content = .symbol("a.square"); textChip.tip = "Text style: outline"
        case .pill: textChip.content = .symbol("a.square.fill"); textChip.tip = "Text style: color background"
        case .card: textChip.content = .symbol("character.textbox"); textChip.tip = "Text style: color text on background"
        }
        opacityChip.isOn = opacitySliderVisible
    }
}

/// A small flat button: an SF Symbol or a color swatch, with hover and selected states.
final class ChipView: NSView {
    enum Content: Equatable {
        case symbol(String)
        case swatch(RGBA)
    }

    var content: Content { didSet { if content != oldValue { needsDisplay = true } } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.3 } }
    var cornerRadius: CGFloat = 6
    /// Shown in a small label after hovering briefly.
    var tip: String?
    var onClick: (() -> Void)?

    private let symbolSize: CGFloat
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var tipWork: DispatchWorkItem?

    init(content: Content, symbolSize: CGFloat = 14) {
        self.content = content
        self.symbolSize = symbolSize
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.arrow.set()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering, let tip = self.tip, let window = self.window else { return }
            TooltipPanel.shared.show(tip, below: window.convertToScreen(self.convert(self.bounds, to: nil)))
        }
        tipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
        hideTip()
    }

    override func mouseDown(with event: NSEvent) {
        hideTip()
        if isEnabled { pressed = true }
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        if wasPressed && isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    private func hideTip() {
        tipWork?.cancel()
        tipWork = nil
        TooltipPanel.shared.hide()
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .symbol(let name):
            if isOn || hovering || pressed {
                NSColor.white.withAlphaComponent(isOn ? 0.24 : pressed ? 0.18 : 0.1).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            let size = image.size
            image.draw(in: NSRect(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height
            ))

        case .swatch(let color):
            let inset: CGFloat = isOn ? 4.5 : hovering ? 2.5 : 3.5
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
            color.nsColor.setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            if isOn {
                let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
                NSColor.white.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }
}

/// A hover label for toolbar buttons. System tooltips only appear in the
/// active app, which Floaty never is, so this draws its own. A shortcut is
/// shown as a small keycap after the name.
final class TooltipPanel: NSPanel {
    static let shared = TooltipPanel()

    private let label = NSTextField(labelWithString: "")
    private let keycap = KeycapView()

    private init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = CGColor(gray: 0.1, alpha: 0.94)
        background.layer?.cornerRadius = 7
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = CGColor(gray: 1, alpha: 0.2)
        contentView = background

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        background.addSubview(label)
        background.addSubview(keycap)
    }

    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// - Parameters:
    ///   - tip: the name, optionally followed by two spaces and the shortcut key
    ///   - anchor: the hovered control's frame in screen coordinates
    func show(_ tip: String, below anchor: NSRect) {
        let parts = tip.components(separatedBy: "  ")
        let key = parts.count > 1 ? parts[parts.count - 1] : nil
        label.stringValue = parts[0]
        label.sizeToFit()

        let height: CGFloat = 26
        let labelWidth = ceil(label.frame.width)
        var width = 9 + labelWidth + 9
        label.setFrameOrigin(CGPoint(x: 9, y: (height - label.frame.height) / 2))

        keycap.isHidden = key == nil
        if let key {
            keycap.key = key
            let keySize = keycap.fittingSize
            keycap.frame = NSRect(x: 9 + labelWidth + 7, y: (height - keySize.height) / 2, width: keySize.width, height: keySize.height)
            width = keycap.frame.maxX + 6
        }
        setFrame(NSRect(x: anchor.midX - width / 2, y: anchor.minY - height - 7, width: width, height: height), display: true)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

/// A shortcut drawn like a physical key: a rounded cap with a heavier bottom edge.
final class KeycapView: NSView {
    var key = "" { didSet { needsDisplay = true } }

    private let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    override var fittingSize: NSSize {
        let textWidth = (key as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: max(18, ceil(textWidth) + 10), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The edge color fills the whole shape; the face sits on top, inset
        // further at the bottom, which leaves the thicker lower lip of a key.
        NSColor.white.withAlphaComponent(0.34).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let face = NSRect(x: 1, y: 2, width: bounds.width - 2, height: bounds.height - 3)
        NSColor(white: 0.2, alpha: 1).setFill()
        NSBezierPath(roundedRect: face, xRadius: 4, yRadius: 4).fill()

        let text = NSAttributedString(string: key, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: CGPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2))
    }
}
