import Foundation

/// Frame-rate summary of one play session, from the Metal Performance HUD's own log (no overlay of MacHub's in the
/// game, no hook: macOS writes it). With MTL_HUD_ENABLED=1 and MTL_HUD_LOG_ENABLED=1, every Metal process logs
/// roughly every few seconds `metal-HUD: <frame number>,<memory MB>,<…><private>` under subsystem
/// com.apple.metal.hud, category Logging. The per-frame details are redacted by macOS, but the frame number and the
/// log timestamp give the real frame rate between two lines (verified with BeamNG.drive, 2026-10-19).
struct PerformanceSummary: Codable, Equatable, Sendable {
    let start: Date
    let duration: TimeInterval
    let averageFPS: Double
    /// The 10th percentile of the per-interval frame rates: the "lows" a player notices.
    let lowFPS: Double
    let worstFPS: Double
    let peakMemoryMB: Double?
}

enum PerformanceLog {
    struct Sample: Equatable {
        let pid: Int32
        let time: TimeInterval
        let frame: Int
        let memoryMB: Double?
    }

    /// Parses `log show --style compact` lines. Only the Logging category is used (macOS also mirrors each line
    /// under the libMTLHud image, which would count every sample twice).
    static func samples(fromCompactLog text: String) -> [Sample] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return text.split(separator: "\n").compactMap { line in
            guard line.contains("com.apple.metal.hud:Logging"),
                  let match = line.firstMatch(of: /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) .*?\[(\d+):[0-9a-fx]+\].*?metal-HUD: (\d+),([0-9.]+)/),
                  let date = formatter.date(from: String(match.1)), let pid = Int32(match.2), let frame = Int(match.3)
            else { return nil }
            return Sample(pid: pid, time: date.timeIntervalSince1970, frame: frame, memoryMB: Double(match.4))
        }
    }

    /// Summary for the process that drew the most frames (the game, not its launcher or a helper).
    static func summarize(_ samples: [Sample]) -> PerformanceSummary? {
        let byProcess = Dictionary(grouping: samples, by: \.pid)
        guard let game = byProcess.values.max(by: { ($0.last?.frame ?? 0) - ($0.first?.frame ?? 0) < ($1.last?.frame ?? 0) - ($1.first?.frame ?? 0) }),
              game.count >= 2 else { return nil }
        let ordered = game.sorted { $0.time < $1.time }
        var rates: [Double] = []
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let elapsed = next.time - previous.time
            let frames = next.frame - previous.frame
            guard elapsed > 0.2, frames >= 0 else { continue }
            rates.append(Double(frames) / elapsed)
        }
        guard !rates.isEmpty, let first = ordered.first, let last = ordered.last else { return nil }
        let duration = last.time - first.time
        let sorted = rates.sorted()
        let low = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.1))]
        return PerformanceSummary(
            start: Date(timeIntervalSince1970: first.time),
            duration: duration,
            averageFPS: duration > 0 ? Double(last.frame - first.frame) / duration : sorted[sorted.count / 2],
            lowFPS: low,
            worstFPS: sorted.first ?? 0,
            peakMemoryMB: ordered.compactMap(\.memoryMB).max()
        )
    }

    /// Reads the HUD lines logged since `start` and summarises them. Nil when the overlay wasn't on.
    static func read(since start: Date) async -> PerformanceSummary? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let arguments = ["show", "--style", "compact", "--start", formatter.string(from: start),
                         "--predicate", #"subsystem == "com.apple.metal.hud" AND category == "Logging""#]
        guard let result = try? await ProcessRunner.run(URL(filePath: "/usr/bin/log"), arguments, timeout: 120) else { return nil }
        return summarize(samples(fromCompactLog: result.stdout))
    }

    static let fileName = "performance.json"

    /// Last sessions per title, newest first (kept to 10).
    static func history() -> [String: [PerformanceSummary]] {
        LocalData.load([String: [PerformanceSummary]].self, from: fileName) ?? [:]
    }

    static func record(_ summary: PerformanceSummary, for id: String) -> [String: [PerformanceSummary]] {
        var all = history()
        all[id] = Array(([summary] + (all[id] ?? [])).prefix(10))
        LocalData.save(all, to: fileName)
        return all
    }
}
