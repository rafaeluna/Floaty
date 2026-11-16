import AppKit

// MARK: - Model

enum Tool: String, Codable, CaseIterable {
    case select, arrow, line, rect, ellipse, text, pen, highlighter, blur, number, spotlight, crop

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .blur: return "Pixelate"
        case .number: return "Numbered step"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .blur: return "checkerboard.rectangle"
        case .number: return "1.circle"
        case .spotlight: return "sun.max"
        case .crop: return "crop"
        }
    }

    /// Single-key shortcut while the toolbar is open.
    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .ellipse: return "e"
        case .text: return "t"
        case .pen: return "p"
        case .highlighter: return "h"
        case .blur: return "b"
        case .number: return "n"
        case .spotlight: return "s"
        case .crop: return "c"
        }
    }

    var usesColor: Bool { ![.select, .blur, .spotlight, .crop].contains(self) }
    var usesSize: Bool { ![.select, .blur, .spotlight, .crop].contains(self) }
    var usesFill: Bool { self == .rect || self == .ellipse }
    var usesTextStyle: Bool { self == .text }
}

struct RGBA: Codable, Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func withAlpha(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }

    var isLight: Bool { 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.62 }
    /// Black or white, whichever reads better on top of this color.
    var contrast: RGBA { isLight ? RGBA(0x111111) : RGBA(0xFFFFFF) }

    static let palette: [RGBA] = [
        RGBA(0xFF3B30), RGBA(0xFF9500), RGBA(0xFFD60A), RGBA(0x30D158),
        RGBA(0x0A84FF), RGBA(0xBF5AF2), RGBA(0x1C1C1E), RGBA(0xFFFFFF),
    ]
}

enum FillMode: String, Codable, CaseIterable { case none, tint, solid }
/// `pill` puts contrasting text on a background of the chosen color;
/// `card` puts text in the chosen color on a contrasting background.
enum TextStyle: String, Codable, CaseIterable {
    case plain, shadow, outline, pill, card
    var hasBackground: Bool { self == .pill || self == .card }
}

struct ToolStyle: Codable, Equatable {
    var color: RGBA
    /// Stroke width for shapes and strokes, font size for text, radius for numbered steps.
    var size: CGFloat
    var fill: FillMode = .none
    var textStyle: TextStyle = .pill

    /// The color of the letters themselves for a text annotation.
    var textColor: RGBA { textStyle == .pill ? color.contrast : color }

    static func standard(for tool: Tool) -> ToolStyle {
        switch tool {
        case .arrow: return ToolStyle(color: RGBA.palette[0], size: 5)
        case .text: return ToolStyle(color: RGBA.palette[0], size: 20)
        case .highlighter: return ToolStyle(color: RGBA.palette[2], size: 16)
        case .number: return ToolStyle(color: RGBA.palette[0], size: 13)
        default: return ToolStyle(color: RGBA.palette[0], size: 4)
        }
    }

    static func sizeRange(for tool: Tool) -> (range: ClosedRange<CGFloat>, step: CGFloat) {
        switch tool {
        case .text: return (10...120, 2)
        case .number: return (8...48, 1)
        case .highlighter: return (6...48, 2)
        default: return (1...28, 1)
        }
    }
}

/// One editable mark. All coordinates are in image points with the origin at
/// the top-left of the original capture, so marks survive resizing and cropping.
struct Annotation: Codable, Equatable {
    var id = UUID()
    var tool: Tool
    var style: ToolStyle
    /// Endpoints for arrows and lines, opposite corners for boxes, the
    /// top-left for text, the center for numbered steps.
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    /// A point the arrow or line bends through, when it has been curved.
    var control: CGPoint?
    var points: [CGPoint] = []
    var text = ""
    var number = 0
}

// MARK: - Geometry

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var length: CGFloat { hypot(x, y) }
    func distance(to other: CGPoint) -> CGFloat { (self - other).length }

    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = min(max(((x - a.x) * ab.x + (y - a.y) * ab.y) / lengthSquared, 0), 1)
        return distance(to: a + ab * t)
    }
}

extension Annotation {
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var midpoint: CGPoint { control ?? (start + end) * 0.5 }

    /// Points along the (possibly curved) path from start to end.
    func pathPoints(samples: Int = 40) -> [CGPoint] {
        guard let control else { return [start, end] }
        let handle = control * 2 - (start + end) * 0.5
        return (0...samples).map { index in
            let t = CGFloat(index) / CGFloat(samples), u = 1 - t
            return start * (u * u) + handle * (2 * u * t) + end * (t * t)
        }
    }

    var font: NSFont { NSFont.systemFont(ofSize: style.size, weight: .bold) }

