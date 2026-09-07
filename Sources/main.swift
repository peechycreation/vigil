import AppKit
import Combine
import SwiftUI

// Vigil — utilitaire natif Peechy (arm64 + x86_64) qui empêche le Mac
// de se mettre en veille. Barre de menus uniquement : l'icône ouvre un
// panneau (interrupteur, minuteur, options).

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = PowerController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

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
        popover.behavior = .transient
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
        controller.shutdown()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            controller.refreshLoginStatus()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
