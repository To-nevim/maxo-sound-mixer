import SwiftUI

private let accent = Color.accentColor
private let primaryLabel = Color(nsColor: .labelColor)
private let card = primaryLabel.opacity(0.045)
private let inset = primaryLabel.opacity(0.035)
private let outline = primaryLabel.opacity(0.07)
private let secondaryLabel = Color(nsColor: .secondaryLabelColor)

struct MixerView: View {
    @ObservedObject var model: MixerModel
    let compact: Bool
    var openMixer: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.17) }

    var body: some View {
        Group {
            if compact {
                layout.frame(width: 364, height: Self.compactHeight(for: model))
            } else {
                layout.frame(minWidth: 660, idealWidth: 778, maxWidth: .infinity,
                             minHeight: 440, idealHeight: 540, maxHeight: .infinity)
            }
        }
        .modifier(MixerSurface(compact: compact))
        .foregroundStyle(primaryLabel)
        .tint(accent)
        .animation(motion, value: model.sources.map(\.id))
    }

    private var layout: some View {
        VStack(spacing: 0) {
            header
            if model.sources.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: compact ? 5 : 11) {
                        ForEach(model.sources) { source in
                            MixerRow(source: source, model: model, compact: compact)
                                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))
                        }
                    }
                    .padding(.horizontal, compact ? 10 : 27)
                    .padding(.vertical, 4)
                }
                .padding(.bottom, compact ? 7 : 19)
            }
            footer
        }
    }

    static func compactHeight(for model: MixerModel) -> CGFloat {
        let sources = model.sources
        let needsStatus = sources.filter {
            let output = model.preferences(for: $0.id).preferredOutput
            return $0.state == .bypassed || (output != nil && !model.snapshot.devices.contains { $0.id == output })
        }.count
        let feedback: CGFloat = model.balanceStatus.message == nil ? 0 : 23
        return min(465, max(245, 145 + CGFloat(sources.count) * 79 + CGFloat(needsStatus) * 17 + feedback))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 23) {
            HStack(spacing: compact ? 9 : 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: compact ? 15 : 23, weight: .semibold))
                    .foregroundStyle(primaryLabel)
                    .frame(width: compact ? 25 : 49, height: compact ? 27 : 49)
                    .background(compact ? Color.clear : inset, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(compact ? "Maxo" : "Playback Mixer")
                        .font(.system(size: compact ? 17 : 29, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if !compact {
                        Text("Volume and output for each app")
                            .font(.system(size: 13))
                            .foregroundStyle(secondaryLabel)
                    }
                }
                Spacer(minLength: 7)
                if !compact, let device = model.snapshot.defaultName {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("System Default").font(.system(size: 10, weight: .medium))
                                .foregroundStyle(secondaryLabel)
                            Text(device).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(card, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(outline))
                    .accessibilityElement(children: .combine)
                }
            }
            if !model.sources.isEmpty {
                HStack {
                    Text("Apps").font(.system(size: compact ? 12 : 14, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    let playing = model.sources.filter(\.playing).count
                    Text("\(playing) playing")
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(secondaryLabel)
                }
            }
        }
        .padding(.horizontal, compact ? 19 : 28)
        .padding(.top, compact ? 17 : 27)
        .padding(.bottom, compact ? 8 : 9)
    }

    private var emptyState: some View {
        VStack(spacing: compact ? 7 : 9) {
            Image(systemName: "waveform")
                .font(.system(size: compact ? 23 : 33, weight: .medium))
                .foregroundStyle(accent)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text("No apps playing")
                .font(.system(size: compact ? 14 : 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Start playback in an app to see it here.")
                .font(.system(size: compact ? 12 : 13))
                .foregroundStyle(secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(outline))
        .padding(.horizontal, compact ? 14 : 27)
        .padding(.vertical, compact ? 9 : 16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.6).accessibilityHidden(true)
            if let message = model.balanceStatus.message {
                HStack(spacing: 7) {
                    if model.isBalancing && !reduceMotion {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, compact ? 15 : 28)
                .padding(.top, 8)
            }
            HStack(spacing: 10) {
                if compact, let openMixer {
                    Button(action: openMixer) {
                        Label("Open Mixer", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                    }
                    .modifier(MixerButtonAppearance())
                    .keyboardShortcut("o", modifiers: .command)
                    Spacer()
                    autoBalanceButton
                    mixerActions
                } else {
                    Label("Audio processed live on this Mac", systemImage: "lock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondaryLabel)
                    Spacer()
                    Text("\(model.snapshot.devices.count) available outputs")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryLabel)
                    autoBalanceButton
                    if !model.hiddenApps.isEmpty {
                        mixerActions
                    }
                }
            }
            .padding(.horizontal, compact ? 16 : 28)
            .padding(.vertical, compact ? 12 : 13)
        }
    }

    private var mixerActions: some View {
        Menu {
            if !model.hiddenApps.isEmpty {
                Menu("Restore Hidden Apps") {
                    ForEach(model.hiddenApps.keys.sorted { left, right in
                        let a = model.hiddenApps[left] ?? left
                        let b = model.hiddenApps[right] ?? right
                        return a == b ? left < right : a.localizedStandardCompare(b) == .orderedAscending
                    }, id: \.self) { id in
                        Button(model.hiddenApps[id] ?? id) { model.restore(id) }
                    }
                }
                Divider()
            }
            Button("Quit Maxo", action: { NSApp.terminate(nil) })
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 17))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Maxo actions")
    }

    private var autoBalanceButton: some View {
        Button(action: model.autoBalance) {
            Label(model.isBalancing ? "Cancel" : "Auto Balance",
                  systemImage: model.isBalancing ? "xmark" : "waveform")
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
        }
        .modifier(MixerButtonAppearance())
        .disabled(!model.isBalancing && !model.canAutoBalance)
        .accessibilityLabel(model.isBalancing ? "Cancel Auto Balance" : "Auto Balance")
        .accessibilityHint("Matches the loudness of apps with sustained playback.")
        .help("Play audio in at least two unmuted apps to balance their loudness.")
    }
}

private struct MixerSurface: ViewModifier {
    let compact: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if compact {
            if reduceTransparency {
                content.background(Color(nsColor: .windowBackgroundColor),
                                   in: RoundedRectangle(cornerRadius: 26))
            } else if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
            }
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct MixerButtonAppearance: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct MixerRow: View {
    let source: MixerSource
    @ObservedObject var model: MixerModel
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var dragPreview = MixerRowDragPreview()

    private var settings: AppSettings { model.preferences(for: source.id) }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.17) }
    private var percent: String { settings.volume.formatted(.percent.precision(.fractionLength(0))) }
    private var output: PlaybackDevice? {
        model.snapshot.devices.first { $0.id == settings.preferredOutput }
    }

    private var offline: String? {
        if settings.preferredOutput != nil && output == nil { settings.preferredName ?? "Preferred device" }
        else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            if compact {
                HStack(spacing: 6) {
                    identity.layoutPriority(1)
                    Spacer(minLength: 0)
                    waveform.frame(width: 104)
                    mute
                }
                HStack(spacing: 8) {
                    volume
                    outputMenu
                        .frame(width: 133)
                }
            } else {
                HStack(spacing: 11) {
                    identity.frame(width: 159, alignment: .leading)
                    waveform.frame(minWidth: 64, idealWidth: 94, maxWidth: 105)
                    HStack(spacing: 11) {
                        mute
                        volume
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 9).fill(inset).allowsHitTesting(false)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 9).strokeBorder(outline).allowsHitTesting(false)
                    }
                    outputMenu.frame(width: 145)
                }
            }
            if let offline {
                Label("\(offline) offline · \(model.snapshot.defaultName.map { "using \($0)" } ?? "no system output")",
                      systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if source.state == .bypassed {
                HStack(spacing: 8) {
                    Text("Mixing unavailable · normal playback")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Spacer()
                    Menu("Fix") {
                        Button("Retry") { model.retry(source.id) }
                        Button("Audio Privacy Settings", action: openPrivacy)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Fix routing for \(source.app.name)")
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 10 : 11)
        .background {
            RoundedRectangle(cornerRadius: compact ? 17 : 15)
                .fill(card)
                .overlay {
                    MixerRowDragSurface(id: source.id, preview: dragPreview, isRowBackground: true)
                        .accessibilityHidden(true)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 17 : 15)
                .strokeBorder(outline.opacity(0.65))
                .allowsHitTesting(false)
        }
        .onDrop(of: [MixerRowDragView.rowType], delegate: MixerRowDrop(target: source.id, model: model))
        .contextMenu { rowContextMenu }
        .animation(motion, value: offline)
        .animation(motion, value: source.state == .bypassed)
    }

    private var waveform: some View {
        RowWaveform(waveforms: model.waveforms, app: source.app)
            .frame(height: compact ? 27 : 32)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Toggle(isOn: Binding(get: { settings.extraLoud }, set: { _ in
            withAnimation(reduceMotion ? nil : boostSpring) { model.toggleExtraLoud(for: source.id) }
        })) {
            Label("Extra Loud", systemImage: "flame")
        }
        Divider()
        let apps = model.sources
        if let index = apps.firstIndex(where: { $0.id == source.id }), apps.count > 1 {
            if index > 0 {
                Button("Move Up") { model.move(source.id, to: apps[index - 1].id) }
            }
            if index + 1 < apps.count {
                Button("Move Down") { model.move(source.id, to: apps[index + 1].id) }
            }
            Divider()
        }
        Button("Remove from Mixer") { model.hide(source) }
    }

    private var identity: some View {
        HStack(spacing: compact ? 8 : 10) {
            AppIcon(path: source.app.iconPath, size: compact ? 27 : 39)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.app.name)
                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                    .lineLimit(1)
                    .help(source.app.name)
                if !compact {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryLabel)
                }
            }
            if compact && source.playing {
                Circle().fill(accent).frame(width: 5, height: 5)
                    .accessibilityLabel("Playing")
            }
        }
        .overlay {
            MixerRowDragSurface(id: source.id, preview: dragPreview)
                .accessibilityHidden(true)
        }
    }

    private var status: String {
        switch source.state {
        case .idle: "Idle"
        case .native, .bypassed: source.playing ? "Playing" : "Idle"
        case .starting: "Connecting…"
        case .mixing: source.playing ? "Mixing" : "Idle"
        }
    }

    private var volume: some View {
        HStack(spacing: compact ? 5 : 9) {
            VolumeSlider(id: source.id, appName: source.app.name, settings: settings,
                         model: model, valueText: levelText)
            Text(levelText)
                .font(.system(size: compact ? 10 : 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(settings.muted ? secondaryLabel : boostDecibels > 0.05 ? boostRed : primaryLabel)
                .lineLimit(1)
                .fixedSize()
                .frame(width: settings.extraLoud ? 44 : 36, alignment: .trailing)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .accessibilityHidden(true)
        }
        .animation(motion, value: settings.extraLoud)
    }

    private var boostDecibels: Double {
        guard settings.boosting, let boost = settings.boost else { return 0 }
        return 20 * log10(max(1, AppSettings.boostGain(forPosition: boost)))
    }

    private var levelText: String {
        guard settings.boosting else { return percent }
        let db = boostDecibels
        return db < 0.05 ? "100%" : "+" + db.formatted(.number.precision(.fractionLength(db < 9.95 ? 1 : 0))) + " dB"
    }

    private var mute: some View {
        Button {
            withAnimation(motion) { model.toggleMute(for: source.id) }
        } label: {
            Image(systemName: settings.muted ? "speaker.slash.fill" : "speaker.wave.2")
                .font(.system(size: compact ? 14 : 16, weight: .medium))
                .foregroundStyle(settings.muted ? accent : secondaryLabel)
                .contentTransition(reduceMotion ? .identity : .opacity)
                .frame(width: compact ? 30 : 34, height: compact ? 27 : 30)
                .background(settings.muted ? accent.opacity(0.16) : Color.clear,
                            in: Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(settings.muted ? "Unmute \(source.app.name)" : "Mute \(source.app.name)")
        .accessibilityValue(settings.muted ? "Muted" : "Unmuted")
        .help(settings.muted ? "Unmute \(source.app.name)" : "Mute \(source.app.name)")
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    private var outputMenu: some View {
        Menu {
            Button {
                withAnimation(motion) { model.select(nil, for: source.id) }
            } label: {
                if settings.preferredOutput == nil { Label("System Default", systemImage: "checkmark") }
                else { Text("System Default") }
            }
            if !model.snapshot.devices.isEmpty { Divider() }
            ForEach(model.snapshot.devices) { device in
                Button {
                    withAnimation(motion) { model.select(device, for: source.id) }
                } label: {
                    Label(device.name, systemImage: settings.preferredOutput == device.id ? "checkmark" : device.symbol)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: output?.symbol ?? "speaker.wave.2")
                    .foregroundStyle(output != nil ? accent : secondaryLabel)
                Text(output?.name ?? "System Default")
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .font(.system(size: compact ? 11 : 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(output != nil ? accent : primaryLabel)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 25 : 30)
        .background(inset, in: Capsule())
        .accessibilityLabel("\(source.app.name) output")
        .accessibilityValue(output?.name ?? "System Default")
    }

    private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private let boostRed = Color(red: 1, green: 0.23, blue: 0.19)
private let boostGradient = LinearGradient(colors: [.orange, boostRed], startPoint: .leading, endPoint: .trailing)
private let boostSpring = Animation.spring(response: 0.55, dampingFraction: 0.68)

/// A two-stage volume slider. Normally it is a plain 0–100% slider. With Extra Loud on,
/// dragging to the right end swaps it for the boost slider: the thumb springs back to the
/// unity mark at one third and the red zone to its right raises the level above 100%.
/// Dragging the boost slider to its left end swaps back, with the thumb parked at 100%.
private struct VolumeSlider: View {
    let id: String
    let appName: String
    let settings: AppSettings
    @ObservedObject var model: MixerModel
    let valueText: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: DragState?
    @State private var flare = 1.0

    private struct DragState {
        var startValue: Double
        var onThumb: Bool
        // Set after a mode swap so the rest of this drag can't run the new slider to its far end.
        var latched = false
    }

    private static let thumb: CGFloat = 18
    private var boosting: Bool { settings.boosting }
    private var value: Double { boosting ? settings.boost ?? 0 : settings.volume }
    private var redStart: Double { boosting ? AppSettings.boostUnityPosition : 1 }
    private var swapAnimation: Animation? { reduceMotion ? nil : boostSpring }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usable = max(1, width - Self.thumb)
            let x = Self.thumb / 2 + usable * value
            let redX = Self.thumb / 2 + usable * redStart
            let heat = boosting ? min(1, max(0, (value - redStart) / (1 - redStart))) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(primaryLabel.opacity(0.13))
                    .frame(width: width, height: 4)
                // The boost range. While armed it is a small red cap at the right end.
                Capsule().fill(boostGradient.opacity(boosting ? 0.3 : 0.75))
                    .frame(width: max(4, width - redX), height: 4)
                    .offset(x: min(redX, width - 4))
                    .opacity(settings.extraLoud ? 1 : 0)
                Capsule().fill(settings.muted ? secondaryLabel : accent)
                    .frame(width: max(4, min(x, redX)), height: 4)
                if boosting && x > redX {
                    Capsule().fill(boostGradient)
                        .frame(width: x - redX + 2, height: 4)
                        .offset(x: redX - 1)
                        .shadow(color: boostRed.opacity(0.6 * heat), radius: 3 * heat)
                }
                if boosting {
                    Capsule().fill(secondaryLabel.opacity(0.7))
                        .frame(width: 1.5, height: 10)
                        .offset(x: redX - 0.75)
                        .transition(.opacity)
                }
                Circle().strokeBorder(boostGradient, lineWidth: 2)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .scaleEffect(1 + 1.9 * flare)
                    .opacity(1 - flare)
                    .offset(x: x - Self.thumb / 2)
                Circle().fill(.white)
                    .overlay { Circle().strokeBorder(boosting ? AnyShapeStyle(boostGradient) : AnyShapeStyle(outline),
                                                     lineWidth: boosting ? 1.5 : 0.5) }
                    .shadow(color: boosting ? boostRed.opacity(0.35 + 0.5 * heat) : .black.opacity(0.25),
                            radius: boosting ? 2 + 5 * heat : 1.5, y: boosting ? 0 : 0.5)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: x - Self.thumb / 2)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(usable: usable))
        }
        .frame(height: 22)
        .onChange(of: boosting) { _, now in
            guard now, !reduceMotion else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { flare = 0 }
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.75)) { flare = 1 } }
        }
        .accessibilityElement()
        .accessibilityLabel("\(appName) volume")
        .accessibilityValue(valueText)
        .accessibilityHint(settings.extraLoud ? "Extra Loud is on. Go past 100% to boost." : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: apply(value + 0.05, allowSwap: true)
            case .decrement: apply(value - 0.05, allowSwap: true)
            @unknown default: break
            }
        }
    }

    private func dragGesture(usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if drag == nil {
                    // Grabbing the thumb moves it relative to the pointer, like a native slider;
                    // clicking the track jumps there.
                    let thumbX = Self.thumb / 2 + usable * value
                    let onThumb = abs(gesture.startLocation.x - thumbX) <= Self.thumb / 2 + 2
                    let start = onThumb ? value : Double((gesture.startLocation.x - Self.thumb / 2) / usable)
                    drag = DragState(startValue: start, onThumb: onThumb)
                }
                guard let state = drag, !state.latched else { return }
                let target = state.startValue + Double(gesture.translation.width / usable)
                // Pressing the thumb while it rests at an end must not swap modes by itself.
                let moved = !state.onThumb || abs(gesture.translation.width) >= 1
                if apply(target, allowSwap: moved) { drag?.latched = true }
            }
            .onEnded { _ in drag = nil }
    }

    /// Applies a slider position, swapping modes at the ends. Returns true when it swapped.
    @discardableResult
    private func apply(_ target: Double, allowSwap: Bool) -> Bool {
        let position = min(max(target, 0), 1)
        if boosting {
            if allowSwap && position <= 0 {
                withAnimation(swapAnimation) { model.exitBoost(for: id) }
                return true
            }
            model.setBoost(position, for: id)
        } else {
            if allowSwap && settings.extraLoud && position >= 1 {
                withAnimation(swapAnimation) { model.enterBoost(for: id) }
                return true
            }
            model.setVolume(position, for: id)
        }
        return false
    }
}

enum PlaybackLevel: Equatable {
    case silent, quiet, normal, strong, high, nearClipping

    static func decibels(_ peak: Float) -> Double {
        guard peak.isFinite, peak > 0 else { return -80 }
        return 20 * log10(Double(peak))
    }

    static func band(_ peak: Float) -> PlaybackLevel {
        switch decibels(peak) {
        case ..<(-60): .silent
        case ..<(-30): .quiet
        case ..<(-12): .normal
        case ..<(-6): .strong
        case ..<(-1): .high
        default: .nearClipping
        }
    }

    static func height(_ peak: Float) -> Double {
        guard peak.isFinite, peak > 0.001 else { return 0 }
        // Keep everyday playback in the middle of the display and leave room for peaks.
        return pow(min(1, Double(peak)), 0.45)
    }

    var color: Color {
        switch self {
        case .silent: .secondary
        case .quiet: .cyan
        case .normal: .green
        case .strong: .yellow
        case .high: .orange
        case .nearClipping: .red
        }
    }

    var label: String {
        switch self {
        case .silent: "Silent"
        case .quiet: "Quiet"
        case .normal: "Normal"
        case .strong: "Strong"
        case .high: "High"
        case .nearClipping: "Near clipping"
        }
    }
}

private struct RowWaveform: View {
    @ObservedObject var waveforms: MixerWaveforms
    let app: PlaybackApp

    var body: some View {
        let peaks = waveforms.peaks[app.id] ?? []
        Canvas { context, size in
            let middle = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 3, y: middle))
            baseline.addLine(to: CGPoint(x: size.width - 3, y: middle))
            context.stroke(baseline, with: .color(secondaryLabel.opacity(0.27)), lineWidth: 0.8)
            guard !peaks.isEmpty else { return }

            let step = (size.width - 6) / CGFloat(peaks.count)
            for (index, peak) in peaks.enumerated() where peak > 0.001 {
                let level = PlaybackLevel.height(peak)
                let x = 3 + step * (CGFloat(index) + 0.5)
                let height = max(0.9, (middle - 3) * level)
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: middle - height))
                bar.addLine(to: CGPoint(x: x, y: middle + height))
                let color = PlaybackLevel.band(peak).color
                context.stroke(bar, with: .color(color), style: StrokeStyle(lineWidth: min(2, step * 0.64),
                                                                            lineCap: .round))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name) sound level")
        .accessibilityValue(PlaybackLevel.band(peaks.max() ?? 0).label)
        .help("Output level · cyan for quiet audio, green for normal, yellow and orange for high peaks, red near clipping.")
    }
}

private struct AppIcon: View {
    let path: String?
    let size: CGFloat
    private static let icons = NSCache<NSString, NSImage>()

    private var icon: NSImage? {
        guard let path else { return nil }
        let key = path as NSString
        if let cached = Self.icons.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        Self.icons.setObject(image, forKey: key)
        return image
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.62))
                    .foregroundStyle(secondaryLabel)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