    var textRect: CGRect {
        let string = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let size = string.boundingRect(
            with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]
        ).size
        return CGRect(origin: start, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
    }

    var textPadding: CGSize {
        style.textStyle.hasBackground ? CGSize(width: style.size * 0.42, height: style.size * 0.2) : .zero
    }

    /// The box used for selection outlines.
    var bounds: CGRect {
        switch tool {
        case .arrow, .line:
            let points = pathPoints()
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .insetBy(dx: -style.size, dy: -style.size)
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for point in points { box = box.union(CGRect(origin: point, size: .zero)) }
            return box.insetBy(dx: -style.size / 2, dy: -style.size / 2)
        case .text:
            return textRect.insetBy(dx: -textPadding.width, dy: -textPadding.height)
        case .number:
            return CGRect(x: start.x - style.size, y: start.y - style.size, width: style.size * 2, height: style.size * 2)
        default:
            return rect
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        func nearPolyline(_ points: [CGPoint]) -> Bool {
            let reach = style.size / 2 + tolerance
            if points.count == 1 { return point.distance(to: points[0]) <= reach }
            for index in 1..<max(points.count, 1) where point.distance(toSegment: points[index - 1], points[index]) <= reach {
                return true
            }
            return false
        }

        switch tool {
        case .arrow, .line:
            return nearPolyline(pathPoints())
        case .pen, .highlighter:
            return nearPolyline(points)
        case .rect:
            let outer = rect.insetBy(dx: -style.size / 2 - tolerance, dy: -style.size / 2 - tolerance)
            guard outer.contains(point) else { return false }
            if style.fill != .none { return true }
            let inner = rect.insetBy(dx: style.size / 2 + tolerance, dy: style.size / 2 + tolerance)
            return inner.isNull || inner.isEmpty || !inner.contains(point)
        case .ellipse:
            let box = rect
            guard box.width > 0, box.height > 0 else { return false }
            let dx = (point.x - box.midX) / (box.width / 2), dy = (point.y - box.midY) / (box.height / 2)
            let radial = hypot(dx, dy)
            if style.fill != .none { return radial <= 1 }
            return abs(radial - 1) * min(box.width, box.height) / 2 <= style.size / 2 + tolerance
        case .number:
            return point.distance(to: start) <= style.size + tolerance
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    mutating func translate(by delta: CGPoint) {
        start = start + delta
        end = end + delta
        if let control { self.control = control + delta }
        points = points.map { $0 + delta }
    }
}

// MARK: - Rendering

/// Draws annotations into a context whose coordinates are image points with
/// the origin at the top-left. Used for both the live canvas and exports, so
/// what is copied always matches what is on screen.
@MainActor
final class AnnotationRenderer {
    let image: CGImage
    let scale: CGFloat
    private var pixelated: [UUID: (rect: CGRect, image: CGImage)] = [:]

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    /// - Parameters:
    ///   - canvas: the visible part of the image, in image points
    ///   - pixelsPerPoint: device pixels per image point, used to keep shadows consistent
    ///   - hiddenText: an annotation being edited in a text field, so not drawn twice
    func draw(
        _ annotations: [Annotation], in context: CGContext, canvas: CGRect,
        pixelsPerPoint: CGFloat, hiddenText: UUID? = nil
    ) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Pixelation and the spotlight alter the picture itself, so they sit
        // beneath every other mark regardless of when they were added.
        for annotation in annotations where annotation.tool == .blur { drawPixelated(annotation, in: context) }
        drawSpotlight(annotations.filter { $0.tool == .spotlight }, in: context, canvas: canvas)

        for annotation in annotations {
            context.saveGState()
            // Each mark is composited as one piece so its fill and outline
            // share a single soft shadow instead of shadowing each other.
            let layered = annotation.tool != .highlighter
            if layered {
                context.setShadow(offset: .zero, blur: 4.5 * pixelsPerPoint, color: CGColor(gray: 0, alpha: 0.38))
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            switch annotation.tool {
            case .arrow: drawArrow(annotation, in: context)
            case .line: drawLine(annotation, in: context)
            case .rect, .ellipse: drawShape(annotation, in: context)
            case .pen, .highlighter: drawStroke(annotation, in: context)
            case .number: drawNumber(annotation, in: context)
            case .text: drawText(annotation, in: context, glyphs: annotation.id != hiddenText)
            default: break
            }
            if layered { context.endTransparencyLayer() }
            context.restoreGState()
        }
        pixelated = pixelated.filter { entry in annotations.contains { $0.id == entry.key } }
    }

    // MARK: Marks

    private func drawArrow(_ annotation: Annotation, in context: CGContext) {
        let points = annotation.pathPoints()
        var lengths: [CGFloat] = [0]
        for index in 1..<points.count { lengths.append(lengths[index - 1] + points[index].distance(to: points[index - 1])) }
        let total = lengths.last ?? 0
        guard total > 1 else { return }

        let size = annotation.style.size
        let headLength = min(max(size * 3.4, 11), total * 0.6)
        let headHalfWidth = max(size * 1.75, 5.5) * min(1, headLength / max(size * 3.4, 11) + 0.25)
        let shaftLength = total - headLength

        // Shaft points up to where the head begins (the neck).
        var shaft: [CGPoint] = []
        var shaftAt: [CGFloat] = []
        for index in 0..<points.count {
            if lengths[index] < shaftLength {
                shaft.append(points[index])
                shaftAt.append(lengths[index])
            } else {
                let previous = max(index - 1, 0)
                let span = lengths[index] - lengths[previous]
                let t = span > 0 ? (shaftLength - lengths[previous]) / span : 0
                shaft.append(points[previous] + (points[index] - points[previous]) * t)
                shaftAt.append(shaftLength)
                break
            }
        }
        guard let neck = shaft.last, let tip = points.last else { return }
        let direction = (tip - neck) * (1 / max((tip - neck).length, 0.001))
        let headNormal = CGPoint(x: -direction.y, y: direction.x)

        var left: [CGPoint] = [], right: [CGPoint] = []
        for index in 0..<shaft.count {
            let before = shaft[max(index - 1, 0)], after = shaft[min(index + 1, shaft.count - 1)]
            var tangent = after - before
            if tangent.length < 0.001 { tangent = direction }
            tangent = tangent * (1 / tangent.length)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let progress = shaftLength > 0 ? shaftAt[index] / shaftLength : 1
            let halfWidth = size * (0.26 + 0.24 * progress) // tapers from tail to neck
            left.append(shaft[index] + normal * halfWidth)
            right.append(shaft[index] - normal * halfWidth)
        }

        let path = CGMutablePath()
        path.addLines(between: left)
        path.addLine(to: neck + headNormal * headHalfWidth)
        path.addLine(to: tip)
        path.addLine(to: neck - headNormal * headHalfWidth)
        for point in right.reversed() { path.addLine(to: point) }
        path.closeSubpath()

        context.setFillColor(annotation.style.color.cgColor)
        context.setStrokeColor(annotation.style.color.cgColor)
        context.setLineWidth(max(size * 0.3, 1))
        context.setLineJoin(.round)
        context.addPath(path)
        context.drawPath(using: .fillStroke)
    }

    private func drawLine(_ annotation: Annotation, in context: CGContext) {
        let path = CGMutablePath()
        path.move(to: annotation.start)
        if let control = annotation.control {
            path.addQuadCurve(to: annotation.end, control: control * 2 - (annotation.start + annotation.end) * 0.5)
        } else {
            path.addLine(to: annotation.end)
        }
        context.setStrokeColor(annotation.style.color.cgColor)
        context.setLineWidth(annotation.style.size)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func drawShape(_ annotation: Annotation, in context: CGContext) {
        let rect = annotation.rect
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let style = annotation.style
        let path: CGPath
        if annotation.tool == .ellipse {
            path = CGPath(ellipseIn: rect, transform: nil)
        } else {
            let radius = min(style.size * 1.1 + 2, min(rect.width, rect.height) / 2)
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        if style.fill != .none {
            context.saveGState()
            if style.fill == .tint { context.setShadow(offset: .zero, blur: 0, color: nil) }
            context.setFillColor(style.fill == .solid ? style.color.cgColor : style.color.withAlpha(0.22))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(style.size)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func drawStroke(_ annotation: Annotation, in context: CGContext) {
        let points = annotation.points
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
        } else if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            // Curves through the midpoints, which smooths out hand jitter.
            for index in 1..<points.count - 1 {
                path.addQuadCurve(to: (points[index] + points[index + 1]) * 0.5, control: points[index])
            }
            path.addLine(to: points[points.count - 1])
        }

        if annotation.tool == .highlighter {
            context.setBlendMode(.multiply)
            context.setStrokeColor(annotation.style.color.withAlpha(0.55))
        } else {
            context.setStrokeColor(annotation.style.color.cgColor)
        }
        context.setLineWidth(annotation.style.size)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func drawNumber(_ annotation: Annotation, in context: CGContext) {
        let radius = annotation.style.size
        let circle = CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(annotation.style.color.cgColor)
        context.fillEllipse(in: circle)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(annotation.style.color.contrast.withAlpha(0.9))
        context.setLineWidth(max(radius * 0.12, 1))
        context.strokeEllipse(in: circle.insetBy(dx: radius * 0.1, dy: radius * 0.1))

        let label = NSAttributedString(string: "\(annotation.number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: radius * 1.05, weight: .bold),
            .foregroundColor: annotation.style.color.contrast.nsColor,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: annotation.start.x - size.width / 2, y: annotation.start.y - size.height / 2))
    }

    /// `glyphs` is false while the text is being typed: the live text field
    /// shows the letters, and this draws only the background behind it.
    private func drawText(_ annotation: Annotation, in context: CGContext, glyphs: Bool) {
        guard !annotation.text.isEmpty || !glyphs else { return }
        let style = annotation.style
        let rect = annotation.textRect
        let textColor = style.textColor

        switch style.textStyle {
        case .pill, .card:
            let padding = annotation.textPadding
            let box = rect.insetBy(dx: -padding.width, dy: -padding.height)
            let radius = min(style.size * 0.45, box.height / 2)
            context.setFillColor((style.textStyle == .pill ? style.color : style.color.contrast).cgColor)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
        case .outline:
            guard glyphs else { return }
            let outline = NSAttributedString(string: annotation.text, attributes: [
                .font: annotation.font,
                .strokeColor: style.color.contrast.nsColor,
                .strokeWidth: 13,
                .foregroundColor: style.color.contrast.nsColor,
            ])
            outline.draw(with: rect, options: [.usesLineFragmentOrigin])
            context.setShadow(offset: .zero, blur: 0, color: nil)
        case .shadow:
            // A crisp offset copy underneath, rather than the soft all-round glow.
            guard glyphs else { return }
            context.setShadow(offset: .zero, blur: 0, color: nil)
            let offset = max(style.size * 0.07, 1)
            let under = NSAttributedString(string: annotation.text, attributes: [
                .font: annotation.font, .foregroundColor: NSColor(white: 0, alpha: 0.6),
            ])
            under.draw(with: rect.offsetBy(dx: offset * 0.6, dy: offset), options: [.usesLineFragmentOrigin])
        case .plain:
            break
        }

        guard glyphs else { return }
        let string = NSAttributedString(string: annotation.text, attributes: [
            .font: annotation.font, .foregroundColor: textColor.nsColor,
        ])
        string.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    // MARK: Picture effects

    private func drawSpotlight(_ spotlights: [Annotation], in context: CGContext, canvas: CGRect) {
        let holes = spotlights.map(\.rect).filter { $0.width > 1 && $0.height > 1 }
        guard !holes.isEmpty else { return }
        context.saveGState()
        // Clip away each lit area in turn, then dim whatever remains.
        for hole in holes {
            let clip = CGMutablePath()
            clip.addRect(canvas.insetBy(dx: -1, dy: -1))
            clip.addPath(CGPath(roundedRect: hole, cornerWidth: min(6, hole.width / 2), cornerHeight: min(6, hole.height / 2), transform: nil))
            context.addPath(clip)
            context.clip(using: .evenOdd)
        }
        context.setFillColor(CGColor(gray: 0, alpha: 0.58))
        context.fill(canvas)
        context.restoreGState()
    }

    private func drawPixelated(_ annotation: Annotation, in context: CGContext) {
        let full = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let rect = annotation.rect.intersection(full)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return }

        let mosaic: CGImage
        if let cached = pixelated[annotation.id], cached.rect == rect {
            mosaic = cached.image
        } else {
            guard let made = makeMosaic(of: rect) else { return }
            pixelated[annotation.id] = (rect, made)
            mosaic = made
        }

        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(mosaic, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Shrinks the region to one pixel per block; drawn back enlarged without
    /// smoothing, that gives a mosaic that cannot be sharpened back.
    private func makeMosaic(of rect: CGRect) -> CGImage? {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let source = image.cropping(to: pixels) else { return nil }
        let block: CGFloat = 9
        let width = max(Int((rect.width / block).rounded(.up)), 1)
        let height = max(Int((rect.height / block).rounded(.up)), 1)
        guard let small = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        small.interpolationQuality = .medium
        small.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return small.makeImage()
    }
}

// MARK: - Per-tool style memory

/// Remembers the last color, size, fill, and text style used with each tool.
enum StyleStore {
    private static let key = "toolStyles"
    private static var cache: [String: ToolStyle] = {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: ToolStyle].self, from: data)
        else { return [:] }
        return decoded
    }()

    static func style(for tool: Tool) -> ToolStyle {
        cache[tool.rawValue] ?? .standard(for: tool)
    }

    static func set(_ style: ToolStyle, for tool: Tool) {
        cache[tool.rawValue] = style
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
