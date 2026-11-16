import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlay = SelectionOverlayController()
    private let capturer = ScreenCapturer()
    private var floats: [FloatController] = []
    private var floatsHidden = false

    private var statusItem: NSStatusItem?
    private var regionHotKey: HotKey?
    private var hideHotKey: HotKey?
    private var hideMenuItem: NSMenuItem?

    private let shutter: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CursorControl.allowCursorChangesInBackground()
        setUpStatusItem()

        // Floaty is never the active app, so trackpad pinches go to whichever app
        // is. With Accessibility permission we intercept them over a float.
        PinchTap.shared.handler = { [weak self] magnification in
            guard let float = self?.floatUnderPointer() else { return false }
            float.scale(by: 1 + magnification)
            return true
        }
        PinchTap.shared.start()

        regionHotKey = HotKey(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.startRegionCapture()
        }
        hideHotKey = HotKey(keyCode: kVK_ANSI_H, modifiers: cmdKey | shiftKey | optionKey) { [weak self] in
            self?.toggleFloatsHidden()
        }
        if regionHotKey == nil {
            NSLog("Floaty: could not register the Cmd+Shift+2 shortcut (already in use?)")
        }

        overlay.onComplete = { [weak self] rect, screen in
            self?.finishRegionCapture(rect: rect, screen: screen)
        }

        HistoryStore.shared.prune()

        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.floats.forEach { $0.settingsDidChange() } }
        }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Floaty")

        let menu = NSMenu()
        let capture = menu.addItem(withTitle: "Capture Region", action: #selector(captureRegionFromMenu), keyEquivalent: "2")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self

        let hide = menu.addItem(withTitle: "Hide All Floats", action: #selector(toggleFloatsHiddenFromMenu), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command, .shift, .option]
        hide.target = self
        hideMenuItem = hide

        menu.addItem(withTitle: "Close All Floats", action: #selector(closeAllFloats), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Floaty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    @objc private func captureRegionFromMenu() {
        // Let the menu finish closing so it is not in the shot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startRegionCapture() }
    }

    @objc private func toggleFloatsHiddenFromMenu() { toggleFloatsHidden() }

    @objc private func closeAllFloats() {
        floats.forEach { $0.close() }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openFolder() {
        let folder = HistoryStore.shared.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Capture

    private func startRegionCapture() {
        guard !overlay.isActive else { return }
        guard CGPreflightScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }
        overlay.begin()
        capturer.prefetch()
    }

    private func finishRegionCapture(rect: CGRect, screen: NSScreen) {
        let overlayWindows = overlay.windowNumbers
        overlay.end()
        CATransaction.flush()

        Task {
            do {
                let captured = try await capturer.capture(
                    rect: rect, on: screen, excludingWindowNumbers: overlayWindows
                )
                present(captured, rect: rect, screen: screen)
            } catch {
                showError(error)
            }
        }
    }

    private func present(_ captured: CapturedImage, rect: CGRect, screen: NSScreen) {
        if Settings.shutterSound {
            shutter?.stop()
            shutter?.play()
        }

        let url = HistoryStore.shared.save(captured.image, scale: captured.scale)

        // The selection is top-left based; AppKit screen coordinates are bottom-left.
        let frame = NSRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width, height: rect.height
        )
        let float = FloatController(image: captured.image, scale: captured.scale, frame: frame, fileURL: url)
        float.onClose = { [weak self] closed in
            self?.floats.removeAll { $0 === closed }
        }
        floats.append(float)

        if floatsHidden { toggleFloatsHidden() }
        float.show(takingFocus: true, animated: true)
    }

    private func floatUnderPointer() -> FloatController? {
        let mouse = NSEvent.mouseLocation
        return floats.last { $0.isVisible && $0.frame.contains(mouse) }
    }

    private func toggleFloatsHidden() {
        floatsHidden.toggle()
        floats.forEach { $0.setHidden(floatsHidden) }
        hideMenuItem?.title = floatsHidden ? "Show All Floats" : "Hide All Floats"
    }

    // MARK: Alerts

    private func showPermissionAlert() {
        CGRequestScreenCaptureAccess()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Floaty needs Screen Recording permission"
        alert.informativeText = "Enable Floaty under Privacy & Security → Screen & System Audio Recording, then relaunch it."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Capture failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
