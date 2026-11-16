import AppKit

/// Turns mouse input on a float into annotation edits: creating marks with the
/// current tool, selecting, moving, and reshaping them through handles.
@MainActor
final class AnnotationEditor {
    weak var controller: FloatController?

    private(set) var tool: Tool = .arrow
    private(set) var selectedID: UUID?
    private(set) var cropMarquee: CGRect?

    enum Handle: Equatable {
        case start, end, control
        case corner(Int)
    }

    private enum Action {
        case creating(UUID)
        case moving(UUID)
        case handle(UUID, Handle)
        case cropping(CGPoint)
    }

    private var action: Action?
    private var lastPoint = CGPoint.zero

    // MARK: State

    var selected: Annotation? {
        guard let selectedID else { return nil }
        return controller?.annotations.first { $0.id == selectedID }
    }

    /// The tool whose style the toolbar is showing: the selected mark's, else the active tool's.
    var styleTool: Tool { selected?.tool ?? tool }
    var currentStyle: ToolStyle { selected?.style ?? StyleStore.style(for: tool) }

    private func index(of id: UUID) -> Int? {
        controller?.annotations.firstIndex { $0.id == id }
    }

    func setTool(_ newTool: Tool) {
        tool = newTool
        selectedID = nil
        cropMarquee = nil
        controller?.editorDidChange()
    }

    func select(_ id: UUID?) {
        selectedID = id
        controller?.editorDidChange()
    }

    /// Applies a style change to the selected mark (if any) and remembers it for that tool.
    func updateStyle(_ change: (inout ToolStyle) -> Void) {
        guard let controller else { return }
        if let selectedID, let index = index(of: selectedID) {
            controller.recordUndo(coalescing: "style")
            var style = controller.annotations[index].style
            change(&style)
            controller.annotations[index].style = style
            StyleStore.set(style, for: controller.annotations[index].tool)
        } else {
            var style = StyleStore.style(for: tool)
            change(&style)
            StyleStore.set(style, for: tool)
        }
        controller.editorDidChange()
    }

    func adjustSize(steps: Int) {
        let (range, step) = ToolStyle.sizeRange(for: styleTool)
        updateStyle { $0.size = min(max($0.size + CGFloat(steps) * step, range.lowerBound), range.upperBound) }
    }

    func deleteSelected() {
        guard let controller, let selectedID, let index = index(of: selectedID) else { return }
        controller.recordUndo()
        controller.annotations.remove(at: index)
        self.selectedID = nil
        controller.editorDidChange()
    }

    // MARK: Handles

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    func handles(for annotation: Annotation) -> [(Handle, CGPoint)] {
        switch annotation.tool {
        case .arrow, .line:
            return [(.start, annotation.start), (.end, annotation.end), (.control, annotation.midpoint)]
        case .rect, .ellipse, .blur, .spotlight:
            return corners(of: annotation.rect).enumerated().map { (.corner($0.offset), $0.element) }
        default:
            return []
        }
    }

