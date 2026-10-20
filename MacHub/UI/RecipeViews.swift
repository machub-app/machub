import SwiftUI

/// The game page's "Recommended fixes": highball-db's recipe for the game, what it will do, and one button.
struct RecipePanel: View {
    let title: Title
    @Environment(LibraryStore.self) private var store
    @State private var loaded: (recipes: [Recipe], unmet: [String])?

    var body: some View {
        if store.recommendation(for: title)?.hasRecipe == true {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recommended fixes").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                VStack(alignment: .leading, spacing: 10) {
                    if let loaded {
                        ForEach(loaded.recipes) { recipe in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: recipe.title).font(.headline).foregroundStyle(Theme.textPrimary)
                                ForEach(Array(summary(of: recipe).enumerated()), id: \.offset) { _, line in
                                    Label { Text(verbatim: line) } icon: { Image(systemName: "wrench.and.screwdriver") }
                                        .font(.callout).foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        state
                    } else {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the recipe…").foregroundStyle(Theme.textSecondary) }
                    }
                    Text("From highball-db's recipes (CC0). Downloads are checked against the recipe's SHA-256 before they run, inside this game's Windows environment only.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: .rect(cornerRadius: 12))
            }
            .task(id: title.id) { loaded = await store.recipes(for: title) }
        }
    }

    @ViewBuilder private var state: some View {
        switch store.recipeStates[title.id] {
        case .working(let step)?:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(verbatim: step) }
        case .failed(let message)?:
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .foregroundStyle(.orange).textSelection(.enabled)
            applyButton
        case .done(let outcome)?:
            Label("Applied. They take effect at the next launch.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            outcomeDetails(outcome)
        case nil:
            if let prefix = store.prefix(of: title), let applied = loaded?.recipes.last.flatMap({ AppliedRecipes.date($0.id, in: prefix) }) {
                Label("Applied \(applied.formatted(date: .abbreviated, time: .omitted)).", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.textSecondary)
            }
            applyButton
        }
    }

    private var applyButton: some View {
        Button("Apply Recommended Fixes") { Task { await store.applyRecipes(for: title) } }
            .buttonStyle(.borderedProminent)
            .disabled(store.prefix(of: title) == nil)
    }

    @ViewBuilder private func outcomeDetails(_ outcome: RecipeOutcome) -> some View {
        if !outcome.manual.isEmpty {
            Text("Still to do by hand").font(.callout.weight(.semibold))
            ForEach(Array(outcome.manual.enumerated()), id: \.offset) { _, line in
                Text(verbatim: "• " + line).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if !outcome.notes.isEmpty {
            Text("Notes").font(.callout.weight(.semibold))
            ForEach(Array(outcome.notes.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What a recipe will do, one short line per kind of step.
    private func summary(of recipe: Recipe) -> [String] {
        var lines: [String] = []
        var registry = 0
        for step in recipe.steps {
            switch step {
            case .installer(_, _, _, let label, _, _): lines.append(String(localized: "Install \(label)"))
            case .environment(let name, let value): lines.append(String(localized: "Start the game with \(name)=\(value)"))
            case .registry, .dllOverride: registry += 1
            case .winver(let version): lines.append(String(localized: "Windows version \(version)"))
            case .file(let path, _): lines.append(String(localized: "Write C:\\\(path)"))
            case .dxvkConfig(let exe, _): lines.append(String(localized: "DXVK settings for \(exe)"))
            case .copy(_, let to, _): lines.append(String(localized: "Copy a DLL to C:\\\(to)"))
            case .sync(let sync): lines.append(String(localized: "Synchronization: \(sync)"))
            case .manual(_, let text): lines.append(text)
            case .note, .renderer: continue
            }
        }
        if registry > 0 { lines.insert(String(localized: "\(registry) registry setting(s)"), at: 0) }
        let notes = recipe.steps.filter { if case .note = $0 { true } else { false } }.count
        if notes > 0 { lines.append(String(localized: "\(notes) note(s) to read after applying")) }
        return lines
    }
}

/// Settings › Windows Environments: common Windows components, installed once per environment.
struct WindowsComponentsRow: View {
    let prefix: InstalledPrefix
    @Environment(LibraryStore.self) private var store

    var body: some View {
        DisclosureGroup("Windows components") {
            ForEach(Recipes.components, id: \.self) { id in
                let key = "\(prefix.settings.id.uuidString)/\(id)"
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: Self.names[id] ?? id)
                        switch store.recipeStates[key] {
                        case .working(let step)?: Text(verbatim: step).font(.caption).foregroundStyle(.secondary)
                        case .failed(let message)?: Text(verbatim: message).font(.caption).foregroundStyle(.orange)
                        case .done(let outcome)?:
                            Text(outcome.manual.isEmpty ? "Installed" : "Needs a manual step: \(outcome.manual.joined(separator: " "))")
                                .font(.caption).foregroundStyle(outcome.manual.isEmpty ? .green : .orange)
                        case nil:
                            if let date = AppliedRecipes.date(id, in: prefix) {
                                Text("Installed \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if case .working? = store.recipeStates[key] {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(AppliedRecipes.date(id, in: prefix) == nil ? "Install" : "Reinstall") {
                            Task { await store.installComponent(id, in: prefix) }
                        }
                        .disabled(!prefix.hasDriveC)
                    }
                }
            }
            Text("Recipes from highball-db. .NET Framework needs winetricks, which MacHub doesn't include yet: MacHub tells you when a step must be done by hand.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static let names = ["vcrun2022": "Visual C++ 2015–2022", "corefonts": "Microsoft core fonts", "xact": "XAudio / XACT",
                        "dotnet48": ".NET Framework 4.8"]
}
