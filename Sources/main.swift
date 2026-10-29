import AppKit

if CommandLine.arguments.contains("--self-test") {
    runGateTests()
    runSceneOcclusionTests()
    runLocalizationTests()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
