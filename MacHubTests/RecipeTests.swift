import Foundation
import Testing
@testable import MacHub

struct RecipeTests {
    static let vcrun = Data(#"""
    {"id":"vcrun2022","kind":"tweak","title":"Visual C++ runtimes (2015-2022)","requires":[],"renderer":null,"steps":[
      {"type":"installer","url":"https://aka.ms/vs/17/release/VC_redist.x64.exe","sha256":"CC0F","arguments":["/install","/quiet"],"label":"VC++ x64"},
      {"type":"registry","key":"HKCU\\Software\\Wine\\DllOverrides","name":"msvcp140","valueType":"REG_SZ","data":"native,builtin"},
      {"type":"registry","key":"HKLM\\Software\\Test","name":"Flag","valueType":"REG_DWORD","data":"1"},
      {"type":"dlloverride","value":"amd_ags_x64="},
      {"type":"environment","name":"ROSETTA_ADVERTISE_AVX","value":"1"},
      {"type":"sync","sync":"none"},
      {"type":"winetricks","verbs":["dotnet48"]},
      {"type":"note","text":"Done."}]}
    """#.utf8)

    @Test func parsesEveryStepKind() throws {
        let recipe = try #require(Recipes.parse(Self.vcrun))
        #expect(recipe.id == "vcrun2022" && recipe.kind == "tweak" && recipe.steps.count == 8)
        guard case .installer(_, let sha, let arguments, let label, false, nil) = recipe.steps[0] else { Issue.record("installer"); return }
        #expect(sha == "cc0f" && arguments == ["/install", "/quiet"] && label == "VC++ x64")
        guard case .manual(let type, _) = recipe.steps[6] else { Issue.record("winetricks should be manual"); return }
        #expect(type == "winetricks")
    }

    @Test func writesRegistryDocument() throws {
        let recipe = try #require(Recipes.parse(Self.vcrun))
        let document = try #require(Recipes.registryDocument(recipe.steps))
        #expect(document.hasPrefix("Windows Registry Editor Version 5.00"))
        #expect(document.contains(#"[HKEY_CURRENT_USER\Software\Wine\DllOverrides]"#))
        #expect(document.contains(#""msvcp140"="native,builtin""#))
        #expect(document.contains(#"[HKEY_LOCAL_MACHINE\Software\Test]"#))
        #expect(document.contains(#""Flag"=dword:00000001"#))
        #expect(document.contains(#""amd_ags_x64"="""#))
    }

    @Test func collectsEnvironmentAndSync() throws {
        let recipe = try #require(Recipes.parse(Self.vcrun))
        let env = Recipes.environment(of: recipe.steps)
        #expect(env["ROSETTA_ADVERTISE_AVX"] == "1" && env["WINEESYNC"] == "0" && env["WINEMSYNC"] == "0")
    }

    @Test func titleSettingsKeepEnvironment() throws {
        var settings = TitleSettings()
        settings.environment = ["ROSETTA_ADVERTISE_AVX": "1"]
        let decoded = try JSONDecoder().decode(TitleSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.environment == ["ROSETTA_ADVERTISE_AVX": "1"])
    }
}

/// Applies the real vcrun2022 recipe from highball-db in a throwaway environment. Opt-in (downloads ~50 MB and runs
/// Microsoft's installers under Wine): `TEST_RUNNER_MACHUB_RECIPE=1 xcodebuild … test -only-testing:MacHubTests/RealRecipeTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACHUB_RECIPE"] != nil))
struct RealRecipeTests {
    @Test func installsVisualCPlusPlus() async throws {
        let runtime = try #require(RuntimeManager.live.current())
        let root = FileManager.default.temporaryDirectory.appending(path: "machub-recipe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try await PrefixStore(directory: root).create(name: "Recipe test", role: .apps, runtime: runtime, takenNames: [])
        let recipe = try #require(await Recipes.fetch("vcrun2022"))
        var outcome = RecipeOutcome()
        await RecipeRunner(runtime: runtime, prefix: prefix).apply(recipe, into: &outcome)
        #expect(outcome.failure == nil, "\(outcome.failure ?? "")")
        let system32 = prefix.url.appending(path: "drive_c/windows/system32")
        // Wine leaves placeholder DLLs in system32 marked "Wine builtin DLL"; Microsoft's own file has no such marker.
        let dll = try Data(contentsOf: system32.appending(path: "msvcp140.dll"))
        #expect(dll.range(of: Data("Wine builtin DLL".utf8)) == nil, "msvcp140.dll is still Wine's placeholder")
        #expect(dll.count > 200_000)
        let env = WineEnvironment(runtime: runtime, prefix: prefix).variables
        _ = try? await ProcessRunner.run(runtime.wineserver, ["-k"], timeout: 30, environment: env)
    }
}
