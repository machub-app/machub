import CoreAudio
import Foundation
import Testing
@testable import MacHub

@Suite struct AppVolumeMixerTests {
    private func entry(_ object: AudioObjectID, _ pid: pid_t, _ path: String, playing: Bool = false) -> AudioProcesses.Entry {
        AudioProcesses.Entry(object: object, pid: pid, executable: path, isPlaying: playing)
    }

    @Test func helpersCountAsTheirApp() {
        let discord = "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"
        #expect(AudioProcesses.owner(ofExecutable: discord)?.id == "/Applications/Discord.app")
        let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(AudioProcesses.owner(ofExecutable: chrome)?.id == "/Applications/Google Chrome.app")
    }

    @Test func wineAndWebKitHaveTheirOwnEntries() {
        let whiskyWine = "/Users/me/Library/Application Support/com.franke.Whisky/Libraries/Wine/bin/wine64-preloader"
        let machubWine = "/Users/me/Library/Application Support/app.machub.MacHub/Runtimes/1.0.5/wine/bin/wine"
        let webkit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        #expect(AudioProcesses.owner(ofExecutable: whiskyWine)?.kind == .windowsGames)
        #expect(AudioProcesses.owner(ofExecutable: machubWine)?.id == AudioProcesses.windowsGamesID)
        #expect(AudioProcesses.owner(ofExecutable: webkit)?.kind == .webKit)
        #expect(AudioProcesses.owner(ofExecutable: "/usr/libexec/powerd") == nil)
    }

    @Test func groupsMergesHidesAgentsAndPutsPlayingFirst() {
        let apps = AudioProcesses.group([
            entry(10, 100, "/Applications/Discord.app/Contents/MacOS/Discord"),
            entry(11, 101, "/Applications/Discord.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper", playing: true),
            entry(12, 102, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            entry(13, 103, "/System/Library/CoreServices/PowerChime.app/Contents/MacOS/PowerChime"),
            entry(14, 104, "/x/Library/Application Support/com.franke.Whisky/Libraries/Wine/bin/wine64-preloader"),
            entry(15, 999, "/Applications/MacHub.app/Contents/MacOS/MacHub"),
        ], ownPID: 999, isUserApp: { !$0.contains("CoreServices") })
        #expect(apps.map(\.name).first == "Discord")
        #expect(apps.first?.processObjects == [10, 11])
        #expect(apps.first?.isPlaying == true)
        #expect(!apps.contains { $0.name == "PowerChime" }, "background agents are hidden")
        #expect(!apps.contains { $0.name == "MacHub" }, "MacHub never lists itself")
        #expect(apps.contains { $0.kind == .windowsGames })
    }

    /// Renders one buffer of tapped sound and returns what reaches the output.
    private func render(_ input: [Float], inChannels: UInt32, outChannels: UInt32, outFrames: Int, gain: Float) -> [Float] {
        var source = input
        var output = [Float](repeating: 9, count: outFrames * Int(outChannels))
        source.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: inChannels, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: outChannels, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                ProcessVolumeTap.render(input: &inList, output: &outList, gain: gain)
            }
        }
        return output
    }

    @Test func gainScalesTheSound() {
        #expect(render([1, -1, 0.5, -0.5], inChannels: 2, outChannels: 2, outFrames: 2, gain: 0.25) == [0.25, -0.25, 0.125, -0.125])
        #expect(render([1, 1], inChannels: 2, outChannels: 2, outFrames: 1, gain: 0) == [0, 0], "muted means silence, not the original")
    }

    @Test func stereoGoesToTheFirstTwoChannelsOfAWiderDevice() {
        // A 4-channel output (e.g. an audio interface): extra channels stay silent instead of receiving stale data.
        #expect(render([1, 2, 3, 4], inChannels: 2, outChannels: 4, outFrames: 2, gain: 1) == [1, 2, 0, 0, 3, 4, 0, 0])
    }

    @Test func gainIsClampedBetweenSilenceAndFullVolume() {
        let box = GainBox()
        box.value = 3
        #expect(box.value == 1)
        box.value = -1
        #expect(box.value == 0)
    }
}
