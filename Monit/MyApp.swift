import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let metrics = MetricsStore()

    private var allowsTermination = false
    private var statusItem: NSStatusItem?
    private var monitorPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var panelVisibilityTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateExistingInstances()
        NSApplication.shared.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMonitorPanel()
        installOutsideClickMonitors()
        metrics.startMonitoring()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        allowsTermination ? .terminateNow : .terminateCancel
    }

    func terminateFromMenu() {
        allowsTermination = true
        NSApplication.shared.terminate(nil)
    }

    private func terminateExistingInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where application.processIdentifier != currentProcessIdentifier {
            application.forceTerminate()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let button = item.button
        button?.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: "Takt"
        )
        button?.target = self
        button?.action = #selector(toggleMonitorPanel)
        // Toggle after AppKit has finished dispatching the click. Changing panel
        // visibility during mouse-down can re-enter window layout on macOS 27.
        button?.sendAction(on: [.leftMouseUp])
        statusItem = item
    }

    private func configureMonitorPanel() {
        let rootView = MenuBarView(
            openSettings: { [weak self] in
                self?.openSettings()
            },
            quit: { [weak self] in
                self?.terminateFromMenu()
            }
        )
        .environment(settings)
        .environment(metrics)

        let hostingView = NSHostingView(rootView: rootView)

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        monitorPanel = panel
    }

    private func installOutsideClickMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else {
            return
        }

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            let clickLocation = event.locationInWindow
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseDown(at: clickLocation)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let self, let panel = self.monitorPanel, panel.isVisible else {
                return event
            }

            let statusWindow = self.statusItem?.button?.window
            if event.window !== panel, event.window !== statusWindow {
                self.hideMonitorPanel()
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelVisibilityTask?.cancel()
        metrics.pauseMonitoring()
        removeOutsideClickMonitors()
    }

    private func removeOutsideClickMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func hideMonitorPanel() {
        guard let panel = monitorPanel, panel.isVisible else {
            return
        }

        panelVisibilityTask?.cancel()
        panelVisibilityTask = Task { @MainActor [weak self, weak panel] in
            // Do not order out an NSHostingView while AppKit is still dispatching
            // the click that requested the close. On macOS 27 this can re-enter
            // the Liquid Glass layout pass and crash inside NSWindow/AppKit.
            await Task.yield()
            guard !Task.isCancelled, let panel else {
                return
            }

            panel.orderOut(nil)
            self?.metrics.pauseMonitoring()
            self?.panelVisibilityTask = nil
        }
    }

    private func handleGlobalMouseDown(at clickLocation: NSPoint) {
        guard monitorPanel?.isVisible == true else {
            return
        }

        guard !statusItemScreenFrame.contains(clickLocation) else {
            return
        }

        hideMonitorPanel()
    }

    private var statusItemScreenFrame: NSRect {
        guard
            let button = statusItem?.button,
            let buttonWindow = button.window
        else {
            return .zero
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        return buttonWindow.convertToScreen(buttonRect)
    }

    @objc
    private func toggleMonitorPanel() {
        guard let panel = monitorPanel else {
            return
        }

        if panel.isVisible {
            hideMonitorPanel()
        } else {
            panelVisibilityTask?.cancel()
            panelVisibilityTask = nil
            metrics.resumeMonitoring()
            positionPanel(panel)
            panel.orderFrontRegardless()
        }
    }

    private func positionPanel(_ panel: NSPanel) {
        guard
            let button = statusItem?.button,
            let buttonWindow = button.window
        else {
            return
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        let statusRect = buttonWindow.convertToScreen(buttonRect)
        let panelSize = panel.frame.size
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        let preferredX = statusRect.midX - panelSize.width / 2
        let x = min(max(preferredX, screenFrame.minX), screenFrame.maxX - panelSize.width)
        let y = statusRect.minY - panelSize.height + MenuBarView.transparentMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func openSettings() {
        hideMonitorPanel()

        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            let hostingView = NSHostingView(
                rootView: ContentView()
                    .environment(settings)
                    .environment(metrics)
                    .frame(width: 460, height: 240)
            )
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Settings"
            newWindow.contentView = hostingView
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            settingsWindow = newWindow
            window = newWindow
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            ContentView()
                .environment(appDelegate.settings)
                .environment(appDelegate.metrics)
                .frame(width: 460, height: 240)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
            }
        }
    }
}
