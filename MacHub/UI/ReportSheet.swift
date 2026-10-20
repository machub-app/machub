import SwiftUI

/// "How did it run?": a rating, one line, and the pre-filled report opened in the browser for the player to submit.
struct ReportSheet: View {
    @State var report: GameReport
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(LibraryStore.askForReportsKey) private var askAfterSessions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(report.crashedAtStart ? "\(report.titleName) closed right after starting" : "How did \(report.titleName) run?")
                .font(.title2.weight(.bold))
            Text("Your report helps other Mac players know what works. MacHub fills in the details; you review and post it on GitHub with your own account.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Rating", selection: $report.rating) {
                ForEach([5, 4, 3, 2, 1], id: \.self) { Text(verbatim: GameReport.ratings[$0] ?? "\($0)").tag($0) }
            }
            .pickerStyle(.radioGroup)
            TextField("What wasn't perfect? (optional)", text: $report.issues, axis: .vertical)
                .lineLimit(2...4)
            TextField("What you played, settings, anything that mattered (optional)", text: $report.notes, axis: .vertical)
                .lineLimit(2...4)
            GroupBox("Filled in by MacHub") {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Mac", "\(report.chip), macOS \(report.macOS)")
                    detail("App", [report.app, report.engine].compactMap { $0 }.joined(separator: " · "))
                    if let renderer = report.renderer { detail("Renderer", GameReport.graphicsLabel(renderer)) }
                    detail("Session", report.sessionText)
                    if let fps = report.averageFPS { detail("Frame rate", "\(fps) fps average") }
                    if !report.settingsText.isEmpty { detail("Settings", report.settingsText) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Ask after each session", isOn: $askAfterSessions)
            HStack {
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Report to MacHub") { openURL(report.macHubURL); dismiss() }
                    .help("For problems that come from MacHub itself")
                Button("Share with highball-db") { openURL(report.highballURL); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .help("The open compatibility database other Mac players and tools read")
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(verbatim: value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