    private func topmost(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        controller?.annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    enum Hover { case none, handle, body }

    /// What the pointer is over, used to pick a cursor.
    func hover(at point: CGPoint, tolerance: CGFloat) -> Hover {
        if let selected {
            for (_, position) in handles(for: selected) where position.distance(to: point) <= tolerance * 1.5 {
                return .handle
            }
            if selected.tool != .pen, selected.tool != .highlighter, selected.hitTest(point, tolerance: tolerance) {
                return .body
            }
        }
        if tool == .select, topmost(at: point, tolerance: tolerance) != nil { return .body }
        return .none
    }

    // MARK: Mouse

    /// Returns false when the click was not used, so the float can be dragged instead.
    func mouseDown(at point: CGPoint, tolerance: CGFloat, clickCount: Int) -> Bool {
        guard let controller else { return false }
        lastPoint = point

        if let selected {
            for (handle, position) in handles(for: selected) where position.distance(to: point) <= tolerance * 1.5 {
                action = .handle(selected.id, handle)
                return true
            }
        }

        switch tool {
        case .select:
            guard let hit = topmost(at: point, tolerance: tolerance) else {
                if selectedID != nil { select(nil) }
                return false
            }
            selectedID = hit.id
            if hit.tool == .text && clickCount >= 2 {
                controller.beginTextEditing(hit.id, isNew: false)
            } else {
                action = .moving(hit.id)
            }
            controller.editorDidChange()
            return true

        case .crop:
            action = .cropping(point)
            cropMarquee = CGRect(origin: point, size: .zero)
            return true

        case .text:
            if let hit = topmost(at: point, tolerance: tolerance), hit.tool == .text {
                selectedID = hit.id
                controller.beginTextEditing(hit.id, isNew: false)
            } else {
                var annotation = Annotation(tool: .text, style: StyleStore.style(for: .text))
                annotation.start = CGPoint(x: point.x, y: point.y - annotation.style.size * 0.6)
                controller.annotations.append(annotation)
                selectedID = annotation.id
                controller.beginTextEditing(annotation.id, isNew: true)
            }
            controller.editorDidChange()
            return true

        default:
            // The mark just drawn stays selected, so it can be nudged without switching tools.
            if let selected, selected.tool != .pen, selected.tool != .highlighter,
               selected.hitTest(point, tolerance: tolerance) {
                action = .moving(selected.id)
                return true
            }
            var annotation = Annotation(tool: tool, style: StyleStore.style(for: tool))
            annotation.start = point
            annotation.end = point
            if tool == .pen || tool == .highlighter { annotation.points = [point] }
            if tool == .number {
                annotation.number = (controller.annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
            }
            controller.annotations.append(annotation)
            selectedID = annotation.id
            action = tool == .number ? .moving(annotation.id) : .creating(annotation.id)
            controller.editorDidChange()
            return true
        }
    }

    /// `constrain` (Shift) snaps lines to 45° steps and boxes to squares.
    func mouseDragged(to point: CGPoint, constrain: Bool, tolerance: CGFloat) {
        guard let controller, let action else { return }
        defer { lastPoint = point }

        switch action {
        case .creating(let id):
            guard let index = index(of: id) else { return }
            var annotation = controller.annotations[index]
            if annotation.tool == .pen || annotation.tool == .highlighter {
                if constrain {
                    annotation.points = [annotation.start, snapped(point, from: annotation.start, tool: .line)]
                } else if let last = annotation.points.last, last.distance(to: point) > 0.6 {
                    annotation.points.append(point)
                }
            } else {
                annotation.end = constrain ? snapped(point, from: annotation.start, tool: annotation.tool) : point
            }
            controller.annotations[index] = annotation

        case .moving(let id):
            guard let index = index(of: id) else { return }
            controller.annotations[index].translate(by: point - lastPoint)

        case .handle(let id, let handle):
            guard let index = index(of: id) else { return }
            var annotation = controller.annotations[index]
            switch handle {
            case .start:
                annotation.start = constrain ? snapped(point, from: annotation.end, tool: annotation.tool) : point
            case .end:
                annotation.end = constrain ? snapped(point, from: annotation.start, tool: annotation.tool) : point
            case .control:
                // Dropping the handle back near the straight line removes the bend.
                let straightMid = (annotation.start + annotation.end) * 0.5
                annotation.control = point.distance(to: straightMid) <= tolerance * 0.6 ? nil : point
            case .corner(let corner):
                let opposite = corners(of: annotation.rect)[(corner + 2) % 4]
                annotation.start = opposite
                annotation.end = constrain ? snapped(point, from: opposite, tool: annotation.tool) : point
                self.action = .handle(id, .corner(self.corner(of: annotation, nearest: annotation.end)))
            }
            controller.annotations[index] = annotation

        case .cropping(let origin):
            let marquee = CGRect(
                x: min(origin.x, point.x), y: min(origin.y, point.y),
                width: abs(point.x - origin.x), height: abs(point.y - origin.y)
            ).intersection(controller.crop)
            cropMarquee = marquee.isNull ? nil : marquee
            controller.redrawCanvas()
        }
    }

    func mouseUp() {
        guard let controller else { return }
        switch action {
        case .creating(let id):
            if let index = index(of: id) {
                let annotation = controller.annotations[index]
                let isStroke = annotation.tool == .pen || annotation.tool == .highlighter
                if !isStroke && annotation.start.distance(to: annotation.end) < 3 {
                    controller.annotations.remove(at: index)
                    selectedID = nil
                } else if isStroke {
                    selectedID = nil
                }
            }
        case .cropping:
            if let marquee = cropMarquee, marquee.width >= 8, marquee.height >= 8 {
                controller.applyCrop(marquee)
                tool = .select
            }
            cropMarquee = nil
        default:
            break
        }
        action = nil
        controller.editorDidChange()
    }

    private func corner(of annotation: Annotation, nearest point: CGPoint) -> Int {
        let all = corners(of: annotation.rect)
        return all.indices.min { all[$0].distance(to: point) < all[$1].distance(to: point) } ?? 0
    }

    private func snapped(_ point: CGPoint, from origin: CGPoint, tool: Tool) -> CGPoint {
        let delta = point - origin
        switch tool {
        case .arrow, .line:
            let step = CGFloat.pi / 4
            let angle = (atan2(delta.y, delta.x) / step).rounded() * step
            return origin + CGPoint(x: cos(angle), y: sin(angle)) * delta.length
        default:
            let side = max(abs(delta.x), abs(delta.y))
            return origin + CGPoint(x: delta.x < 0 ? -side : side, y: delta.y < 0 ? -side : side)
        }
    }

    // MARK: Overlay

    /// Selection outline, handles, and the crop marquee. `zoom` is screen points
    /// per image point, so handles stay the same size at any float scale.
    func drawOverlay(in context: CGContext, canvas: CGRect, zoom: CGFloat) {
        let accent = NSColor.controlAccentColor.cgColor

        if let selected, action == nil || !isCreating {
            let handles = handles(for: selected)
            if handles.isEmpty {
                context.saveGState()
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
                context.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.8))
                context.setLineWidth(1 / zoom)
                context.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
                context.stroke(selected.bounds.insetBy(dx: -3 / zoom, dy: -3 / zoom))
                context.restoreGState()
            }
            for (handle, position) in handles {
                let radius = (handle == .control ? 4 : 5) / zoom
                let circle = CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2)
                context.saveGState()
                context.setShadow(offset: .zero, blur: 2.5, color: CGColor(gray: 0, alpha: 0.6))
                context.setFillColor(handle == .control ? accent : CGColor(gray: 1, alpha: 1))
                context.fillEllipse(in: circle)
                context.restoreGState()
                context.setStrokeColor(handle == .control ? CGColor(gray: 1, alpha: 1) : accent)
                context.setLineWidth(1.5 / zoom)
                context.strokeEllipse(in: circle)
            }
        }

