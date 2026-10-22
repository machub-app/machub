import Foundation
import Testing
@testable import MacHub

@Suite struct GameRenderersTests {
    @Test func vulkanReplacesTheRecommendedRenderer() throws {
        let vulkan = try #require(GameRenderers.renderers(appID: 284160).first { $0.id == "vulkan" })
        #expect(GameRenderers.apply(vulkan, to: ["-gfx", "dx11"]) == ["-gfx", "vulkan"])
        #expect(GameRenderers.apply(vulkan, to: ["-console", "-GFX", "dx12", "-nosteam"]) == ["-console", "-nosteam", "-gfx", "vulkan"])
        #expect(GameRenderers.apply(nil, to: ["-gfx", "dx11"]) == ["-gfx", "dx11"])
        #expect(GameRenderers.renderers(appID: 440).isEmpty)
    }

    @Test func olderSettingsHaveNoRenderer() throws {
        let old = Data(#"{"graphics":"dxmt","arguments":"","useRecommended":true,"environment":{}}"#.utf8)
        #expect(try JSONDecoder().decode(TitleSettings.self, from: old).gameRenderer == nil)
        var settings = TitleSettings()
        settings.gameRenderer = "vulkan"
        let again = try JSONDecoder().decode(TitleSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.gameRenderer == "vulkan")
    }
}
