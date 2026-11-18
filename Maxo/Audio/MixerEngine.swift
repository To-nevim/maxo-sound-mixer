import CoreAudio
import Foundation
import OSLog

struct AppSettings: Codable, Equatable {
    var volume = 1.0
    var muted = false
    var preferredOutput: String?
    var preferredName: String?
    /// Extra Loud is switched on from the row's context menu. While it is on, reaching the
    /// right end of the normal slider swaps it for the boost slider.
    var extraLoud = false
    /// Thumb position on the boost slider, or nil while the normal slider is shown.
    var boost: Double?

    var boosting: Bool { extraLoud && boost != nil }
    var gain: Float {
        if muted { return 0 }
        if boosting, let boost {
            // Guard the render thread: never below unity (no jump on entering) and never wild.
            let boosted = Self.boostGain(forPosition: boost)
            return Float(boosted.isFinite ? min(max(boosted, 1), 16) : 1)
        }
        return Float(Self.gain(forVolume: volume))
    }
    // A boosting route stays alive at unity so crossing 0 dB never reconnects the tap.
    var needsMixing: Bool { muted || volume < 1 || preferredOutput != nil || boosting }

    /// Where unity gain sits on the boost slider. Left of it is a neutral zone; the
    /// red zone to its right is the boost range.
    static let boostUnityPosition = 1.0 / 3.0

    /// The top of the red zone. The limiter keeps it clean, so loud, fully mastered sources
    /// gain less than this; quieter ones get all of it.
    static let maxBoostDecibels = 16.0

    /// Maps a boost-slider position (0...1) to a linear gain of 1 or more. The red zone is
    /// spread evenly in decibels, so each step of travel sounds like the same step up.
    static func boostGain(forPosition position: Double) -> Double {
        let fraction = (position - boostUnityPosition) / (1 - boostUnityPosition)
        guard fraction > 0 else { return 1 }
        return pow(10, maxBoostDecibels * min(fraction, 1) / 20)
    }

    /// Loudness is perceived logarithmically, so a linear slider crowds every audible
    /// change into its bottom quarter. A cubic taper spreads it across the travel:
    /// 80% ≈ −6 dB, 50% ≈ −18 dB, 30% ≈ −31 dB, 10% ≈ −60 dB, and 100% stays unity.
    static let taperExponent = 3.0

    static func gain(forVolume volume: Double) -> Double {
        pow(min(max(volume, 0), 1), taperExponent)
    }

    static func volume(forGain gain: Double) -> Double {
        pow(min(max(gain, 0), 1), 1 / taperExponent)
    }
}

extension AppSettings {
    // Settings saved by earlier versions lack the Extra Loud keys, so decode them leniently.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        preferredOutput = try values.decodeIfPresent(String.self, forKey: .preferredOutput)
        preferredName = try values.decodeIfPresent(String.self, forKey: .preferredName)
        extraLoud = try values.decodeIfPresent(Bool.self, forKey: .extraLoud) ?? false
        boost = try values.decodeIfPresent(Double.self, forKey: .boost)
            .flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        if !extraLoud { boost = nil }
    }
}

struct MixerSource: Identifiable, Equatable {
    let app: PlaybackApp
    let playing: Bool
    let state: RouteState

    var id: String { app.id }
}

enum RouteState: Equatable {
    case idle
    case native
    case starting
    case mixing
    case bypassed
}

enum BalanceResult: Sendable {
    case volumes([String: Double])
    case unavailable
}

struct MixerSnapshot: Equatable {
    var devices: [PlaybackDevice] = []
    var defaultName: String?
    var sources: [MixerSource] = []
}

final class MixerEngine: @unchecked Sendable {
    private struct RoutePlan: Equatable {
        let appID: String
        let processes: [AudioObjectID]
        let device: PlaybackDevice?
    }

    private struct ActiveRoute {
        let plan: RoutePlan
        let route: PlaybackRoute
        var retained: Bool
        var cycles: UInt64 = 0
        var activity: UInt32 = 0
        var lastCycle = DispatchTime.now()
    }

    private struct BalanceSession {
        let id: UUID
        let apps: Set<String>
    }

    private struct RouteMeasurement {
        let route: ObjectIdentifier
        let token: UInt32
    }

