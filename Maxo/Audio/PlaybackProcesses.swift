import AppKit
import CoreAudio

struct PlaybackApp: Equatable {
    let id: String
    let name: String
    let iconPath: String?
}

struct PlaybackGroup {
    let app: PlaybackApp
    var processes: [AudioObjectID] = []
    var playing = false
}

final class PlaybackProcesses {
    private struct Client {
        let pid: pid_t
        let app: PlaybackApp
    }

    private var clients: [AudioObjectID: Client] = [:]

    func groups() -> [String: PlaybackGroup]? {
        guard let ids = HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList) else { return nil }
        let existing = Set(ids)
        clients = clients.filter { existing.contains($0.key) }
        var groups: [String: PlaybackGroup] = [:]

        for object in ids {
            guard let pid = HAL.read(object, kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid > 1, pid != getpid() else { continue }
            let playing = HAL.read(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) == 1
            let app: PlaybackApp
            if let client = clients[object], client.pid == pid {
                app = client.app
            } else {
                guard playing, let resolved = Self.resolve(pid: pid, object: object) else { continue }
                clients[object] = Client(pid: pid, app: resolved)
                app = resolved
            }
            groups[app.id, default: PlaybackGroup(app: app)].processes.append(object)
            if playing { groups[app.id]?.playing = true }
        }
        return groups
    }

    private static func resolve(pid: pid_t, object: AudioObjectID) -> PlaybackApp? {
        let halBundleID = HAL.string(object, kAudioProcessPropertyBundleID)
        let running = NSRunningApplication(processIdentifier: pid)
        let executable = running?.executableURL ?? processPath(pid)
        if executable?.lastPathComponent == "systemsoundserverd"
            || halBundleID == "com.apple.systemsoundserverd" { return nil }
        let directBundle = running?.bundleURL.flatMap(containingApp)
            ?? executable.flatMap(containingApp)

        if let bundle = directBundle { return app(from: bundle) }
        if let halBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: halBundleID),
           let bundle = containingApp(url) {
            return app(from: bundle)
        }

        // Browser helpers with executables outside the app bundle can inherit its parent process.
        var ancestor = pid
        for _ in 0..<12 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_ppid > 1, info.pbi_ppid != ancestor else { break }
            ancestor = pid_t(info.pbi_ppid)
            if let url = processPath(ancestor), let bundle = containingApp(url) {
                return app(from: bundle)
            }
        }

        // The system WebKit GPU service can be shared. Use Safari when it is the only running WebKit host
        // we can identify. Prefer the HAL identity and app bundle when either provides a definite owner.
        if halBundleID?.hasPrefix("com.apple.WebKit.") == true,
           let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first,
           let url = safari.bundleURL, let bundle = Bundle(url: url) {
            return app(from: bundle)
        }

        guard let executable else { return nil }
        let path = executable.path
        // System daemons may open output streams for effects. Keep the mixer focused on apps.
        guard !path.hasPrefix("/System/"), !path.hasPrefix("/usr/libexec/") else { return nil }
        let name = running?.localizedName ?? executable.lastPathComponent
        return PlaybackApp(id: halBundleID ?? path, name: name, iconPath: path)
    }

    private static func app(from bundle: Bundle) -> PlaybackApp {
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        return PlaybackApp(id: bundle.bundleIdentifier ?? bundle.bundlePath, name: name,
                           iconPath: bundle.bundlePath)
    }

    private static func containingApp(_ url: URL) -> Bundle? {
        // The outer .app is the host of Chromium and Electron Helper apps.
        let components = url.pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        let path = NSString.path(withComponents: Array(components[...index]))
        return Bundle(path: path)
    }

    private static func processPath(_ pid: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }
}
