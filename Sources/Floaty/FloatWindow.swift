import AppKit

/// One floating screenshot: a borderless panel that sits above other apps
/// without ever activating Floaty.
@MainActor
final class FloatController: NSObject, NSWindowDelegate {
    let image: CGImage
    let scale: CGFloat
    let fileURL: URL?
    /// Size in points at which the capture is pixel-exact.
    let naturalSize: CGSize

    var onClose: ((FloatController) -> Void)?

    private let panel: FloatPanel
    private let view: FloatView
    private let shadowPanel: ShadowPanel

    // Annotations
    let renderer: AnnotationRenderer
    let editor = AnnotationEditor()
    var annotations: [Annotation] = [] { didSet { view.canvas.needsDisplay = true } }
    /// The visible part of the capture, in image points from its top-left.
    private(set) var crop: CGRect
    private(set) var isAnnotating = false
    private var toolbarPanel: ToolbarPanel?
    private var toolbar: AnnotationToolbar?
    private var textUndoStart: Snapshot?
    private var saveWork: DispatchWorkItem?

    static let minimumSide: CGFloat = 24

    init(image: CGImage, scale: CGFloat, frame: NSRect, fileURL: URL?) {
        self.image = image
        self.scale = scale
        self.fileURL = fileURL
        self.naturalSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        panel = FloatPanel(contentRect: frame)
        view = FloatView(frame: NSRect(origin: .zero, size: frame.size), image: image)
        shadowPanel = ShadowPanel(around: frame)
        renderer = AnnotationRenderer(image: image, scale: scale)
        crop = CGRect(origin: .zero, size: naturalSize)
        super.init()

        editor.controller = self
        view.canvas.controller = self
        view.controller = self
        panel.contentView = view
        panel.delegate = self
        panel.addChildWindow(shadowPanel, ordered: .below)
    }

    var isVisible: Bool { panel.isVisible }

    func show(takingFocus: Bool, animated: Bool = false) {
        panel.orderFrontRegardless()
        if takingFocus {
            panel.makeKey()
            panel.makeFirstResponder(view)
        }
        if animated {
            view.playArrival()
            (shadowPanel.contentView as? ShadowView)?.playLift()
        }
    }

    func setHidden(_ hidden: Bool) {
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    func close() {
        setAnnotating(false)
        saveWork?.perform()
        panel.orderOut(nil)
        onClose?(self)
    }

    // MARK: Actions

    private var fullRect: CGRect { CGRect(origin: .zero, size: naturalSize) }

    /// The image as it currently looks: cropped, stretched, and with every
    /// annotation drawn in, at full capture resolution.
    func renderedImage() -> CGImage {
        let size = panel.frame.size
        let contentAspect = crop.width / crop.height
        let aspect = size.width / size.height
        let stretched = abs(aspect - contentAspect) / contentAspect > 0.002
        if !stretched && annotations.isEmpty && crop == fullRect { return image }

        var pixelWidth = crop.width * scale, pixelHeight = crop.height * scale
        if stretched {
            if aspect > contentAspect { pixelWidth = pixelHeight * aspect } else { pixelHeight = pixelWidth / aspect }
        }
        let width = Int(pixelWidth.rounded()), height = Int(pixelHeight.rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        // Work in image points with the origin at the top-left, like the canvas.
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / crop.width, y: -CGFloat(height) / crop.height)
        context.translateBy(x: -crop.minX, y: -crop.minY)

        context.saveGState()
        context.translateBy(x: 0, y: naturalSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: fullRect)
        context.restoreGState()

        renderer.draw(annotations, in: context, canvas: crop, pixelsPerPoint: CGFloat(width) / crop.width)
        return context.makeImage() ?? image
    }

    func copy() {
        let ok = ImageExport.copyToPasteboard(renderedImage(), scale: scale)
        view.flash(ok ? "Copied" : "Copy failed")
    }

    // MARK: Files

    /// A PNG on disk that matches what the float shows. With no edits that is
    /// the original capture; otherwise an "(annotated)" copy is written beside
    /// it, leaving the original untouched.
    func exportedFileURL() -> URL? {
        let rendered = renderedImage()
        let original = fileURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("Floaty Screenshot.png")
        let edited = rendered !== image
        if !edited, FileManager.default.fileExists(atPath: original.path) { return original }

        let destination = edited
            ? original.deletingLastPathComponent().appendingPathComponent(
                original.deletingPathExtension().lastPathComponent + " (annotated).png")
            : original
        guard let data = ImageExport.pngData(rendered, scale: scale) else { return nil }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            NSLog("Floaty: could not write \(destination.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    func copyPath() {
        guard let url = exportedFileURL() else { view.flash("Could not save file"); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        view.flash("Path copied")
    }

    /// Captures are saved automatically; this confirms it and refreshes the annotated copy.
    func save() {
        view.flash(exportedFileURL() != nil ? "Saved" : "Could not save file")
    }

    func saveAs() {
        let rendered = renderedImage()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Floaty Screenshot") + ".png"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data: Data?
        if ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
            let rep = NSBitmapImageRep(cgImage: rendered)
            rep.size = NSSize(width: CGFloat(rendered.width) / scale, height: CGFloat(rendered.height) / scale)
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        } else {
            data = ImageExport.pngData(rendered, scale: scale)
        }
        do {
            try data?.write(to: url, options: .atomic)
        } catch {
            NSLog("Floaty: could not save: \(error.localizedDescription)")
        }
    }

    func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func resetSize() {
        recordUndo()
        let frame = panel.frame
        setFrame(NSRect(
            x: frame.midX - crop.width / 2, y: frame.midY - crop.height / 2,
            width: crop.width, height: crop.height
        ))
    }

    /// The float's proportions: exactly the image's unless it was deliberately stretched.
    private var stableAspect: CGFloat {
        let frame = panel.frame
        let current = frame.width / frame.height, natural = crop.width / crop.height
        return abs(current - natural) / natural < 0.015 ? natural : current
    }

    func scale(by factor: CGFloat) {
        recordUndo(coalescing: "scale")
        let frame = panel.frame
        let lower = Self.minimumSide / min(frame.width, frame.height)
        let upper = 8 * max(crop.width / frame.width, crop.height / frame.height)
        let clamped = min(max(factor, lower), max(upper, lower))
        // Height is always derived from width, so rounding in many small
        // pinch steps can never drift the proportions.
        let width = frame.width * clamped, height = width / stableAspect
        setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height))
    }

