import AppKit
import Combine
import SwiftUI

// Vigil — utilitaire natif Peechy (arm64 + x86_64) qui empêche le Mac
// de se mettre en veille. Barre de menus uniquement : l'icône ouvre un
// panneau (interrupteur, minuteur, options).

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let escapeKeyCode: UInt16 = 53

    private let controller = PowerController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let path = Bundle.main.path(forResource: "MenuIcon", ofType: "png"),
           let icon = NSImage(contentsOfFile: path) {
            icon.isTemplate = true
            icon.size = NSSize(width: 20, height: 20)
            item.button?.image = icon
        } else {
            item.button?.title = "V"
        }
        item.button?.toolTip = "Vigil"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        let hosting = NSHostingController(rootView: PopoverView(controller: controller))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        // Surtout pas « transient » : macOS fermerait lui-même le panneau au
        // clic sur l'icône, et l'action du bouton, exécutée juste après, le
        // rouvrirait aussitôt : l'icône ne refermerait jamais rien.
        popover.behavior = .applicationDefined
        popover.animates = false

        // L'icône reflète l'état : pleine quand la veille est bloquée.
        controller.$isAwake
            .receive(on: RunLoop.main)
            .sink { [weak self] awake in
                self?.statusItem?.button?.appearsDisabled = !awake
            }
            .store(in: &cancellables)

        controller.handleLaunch(arguments: CommandLine.arguments)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDismissMonitors()
        controller.shutdown()
    }

    // MARK: - Panneau

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        controller.refreshLoginStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        startDismissMonitors()
    }

    private func closePopover() {
        stopDismissMonitors()
        popover.performClose(nil)
    }

    /// Le mode « applicationDefined » laisse la fermeture à notre charge :
    /// clic dans une autre app (les moniteurs globaux ignorent nos propres
    /// clics, donc ni l'icône ni le panneau ne déclenchent ceci) ou touche Échap.
    private func startDismissMonitors() {
        stopDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == AppDelegate.escapeKeyCode else { return event }
            self?.closePopover()
            return nil
        }
    }

    private func stopDismissMonitors() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
