import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let flag = CommandLine.arguments.firstIndex(of: "--render-test"), CommandLine.arguments.count > flag + 1 {
        RenderTest.run(output: CommandLine.arguments[flag + 1])
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `delegate` stays alive because run() never returns.
    app.run()
}
