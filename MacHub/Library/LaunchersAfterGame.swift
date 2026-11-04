import Foundation

/// Steam for Mac and Astris, when MacHub started them for a game, quit once that game is closed (default on).
/// A launcher that was already open before stays open.
enum LaunchersAfterGame {
    static let key = "launchers.quitAfterGame"

    static var quitWhenGameCloses: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