    // MARK: Opacity

    nonisolated static let minimumOpacity: CGFloat = 0.1
    private(set) var opacity: CGFloat = 1

    /// Fades the image and its shadow; controls drawn on top stay fully visible.
    func setOpacity(_ value: CGFloat) {
        opacity = min(max(value, Self.minimumOpacity), 1)
        view.imageOpacityDidChange(opacity)
        shadowPanel.alphaValue = opacity
    }

    func adjustOpacity(by delta: CGFloat) {
        recordUndo(coalescing: "opacity")
        setOpacity(opacity + delta)
    }

    // MARK: Undo

    struct Snapshot: Equatable {
        var frame: NSRect
        var opacity: CGFloat
        var annotations: [Annotation]
        var crop: CGRect
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastUndoKey: String?
    private var lastUndoTime: TimeInterval = 0

    var snapshot: Snapshot {
        Snapshot(frame: panel.frame, opacity: opacity, annotations: annotations, crop: crop)
    }

    /// Saves the current state before a change. Continuous gestures pass a
    /// `key` so a whole pinch or scroll becomes a single undo step.
    func recordUndo(coalescing key: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastUndoKey = key; lastUndoTime = now }
        if let key, key == lastUndoKey, now - lastUndoTime < 0.7 { return }
        pushUndo(snapshot)
    }

    func pushUndo(_ state: Snapshot) {
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let state = undoStack.popLast() else { view.flash("Nothing to undo"); return }
        redoStack.append(snapshot)
        restore(state)
    }

    func redo() {
        guard let state = redoStack.popLast() else { view.flash("Nothing to redo"); return }
        undoStack.append(snapshot)
        restore(state)
    }

    private func restore(_ state: Snapshot) {
        lastUndoKey = nil
        _ = view.canvas.endEditing()
        crop = state.crop
        annotations = state.annotations
        setFrame(state.frame)
        setOpacity(state.opacity)
        if let selected = editor.selectedID, !annotations.contains(where: { $0.id == selected }) {
            editor.select(nil)
        }
        view.contentDidChange()
        editorDidChange()
    }

    // MARK: Annotating

