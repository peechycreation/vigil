import AppKit
import SwiftUI

/// Panneau affiché au clic sur l'icône de la barre de menus.
///
/// Mouvement : chaque changement d'état se voit bouger, rien ne bouge au
/// repos. Les ressorts sont ceux d'Apple (`.snappy`, `.smooth`) ; les curseurs
/// d'accessibilité « réduire les animations » coupent tout déplacement et ne
/// gardent que les fondus.
struct PopoverView: View {
    @ObservedObject var controller: PowerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customMinutes = ""
    @State private var eyeBlink = false
    @FocusState private var customFieldFocused: Bool

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

    /// Ressort court pour les bascules d'état ; fondu seul en mouvement réduit.
    private var stateAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .snappy(duration: 0.28, extraBounce: 0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusCard
                .padding(.bottom, 14)
            timerSection
            if controller.timerEndDate != nil {
                countdownBar
                    .padding(.top, 10)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            Divider().padding(.vertical, 12)
            options
            Divider().padding(.vertical, 12)
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(panelBackground)
        .animation(stateAnimation, value: controller.isAwake)
        .animation(stateAnimation, value: controller.timerDuration)
        .animation(stateAnimation, value: controller.isLidModeActive)
        .onChange(of: controller.isAwake) { _ in blinkEye() }
    }

    /// macOS 26 : Liquid Glass. Avant : matériau translucide classique.
    @ViewBuilder private var panelBackground: some View {
        if #available(macOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    // MARK: - Carte d'état : la seule chose à lire d'un coup d'œil

    private var statusCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(alignment: .center, spacing: 12) {
                eyeGlyph
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateTitle)
                        .font(.headline)
                        .contentTransition(.numericText(countsDown: true))
                        .id("title")
                    Text(stateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
                Toggle("Empêcher la veille", isOn: awakeBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(12)
            .modifier(GlassCard(isActive: controller.isAwake))
            .animation(stateAnimation, value: stateTitle)
        }
    }

    /// Un battement à chaque bascule, puis l'œil reste immobile.
    private var eyeGlyph: some View {
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
        .frame(width: 34, height: 24)
        .scaleEffect(y: eyeBlink && !reduceMotion ? 0.15 : 1, anchor: .center)
        .shadow(color: controller.isAwake ? Color.accentColor.opacity(0.45) : .clear, radius: 8)
    }

    private func blinkEye() {
        guard !reduceMotion else { return }
        withAnimation(.easeIn(duration: 0.07)) { eyeBlink = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            withAnimation(.snappy(duration: 0.22, extraBounce: 0.1)) { eyeBlink = false }
        }
    }

    private var awakeBinding: Binding<Bool> {
        Binding(
            get: { controller.isAwake },
            set: { $0 ? controller.activateIndefinitely() : controller.deactivate() })
    }

    private var stateTitle: String {
        guard controller.isAwake else { return "Veille normale" }
        if controller.isLidModeActive { return "Éveillé, capot fermé possible" }
        if let endDate = controller.timerEndDate {
            return PowerController.remainingLabel(endDate.timeIntervalSinceNow).capitalizedFirst
        }
        return "Éveillé sans limite"
    }

    private var stateDetail: String {
        if let notice = controller.notice { return notice }
        guard controller.isAwake else { return "Le Mac se met en veille comme d'habitude." }
        if let endDate = controller.timerEndDate {
            let end = Self.endTimeFormatter.string(from: endDate)
            let suffix = controller.sleepAtTimerEnd ? "puis veille" : "puis retour à la normale"
            let activity = controller.resetOnActivity && !controller.isLidModeActive
                ? ", repoussé tant que tu utilises le Mac" : ""
            return "Jusqu'à \(end)\(activity), \(suffix)."
        }
        if controller.isLidModeActive {
            return "Écran éteint. Arrêt sous \(LidMode.batteryFloorPercent)\u{00A0}% de batterie."
        }
        return "Jusqu'à ce que tu l'arrêtes."
    }

    // MARK: - Minuteur

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Éveillé pendant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if controller.timerDuration != nil {
                    Button("Arrêter") { controller.stopTimer() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                }
            }
            glassGroup {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(PowerController.timerChoices) { choice in
                        timerButton(label: choice.label, seconds: choice.seconds)
                    }
                }
            }
            customDuration
        }
    }

    private func timerButton(label: String, seconds: TimeInterval) -> some View {
        let isSelected = controller.timerDuration == seconds
        return Button {
            controller.toggleTimer(seconds: seconds)
        } label: {
            Text(label)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .modifier(GlassChip(isSelected: isSelected))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressableChip())
        .help(isSelected ? "Cliquer à nouveau arrête le minuteur" : "Rester éveillé \(label)")
    }

    private var customDuration: some View {
        let isCustomActive = controller.timerDuration.map { duration in
            !PowerController.timerChoices.contains { $0.seconds == duration }
        } ?? false
        return HStack(spacing: 6) {
            TextField("Autre durée", text: $customMinutes)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($customFieldFocused)
                .onSubmit(startCustom)
            Text("min")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Lancer", action: startCustom)
                .controlSize(.small)
                .disabled(Int(customMinutes).map { $0 <= 0 } ?? true)
            if isCustomActive, let duration = controller.timerDuration {
                Text(PowerController.durationLabel(duration))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
            }
        }
    }

    private func startCustom() {
        guard let minutes = Int(customMinutes), minutes > 0 else { return }
        controller.startTimer(seconds: TimeInterval(minutes * 60))
        customFieldFocused = false
    }

    // MARK: - Compte à rebours : barre qui se vide, teintée

    private var countdownBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = max(controller.timerEndDate?.timeIntervalSinceNow ?? 0, 0)
            let total = max(controller.timerDuration ?? 1, 1)
            let fraction = min(max(remaining / total, 0), 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * fraction, 6))
                        .animation(.linear(duration: 1), value: fraction)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Repartir à zéro quand j'utilise le Mac", isOn: $controller.resetOnActivity)
            Toggle("Mettre en veille à la fin du minuteur", isOn: $controller.sleepAtTimerEnd)
            Toggle("Continuer capot fermé, écran éteint", isOn: $controller.lidClosedMode)
            if controller.lidClosedMode && !LidMode.isAuthorized {
                Text("Autorisation à installer une fois (voir le README).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .transition(.opacity)
            }
            Toggle("Lancer au démarrage", isOn: $controller.launchAtLogin)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .animation(stateAnimation, value: controller.lidClosedMode)
    }

    // MARK: - Pied

    private var footer: some View {
        HStack {
            Text("Vigil \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quitter") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Les pastilles voisines fusionnent leur verre quand macOS le permet.
    @ViewBuilder private func glassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { content() }
        } else {
            content()
        }
    }
}

/// Retour de pression : la pastille s'enfonce légèrement, 120 ms, et revient.
private struct PressableChip: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Carte d'état : verre teinté quand l'anti-veille est actif.
private struct GlassCard: ViewModifier {
    let isActive: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                isActive ? .regular.tint(.accentColor.opacity(0.35)) : .regular,
                in: .rect(cornerRadius: 12))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isActive ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
        }
    }
}

/// Bouton de durée : pastille de verre, pleine couleur quand sélectionnée.
private struct GlassChip: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .glassEffect(
                    isSelected ? .regular.tint(.accentColor) : .regular,
                    in: .rect(cornerRadius: 8))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
