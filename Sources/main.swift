import AppKit
import Combine
import os
import SwiftUI

// Vigil — utilitaire natif Peechy (arm64 + x86_64) qui empêche le Mac
// de se mettre en veille. Barre de menus uniquement : l'icône ouvre un
// panneau (interrupteur, minuteur, options).

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private static let escapeKeyCode: UInt16 = 53
    /// Un clic qui vient de fermer le panneau ne doit pas le rouvrir.
    private static let reopenGuard: TimeInterval = 0.3
    /// Diagnostic du panneau, niveau debug (non conservé par défaut). Lecture :
    /// /usr/bin/log stream --level debug --predicate 'subsystem == "fr.peechy.vigil"'
    private static let logger = Logger(subsystem: "fr.peechy.vigil", category: "panneau")

    private let controller = PowerController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?
    private var lastCloseDate: Date?

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
        popover.delegate = self

        // L'icône reflète l'état : pleine quand la veille est bloquée.
        controller.$isAwake
            .receive(on: RunLoop.main)
            .sink { [weak self] awake in
                self?.statusItem?.button?.appearsDisabled = !awake
            }
            .store(in: &cancellables)

        controller.handleLaunch(arguments: CommandLine.arguments)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        log("démarrage v\(version)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDismissMonitors()
        controller.shutdown()
    }

    // MARK: - Panneau

    @objc private func togglePopover() {
        if popover.isShown {
            log("clic icône : panneau ouvert, fermeture")
            closePopover()
            return
        }
        // Selon l'ordre des événements, le panneau peut déjà avoir été fermé
        // par le mouse-down de ce même clic : ne pas le rouvrir dans la foulée.
        if let last = lastCloseDate, Date().timeIntervalSince(last) < Self.reopenGuard {
            log("clic icône : fermeture déjà provoquée par ce clic, on ne rouvre pas")
            lastCloseDate = nil
            return
        }
        log("clic icône : ouverture")
        showPopover()
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

    func popoverDidClose(_ notification: Notification) {
        lastCloseDate = Date()
        stopDismissMonitors()
        log("panneau fermé")
    }

    /// Le mode « applicationDefined » laisse la fermeture à notre charge :
    /// clic dans une autre app ou touche Échap. Un clic sur l'icône elle-même
    /// est ignoré ici, c'est l'action du bouton qui fait la bascule.
    private func startDismissMonitors() {
        stopDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                guard let self else { return }
                if self.isPointerOverStatusButton {
                    self.log("clic global sur l'icône : ignoré par le moniteur")
                    return
                }
                self.log("clic global hors panneau : fermeture")
                self.closePopover()
            }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == AppDelegate.escapeKeyCode else { return event }
            self?.log("Échap : fermeture")
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

    private var isPointerOverStatusButton: Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow).contains(NSEvent.mouseLocation)
    }

    private func log(_ message: String) {
        Self.logger.debug("\(message, privacy: .public)")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