    func setAnnotating(_ on: Bool) {
        guard on != isAnnotating else { return }
        if !on {
            endTextEditing()
            editor.select(nil)
        }
        isAnnotating = on

        if on {
            if toolbarPanel == nil { buildToolbar() }
            if let toolbarPanel {
                // Fade in from clear: popping in at full strength shows a flash
                // while the blurred background settles.
                positionToolbar()
                toolbarPanel.alphaValue = 0
                panel.addChildWindow(toolbarPanel, ordered: .above)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    toolbarPanel.animator().alphaValue = 1
                }
            }
            refreshToolbar()
        } else if let toolbarPanel {
            panel.removeChildWindow(toolbarPanel)
            toolbarPanel.orderOut(nil)
        }
        view.contentDidChange()
    }

    private func buildToolbar() {
        let toolbar = AnnotationToolbar()
        toolbar.onTool = { [weak self] in self?.editor.setTool($0) }
        toolbar.onColor = { [weak self] color in self?.editor.updateStyle { $0.color = color } }
        toolbar.onSize = { [weak self] in self?.editor.adjustSize(steps: $0) }
        toolbar.onFill = { [weak self] in
            self?.editor.updateStyle { style in
                let all = FillMode.allCases
                style.fill = all[(all.firstIndex(of: style.fill)! + 1) % all.count]
            }
        }
        toolbar.onTextStyle = { [weak self] in
            self?.editor.updateStyle { style in
                let all = TextStyle.allCases
                style.textStyle = all[(all.firstIndex(of: style.textStyle)! + 1) % all.count]
            }
        }
        toolbar.onOpacity = { [weak self] in self?.view.toggleSlider() }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onDone = { [weak self] in self?.setAnnotating(false) }
        toolbar.onHoverChange = { [weak self] in self?.pointerDidMove() }
        self.toolbar = toolbar
        toolbarPanel = ToolbarPanel(toolbar: toolbar)
    }

    /// Below the float when there is room, otherwise above it, otherwise inside its bottom edge.
    private func positionToolbar() {
        guard let toolbarPanel else { return }
        let frame = panel.frame
        let size = AnnotationToolbar.size
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        var x = frame.midX - size.width / 2
        x = min(max(x, screen.minX + 6), max(screen.maxX - size.width - 6, screen.minX + 6))
        var y = frame.minY - size.height - 12
        if y < screen.minY + 4 {
            y = frame.maxY + 12
            if y + size.height > screen.maxY - 4 { y = frame.minY + 12 }
        }
        toolbarPanel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }

    func refreshToolbar() {
        toolbar?.update(
            tool: editor.tool, styleTool: editor.styleTool, style: editor.currentStyle,
            opacitySliderVisible: view.isSliderVisible
        )
    }

    func redrawCanvas() { view.canvas.needsDisplay = true }

    /// Called after the editor changes tool, selection, or marks.
    func editorDidChange() {
        if let id = view.canvas.editingID, let annotation = annotations.first(where: { $0.id == id }) {
            view.canvas.restyle(annotation)
        }
        redrawCanvas()
        refreshToolbar()
        view.refreshCursor()
        scheduleSave()
    }

    /// Crops to `rect` (image points) while keeping the remaining pixels where they are on screen.
    func applyCrop(_ rect: CGRect) {
        let target = rect.intersection(crop)
        guard !target.isNull, target.width >= 4, target.height >= 4 else { return }
        let frame = panel.frame
        let zoomX = frame.width / crop.width, zoomY = frame.height / crop.height
        let newFrame = NSRect(
            x: frame.minX + (target.minX - crop.minX) * zoomX,
            y: frame.maxY - (target.maxY - crop.minY) * zoomY,
            width: target.width * zoomX, height: target.height * zoomY
        )
        crop = target
        setFrame(newFrame)
        view.contentDidChange()
    }

    var isCropped: Bool { crop != fullRect }

    func removeCrop() {
        guard isCropped else { return }
        recordUndo()
        let frame = panel.frame
        let zoomX = frame.width / crop.width, zoomY = frame.height / crop.height
        let newFrame = NSRect(
            x: frame.minX - crop.minX * zoomX,
            y: frame.maxY + crop.minY * zoomY - naturalSize.height * zoomY,
            width: naturalSize.width * zoomX, height: naturalSize.height * zoomY
        )
        crop = fullRect
        setFrame(newFrame)
        view.contentDidChange()
        scheduleSave()
    }

    // MARK: Text editing

    var isEditingText: Bool { view.canvas.editingID != nil }

    func beginTextEditing(_ id: UUID, isNew: Bool) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        textUndoStart = isNew ? nil : snapshot
        view.canvas.beginEditing(annotation)
    }

    func endTextEditing() {
        guard let id = view.canvas.editingID, let text = view.canvas.endEditing() else { return }
        panel.makeFirstResponder(view)
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                annotations.remove(at: index)
                editor.select(nil)
            } else {
                annotations[index].text = text
                if let textUndoStart, textUndoStart.annotations != annotations { pushUndo(textUndoStart) }
            }
        }
        textUndoStart = nil
        editorDidChange()
    }

    func textEditingDidChange(_ text: String) {
        guard let id = view.canvas.editingID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].text = text
    }

    /// Opens the toolbar if needed and switches to `tool`.
    func activate(_ tool: Tool) {
        setAnnotating(true)
        editor.setTool(tool)
    }

    // MARK: Saving

    /// Annotations are kept next to the PNG so they stay editable later.
    private func scheduleSave() {
        guard let fileURL else { return }
        saveWork?.cancel()
        let sidecar = HistoryStore.Sidecar(annotations: annotations, crop: crop)
        let work = DispatchWorkItem { HistoryStore.shared.saveSidecar(sidecar, for: fileURL) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    var frame: NSRect { panel.frame }

    func setFrame(_ frame: NSRect) {
        panel.setFrame(frame, display: true)
        shadowPanel.setFrame(ShadowPanel.frame(around: frame), display: true)
        if isAnnotating { positionToolbar() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        setFocused(true)
        if resumeAnnotating {
            resumeAnnotating = false
            restoredAnnotatingAt = ProcessInfo.processInfo.systemUptime
            setAnnotating(true)
        }
    }

    private var resumeAnnotating = false
    private var restoredAnnotatingAt: TimeInterval = 0
    /// True for the click that refocused the float, so it does not also draw a mark.
    var justRestoredAnnotating: Bool {
        ProcessInfo.processInfo.systemUptime - restoredAnnotatingAt < 0.3
    }

    func settingsDidChange() {
        view.needsLayout = true
        shadowPanel.contentView?.needsLayout = true
    }

    // MARK: Toolbar dimming

    private var isMovingFloat = false

    func setMoving(_ moving: Bool) {
        guard moving != isMovingFloat else { return }
        isMovingFloat = moving
        applyToolbarDim()
        if Settings.dimWhileMoving || !moving {
            let visible = moving ? opacity * 0.7 : opacity
            view.setDisplayOpacity(visible)
            shadowPanel.animator().alphaValue = visible
        }
        // The same untinted window blur iTerm2 uses behind a translucent
        // terminal: only what shows through this float is softened. The blur
        // always fills the window's full rectangle, so rounded corners are
        // squared off for the duration; otherwise blurred slivers show outside them.
        let blurred = moving && Settings.dimWhileMoving && Settings.blurWhileMoving
        animateBlur(to: blurred ? 30 : 0)
    }

    private var blurRadius: CGFloat = 0
    private var blurTimer: Timer?

    /// Eases the blur behind the float in or out alongside the opacity fade,
    /// instead of switching it on and off. The blur fills the window's full
    /// rectangle, so rounded corners are squared off while any blur is showing.
    private func animateBlur(to target: CGFloat) {
        blurTimer?.invalidate()
        guard target != blurRadius else { return }
        let start = blurRadius
        let began = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval = 0.25
        if target > 0 { view.squareCorners = true }

        blurTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min((ProcessInfo.processInfo.systemUptime - began) / duration, 1)
                let eased = 1 - pow(1 - progress, 2)
                self.blurRadius = start + (target - start) * eased
                WindowBlur.set(radius: Int32(self.blurRadius.rounded()), for: self.panel)
                if progress >= 1 {
                    timer.invalidate()
                    if target == 0 { self.view.squareCorners = false }
                }
            }
        }
    }

    /// Called when the pointer enters or leaves the float or its toolbar.
    func pointerDidMove() {
        // React at once (so the toolbar wakes instantly), then check again in
        // case the pointer was only crossing the gap between float and toolbar.
        applyToolbarDim()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.applyToolbarDim() }
    }

    /// The toolbar fades back while the float is being moved or the pointer is away from both.
    private func applyToolbarDim() {
        guard isAnnotating, let toolbarPanel else { return }
        let reach = panel.frame.union(toolbarPanel.frame).insetBy(dx: -4, dy: -4)
        let dimmed = isMovingFloat || !reach.contains(NSEvent.mouseLocation)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = dimmed ? 0.22 : 0.07
            toolbarPanel.animator().alphaValue = dimmed ? 0.4 : 1
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Losing focus puts every tool away: toolbar, slider, and hover labels.
        endTextEditing()
        resumeAnnotating = isAnnotating
        setAnnotating(false)
        view.hideSlider()
        TooltipPanel.shared.hide()
        setFocused(false)
    }

    /// Focus is shown by depth alone: the focused float lifts on a deeper shadow.
    private func setFocused(_ focused: Bool) {
        view.isActive = focused
        (shadowPanel.contentView as? ShadowView)?.isFocused = focused
    }
}