    private let queue = DispatchQueue(label: "com.maxo.audio.control", qos: .userInitiated)
    private let processes = PlaybackProcesses()
    private let log = Logger(subsystem: "com.maxo.mixer", category: "Routing")
    private let publish: @Sendable (MixerSnapshot) -> Void
    private let publishWaveforms: @Sendable ([String: [Float]]) -> Void
    private var timer: DispatchSourceTimer?
    private var waveformTimer: DispatchSourceTimer?
    private var settings: [String: AppSettings]
    private var hiddenApps: Set<String>
    private var routes: [String: ActiveRoute] = [:]
    private var failed: [String: RoutePlan] = [:]
    private var lastHeard: [String: DispatchTime] = [:]
    private var previous = MixerSnapshot()
    private var previousWaveforms: [String: [Float]] = [:]
    private var balanceSession: BalanceSession?

    init(settings: [String: AppSettings], hiddenApps: Set<String>,
         publish: @escaping @Sendable (MixerSnapshot) -> Void,
         publishWaveforms: @escaping @Sendable ([String: [Float]]) -> Void) {
        self.settings = settings
        self.hiddenApps = hiddenApps
        self.publish = publish
        self.publishWaveforms = publishWaveforms
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(450), leeway: .milliseconds(70))
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer
            timer.resume()

