import AppKit
import SwiftUI

/// Panneau affiché au clic sur l'icône de la barre de menus.
struct PopoverView: View {
    @ObservedObject var controller: PowerController

    private static let eyeImage: NSImage? = {
        guard let path = Bundle.main.path(forResource: "MenuIcon", ofType: "png"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        return image
    }()

    private static let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            timerGrid
            if controller.timerEndDate != nil {
                countdown
            }
            Divider()
            options
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - En-tête : icône, état, interrupteur principal

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let eye = Self.eyeImage {
                    Image(nsImage: eye)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "eye")
                        .font(.title2)
                }
            }
            .foregroundStyle(controller.isAwake ? Color.accentColor : Color.secondary)
            .frame(width: 34, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vigil")
                    .font(.headline)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Empêcher la veille", isOn: awakeBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var awakeBinding: Binding<Bool> {
        Binding(
            get: { controller.isAwake },
            set: { $0 ? controller.activateIndefinitely() : controller.deactivate() })
    }

    private var stateLabel: String {
        guard controller.isAwake else { return "Veille normale" }
        if let endDate = controller.timerEndDate {
            return "Veille bloquée jusqu'à \(Self.endTimeFormatter.string(from: endDate))"
        }
        return "Veille bloquée sans limite"
    }

    // MARK: - Minuteur : grille de durées

    private var timerGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Minuteur")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) {
                ForEach(PowerController.timerChoices) { choice in
                    timerButton(choice)
                }
            }
        }
    }

    private func timerButton(_ choice: PowerController.TimerChoice) -> some View {
        let isSelected = controller.timerDuration == choice.seconds
        return Button {
            controller.startTimer(seconds: choice.seconds)
        } label: {
            Text(choice.label)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06)))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }

    // MARK: - Compte à rebours

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = max(controller.timerEndDate?.timeIntervalSinceNow ?? 0, 0)
            let total = max(controller.timerDuration ?? 1, 1)
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: remaining, total: total)
                    .controlSize(.small)
                HStack {
                    Text(PowerController.remainingLabel(remaining))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Arrêter") { controller.stopTimer() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Mettre en veille à la fin du minuteur", isOn: $controller.sleepAtTimerEnd)
            Toggle("Lancer au démarrage", isOn: $controller.launchAtLogin)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    // MARK: - Pied

    private var footer: some View {
        HStack {
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quitter") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }
}
