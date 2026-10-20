import SwiftUI

/// Settings › Sound: a volume per app (a game, Discord, the browser playing YouTube…), applied while MacHub is open.
struct SoundSettingsSection: View {
    @State private var mixer = AppVolumeMixer.shared

    var body: some View {
        Section {
            if mixer.apps.isEmpty {
                Text("No app is using sound right now. Start a game, a call or a video: it appears here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(mixer.apps) { app in
                AppVolumeRow(app: app, mixer: mixer)
            }
        } header: {
            Text("Volume per app")
        } footer: {
            Text("macOS has no volume per app of its own. MacHub captures the sound of an app you turn down and plays it at the level you choose; macOS asks once for permission to record other apps' audio. Nothing is recorded or saved. A browser counts as one app: a YouTube video follows the browser's volume, since macOS doesn't separate tabs. Volumes apply while MacHub is open.")
        }
        Section {
            Button("Set every app back to 100 %") { mixer.resetAll() }
                .disabled(!mixer.hasSavedSettings)
            Button("Open Privacy & Security") { SystemSettings.openAudioCapturePrivacy() }
        }
        .onAppear { mixer.start() }
    }
}

private struct AppVolumeRow: View {
    let app: AudioApp
    let mixer: AppVolumeMixer

    var body: some View {
        let muted = mixer.isMuted(app)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                icon.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: app.name)
                    Text(app.isPlaying ? "Playing sound" : "Silent")
                        .font(.caption).foregroundStyle(app.isPlaying ? Compatibility.great.tint : .secondary)
                }
                .frame(width: 190, alignment: .leading)
                Button {
                    mixer.toggleMute(app)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 22)
                }
                .buttonStyle(.borderless)
                .help(muted ? "Unmute" : "Mute")
                .accessibilityLabel(muted ? Text("Unmute \(app.name)") : Text("Mute \(app.name)"))
                Slider(value: Binding(get: { Double(mixer.volume(of: app)) }, set: { mixer.setVolume(Float($0), for: app) }), in: 0...1)
                    .disabled(muted)
                    .accessibilityLabel(Text("Volume of \(app.name)"))
                Text(muted ? 0 : Double(mixer.volume(of: app)), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
            if let problem = mixer.problems[app.id] {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch app.kind {
        case .app:
            if let path = app.bundlePath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            }
        case .windowsGames:
            Image(systemName: "gamecontroller.fill").resizable().scaledToFit().foregroundStyle(.secondary)
        case .webKit:
            Image(systemName: "safari").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}