        if let marquee = cropMarquee {
            context.saveGState()
            let outside = CGMutablePath()
            outside.addRect(canvas)
            outside.addRect(marquee)
            context.addPath(outside)
            context.setFillColor(CGColor(gray: 0, alpha: 0.5))
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(1 / zoom)
            context.stroke(marquee)
            context.restoreGState()
        }
    }

    private var isCreating: Bool {
        if case .creating = action { return true }
        return false
    }
}

/// Draws the annotations on top of the float's image and hosts the text field
/// used while typing a text annotation.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    weak var controller: FloatController?

    private(set) var textView: NSTextView?
    private(set) var editingID: UUID?

    override var isFlipped: Bool { true }

    /// Mouse input is handled by the float view; only the text field takes clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let textView, let superview else { return nil }
        return textView.frame.contains(convert(point, from: superview)) ? textView : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
        let showsOverlay = controller.isAnnotating
        guard !controller.annotations.isEmpty || showsOverlay else { return }

        let crop = controller.crop
        let zoomX = bounds.width / crop.width, zoomY = bounds.height / crop.height
        context.saveGState()
        context.scaleBy(x: zoomX, y: zoomY)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        controller.renderer.draw(
            controller.annotations, in: context, canvas: crop,
            pixelsPerPoint: zoomX * (window?.backingScaleFactor ?? 2), hiddenText: editingID
        )
        if showsOverlay {
            controller.editor.drawOverlay(in: context, canvas: crop, zoom: zoomX)
        }
        context.restoreGState()
    }

    // MARK: Text editing

    func beginEditing(_ annotation: Annotation) {
        _ = endEditing()
        guard let controller else { return }
        let crop = controller.crop
        let zoomX = bounds.width / crop.width, zoomY = bounds.height / crop.height
        let style = annotation.style
        let font = NSFont.systemFont(ofSize: style.size * zoomX, weight: .bold)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        let origin = CGPoint(x: (annotation.start.x - crop.minX) * zoomX, y: (annotation.start.y - crop.minY) * zoomY)
        let field = NSTextView(frame: CGRect(origin: origin, size: CGSize(width: 8, height: lineHeight)))
        field.isRichText = false
        field.allowsUndo = true
        field.font = font
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.widthTracksTextView = false
        field.textContainer?.containerSize = CGSize(width: 10_000, height: 10_000)
        field.isHorizontallyResizable = true
        field.isVerticallyResizable = true
        field.minSize = CGSize(width: 8, height: lineHeight)
        field.maxSize = CGSize(width: 10_000, height: 10_000)

        // The canvas draws the background (with its padding) beneath this field.
        field.drawsBackground = false
        field.textColor = style.textColor.nsColor
        field.insertionPointColor = style.textColor.nsColor
        field.string = annotation.text
        field.delegate = self

        addSubview(field)
        textView = field
        editingID = annotation.id
        field.sizeToFit()
        window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: (annotation.text as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Applies a color, size, or style change made from the toolbar mid-typing.
    func restyle(_ annotation: Annotation) {
        guard let field = textView, let controller else { return }
        let zoom = bounds.width / controller.crop.width
        field.font = NSFont.systemFont(ofSize: annotation.style.size * zoom, weight: .bold)
        field.textColor = annotation.style.textColor.nsColor
        field.insertionPointColor = annotation.style.textColor.nsColor
        field.sizeToFit()
    }

    /// Removes the text field and returns what was typed, or nil if not editing.
    func endEditing() -> String? {
        guard let field = textView else { return nil }
        let text = field.string
        field.delegate = nil
        field.removeFromSuperview()
        textView = nil
        editingID = nil
        needsDisplay = true
        return text
    }

    /// Keeps the annotation in step with every keystroke, so its background
    /// and selection outline grow as you type.
    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        controller?.textEditingDidChange(textView.string)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            controller?.endTextEditing()
            return true
        }
        return false
    }
}