final class FloatPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // drawn by ShadowPanel, which is stronger than the system one
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A click-through window behind a float that draws its drop shadow. Keeping it
/// separate means the shadow never intercepts clicks meant for other apps.
final class ShadowPanel: NSPanel {
    static let outset: CGFloat = 90

    static func frame(around floatFrame: NSRect) -> NSRect {
        floatFrame.insetBy(dx: -outset, dy: -outset)
    }

    init(around floatFrame: NSRect) {
        let frame = Self.frame(around: floatFrame)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = ShadowView(frame: NSRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // The shadow extends past the float, so macOS would otherwise push this
    // window back down when its top edge crosses the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class ShadowView: NSView {
    private let ambient = CALayer()
    private let contact = CALayer()
    private let maskLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        ambient.shadowColor = CGColor(gray: 0, alpha: 1)
        contact.shadowColor = CGColor(gray: 0, alpha: 1)
        applyDepth()

        layer?.addSublayer(ambient)
        layer?.addSublayer(contact)

        // Cut the image area out so a translucent float does not look darkened.
        maskLayer.fillRule = .evenOdd
        layer?.mask = maskLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Focused floats sit high on a deep shadow; unfocused ones rest close to the screen.
    var isFocused = false { didSet { if isFocused != oldValue { applyDepth() } } }

    private func applyDepth() {
        // Set outside a disabled transaction so the change animates.
        ambient.shadowOpacity = isFocused ? 0.58 : 0.32
        ambient.shadowRadius = isFocused ? 30 : 9
        ambient.shadowOffset = CGSize(width: 0, height: isFocused ? -18 : -4)
        contact.shadowOpacity = isFocused ? 0.42 : 0.3
        contact.shadowRadius = isFocused ? 5 : 2
        contact.shadowOffset = CGSize(width: 0, height: isFocused ? -3 : -1)
    }

    /// The shadow grows from nothing, so a new capture appears to lift off the screen.
    func playLift() {
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        for shadow in [ambient, contact] {
            let group = CAAnimationGroup()
            let opacity = CABasicAnimation(keyPath: "shadowOpacity")
            opacity.fromValue = 0
            let radius = CABasicAnimation(keyPath: "shadowRadius")
            radius.fromValue = 0
            let offset = CABasicAnimation(keyPath: "shadowOffset")
            offset.fromValue = CGSize.zero
            group.animations = [opacity, radius, offset]
            group.duration = 0.42
            group.timingFunction = timing
            shadow.add(group, forKey: "lift")
        }
    }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: ShadowPanel.outset, dy: ShadowPanel.outset)
        let radius = min(Settings.cornerRadius, max(min(inner.width, inner.height), 0) / 2)
        let shadowPath = CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let hole = CGMutablePath()
        hole.addRect(bounds)
        hole.addPath(shadowPath)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shadow in [ambient, contact] {
            shadow.frame = bounds
            shadow.shadowPath = shadowPath
        }
        maskLayer.frame = bounds
        maskLayer.path = hole
        CATransaction.commit()
    }
}

struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1)
    static let right = Edges(rawValue: 2)
    static let top = Edges(rawValue: 4)
    static let bottom = Edges(rawValue: 8)
}

final class FloatView: NSView {
    weak var controller: FloatController?

    var isActive = false { didSet { updateRing() } }

    private let imageLayer = CALayer()
    private let ringLayer = CALayer()
    private let closeLayer = CALayer()
    private let fileLayer = CALayer()
    private var filePressed = false
    private var filePressPoint = NSPoint.zero
    private var sharePicker: NSSharingServicePicker?
    private let gripLayer = CAShapeLayer()

    private var isHovered = false { didSet { updateChrome() } }
    private var closePressed = false

    private let slider = OpacitySliderLayer()
    private var sliderVisible = false

    let canvas = AnnotationCanvasView()
    /// Temporarily overrides the rounded-corners setting.
    var squareCorners = false { didSet { if squareCorners != oldValue { needsLayout = true } } }

    private enum Drag {
        case move
        case resize(Edges)
        case slider
        case annotate
    }

    private var dragStartState: FloatController.Snapshot?

    private var drag: Drag?
    private var dragStartFrame = NSRect.zero
    private var dragStartMouse = NSPoint.zero

    init(frame: NSRect, image: CGImage) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(ringLayer)
        setUpChrome()
        slider.isHidden = true
        layer?.addSublayer(slider)

