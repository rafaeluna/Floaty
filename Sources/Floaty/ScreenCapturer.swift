import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Could not find the display to capture."
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

struct CapturedImage {
    let image: CGImage
    /// Pixels per point of the display it was captured from.
    let scale: CGFloat
}

@MainActor
final class ScreenCapturer {
    private var contentTask: Task<SCShareableContent, Error>?

    /// Starts listing shareable content early (it takes a few tens of ms) so the
    /// capture on mouse-up is instant.
    func prefetch() {
        contentTask = Task {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Captures `rect` (points, origin at the top-left of `screen`), leaving out
    /// the windows whose numbers are given.
    func capture(rect: CGRect, on screen: NSScreen, excludingWindowNumbers: [Int]) async throws -> CapturedImage {
        let task = contentTask ?? Task {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        contentTask = nil
        let content = try await task.value

        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw CaptureError.displayNotFound }

        let excluded = content.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }
        if excluded.count < excludingWindowNumbers.count {
            // The listing predates our overlay windows, so they cannot be filtered
            // out. They are already ordered out; give the window server a moment.
            try? await Task.sleep(for: .milliseconds(40))
        }

        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = CGFloat(filter.pointPixelScale)

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, scale: scale)
    }
}