            let meter = DispatchSource.makeTimerSource(queue: self.queue)
            meter.schedule(deadline: .now(), repeating: .milliseconds(60), leeway: .milliseconds(15))
            meter.setEventHandler { [weak self] in self?.refreshWaveforms() }
            self.waveformTimer = meter
            meter.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            waveformTimer?.cancel()
            waveformTimer = nil
            balanceSession = nil
            routes.removeAll()
        }
    }

    func update(_ appID: String, settings: AppSettings) {
        queue.async {
            let prior = self.settings.updateValue(settings, forKey: appID) ?? AppSettings()
            if let active = self.routes[appID], active.plan.device != nil {
                active.route.setGain(settings.gain)
            }
            if prior.preferredOutput != settings.preferredOutput || (settings.needsMixing && !prior.needsMixing) {
                self.failed.removeValue(forKey: appID)
                self.refresh()
            }
        }
    }

    func retry(_ appID: String) {
        queue.async {
            self.failed.removeValue(forKey: appID)
            self.refresh()
        }
    }

    func setHiddenApps(_ apps: Set<String>) {
        queue.async {
            self.hiddenApps = apps
            self.refresh()
        }
    }

    func measureBalance(id: UUID, apps: Set<String>,
                        complete: @escaping @Sendable (BalanceResult) -> Void) {
        queue.async {
            self.balanceSession = BalanceSession(id: id, apps: apps)
            for app in apps {
                self.failed.removeValue(forKey: app)
            }
            self.refresh()

            var measurements: [String: RouteMeasurement] = [:]
            for app in apps {
                if let route = self.routes[app]?.route {
                    measurements[app] = RouteMeasurement(route: ObjectIdentifier(route), token: route.beginMetering())
                }
            }
            guard measurements.count >= 2 else {
                complete(.unavailable)
                return
            }
            let meters = measurements
            self.queue.asyncAfter(deadline: .now() + .seconds(6)) {
                guard self.balanceSession?.id == id else { return }
                complete(.volumes(self.balancedVolumes(meters)))
            }
        }
    }

    func endBalance(id: UUID, updates: [String: AppSettings] = [:]) {
        queue.async {
            guard let session = self.balanceSession, session.id == id else { return }
            for app in session.apps {
                self.routes[app]?.route.endMetering()
            }
            self.balanceSession = nil
            for (app, preferences) in updates {
                self.settings[app] = preferences
                if let active = self.routes[app], active.plan.device != nil {
                    active.route.setGain(preferences.gain)
                }
            }
            self.refresh()
        }
    }

    private func balancedVolumes(_ measurements: [String: RouteMeasurement]) -> [String: Double] {
        var amplitudes: [String: Double] = [:]
        for (id, measurement) in measurements {
            guard let route = routes[id]?.route, ObjectIdentifier(route) == measurement.route else { continue }
            let amplitude = route.measuredAmplitude(measurement.token)
            if amplitude > 0 {
                amplitudes[id] = amplitude
            }
        }
        guard amplitudes.count >= 2, let target = amplitudes.values.min() else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: amplitudes.map { id, amplitude in
            // The ratio is the linear gain that matches loudness; convert it to a slider position.
            (id, AppSettings.volume(forGain: min(1, target / amplitude)))
        })
    }

    private func refresh() {
        let hardware = PlaybackDevice.available()
        let defaultDevice = hardware.devices.first { $0.object == hardware.defaultID }
        guard let discovered = processes.groups() else {
            // A HAL reset invalidates process audio objects. Release taps while discovery recovers.
            routes.removeAll()
            failed.removeAll()
            lastHeard.removeAll()
            deliver(devices: hardware.devices, defaultDevice: defaultDevice, sources: [])
            return
        }

        let groups = discovered.filter { !hiddenApps.contains($0.key) }
        let now = DispatchTime.now()
        for group in groups.values where group.playing {
            if lastHeard[group.app.id] == nil { lastHeard[group.app.id] = now }
        }
        lastHeard = lastHeard.filter { groups[$0.key] != nil }
        for id in Array(routes.keys) where groups[id]?.playing != true {
            routes.removeValue(forKey: id)
        }
        failed = failed.filter { groups[$0.key]?.playing == true }

        var sources: [MixerSource] = []
        for group in groups.values {
            let app = group.app
            guard lastHeard[app.id] != nil else { continue }
            let preference = settings[app.id] ?? AppSettings()
            let preferred = hardware.devices.first { $0.id == preference.preferredOutput }
            let needsRouting = preference.needsMixing || routes[app.id]?.retained == true
            let state: RouteState
            if !group.playing {
                state = .idle
            } else if needsRouting && preferred == nil && defaultDevice == nil {
                routes.removeValue(forKey: app.id)
                failed.removeValue(forKey: app.id)
                state = .bypassed
            } else {
                let plan = RoutePlan(appID: app.id, processes: group.processes.sorted(),
                                     device: needsRouting ? preferred ?? defaultDevice : nil)
                state = reconcile(plan, name: app.name, gain: preference.gain, retain: preference.needsMixing)
            }
            guard let heard = lastHeard[app.id] else { continue }
            let elapsed = DispatchTime.now().uptimeNanoseconds - heard.uptimeNanoseconds
            let captureUnavailable = state == .bypassed && group.playing
            if elapsed < 15_000_000_000 || captureUnavailable {
                let active = group.playing && (elapsed < 950_000_000 || captureUnavailable)
                sources.append(MixerSource(app: app, playing: active, state: state))
            }
        }

        deliver(devices: hardware.devices, defaultDevice: defaultDevice, sources: sources.sorted {
            let order = $0.app.name.localizedStandardCompare($1.app.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        })
    }

    private func reconcile(_ plan: RoutePlan, name: String, gain: Float, retain: Bool) -> RouteState {
        let id = plan.appID
        if var active = routes[id], active.plan == plan {
            if retain && !active.retained {
                active.retained = true
                routes[id] = active
            }
            let now = DispatchTime.now()
            let cycles = active.route.cycles
            let activity = active.route.activity
            if active.activity != activity {
                active.activity = activity
                lastHeard[id] = now
                routes[id] = active
            }
            if cycles != active.cycles {
                active.cycles = cycles
                active.lastCycle = now
                routes[id] = active
                return plan.device == nil ? .native : .mixing
            }
            if plan.device == nil { return .native }
            if now.uptimeNanoseconds - active.lastCycle.uptimeNanoseconds > 3_000_000_000 {
                log.error("Playback callback stalled for \(id, privacy: .public)")
                // Drop the local reference on return so the tap releases before the next refresh.
                routes.removeValue(forKey: id)
                failed[id] = plan
                return .bypassed
            }
            if cycles == 0 { return .starting }
            return .mixing
        }
        // Release the previous tap before muting the same process set on a new device.
        routes.removeValue(forKey: id)
        if failed[id] == plan { return .bypassed }
        failed.removeValue(forKey: id)
        do {
            let route = try PlaybackRoute(name: name, processes: plan.processes, output: plan.device, gain: gain)
            routes[id] = ActiveRoute(plan: plan, route: route, retained: retain)
            return .starting
        } catch {
            failed[id] = plan
            log.error("Playback bypassed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return .bypassed
        }
    }

    private func refreshWaveforms() {
        var waveforms: [String: [Float]] = [:]
        let now = DispatchTime.now()
        for source in previous.sources {
            guard let active = routes[source.id],
                  now.uptimeNanoseconds - active.lastCycle.uptimeNanoseconds < 600_000_000 else { continue }
            let peaks = active.route.waveform()
            if peaks.contains(where: { $0 > 0.001 }) {
                waveforms[source.id] = peaks
            }
        }
        if waveforms != previousWaveforms {
            previousWaveforms = waveforms
            publishWaveforms(waveforms)
        }
    }

    private func deliver(devices: [PlaybackDevice], defaultDevice: PlaybackDevice?, sources: [MixerSource]) {
        let snapshot = MixerSnapshot(devices: devices, defaultName: defaultDevice?.name, sources: sources)
        if snapshot != previous {
            previous = snapshot
            publish(snapshot)
        }
    }
}
