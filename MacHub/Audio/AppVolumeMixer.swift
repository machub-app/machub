import Accelerate
import AppKit
import CoreAudio
import Observation
import Synchronization

/// One app as the sound panel shows it: every audio process that belongs to it (Discord and its helpers, a browser
/// and its renderers, all of Wine), grouped under the app's bundle.
struct AudioApp: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case app, windowsGames, webKit }

    /// Stable across launches: the app bundle's path, or a fixed key for Wine and WebKit.
    let id: String
    let name: String
    let kind: Kind
    let bundlePath: String?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

/// Reads Core Audio's list of processes that use audio. Needs no permission; only tapping does.
enum AudioProcesses {
    struct Entry: Equatable, Sendable {
        let object: AudioObjectID
        let pid: pid_t
        let executable: String
        let isPlaying: Bool
    }

    static func entries() -> [Entry] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let objects: [AudioObjectID] = arrayProperty(system, kAudioHardwarePropertyProcessObjectList)
        return objects.compactMap { object in
            guard let pid: pid_t = scalarProperty(object, kAudioProcessPropertyPID), pid > 0,
                  let path = executablePath(pid) else { return nil }
            let playing: UInt32 = scalarProperty(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            return Entry(object: object, pid: pid, executable: path, isPlaying: playing != 0)
        }
    }

    /// Groups processes by app. Processes outside any app (system daemons, command-line tools) and MacHub itself
    /// are left out: their volume isn't something the user expects to set here.
    static func group(_ entries: [Entry], ownPID: pid_t = getpid(),
                      isUserApp: (String) -> Bool = { AudioProcesses.isRegularApp(bundlePath: $0) }) -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        for entry in entries where entry.pid != ownPID {
            guard let (id, name, kind, bundle) = owner(ofExecutable: entry.executable) else { continue }
            // System agents (Control Centre, loginwindow, PowerChime…) also open audio: only apps in the Dock count.
            if kind == .app, let bundle, !isUserApp(bundle) { continue }
            if var app = apps[id] {
                app.processObjects.append(entry.object)
                app.isPlaying = app.isPlaying || entry.isPlaying
                apps[id] = app
            } else {
                apps[id] = AudioApp(id: id, name: name, kind: kind, bundlePath: bundle, processObjects: [entry.object], isPlaying: entry.isPlaying)
            }
        }
        return apps.values.sorted { a, b in
            a.isPlaying != b.isPlaying ? a.isPlaying : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// An app the user sees in the Dock (regular activation policy), as opposed to a background agent.
    static func isRegularApp(bundlePath: String) -> Bool {
        let path = URL(filePath: bundlePath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains {
            $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL.path == path
        }
    }

    static let windowsGamesID = "machub.windows-games"
    static let webKitID = "machub.webkit"

    /// Which app an executable belongs to: the outermost `.app` in its path (helpers live inside their app's bundle).
    static func owner(ofExecutable path: String) -> (id: String, name: String, kind: AudioApp.Kind, bundle: String?)? {
        // Wine: Whisky's libraries or MacHub's own engines. All Windows programs share one entry.
        if path.contains("/Libraries/Wine/") || path.contains("/app.machub.MacHub/Runtimes/") {
            return (windowsGamesID, String(localized: "Windows games"), .windowsGames, nil)
        }
        // Safari's and other WebKit apps' sound plays in WebKit's shared GPU process, outside any app bundle.
        if path.contains("/WebKit.framework/") {
            return (webKitID, String(localized: "Safari and web pages (WebKit)"), .webKit, nil)
        }
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        let name = (Bundle(path: bundle)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle(path: bundle)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(filePath: bundle).deletingPathExtension().lastPathComponent
        return (bundle, name, .app, bundle)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Core Audio property helpers

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalarProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    static func arrayProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    /// UID of the device sound currently goes to.
    static func defaultOutputUID() -> String? {
        guard let device: AudioObjectID = scalarProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return nil }
        var address = address(kAudioDevicePropertyDeviceUID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// Plays an app's sound back at a chosen level: a Core Audio process tap mutes the app while it is tapped, a private
/// aggregate device receives the tapped sound, and an IO callback writes it to the output device times the gain.
/// The app's own audio is untouched; when the tap goes away (MacHub quits, volume back to 100 %) it plays as before.
final class ProcessVolumeTap: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noOutputDevice
        case tap(OSStatus)
        case aggregate(OSStatus)
        case io(OSStatus)
    }

    let processObjects: [AudioObjectID]
    let outputUID: String
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// The gain, read on Core Audio's IO thread and written from the main thread.
    private let gainBox = GainBox()
    private let queue = DispatchQueue(label: "app.machub.MacHub.volume", qos: .userInteractive)

    var gain: Float {
        get { gainBox.value }
        set { gainBox.value = newValue }
    }

    init(processObjects: [AudioObjectID], gain: Float) throws {
        guard let output = AudioProcesses.defaultOutputUID() else { throw Failure.noOutputDevice }
        self.processObjects = processObjects
        outputUID = output
        self.gain = gain

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "MacHub volume"
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure.tap(status) }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacHub volume",
            kAudioAggregateDeviceUIDKey: "app.machub.volume.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { stop(); throw Failure.aggregate(status) }
        aggregateID = device

        let box = gainBox
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, input, _, output, _ in
            Self.render(input: input, output: output, gain: box.value)
        }
        guard status == noErr else { stop(); throw Failure.io(status) }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else { stop(); throw Failure.io(status) }
    }

    deinit { stop() }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Copies the tapped sound to the output buffers, scaled by `gain`. Handles one interleaved buffer on each side
    /// (any channel counts: the tap is stereo, the output may have more channels) or matching per-channel buffers.
    static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for out in outputs { if let data = out.mData { memset(data, 0, Int(out.mDataByteSize)) } }
        guard let first = inputs.first, first.mData != nil else { return }
        if inputs.count == 1, outputs.count == 1, let out = outputs.first {
            mix(first, into: out, gain: gain)
        } else {
            for (source, destination) in zip(inputs, outputs) { mix(source, into: destination, gain: gain) }
        }
    }

    /// Interleaved Float32: frame by frame, the input's channels go to the output's first channels.
    static func mix(_ source: AudioBuffer, into destination: AudioBuffer, gain: Float) {
        guard let from = source.mData?.assumingMemoryBound(to: Float.self),
              let to = destination.mData?.assumingMemoryBound(to: Float.self) else { return }
        let inChannels = max(Int(source.mNumberChannels), 1), outChannels = max(Int(destination.mNumberChannels), 1)
        let frames = min(Int(source.mDataByteSize) / 4 / inChannels, Int(destination.mDataByteSize) / 4 / outChannels)
        guard frames > 0 else { return }
        var g = gain
        if inChannels == outChannels {
            vDSP_vsmul(from, 1, &g, to, 1, vDSP_Length(frames * inChannels))
        } else {
            for channel in 0..<min(inChannels, outChannels) {
                vDSP_vsmul(from + channel, vDSP_Stride(inChannels), &g, to + channel, vDSP_Stride(outChannels), vDSP_Length(frames))
            }
        }
    }
}

/// A Float shared with the IO thread without locks: stored as its bits in an atomic.
final class GainBox: Sendable {
    private let bits = Atomic<UInt32>(Float(1).bitPattern)

    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(max(0, min(newValue, 1)).bitPattern, ordering: .relaxed) }
    }
}

