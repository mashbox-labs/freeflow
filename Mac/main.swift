import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    #if DEBUG || FF_TESTS
    // The self-test modes run with no Dock icon and no window (they run on a Mac someone may be using).
    app.setActivationPolicy(SelfTest.mode() == nil ? .regular : .prohibited)   // a Dock icon and a normal window
    #else
    app.setActivationPolicy(.regular)   // a Dock icon and a normal window
    #endif
    app.run()
    withExtendedLifetime(delegate) {}
}
