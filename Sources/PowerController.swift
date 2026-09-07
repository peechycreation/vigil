import AppKit
import Combine
import IOKit.pwr_mgt
import ServiceManagement

/// Cœur de Veilleuse : assertion anti-veille, minuteur, mise en veille de fin,
/// lancement au démarrage. État publié pour l'interface SwiftUI.
final class PowerController: ObservableObject {

    struct TimerChoice: Identifiable {
        let label: String
        let seconds: TimeInterval
        var id: TimeInterval { seconds }
    }

    static let timerChoices: [TimerChoice] = [
        TimerChoice(label: "15 min", seconds: 15 * 60),
        TimerChoice(label: "30 min", seconds: 30 * 60),
        TimerChoice(label: "1 h", seconds: 3600),
        TimerChoice(label: "2 h", seconds: 2 * 3600),
        TimerChoice(label: "4 h", seconds: 4 * 3600),
        TimerChoice(label: "8 h", seconds: 8 * 3600),
    ]

    @Published private(set) var isAwake = false
    @Published private(set) var timerEndDate: Date?
    @Published private(set) var timerDuration: TimeInterval?
    @Published var sleepAtTimerEnd: Bool {
        didSet { defaults.set(sleepAtTimerEnd, forKey: Self.sleepAtTimerEndKey) }
    }
    @Published var launchAtLogin = false {
        didSet { applyLaunchAtLogin() }
    }

    private static let keepAwakeKey = "keepAwake"
    private static let sleepAtTimerEndKey = "sleepAtTimerEnd"

    private let defaults = UserDefaults.standard
    private var assertionID = IOPMAssertionID(0)
    private var sleepTimer: Timer?
    private var isSyncingLoginStatus = false

    init() {
        sleepAtTimerEnd = defaults.bool(forKey: Self.sleepAtTimerEndKey)
        refreshLoginStatus()
    }

    /// Restaure l'état mémorisé ou applique les flags CLI
    /// (« --on » : activer sans mémoriser ; « --for <minutes> » : minuteur).
    func handleLaunch(arguments: [String]) {
        if let flagIndex = arguments.firstIndex(of: "--for"), flagIndex + 1 < arguments.count,
           let minutes = Double(arguments[flagIndex + 1]), minutes > 0 {
            startTimer(seconds: minutes * 60)
        } else if arguments.contains("--on") {
            setAwake(true, persist: false)
        } else if defaults.bool(forKey: Self.keepAwakeKey) {
            setAwake(true, persist: false)
        }
    }

    func shutdown() {
        cancelTimer()
        if isAwake { releaseAssertion() }
    }

    // MARK: - Anti-veille

    func activateIndefinitely() {
        cancelTimer()
        setAwake(true, persist: true)
    }

    func deactivate() {
        cancelTimer()
        setAwake(false, persist: true)
    }

    private func setAwake(_ awake: Bool, persist: Bool) {
        if awake, !isAwake {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Vigil - anti-veille" as CFString,
                &id)
            guard result == kIOReturnSuccess else {
                NSLog("Vigil : échec de création de l'assertion (code %d)", result)
                return
            }
            assertionID = id
            isAwake = true
        } else if !awake, isAwake {
            releaseAssertion()
        }
        if persist { defaults.set(isAwake, forKey: Self.keepAwakeKey) }
    }

    private func releaseAssertion() {
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isAwake = false
    }

    // MARK: - Minuteur

    func startTimer(seconds: TimeInterval) {
        cancelTimer()
        // Le minuteur ne se mémorise pas d'un lancement à l'autre :
        // seul le mode « sans limite » persiste.
        defaults.set(false, forKey: Self.keepAwakeKey)
        setAwake(true, persist: false)
        guard isAwake else { return }
        timerDuration = seconds
        timerEndDate = Date().addingTimeInterval(seconds)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.timerDidExpire()
        }
    }

    func stopTimer() {
        cancelTimer()
        setAwake(false, persist: false)
    }

    private func timerDidExpire() {
        cancelTimer()
        setAwake(false, persist: false)
        // La mise en veille ne se déclenche qu'à l'expiration naturelle,
        // jamais sur « Arrêter » ni sur l'interrupteur principal.
        if defaults.bool(forKey: Self.sleepAtTimerEndKey) {
            sleepMac()
        }
    }

    private func cancelTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        timerEndDate = nil
        timerDuration = nil
    }

    private func sleepMac() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do {
            try process.run()
        } catch {
            NSLog("Vigil : mise en veille impossible : %@", error.localizedDescription)
        }
    }

    // MARK: - Lancement au démarrage

    func refreshLoginStatus() {
        isSyncingLoginStatus = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isSyncingLoginStatus = false
    }

    private func applyLaunchAtLogin() {
        guard !isSyncingLoginStatus else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Vigil : réglage du lancement au démarrage impossible : %@",
                  error.localizedDescription)
            refreshLoginStatus()
        }
    }

    // MARK: - Libellés

    static func remainingLabel(_ remaining: TimeInterval) -> String {
        let totalMinutes = max(Int((max(remaining, 0) / 60).rounded(.up)), 1)
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return minutes == 0
                ? "encore \(hours)\u{00A0}h"
                : "encore \(hours)\u{00A0}h \(minutes)\u{00A0}min"
        }
        return "encore \(totalMinutes)\u{00A0}min"
    }
}
