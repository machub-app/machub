import SwiftUI

/// "Advanced" in a game's Launch & Graphics panel: the engine settings for this game only. Folded by default;
/// every choice starts on "Default", which follows Settings › Windows Games.
struct TitleAdvancedSection: View {
    let title: Title
    @Environment(LibraryStore.self) private var store
    @State var expanded = false
    @State private var environmentText = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Synchronization", selection: binding(\.sync)) {
                    Text("Default").tag(EngineSettings.Sync?.none)
                    Text("msync").tag(EngineSettings.Sync?.some(.msync))
                    Text("esync").tag(EngineSettings.Sync?.some(.esync))
                    Text("Off").tag(EngineSettings.Sync?.some(.off))
                }
                triState("Expose AVX instructions", \.advertiseAVX)
                triState("4 GB memory for 32-bit games", \.largeAddressAware)
                triState("Metal performance overlay", \.metalHUD)
                Picker("Resolution", selection: Binding(
                    get: { advanced.virtualDesktop },
                    set: { new in
                        update { $0.virtualDesktop = new }
                        Task { await store.applyVirtualDesktop(for: title) }
                    })) {
                    Text("Game's own").tag(String?.none)
                    ForEach(TitleAdvanced.desktopSizes, id: \.self) { Text(verbatim: $0.replacingOccurrences(of: "x", with: " × ")).tag(String?.some($0)) }
                }
                Text("A fixed resolution runs the game in a Wine window of that size: useful when a game picks a wrong resolution or misbehaves in fullscreen.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DLL overrides (as WINEDLLOVERRIDES, e.g. dinput8=n,b)").font(.callout)
                    TextField("DLL overrides", text: binding(\.dllOverrides), prompt: Text("None"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment variables (one NAME=value per line)").font(.callout)
                    TextEditor(text: $environmentText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Theme.surfaceRaised, in: .rect(cornerRadius: 6))
                        .onChange(of: environmentText) { saveEnvironment() }
                }
                HStack {
                    Text("Changes apply at the next launch; Steam restarts with them if needed.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Reset to Defaults") {
                        update { $0 = TitleAdvanced() }
                        var own = store.settings(for: title)
                        own.environment = [:]
                        store.updateSettings(own, for: title)
                        environmentText = ""
                        Task { await store.applyVirtualDesktop(for: title) }
                    }
                    .disabled(advanced.isDefault && store.settings(for: title).environment.isEmpty)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced").font(.callout.weight(.semibold))
        }
        .onAppear {
            environmentText = store.settings(for: title).environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }

    private var advanced: TitleAdvanced { store.settings(for: title).advanced }

    private func update(_ change: (inout TitleAdvanced) -> Void) {
        var own = store.settings(for: title)
        change(&own.advanced)
        store.updateSettings(own, for: title)
    }

    private func binding<Value>(_ path: WritableKeyPath<TitleAdvanced, Value>) -> Binding<Value> {
        Binding(get: { advanced[keyPath: path] }, set: { new in update { $0[keyPath: path] = new } })
    }

    private func triState(_ label: LocalizedStringKey, _ path: WritableKeyPath<TitleAdvanced, Bool?>) -> some View {
        Picker(label, selection: binding(path)) {
            Text("Default").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
    }

    private func saveEnvironment() {
        var env: [String: String] = [:]
        for line in environmentText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            env[parts[0]] = parts[1]
        }
        var own = store.settings(for: title)
        guard own.environment != env else { return }
        own.environment = env
        store.updateSettings(own, for: title)
    }
}
