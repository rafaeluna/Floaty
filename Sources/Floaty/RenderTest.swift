import AppKit

/// Developer check: `Floaty --render-test out.png` draws one of every
/// annotation onto a generated image, through the same path Copy uses.
@MainActor
enum RenderTest {
    static func run(output: String) {
        let scale: CGFloat = 2
        let size = CGSize(width: 640, height: 400)
        let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphics
        for row in 0..<14 {
            let line = "Row \(row): the quick brown fox jumps over the lazy dog 0123456789" as NSString
            line.draw(at: CGPoint(x: 20, y: 370 - CGFloat(row) * 26), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black,
            ])
        }
        let image = context.makeImage()!

        func make(_ tool: Tool, _ start: CGPoint, _ end: CGPoint, _ change: (inout Annotation) -> Void = { _ in }) -> Annotation {
            var annotation = Annotation(tool: tool, style: .standard(for: tool))
            annotation.start = start
            annotation.end = end
            change(&annotation)
            return annotation
        }
        let annotations: [Annotation] = [
            make(.spotlight, CGPoint(x: 330, y: 20), CGPoint(x: 620, y: 380)),
            make(.blur, CGPoint(x: 350, y: 40), CGPoint(x: 600, y: 100)),
            make(.arrow, CGPoint(x: 40, y: 60), CGPoint(x: 240, y: 110)),
            make(.arrow, CGPoint(x: 40, y: 150), CGPoint(x: 240, y: 150)) { $0.control = CGPoint(x: 140, y: 110); $0.style.color = RGBA.palette[4]; $0.style.size = 9 },
            make(.line, CGPoint(x: 40, y: 200), CGPoint(x: 240, y: 200)) { $0.control = CGPoint(x: 140, y: 230); $0.style.color = RGBA.palette[3] },
            make(.rect, CGPoint(x: 360, y: 130), CGPoint(x: 470, y: 200)),
            make(.rect, CGPoint(x: 490, y: 130), CGPoint(x: 600, y: 200)) { $0.style.fill = .tint; $0.style.color = RGBA.palette[4] },
            make(.ellipse, CGPoint(x: 360, y: 220), CGPoint(x: 470, y: 290)) { $0.style.color = RGBA.palette[5] },
            make(.ellipse, CGPoint(x: 490, y: 220), CGPoint(x: 600, y: 290)) { $0.style.fill = .solid; $0.style.color = RGBA.palette[1] },
            make(.highlighter, .zero, .zero) { $0.points = [CGPoint(x: 20, y: 250), CGPoint(x: 300, y: 250)] },
            make(.pen, .zero, .zero) { $0.points = (0...40).map { CGPoint(x: 40 + CGFloat($0) * 5, y: 290 + sin(CGFloat($0) / 3) * 12) } },
            make(.number, CGPoint(x: 60, y: 340), .zero) { $0.number = 1 },
            make(.number, CGPoint(x: 100, y: 340), .zero) { $0.number = 2; $0.style.color = RGBA.palette[7] },
            make(.text, CGPoint(x: 140, y: 325), .zero) { $0.text = "Pill text" },
            make(.text, CGPoint(x: 260, y: 325), .zero) { $0.text = "Outline"; $0.style.textStyle = .outline },
            make(.text, CGPoint(x: 370, y: 320), .zero) { $0.text = "Plain\ntwo lines"; $0.style.textStyle = .plain; $0.style.color = RGBA.palette[2] },
        ]

        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let float = FloatController(image: image, scale: scale, frame: frame, fileURL: nil)
        float.annotations = annotations
        float.applyCrop(CGRect(x: 10, y: 10, width: 620, height: 380))
        let data = ImageExport.pngData(float.renderedImage(), scale: scale)!
        try! data.write(to: URL(fileURLWithPath: output))
    }
}
