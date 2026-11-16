import AppKit
import ServiceManagement

/// User preferences, stored in UserDefaults.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var shutterSound: Bool {
        get { defaults.object(forKey: "shutterSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shutterSound") }
    }

    /// Days to keep captures; 0 keeps them forever.
    static var retentionDays: Int {
        get { defaults.object(forKey: "retentionDays") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "retentionDays") }
    }

    /// Corner rounding of floats on screen, in points. Copies and saved files stay rectangular.
    static var cornerRadius: CGFloat {
        get { CGFloat(defaults.double(forKey: "cornerRadius")) }
        set { defaults.set(Double(newValue), forKey: "cornerRadius"); notifyChanged() }
    }

    /// Makes a float see-through while it is being dragged, to help line it up.
    static var dimWhileMoving: Bool {
        get { defaults.bool(forKey: "dimWhileMoving") }
        set { defaults.set(newValue, forKey: "dimWhileMoving") }
    }

    /// While a float is dragged, blurs whatever shows through it.
    static var blurWhileMoving: Bool {
        get { defaults.bool(forKey: "blurWhileMoving") }
        set { defaults.set(newValue, forKey: "blurWhileMoving") }
    }

    static let didChange = Notification.Name("FloatySettingsDidChange")
    private static func notifyChanged() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Custom screenshots folder, or nil for ~/Pictures/Floaty.
    static var folderPath: String? {
        get { defaults.string(forKey: "folderPath") }
        set { defaults.set(newValue, forKey: "folderPath") }
    }
}

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: SettingsWindow?
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open Floaty at login", target: nil, action: nil)
    private let soundCheckbox = NSButton(checkboxWithTitle: "Play shutter sound on capture", target: nil, action: nil)
    private let moveDimCheckbox = NSButton(checkboxWithTitle: "Make a float see-through while dragging it", target: nil, action: nil)
    private let moveBlurCheckbox = NSButton(checkboxWithTitle: "Blur what shows through it", target: nil, action: nil)
    private let retentionPopup = NSPopUpButton()
    private let folderLabel = NSTextField(labelWithString: "")
    private let cornerPopup = NSPopUpButton()
    private let cornerChoices: [(title: String, radius: CGFloat)] = [
        ("Square", 0), ("Slightly rounded", 6), ("Rounded", 10), ("Very rounded", 16),
    ]

    private let retentionChoices: [(title: String, days: Int)] = [
        ("7 days", 7), ("30 days", 30), ("90 days", 90), ("1 year", 365), ("Forever", 0),
    ]

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)
        soundCheckbox.target = self
        soundCheckbox.action = #selector(toggleSound)
        moveDimCheckbox.target = self
        moveDimCheckbox.action = #selector(toggleMoveDim)
        moveBlurCheckbox.target = self
        moveBlurCheckbox.action = #selector(toggleMoveBlur)

        retentionPopup.addItems(withTitles: retentionChoices.map(\.title))
        retentionPopup.target = self
        retentionPopup.action = #selector(changeRetention)

        cornerPopup.addItems(withTitles: cornerChoices.map(\.title))
        cornerPopup.target = self
        cornerPopup.action = #selector(changeCorners)

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetFolder))
        let folderRow = NSStackView(views: [folderLabel, choose, reset])
        folderRow.spacing = 8

        func caption(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }

        let grid = NSGridView(views: [
            [caption("Startup:"), loginCheckbox],
            [caption("Sound:"), soundCheckbox],
            [caption("Float corners:"), cornerPopup],
            [caption("Moving:"), moveDimCheckbox],
            [NSGridCell.emptyContentView, moveBlurCheckbox],
            [caption("Keep screenshots for:"), retentionPopup],
            [caption("Save screenshots to:"), folderRow],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Floaty Settings"
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        window.contentView = content
        window.center()
        self.window = window
    }

    private func refresh() {
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        soundCheckbox.state = Settings.shutterSound ? .on : .off
        moveDimCheckbox.state = Settings.dimWhileMoving ? .on : .off
        moveBlurCheckbox.state = Settings.blurWhileMoving ? .on : .off
        moveBlurCheckbox.isEnabled = Settings.dimWhileMoving
        let index = retentionChoices.firstIndex { $0.days == Settings.retentionDays } ?? 1
        retentionPopup.selectItem(at: index)
        cornerPopup.selectItem(at: cornerChoices.firstIndex { $0.radius == Settings.cornerRadius } ?? 0)
        folderLabel.stringValue = (HistoryStore.shared.folder.path as NSString).abbreviatingWithTildeInPath
    }

    @objc private func toggleLogin() {
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Floaty: could not change login item: \(error.localizedDescription)")
        }
        refresh()
    }

    @objc private func changeCorners() {
        Settings.cornerRadius = cornerChoices[cornerPopup.indexOfSelectedItem].radius
    }

    @objc private func toggleMoveDim() {
        Settings.dimWhileMoving = moveDimCheckbox.state == .on
        refresh()
    }

    @objc private func toggleMoveBlur() {
        Settings.blurWhileMoving = moveBlurCheckbox.state == .on
    }

    @objc private func toggleSound() {
        Settings.shutterSound = soundCheckbox.state == .on
    }

    @objc private func changeRetention() {
        Settings.retentionDays = retentionChoices[retentionPopup.indexOfSelectedItem].days
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = HistoryStore.shared.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.folderPath = url.path
        refresh()
    }

    @objc private func resetFolder() {
        Settings.folderPath = nil
        refresh()
    }
}

/// Floaty has no menu bar of its own, so Cmd+W is handled here.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
