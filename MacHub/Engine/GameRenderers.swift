import Foundation

/// Games that choose their own renderer with a launch option. MacHub's Direct3D layer (DXMT/DXVK) only matters for
/// Direct3D; a game's Vulkan renderer goes straight to Wine's winevulkan and MoltenVK (shipped in the engine).
/// DirectX 12 isn't offered: it needs D3DMetal, which MacHub doesn't route yet.
enum GameRenderers {
    struct Renderer: Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let detail: String
        /// The launch option pair that selects it, e.g. ["-gfx", "vulkan"].
        let arguments: [String]
    }

    static func renderers(appID: Int?) -> [Renderer] {
        switch appID {
        case 284160:   // BeamNG.drive: `-gfx dx11|dx12|vulkan`
            [Renderer(id: "dx11", label: "DirectX 11", detail: "Through MacHub's Direct3D layer (DXMT by default). Tested on this Mac.",
                      arguments: ["-gfx", "dx11"]),
             Renderer(id: "vulkan", label: "Vulkan (MoltenVK)", detail: "BeamNG's Vulkan renderer, straight to Metal through MoltenVK. Not tested yet: if the game doesn't start or shows a black screen, choose Automatic again.",
                      arguments: ["-gfx", "vulkan"])]
        default: []
        }
    }

    /// The launch options with the chosen renderer: any renderer option already there is replaced.
    static func apply(_ renderer: Renderer?, to options: [String]) -> [String] {
        guard let renderer, let flag = renderer.arguments.first else { return options }
        var result: [String] = []
        var index = options.startIndex
        while index < options.endIndex {
            if options[index].caseInsensitiveCompare(flag) == .orderedSame {
                index += 2   // the flag and its value
                continue
            }
            result.append(options[index])
            index += 1
        }
        return result + renderer.arguments
    }
}
