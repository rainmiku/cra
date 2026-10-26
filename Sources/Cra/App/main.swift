import AppKit
import CraCEF

MainActor.assumeIsolated {
    // Order matters: the CefAppProtocol NSApplication must exist before Chromium
    // initializes, and Chromium must be initialized before any browser is made.
    let app = CraApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // Cookies and passwords move off the old fixed key before Chromium opens them.
    let profileDir = AppPaths.chromiumCache.appendingPathComponent("Default", isDirectory: true)
    SafeStorage.prepare(profileDir: profileDir)

    // Passwords and cookies staged by the import go into the profile while no
    // Chromium has it open: before initializing, and only when no other Cra runs.
    let me = ProcessInfo.processInfo.processIdentifier
    if CredentialImport.hasPending, !SafeStorage.usesMockKey,
       !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != me }) {
        CredentialImport.applyPending(profileDir: profileDir)
    }

    let useChromeStyle = ProcessInfo.processInfo.environment["CRA_CHROME_STYLE"] == "1"
    let started = CraCEFRuntime.initialize(withCachePath: AppPaths.chromiumCache.path,
                                           userAgentProduct: "",
                                           logPath: AppPaths.log.path,
                                           useChromeStyle: useChromeStyle)
    if !started && CraCEFRuntime.anotherInstanceWasNotified() {
        // The running Cra got our command line; just activate it.
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.rainmiku.cra")
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
            .activate()
        exit(0)
    }
    if !started {
        let alert = NSAlert()
        alert.messageText = "Cra could not start Chromium"
        alert.informativeText = "Chromium Embedded Framework failed to initialize. See \(AppPaths.log.path)."
        alert.runModal()
        exit(1)
    }

    // Belt and braces: Chromium's run loop drives NSApplication and should call
    // applicationDidFinishLaunching, but bootstrapping is idempotent either way.
    DispatchQueue.main.async { delegate.bootstrapIfNeeded() }
    CraCEFRuntime.runMessageLoop()
    delegate.applicationWillShutdown()
    CraCEFRuntime.shutdown()
}
