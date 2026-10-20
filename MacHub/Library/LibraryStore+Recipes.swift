import Foundation

enum RecipeState: Equatable, Sendable {
    case working(String)
    case done(RecipeOutcome)
    case failed(String)
}

extension LibraryStore {
    /// Variables a title is started with: from recipes it had applied, then its advanced settings.
    func titleEnvironment(for title: Title) -> [String: String] {
        let own = settings(for: title)
        var env = own.environment
        env.merge(own.advanced.environment(supportsMsync: runtime?.supportsMsync ?? false)) { _, advanced in advanced }
        return env
    }

    /// Writes (or removes) the Wine virtual desktop of the title's executables.
    func applyVirtualDesktop(for title: Title, prefix: InstalledPrefix? = nil, runtime: WineRuntime? = nil) async {
        guard let runtime = runtime ?? self.runtime, let prefix = prefix ?? self.prefix(of: title),
              let executables = title.install?.executables, !executables.isEmpty else { return }
        let names = executables.map { URL(filePath: $0.replacingOccurrences(of: "\\", with: "/")).lastPathComponent }
        let document = TitleAdvanced.desktopDocument(executables: names, size: settings(for: title).advanced.virtualDesktop)
        let file = prefix.url.appending(path: "drive_c/users/Public/machub-desktop.reg")
        try? document.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        _ = try? await ProcessRunner.run(runtime.wine, ["regedit", "/S", file.path], timeout: 60, environment: env)
    }

    func prefix(of title: Title) -> InstalledPrefix? {
        guard let bottle = title.install?.bottle else { return nil }
        return prefixes.first { $0.name == bottle }
    }

    /// The game's recipe from highball-db, with the tweaks it requires first (launchers MacHub doesn't run are noted).
    func recipes(for title: Title) async -> (recipes: [Recipe], unmet: [String])? {
        guard let game = recommendation(for: title), game.hasRecipe, !game.id.isEmpty,
              let recipe = await Recipes.fetch(game.id) else { return nil }
        var ordered: [Recipe] = []
        var unmet: [String] = []
        for requirement in recipe.requires where !Recipes.builtIn.contains(requirement) {
            if let required = await Recipes.fetch(requirement), required.kind == "tweak" {
                ordered.append(required)
            } else {
                unmet.append(requirement)
            }
        }
        return (ordered + [recipe], unmet)
    }

    /// Applies a title's recipes in its environment and keeps the variables they set for its launches.
    func applyRecipes(for title: Title) async {
        guard let runtime, let prefix = prefix(of: title) else { return }
        let key = title.id
        recipeStates[key] = .working(String(localized: "Reading the recipe…"))
        guard let (recipes, unmet) = await recipes(for: title) else {
            recipeStates[key] = .failed(String(localized: "highball-db has no recipe for this game."))
            return
        }
        var outcome = RecipeOutcome()
        outcome.manual += unmet.map { String(localized: "Install \($0) yourself: MacHub doesn't set up that launcher.") }
        let runner = RecipeRunner(runtime: runtime, prefix: prefix, installFolder: title.installPath.map { URL(filePath: $0) }) { step in
            Task { @MainActor in self.recipeStates[key] = .working(step) }
        }
        for recipe in recipes {
            await runner.apply(recipe, into: &outcome)
            if let failure = outcome.failure {
                recipeStates[key] = .failed(failure)
                return
            }
            AppliedRecipes.record(recipe.id, in: prefix)
        }
        if !outcome.environment.isEmpty {
            var own = settings(for: title)
            own.environment.merge(outcome.environment) { _, recipe in recipe }
            updateSettings(own, for: title)
        }
        recipeStates[key] = .done(outcome)
    }

    /// Installs a Windows component (vcrun2022, corefonts…) in an environment, for every program in it.
    func installComponent(_ id: String, in prefix: InstalledPrefix) async {
        guard let runtime else { return }
        let key = "\(prefix.settings.id.uuidString)/\(id)"
        recipeStates[key] = .working(String(localized: "Reading the recipe…"))
        guard let recipe = await Recipes.fetch(id) else {
            recipeStates[key] = .failed(String(localized: "Couldn't read the recipe from highball-db."))
            return
        }
        var outcome = RecipeOutcome()
        let runner = RecipeRunner(runtime: runtime, prefix: prefix) { step in
            Task { @MainActor in self.recipeStates[key] = .working(step) }
        }
        await runner.apply(recipe, into: &outcome)
        if let failure = outcome.failure {
            recipeStates[key] = .failed(failure)
        } else {
            AppliedRecipes.record(recipe.id, in: prefix)
            recipeStates[key] = .done(outcome)
        }
    }
}
