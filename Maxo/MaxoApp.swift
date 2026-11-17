import AppKit
import Combine
import SwiftUI

@main
struct MaxoApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MaxoApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class MaxoApplicationDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var panel: StatusPanel?
    private var panelUpdates: AnyCancellable?
    private var outsideClick: Any?
    private var localClick: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppMenu()
        installStatusItem()
        model.start()
        showMixer()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMixer()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hidePanel()
        model.stop()
    }

    @objc private func showMixer() {
        hidePanel()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 778, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Maxo"
            window.contentMinSize = NSSize(width: 660, height: 440)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            let mixer = NSHostingController(rootView: MixerView(model: model, compact: false))
            mixer.sizingOptions = []
            window.contentViewController = mixer
            window.setContentSize(NSSize(width: 778, height: 540))
            window.setFrameAutosaveName("Maxo Mixer")
            if !window.setFrameUsingName("Maxo Mixer") { window.center() }
            self.window = window
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Maxo")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Maxo Mixer"
        item.button?.setAccessibilityLabel("Maxo Mixer")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        let panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 364, height: MixerView.compactHeight(for: model)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = "Maxo Mixer"
        panel.setAccessibilityLabel("Maxo Mixer")
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let mixer = MixerView(model: model, compact: true, openMixer: { [weak self] in self?.showMixer() })
            .clipShape(RoundedRectangle(cornerRadius: 26))
        let host = NSHostingController(rootView: mixer)
        host.sizingOptions = []
        panel.contentViewController = host
        panel.onCancel = { [weak self] in self?.hidePanel() }
        self.panel = panel
        panelUpdates = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.position(panel)
            }
        }
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
            return
        }
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.hidePanel()
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            if let self, event.window !== panel, event.window !== self.statusItem?.button?.window {
                self.hidePanel()
            }
            return event
        }
    }

    private func position(_ panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? buttonWindow.screen
        let width: CGFloat = 364
        let height = MixerView.compactHeight(for: model)
        let inset: CGFloat = 5
        let visible = screen?.visibleFrame ?? NSRect(x: anchor.midX - width, y: 0, width: width * 2, height: anchor.minY)
        let x = min(max(anchor.midX - width / 2, visible.minX + inset), visible.maxX - width - inset)
        let top = min(anchor.minY, visible.maxY) - inset
        let frame = NSRect(x: x, y: top - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let localClick { NSEvent.removeMonitor(localClick) }
        outsideClick = nil
        localClick = nil
    }

    private func installAppMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Maxo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let mixer = appMenu.addItem(withTitle: "Open Mixer", action: #selector(showMixer), keyEquivalent: "o")
        mixer.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Maxo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Maxo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu
        main.addItem(application)

        let windowMenu = NSMenu(title: "Window")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

@MainActor
private final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
