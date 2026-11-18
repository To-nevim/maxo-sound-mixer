import SwiftUI

enum AutoBalanceStatus: Equatable {
    case idle
    case listening(UUID)
    case applied(Int)
    case insufficientAudio
    case unavailable
    case cancelled

    var message: String? {
        switch self {
        case .idle: nil
        case .listening: "Listening to the apps playing…"
        case .applied(let count): "Balanced \(count) apps."
        case .insufficientAudio: "Play audio in at least two apps and try again."
        case .unavailable: "Couldn’t measure two apps. Check Maxo’s audio access."
        case .cancelled: "Auto Balance cancelled."
        }
    }
}

@MainActor
final class MixerWaveforms: ObservableObject {
    @Published var peaks: [String: [Float]] = [:]
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var snapshot = MixerSnapshot()
    @Published private(set) var settings: [String: AppSettings]
    @Published private(set) var balanceStatus = AutoBalanceStatus.idle
    @Published private(set) var hiddenApps: [String: String]
    @Published private(set) var appOrder: [String]
    let waveforms = MixerWaveforms()
    private let defaults: UserDefaults
    private let settingsKey = "maxo.playback.settings"
    private let hiddenKey = "maxo.mixer.hiddenApps"
    private let orderKey = "maxo.mixer.appOrder"
    private static let curveKey = "maxo.playback.volumeCurve"
    private var engine: MixerEngine?
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: settingsKey)
        var restored = data.flatMap { try? JSONDecoder().decode([String: AppSettings].self, from: $0) } ?? [:]
        // Volumes saved before the cubic taper were linear gains. Convert them once so
        // each app keeps the loudness it had; only the slider position moves.
        let migrateLinear = data != nil && defaults.integer(forKey: Self.curveKey) < 2
        for id in restored.keys {
            if let volume = restored[id]?.volume {
                let clamped = volume.isFinite ? min(max(volume, 0), 1) : 1
                restored[id]?.volume = migrateLinear ? AppSettings.volume(forGain: clamped) : clamped
            }
        }
        self.settings = restored
        hiddenApps = defaults.dictionary(forKey: hiddenKey) as? [String: String] ?? [:]
        appOrder = defaults.stringArray(forKey: orderKey) ?? []
        // Persist converted volumes together with the marker, so an early exit can't
        // leave linear values flagged as already migrated.
        if migrateLinear { save() }
        defaults.set(2, forKey: Self.curveKey)
    }

    func start() {
        guard engine == nil else { return }
        let engine = MixerEngine(settings: settings, hiddenApps: Set(hiddenApps.keys)) { [weak self] snapshot in
            Task { @MainActor in self?.snapshot = snapshot }
        } publishWaveforms: { [weak self] waveforms in
            Task { @MainActor in self?.waveforms.peaks = waveforms }
        }
        self.engine = engine
        engine.start()
    }

    func stop() {
        engine?.stop()
        engine = nil
        saveTask?.cancel()
        save()
    }

    func preferences(for id: String) -> AppSettings { settings[id] ?? AppSettings() }

    func setVolume(_ volume: Double, for id: String) {
        change(id, saveImmediately: false) { $0.volume = min(max(volume, 0), 1) }
    }

    func toggleMute(for id: String) {
        change(id) { $0.muted.toggle() }
    }

    func select(_ device: PlaybackDevice?, for id: String) {
        change(id) {
            $0.preferredOutput = device?.id
            $0.preferredName = device?.name
        }
    }

    func retry(_ id: String) { engine?.retry(id) }

    var sources: [MixerSource] {
        let shown = snapshot.sources.filter { hiddenApps[$0.id] == nil }
        let positions = Dictionary(appOrder.enumerated().map { ($0.element, $0.offset) },
                                   uniquingKeysWith: min)
        return shown.enumerated().sorted { left, right in
            let a = positions[left.element.id] ?? (appOrder.count + left.offset)
            let b = positions[right.element.id] ?? (appOrder.count + right.offset)
            return a < b
        }.map(\.element)
    }

    func hide(_ source: MixerSource) {
        hiddenApps[source.id] = source.app.name
        updateHiddenApps()
    }

    func restore(_ id: String) {
        hiddenApps.removeValue(forKey: id)
        updateHiddenApps()
    }

    private func updateHiddenApps() {
        cancelBalance()
        defaults.set(hiddenApps, forKey: hiddenKey)
        engine?.setHiddenApps(Set(hiddenApps.keys))
    }

    func move(_ id: String, to target: String) {
        let displayed = sources.map(\.id)
        guard id != target, displayed.contains(id), displayed.contains(target) else { return }
        var order = appOrder
        let known = Set(order)
        order.append(contentsOf: displayed.filter { !known.contains($0) })
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(id, at: to)
        appOrder = order
        defaults.set(order, forKey: orderKey)
    }

    var isBalancing: Bool {
        if case .listening = balanceStatus { return true }
        return false
    }

    var canAutoBalance: Bool { balanceCandidates.count >= 2 }

    private var balanceCandidates: Set<String> {
        Set(sources.compactMap { source in
            let preferences = preferences(for: source.id)
            return source.playing && !preferences.muted && preferences.volume > 0 ? source.id : nil
        })
    }

    func autoBalance() {
        if cancelBalance() { return }
        let apps = balanceCandidates
        guard let engine, apps.count >= 2 else { return }
        let id = UUID()
        balanceStatus = .listening(id)
        engine.measureBalance(id: id, apps: apps) { [weak self] result in
            Task { @MainActor in self?.applyBalance(id: id, result: result) }
        }
    }

    @discardableResult
    private func cancelBalance() -> Bool {
        guard case .listening(let id) = balanceStatus else { return false }
        balanceStatus = .cancelled
        engine?.endBalance(id: id)
        return true
    }

    private func applyBalance(id: UUID, result: BalanceResult) {
        guard case .listening(let activeID) = balanceStatus, activeID == id else { return }
        guard case .volumes(let levels) = result else {
            engine?.endBalance(id: id)
            balanceStatus = .unavailable
            return
        }
        var updates: [String: AppSettings] = [:]
        for (app, volume) in levels {
            var preferences = preferences(for: app)
            if abs(preferences.volume - volume) > 0.0001 {
                preferences.volume = volume
                updates[app] = preferences
            }
        }
        if !updates.isEmpty {
            settings.merge(updates) { _, new in new }
            saveTask?.cancel()
            save()
        }
        engine?.endBalance(id: id, updates: updates)
        balanceStatus = levels.isEmpty ? .insufficientAudio : .applied(levels.count)
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }

    private func change(_ id: String, saveImmediately: Bool = true, _ update: (inout AppSettings) -> Void) {
        var value = preferences(for: id)
        update(&value)
        guard value != settings[id] else { return }
        settings[id] = value
        engine?.update(id, settings: value)
        if !cancelBalance() { balanceStatus = .idle }
        saveTask?.cancel()
        if saveImmediately {
            save()
        } else {
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                if !Task.isCancelled { self?.save() }
            }
        }
    }
}