/// The sound panel's state: the apps that use audio, the volume set for each (remembered), and the live taps.
@MainActor @Observable
final class AppVolumeMixer {
    static let shared = AppVolumeMixer()

    private(set) var apps: [AudioApp] = []
    /// 0…1 per app id; absent means 100 %.
    private(set) var volumes: [String: Float] = (UserDefaults.standard.dictionary(forKey: "mixer.volumes") as? [String: Double] ?? [:])
        .mapValues(Float.init)
    private(set) var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mixer.muted") ?? [])
    /// Why an app's volume couldn't be applied (permission refused, no output device…).
    private(set) var problems: [String: String] = [:]
    private var taps: [String: ProcessVolumeTap] = [:]
    private var poll: Task<Void, Never>?

    /// Starts following the process list. Called when the panel opens, and at launch if volumes were saved.
    func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var hasSavedSettings: Bool { volumes.contains { $0.value < 1 } || !muted.isEmpty }

    func volume(of app: AudioApp) -> Float { volumes[app.id] ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { muted.contains(app.id) }

    func setVolume(_ value: Float, for app: AudioApp) {
        volumes[app.id] = value >= 0.995 ? nil : value
        save()
        apply(app)
    }

    func toggleMute(_ app: AudioApp) {
        if muted.contains(app.id) { muted.remove(app.id) } else { muted.insert(app.id) }
        save()
        apply(app)
    }

    func resetAll() {
        volumes = [:]
        muted = []
        save()
        for tap in taps.values { tap.stop() }
        taps = [:]
        problems = [:]
    }

    func refresh() {
        apps = AudioProcesses.group(AudioProcesses.entries())
        for app in apps { apply(app) }
        // Apps that quit: their tap goes too.
        for id in taps.keys where !apps.contains(where: { $0.id == id }) {
            taps[id]?.stop()
            taps[id] = nil
        }
    }

    private func apply(_ app: AudioApp) {
        let gain: Float = muted.contains(app.id) ? 0 : (volumes[app.id] ?? 1)
        guard gain < 1 else {
            taps[app.id]?.stop()
            taps[app.id] = nil
            problems[app.id] = nil
            return
        }
        // Same processes and output device: just change the gain. Otherwise rebuild the tap.
        if let tap = taps[app.id], tap.processObjects == app.processObjects, tap.outputUID == AudioProcesses.defaultOutputUID() {
            tap.gain = gain
            return
        }
        taps[app.id]?.stop()
        do {
            taps[app.id] = try ProcessVolumeTap(processObjects: app.processObjects, gain: gain)
            problems[app.id] = nil
        } catch {
            taps[app.id] = nil
            problems[app.id] = String(localized: "macOS refused to adjust this app's sound. Check that MacHub may record audio in System Settings › Privacy & Security.")
        }
    }

    private func save() {
        UserDefaults.standard.set(volumes.mapValues(Double.init), forKey: "mixer.volumes")
        UserDefaults.standard.set(Array(muted), forKey: "mixer.muted")
    }
}
