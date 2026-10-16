import AppKit
import Combine
import CoreGraphics
import IOKit.pwr_mgt
import ServiceManagement

/// Cœur de Vigil : assertion anti-veille, minuteur d'inactivité, mise en
/// veille de fin, mode capot fermé, lancement au démarrage.
/// État publié pour l'interface SwiftUI.
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

    // MARK: État publié

    @Published private(set) var isAwake = false
    /// Durée d'inactivité choisie : nil = sans limite.
    @Published private(set) var timerDuration: TimeInterval?
    /// Échéance courante. Elle recule à chaque geste de l'utilisateur tant
    /// que « repartir à zéro quand j'utilise le Mac » est actif.
    @Published private(set) var timerEndDate: Date?
    @Published var resetOnActivity: Bool {
        didSet { defaults.set(resetOnActivity, forKey: Self.resetOnActivityKey) }
    }
    @Published var sleepAtTimerEnd: Bool {
        didSet { defaults.set(sleepAtTimerEnd, forKey: Self.sleepAtTimerEndKey) }
    }
    /// Mode capot fermé : écran éteint, le Mac continue de tourner rabat baissé.
    @Published var lidClosedMode: Bool {
        didSet {
            defaults.set(lidClosedMode, forKey: Self.lidClosedModeKey)
            if isAwake { reacquire() }
        }
    }
    @Published private(set) var isLidModeActive = false
    @Published private(set) var notice: String?
    @Published var launchAtLogin = false {
        didSet { applyLaunchAtLogin() }
    }

    // MARK: Réglages internes

    private static let keepAwakeKey = "keepAwake"
    private static let resetOnActivityKey = "resetOnActivity"
    private static let sleepAtTimerEndKey = "sleepAtTimerEnd"
    private static let lidClosedModeKey = "lidClosedMode"
    /// Vrai tant que Vigil a coupé la veille système : sert à la rétablir
    /// au lancement suivant si l'app a été tuée entre-temps.
    private static let sleepDisabledKey = "sleepDisabledByVigil"
    private static let displayOffDelay: TimeInterval = 1.5
    /// Le tic compare l'heure réelle à l'échéance : un compte à rebours unique
    /// ne survit ni à un sommeil ni à un décalage d'horloge, et un minuteur
    /// raté laisserait l'anti-veille actif indéfiniment.
    private static let tickInterval: TimeInterval = 5
    /// En deçà, un geste n'est pas compté : évite de recalculer l'échéance
    /// à chaque pixel de souris.
    private static let activityDebounce: TimeInterval = 2

    private let defaults = UserDefaults.standard
    private var assertionID = IOPMAssertionID(0)
    private var tick: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastActivityDate = Date.distantPast
    private var isSyncingLoginStatus = false

    init() {
        resetOnActivity = defaults.object(forKey: Self.resetOnActivityKey) as? Bool ?? true
        sleepAtTimerEnd = defaults.bool(forKey: Self.sleepAtTimerEndKey)
        lidClosedMode = defaults.bool(forKey: Self.lidClosedModeKey)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.onTick()
            }
        refreshLoginStatus()
    }

    /// Restaure l'état mémorisé ou applique les flags CLI
    /// (« --on » : activer sans mémoriser ; « --for <minutes> » : minuteur).
    func handleLaunch(arguments: [String]) {
        restoreSleepIfLeftDisabled()
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
            guard acquire() else { return }
        } else if !awake, isAwake {
            releaseAssertion()
        }
        if persist { defaults.set(isAwake, forKey: Self.keepAwakeKey) }
    }

    /// En mode capot fermé l'écran doit pouvoir s'éteindre : on ne bloque
    /// alors que la veille du système, pas celle de l'écran.
    private func acquire() -> Bool {
        let type = lidClosedMode
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Vigil - anti-veille" as CFString,
            &id)
        guard result == kIOReturnSuccess else {
            NSLog("Vigil : échec de création de l'assertion (code %d)", result)
            notice = "macOS a refusé de bloquer la veille."
            return false
        }
        assertionID = id
        isAwake = true
        notice = nil
        if lidClosedMode { startLidMode() }
        return true
    }

    private func releaseAssertion() {
        stopLidMode()
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isAwake = false
    }

    /// Changement de mode en cours de session : même session, autre assertion.
    private func reacquire() {
        stopLidMode()
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isAwake = false
        _ = acquire()
    }

    // MARK: - Mode capot fermé

    private func startLidMode() {
        guard LidMode.isAuthorized else {
            notice = "Capot fermé : autorisation à installer une fois (voir le README). En attendant, le Mac s'endort rabat baissé."
            return
        }
        guard LidMode.setSleepDisabled(true) else {
            notice = "macOS a refusé de couper la veille. Le Mac s'endort rabat baissé."
            return
        }
        defaults.set(true, forKey: Self.sleepDisabledKey)
        isLidModeActive = true
        ensureTick()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayOffDelay) { [weak self] in
            guard self?.isLidModeActive == true else { return }
            LidMode.turnDisplayOff()
        }
    }

    private func stopLidMode() {
        isLidModeActive = false
        restoreSleepIfLeftDisabled()
    }

    private func restoreSleepIfLeftDisabled() {
        guard defaults.bool(forKey: Self.sleepDisabledKey) else { return }
        if LidMode.setSleepDisabled(false) {
            defaults.set(false, forKey: Self.sleepDisabledKey)
        } else {
            notice = "Veille non rétablie. Dans le Terminal : sudo pmset -a disablesleep 0"
        }
    }

    private func stopIfBatteryLow() {
        guard isLidModeActive,
              let percent = LidMode.batteryPercentIfDischarging(),
              percent < LidMode.batteryFloorPercent else { return }
        deactivate()
        notice = "Arrêté : batterie sous \(LidMode.batteryFloorPercent)\u{00A0}%."
    }

    // MARK: - Minuteur d'inactivité

    /// Un deuxième clic sur la durée déjà en cours arrête le minuteur.
    func toggleTimer(seconds: TimeInterval) {
        if timerDuration == seconds {
            stopTimer()
        } else {
            startTimer(seconds: seconds)
        }
    }

    func startTimer(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        cancelTimer()
        // Le minuteur ne se mémorise pas d'un lancement à l'autre :
        // seul le mode « sans limite » persiste.
        defaults.set(false, forKey: Self.keepAwakeKey)
        setAwake(true, persist: false)
        guard isAwake else { return }
        timerDuration = seconds
        timerEndDate = Date().addingTimeInterval(seconds)
        lastActivityDate = Date()
        ensureTick()
    }

    func stopTimer() {
        cancelTimer()
        setAwake(false, persist: false)
    }

    private func ensureTick() {
        guard tick == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func onTick() {
        stopIfBatteryLow()
        guard let endDate = timerEndDate, let duration = timerDuration else {
            if !isLidModeActive { stopTickIfIdle() }
            return
        }
        if resetOnActivity && !isLidModeActive, let idle = Self.secondsSinceLastInput() {
            // Seul un geste postérieur au lancement (ou au dernier report)
            // repousse l'échéance : un minuteur lancé au clic démarre au clic.
            let activity = Date().addingTimeInterval(-idle)
            if activity > lastActivityDate.addingTimeInterval(Self.activityDebounce) {
                lastActivityDate = activity
                timerEndDate = activity.addingTimeInterval(duration)
                return
            }
        }
        if Date() >= endDate { timerDidExpire() }
    }

    private func stopTickIfIdle() {
        tick?.invalidate()
        tick = nil
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
        timerEndDate = nil
        timerDuration = nil
        if !isLidModeActive { stopTickIfIdle() }
    }

    /// Secondes depuis le dernier clavier ou souris, toutes apps confondues.
    /// Ne demande aucune permission : macOS expose ce compteur publiquement.
    private static func secondsSinceLastInput() -> TimeInterval? {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return seconds.isFinite ? seconds : nil
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

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes % 60 == 0 { return "\(minutes / 60)\u{00A0}h" }
        if minutes > 60 { return "\(minutes / 60)\u{00A0}h \(minutes % 60)" }
        return "\(minutes)\u{00A0}min"
    }
}