        canvas.frame = bounds
        canvas.wantsLayer = true
        addSubview(canvas)
        // Keep the hover controls above the annotation canvas.
        for chrome in [ringLayer, closeLayer, fileLayer, gripLayer, slider] { chrome.zPosition = 10 }
        updateRing()
        updateChrome()

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = squareCorners ? 0 : min(Settings.cornerRadius, min(bounds.width, bounds.height) / 2)
        layer?.cornerRadius = radius
        ringLayer.cornerRadius = radius
        imageLayer.frame = imageFrame
        canvas.frame = bounds
        canvas.needsDisplay = true
        ringLayer.frame = bounds
        closeLayer.frame = closeRect
        fileLayer.frame = fileRect
        gripLayer.frame = bounds
        gripLayer.path = gripPath()
        slider.frame = sliderRect
        slider.layoutParts()
        CATransaction.commit()
        updateChrome()
    }

    // MARK: Image geometry

    private var crop: CGRect {
        controller?.crop ?? CGRect(origin: .zero, size: bounds.size)
    }

    /// Where the whole capture sits so that its cropped part exactly fills the view.
    private var imageFrame: CGRect {
        guard let controller else { return bounds }
        let crop = controller.crop, full = controller.naturalSize
        let zoomX = bounds.width / crop.width, zoomY = bounds.height / crop.height
        let height = full.height * zoomY
        return CGRect(
            x: -crop.minX * zoomX, y: bounds.height + crop.minY * zoomY - height,
            width: full.width * zoomX, height: height
        )
    }

    /// Screen points per image point.
    private var zoom: CGFloat { bounds.width / crop.width }

    private func imagePoint(_ point: NSPoint) -> CGPoint {
        let crop = self.crop
        return CGPoint(
            x: crop.minX + point.x / bounds.width * crop.width,
            y: crop.minY + (bounds.height - point.y) / bounds.height * crop.height
        )
    }

    func contentDidChange() {
        needsLayout = true
        canvas.needsDisplay = true
        updateChrome()
    }

    func refreshCursor() {
        guard drag == nil, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) { setCursor(at: point) }
    }

    // MARK: Arrival animation

    /// A soft flash while the image settles from a hair too large to exact size.
    func playArrival() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)

        let settle = CABasicAnimation(keyPath: "transform.scale")
        settle.fromValue = 1.035
        settle.toValue = 1
        settle.duration = 0.34
        settle.timingFunction = timing
        imageLayer.add(settle, forKey: "settle")

        let flashLayer = CALayer()
        flashLayer.frame = bounds
        flashLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
        flashLayer.opacity = 0
        layer?.insertSublayer(flashLayer, above: imageLayer)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.42
        fade.toValue = 0
        fade.duration = 0.38
        fade.timingFunction = timing
        flashLayer.add(fade, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { flashLayer.removeFromSuperlayer() }
    }

    // MARK: Opacity slider

    /// Sits near the bottom edge; shrinks, then drops its label, then centers
    /// itself vertically as the float gets smaller.
    private var sliderRect: CGRect {
        let width = bounds.width >= 60 ? min(230, bounds.width - 16) : max(bounds.width - 4, 8)
        let height = min(28, max(bounds.height - 6, 8))
        let y = bounds.height >= 76 ? 12 : (bounds.height - height) / 2
        return CGRect(x: (bounds.width - width) / 2, y: y, width: width, height: height).integral
    }

    var isSliderVisible: Bool { sliderVisible }
    func toggleSlider() { setSliderVisible(!sliderVisible) }
    func hideSlider() { if sliderVisible { setSliderVisible(false) } }

    private func setSliderVisible(_ visible: Bool) {
        sliderVisible = visible
        slider.value = controller?.opacity ?? 1
        slider.isHidden = !visible
        updateChrome()
        controller?.refreshToolbar()
    }

    func imageOpacityDidChange(_ value: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.opacity = Float(value)
        canvas.alphaValue = value
        slider.value = value
        CATransaction.commit()
    }

    /// Temporarily shows the image at another opacity without changing the float's own setting.
    func setDisplayOpacity(_ value: CGFloat) {
        imageLayer.opacity = Float(value)
        canvas.animator().alphaValue = value
    }

    private func setOpacityFromSlider(at point: NSPoint) {
        let fraction = slider.fraction(atX: point.x - sliderRect.minX)
        let minimum = FloatController.minimumOpacity
        controller?.setOpacity(minimum + fraction * (1 - minimum))
    }

    // MARK: Hover chrome (close button and resize grip)

    /// The file handle beside the close button: drag it into another app, or click to share.
    private var fileRect: CGRect {
        CGRect(x: 7 + 20 + 6, y: bounds.height - 7 - 20, width: 20, height: 20)
    }

    private func isOnFileButton(_ point: NSPoint) -> Bool {
        fileLayer.opacity > 0 && fileRect.insetBy(dx: -3, dy: -3).contains(point)
    }

    private var closeRect: CGRect {
        CGRect(x: 7, y: bounds.height - 7 - 20, width: 20, height: 20)
    }

    private func setUpChrome() {
        closeLayer.backgroundColor = CGColor(gray: 0.1, alpha: 0.72)
        closeLayer.borderColor = CGColor(gray: 1, alpha: 0.35)
        closeLayer.borderWidth = 1
        closeLayer.cornerRadius = 10
        closeLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        closeLayer.shadowOpacity = 0.35
        closeLayer.shadowRadius = 2
        closeLayer.shadowOffset = .zero

        let cross = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6.5, y: 6.5)); path.addLine(to: CGPoint(x: 13.5, y: 13.5))
        path.move(to: CGPoint(x: 13.5, y: 6.5)); path.addLine(to: CGPoint(x: 6.5, y: 13.5))
        cross.path = path
        cross.strokeColor = CGColor(gray: 1, alpha: 0.95)
        cross.lineWidth = 1.6
        cross.lineCap = .round
        cross.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        closeLayer.addSublayer(cross)
        layer?.addSublayer(closeLayer)

        fileLayer.backgroundColor = closeLayer.backgroundColor
        fileLayer.borderColor = closeLayer.borderColor
        fileLayer.borderWidth = 1
        fileLayer.cornerRadius = 10
        fileLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        fileLayer.shadowOpacity = 0.35
        fileLayer.shadowRadius = 2
        fileLayer.shadowOffset = .zero
        let page = CAShapeLayer()
        let outline = CGMutablePath()
        // A sheet of paper with a folded top-right corner.
        outline.addLines(between: [
            CGPoint(x: 6.5, y: 5), CGPoint(x: 6.5, y: 15), CGPoint(x: 11, y: 15),
            CGPoint(x: 13.5, y: 12.5), CGPoint(x: 13.5, y: 5),
        ])
        outline.closeSubpath()
        outline.addLines(between: [CGPoint(x: 11, y: 15), CGPoint(x: 11, y: 12.5), CGPoint(x: 13.5, y: 12.5)])
        page.path = outline
        page.strokeColor = CGColor(gray: 1, alpha: 0.95)
        page.fillColor = nil
        page.lineWidth = 1.3
        page.lineJoin = .round
        page.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        fileLayer.addSublayer(page)
        layer?.addSublayer(fileLayer)

        gripLayer.strokeColor = CGColor(gray: 1, alpha: 0.95)
        gripLayer.fillColor = nil
        gripLayer.lineWidth = 1.5
        gripLayer.lineCap = .round
        gripLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        gripLayer.shadowOpacity = 0.9
        gripLayer.shadowRadius = 1.5
        gripLayer.shadowOffset = .zero
        layer?.addSublayer(gripLayer)
    }

    /// Three diagonal lines in the bottom-right corner, the classic resize grip.
    private func gripPath() -> CGPath {
        let path = CGMutablePath()
        let inset: CGFloat = 4.5
        for step in 1...3 {
            let length = CGFloat(step) * 4.5
            path.move(to: CGPoint(x: bounds.maxX - inset - length, y: inset))
            path.addLine(to: CGPoint(x: bounds.maxX - inset, y: inset + length))
        }
        return path
    }

    private func updateChrome() {
        let side = min(bounds.width, bounds.height)
        closeLayer.opacity = isHovered && side >= 34 ? 1 : 0
        fileLayer.opacity = isHovered && side >= 34 && bounds.width >= 64 ? 1 : 0
        gripLayer.opacity = isHovered && side >= 60 && !(sliderVisible && bounds.width < 300) ? 1 : 0
    }

    private func updateRing() {
        // No focus border: only a faint hairline so pale images keep an edge.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.borderWidth = 0.5
        ringLayer.borderColor = CGColor(gray: 0, alpha: 0.18)
        CATransaction.commit()
    }

    // MARK: Feedback

    func flash(_ text: String) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(textSize.width) + 20, height: 24)

        let pill = CALayer()
        pill.backgroundColor = CGColor(gray: 0, alpha: 0.72)
        pill.cornerRadius = 12
        pill.frame = CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )

        let label = CATextLayer()
        label.string = text
        label.font = font
        label.fontSize = 12
        label.foregroundColor = CGColor(gray: 1, alpha: 1)
        label.alignmentMode = .center
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 0, y: (size.height - 16) / 2 - 1, width: size.width, height: 16)
        pill.addSublayer(label)
        pill.zPosition = 20
        layer?.addSublayer(pill)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.6
        fade.duration = 0.3
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        pill.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pill.removeFromSuperlayer() }
    }

    // MARK: Edges and cursors

    private func edges(at point: NSPoint) -> Edges {
        let side = min(bounds.width, bounds.height)
        // Slimmer resize zones while annotating, to leave more room for drawing.
        let annotating = controller?.isAnnotating == true
        let edge = min(annotating ? 6 : 12, side / 4)
        let corner = min(annotating ? 12 : 26, side / 3)

        let nearLeft = point.x < corner, nearRight = point.x > bounds.width - corner
        let nearBottom = point.y < corner, nearTop = point.y > bounds.height - corner
        if (nearLeft || nearRight) && (nearBottom || nearTop) {
            return [nearLeft ? .left : .right, nearBottom ? .bottom : .top]
        }

        var edges: Edges = []
        if point.x < edge { edges.insert(.left) }
        if point.x > bounds.width - edge { edges.insert(.right) }
        if point.y < edge { edges.insert(.bottom) }
        if point.y > bounds.height - edge { edges.insert(.top) }
        return edges
    }

    private func isOnCloseButton(_ point: NSPoint) -> Bool {
        closeLayer.opacity > 0 && closeRect.insetBy(dx: -3, dy: -3).contains(point)
    }

    private func cursor(for edges: Edges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.left, .top]: position = .topLeft
        case [.right, .top]: position = .topRight
        case [.left, .bottom]: position = .bottomLeft
        case [.right, .bottom]: position = .bottomRight
        case [.left]: position = .left
        case [.right]: position = .right
        case [.top]: position = .top
        case [.bottom]: position = .bottom
        default: return .arrow
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    private func updateCursor(with event: NSEvent) {
        guard drag == nil else { return }
        setCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func setCursor(at point: NSPoint) {
        // After a drag that ends outside the float, do not leave a resize cursor behind.
        guard bounds.contains(point) else {
            NSCursor.arrow.set()
            return
        }
        let edges = edges(at: point)
        if isOnFileButton(point) {
            NSCursor.openHand.set()
        } else if isOnCloseButton(point) || (sliderVisible && sliderRect.contains(point)) {
            NSCursor.arrow.set()
        } else if edges.isEmpty, let controller, controller.isAnnotating {
            switch controller.editor.hover(at: imagePoint(point), tolerance: 7 / zoom) {
            case .handle: NSCursor.pointingHand.set()
            case .body: NSCursor.openHand.set()
            case .none:
                switch controller.editor.tool {
                case .select: NSCursor.arrow.set()
                case .text: NSCursor.iBeam.set()
                default: NSCursor.crosshair.set()
                }
            }
        } else {
            cursor(for: edges).set()
        }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(with: event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(with: event) }
    override func mouseEntered(with event: NSEvent) {
        controller?.pointerDidMove()
        isHovered = true
        updateCursor(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.pointerDidMove()
        isHovered = false
        if drag == nil { NSCursor.arrow.set() }
    }

    // MARK: Move and resize

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        controller?.endTextEditing()
        window.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if isOnCloseButton(point) {
            closePressed = true
            return
        }
        if isOnFileButton(point) {
            filePressed = true
            filePressPoint = point
            return
        }
        dragStartState = controller?.snapshot
        if sliderVisible && sliderRect.insetBy(dx: -2, dy: -4).contains(point) {
            drag = .slider
            setOpacityFromSlider(at: point)
            return
        }
        let edges = edges(at: point)
        if edges.isEmpty, let controller, controller.isAnnotating, !controller.justRestoredAnnotating,
           controller.editor.mouseDown(at: imagePoint(point), tolerance: 7 / zoom, clickCount: event.clickCount) {
            drag = .annotate
            return
        }
        drag = edges.isEmpty ? .move : .resize(edges)
        dragStartFrame = window.frame
        dragStartMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        if filePressed {
            // Ignore the tiny wobble of an ordinary click; only real travel starts a drag.
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - filePressPoint.x, point.y - filePressPoint.y) > 4 else { return }
            filePressed = false
            beginFileDrag(with: event)
            return
        }
        if case .slider = drag {
            setOpacityFromSlider(at: convert(event.locationInWindow, from: nil))
        } else if case .annotate = drag {
            controller?.editor.mouseDragged(
                to: imagePoint(convert(event.locationInWindow, from: nil)),
                constrain: event.modifierFlags.contains(.shift), tolerance: 7 / zoom
            )
        } else {
            applyDrag()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Lets Shift / Option take effect mid-drag without moving the mouse.
        if drag != nil { applyDrag() }
    }

    override func mouseUp(with event: NSEvent) {
        if filePressed {
            // A click (no drag) on the file handle opens the share sheet.
            filePressed = false
            showSharePicker()
            return
        }
        if closePressed {
            closePressed = false
            if isOnCloseButton(convert(event.locationInWindow, from: nil)) { controller?.close() }
            return
        }
        if case .annotate = drag { controller?.editor.mouseUp() }
        if case .move = drag { controller?.setMoving(false) }
        if drag != nil, let start = dragStartState, start != controller?.snapshot {
            controller?.pushUndo(start)
        }
        dragStartState = nil
        drag = nil
        updateCursor(with: event)
    }

    private func applyDrag() {
        guard let drag, let controller else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStartMouse.x, dy = mouse.y - dragStartMouse.y

        switch drag {
        case .slider, .annotate:
            break
        case .move:
            // A plain click (to focus, say) is not a move; wait for real travel.
            if hypot(dx, dy) > 3 { controller.setMoving(true) }
            controller.setFrame(dragStartFrame.offsetBy(dx: dx, dy: dy))
        case .resize(let edges):
            let flags = NSEvent.modifierFlags
            controller.setFrame(Self.resizedFrame(
                from: dragStartFrame, edges: edges, dx: dx, dy: dy,
                free: flags.contains(.shift), centered: flags.contains(.option)
            ))
        }
    }

    /// Proportional by default; `free` (Shift) lets the shape change and
    /// `centered` (Option) grows from the middle, like native windows.
    static func resizedFrame(
        from start: NSRect, edges: Edges, dx: CGFloat, dy: CGFloat, free: Bool, centered: Bool
    ) -> NSRect {
        let horizontal: CGFloat = edges.contains(.right) ? 1 : edges.contains(.left) ? -1 : 0
        let vertical: CGFloat = edges.contains(.top) ? 1 : edges.contains(.bottom) ? -1 : 0
        let reach: CGFloat = centered ? 2 : 1
        let minimum = FloatController.minimumSide

        var width = start.width + horizontal * dx * reach
        var height = start.height + vertical * dy * reach

        if free {
            width = max(width, minimum)
            height = max(height, minimum)
        } else {
            let byWidth = width / start.width, byHeight = height / start.height
            var factor: CGFloat
            if horizontal != 0 && vertical != 0 {
                factor = max(byWidth, byHeight)
            } else {
                factor = horizontal != 0 ? byWidth : byHeight
            }
            factor = max(factor, minimum / min(start.width, start.height))
            width = start.width * factor
            height = start.height * factor
        }

        let x: CGFloat, y: CGFloat
        if centered {
            x = start.midX - width / 2
            y = start.midY - height / 2
        } else {
            x = horizontal > 0 ? start.minX : horizontal < 0 ? start.maxX - width : start.midX - width / 2
            y = vertical > 0 ? start.minY : vertical < 0 ? start.maxY - height : start.midY - height / 2
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    override func magnify(with event: NSEvent) {
        controller?.scale(by: 1 + event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.03
        if sliderVisible && flags.intersection([.command, .option, .control, .shift]).isEmpty {
            // Two fingers right or up raises opacity, left or down lowers it.
            let natural = event.isDirectionInvertedFromDevice
            let right = natural ? event.scrollingDeltaX : -event.scrollingDeltaX
            let up = natural ? -event.scrollingDeltaY : event.scrollingDeltaY
            let travel = abs(right) > abs(up) ? right : up
            let step = event.hasPreciseScrollingDeltas ? travel * 0.004 : travel * 0.03
            if step != 0 { controller?.adjustOpacity(by: step) }
        } else if flags.contains(.command) {
            controller?.scale(by: 1 + delta)
        } else if flags.contains(.option) {
            controller?.adjustOpacity(by: delta)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Dragging out and sharing

    private func beginFileDrag(with event: NSEvent) {
        guard let controller, let url = controller.exportedFileURL() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)

        // Drag a small thumbnail of the float, centered under the pointer.
        let longest = max(bounds.width, bounds.height)
        let ratio = min(1, 150 / longest)
        let size = CGSize(width: bounds.width * ratio, height: bounds.height * ratio)
        let point = convert(event.locationInWindow, from: nil)
        let thumbnail = NSImage(cgImage: controller.renderedImage(), size: size)
        item.setDraggingFrame(
            CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: thumbnail
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func showSharePicker() {
        guard let url = controller?.exportedFileURL() else { return }
        let picker = NSSharingServicePicker(items: [url])
        sharePicker = picker
        // Shown as a menu, which works even though Floaty is not the active
        // app; the system share popover does not appear reliably from here.
        if let services = picker.standardShareMenuItem.submenu {
            services.popUp(positioning: nil, at: CGPoint(x: fileRect.minX, y: fileRect.minY - 4), in: self)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            picker.show(relativeTo: fileRect, of: self, preferredEdge: .minY)
        }
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()

        // While typing a text annotation, the editing shortcuts go to the text
        // field. Floaty has no Edit menu to route them, so do it by hand.
        if let controller, controller.isEditingText, let field = canvas.textView {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            switch (flags, key) {
            case ([.command], _) where isReturn: controller.endTextEditing()
            case ([.command], "a"): field.selectAll(nil)
            case ([.command], "c"): field.copy(nil)
            case ([.command], "x"): field.cut(nil)
            case ([.command], "v"): field.pasteAsPlainText(nil)
            case ([.command], "z"): field.undoManager?.undo()
            case ([.command, .shift], "z"): field.undoManager?.redo()
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }

        switch (flags, key) {
        case ([.command], "c"): controller?.copy()
        case ([.command, .option], "c"): controller?.copyPath()
        case ([.command], "s"): controller?.save()
        case ([.command, .shift], "s"): controller?.saveAs()
        case ([.command], "w"): controller?.close()
        case ([.command], "0"): controller?.resetSize()
        case ([.command], "z"): controller?.undo()
        case ([.command, .shift], "z"): controller?.redo()
        case ([.command], ","): SettingsWindowController.shared.show()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty, let controller else { return super.keyDown(with: event) }
        let annotating = controller.isAnnotating
        let editor = controller.editor

        // Esc backs out one level at a time.
        if event.keyCode == 53 {
            if annotating {
                // First back to the Select tool, then deselect, then put the toolbar away.
                if editor.tool != .select {
                    editor.setTool(.select)
                } else if editor.selectedID != nil {
                    editor.select(nil)
                } else {
                    controller.setAnnotating(false)
                }
            } else if sliderVisible {
                setSliderVisible(false)
            } else {
                controller.close()
            }
            return
        }
        if annotating, event.keyCode == 51 || event.keyCode == 117 { // Delete
            editor.deleteSelected()
            return
        }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "0": controller.resetSize()
        case "o": setSliderVisible(!sliderVisible)
        case "u": event.modifierFlags.contains(.shift) ? controller.redo() : controller.undo()
        case "[" where annotating: editor.adjustSize(steps: -1)
        case "]" where annotating: editor.adjustSize(steps: 1)
        default:
            // Tool keys work straight from a focused float, opening the toolbar.
            if let tool = Tool.allCases.first(where: { $0.key == key }) {
                controller.activate(tool)
            } else if annotating, let digit = Int(key), (1...RGBA.palette.count).contains(digit) {
                editor.updateStyle { $0.color = RGBA.palette[digit - 1] }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(menuCopy), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Path", action: #selector(menuCopyPath), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save As…", action: #selector(menuSaveAs), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let annotating = controller?.isAnnotating == true
        menu.addItem(withTitle: annotating ? "Finish Annotating" : "Annotate", action: #selector(menuAnnotate), keyEquivalent: "").target = self
        if controller?.isCropped == true {
            menu.addItem(withTitle: "Remove Crop", action: #selector(menuRemoveCrop), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Actual Size", action: #selector(menuResetSize), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(menuReveal), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(menuClose), keyEquivalent: "").target = self
        return menu
    }

    @objc private func menuCopy() { controller?.copy() }
    @objc private func menuCopyPath() { controller?.copyPath() }
    @objc private func menuSaveAs() { controller?.saveAs() }
    @objc private func menuAnnotate() { controller.map { $0.setAnnotating(!$0.isAnnotating) } }
    @objc private func menuRemoveCrop() { controller?.removeCrop() }
    @objc private func menuResetSize() { controller?.resetSize() }
    @objc private func menuReveal() { controller?.revealInFinder() }
    @objc private func menuClose() { controller?.close() }
}

/// A compact horizontal slider drawn with layers: track, fill, knob, and a
/// percentage label that is dropped when there is no room for it.
final class OpacitySliderLayer: CALayer {
    var value: CGFloat = 1 { didSet { layoutParts() } }

    private let track = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()
    private let label = CATextLayer()

    override init() {
        super.init()
        backgroundColor = CGColor(gray: 0.08, alpha: 0.78)
        borderColor = CGColor(gray: 1, alpha: 0.22)
        borderWidth = 1
        shadowColor = CGColor(gray: 0, alpha: 1)
        shadowOpacity = 0.35
        shadowRadius = 4
        shadowOffset = CGSize(width: 0, height: -1)

        track.backgroundColor = CGColor(gray: 1, alpha: 0.25)
        fill.backgroundColor = CGColor(gray: 1, alpha: 0.95)
        knob.backgroundColor = CGColor(gray: 1, alpha: 1)
        knob.shadowColor = CGColor(gray: 0, alpha: 1)
        knob.shadowOpacity = 0.45
        knob.shadowRadius = 1.5
        knob.shadowOffset = .zero

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.fontSize = 11
        label.foregroundColor = CGColor(gray: 1, alpha: 0.9)
        label.alignmentMode = .right
        label.contentsScale = 2

        [track, fill, knob, label].forEach(addSublayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var knobSize: CGFloat { max(min(14, bounds.height - 8), 4) }
    private var padding: CGFloat { bounds.width >= 60 ? 10 : 3 }
    private var showsLabel: Bool { bounds.width >= 130 && bounds.height >= 20 }

    /// The horizontal span the knob center travels along.
    private var travel: ClosedRange<CGFloat> {
        let start = padding + knobSize / 2
        let end = bounds.width - padding - knobSize / 2 - (showsLabel ? 40 : 0)
        return start...max(end, start + 1)
    }

    private var fractionValue: CGFloat {
        let minimum = FloatController.minimumOpacity
        return min(max((value - minimum) / (1 - minimum), 0), 1)
    }

    /// Converts an x position inside the slider to 0...1.
    func fraction(atX x: CGFloat) -> CGFloat {
        let range = travel
        return min(max((x - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    func layoutParts() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cornerRadius = bounds.height / 2

        let range = travel
        let centerX = range.lowerBound + fractionValue * (range.upperBound - range.lowerBound)
        let midY = bounds.midY
        let thickness: CGFloat = min(4, max(bounds.height - 6, 2))

        track.frame = CGRect(
            x: range.lowerBound, y: midY - thickness / 2,
            width: range.upperBound - range.lowerBound, height: thickness
        )
        track.cornerRadius = thickness / 2
        fill.frame = CGRect(x: range.lowerBound, y: midY - thickness / 2, width: centerX - range.lowerBound, height: thickness)
        fill.cornerRadius = thickness / 2
        knob.frame = CGRect(x: centerX - knobSize / 2, y: midY - knobSize / 2, width: knobSize, height: knobSize)
        knob.cornerRadius = knobSize / 2

        label.isHidden = !showsLabel
        label.string = "\(Int((value * 100).rounded()))%"
        label.frame = CGRect(x: bounds.width - padding - 36, y: midY - 8, width: 36, height: 15)
        CATransaction.commit()
    }
}

extension FloatView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
