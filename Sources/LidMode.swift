import Foundation
import IOKit.ps

/// Accès système du mode « capot fermé » : la veille au rabat ne se coupe
/// qu'avec `pmset disablesleep`, réservé à root. Une règle sudoers installée
/// une fois par l'utilisateur (voir README) autorise ces deux seules commandes.
enum LidMode {

    static let sudoersPath = "/etc/sudoers.d/vigil"
    /// Sur batterie, le mode s'arrête sous ce niveau pour ne pas vider le Mac.
    static let batteryFloorPercent = 10

    static var isAuthorized: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
    }

    static func turnDisplayOff() {
        _ = run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Niveau de batterie si le Mac tourne sur batterie, nil sur secteur.
    static func batteryPercentIfDischarging() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
