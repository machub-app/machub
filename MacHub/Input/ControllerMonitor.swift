import Foundation
import GameController
import Observation

/// Controller families macOS's Game Controller framework names through `productCategory`.
/// Only used for labels and guidance: MacHub never assumes a family works in a given Windows game.
enum ControllerFamily: String, Sendable, CaseIterable {
    case xbox, dualSense, dualShock, switchPro, joyCon, mfi, other

    static func classify(productCategory: String, vendorName: String?) -> ControllerFamily {
        let text = (productCategory + " " + (vendorName ?? "")).lowercased()
        if text.contains("xbox") { return .xbox }
        if text.contains("dualsense") { return .dualSense }
        if text.contains("dualshock") { return .dualShock }
        if text.contains("switch pro") { return .switchPro }
        if text.contains("joy-con") || text.contains("joycon") { return .joyCon }
        if text.contains("mfi") { return .mfi }
        return .other
    }

    var symbol: String {
        switch self {
        case .xbox: "xbox.logo"
        case .dualSense, .dualShock: "playstation.logo"
        default: "gamecontroller.fill"
        }
    }
}

/// What MacHub shows about one controller. Everything here comes from the framework, never guessed.
struct ConnectedController: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let productCategory: String
    let family: ControllerFamily
    /// A full gamepad (two sticks, triggers): what Windows games expect.
    let hasExtendedGamepad: Bool
    let hasHaptics: Bool
    /// nil when the controller doesn't report a battery (wired pads, some third-party pads).
    let batteryLevel: Float?
    let isCharging: Bool

    @MainActor
    init(_ controller: GCController) {
        id = ObjectIdentifier(controller).hashValue
        productCategory = controller.productCategory
        name = controller.vendorName.flatMap { $0.isEmpty ? nil : $0 } ?? controller.productCategory
        family = ControllerFamily.classify(productCategory: controller.productCategory, vendorName: controller.vendorName)
        hasExtendedGamepad = controller.extendedGamepad != nil
        hasHaptics = controller.haptics != nil
        if let battery = controller.battery, battery.batteryState != .unknown {
            batteryLevel = battery.batteryLevel
            isCharging = battery.batteryState == .charging || battery.batteryState == .full
        } else {
            batteryLevel = nil
            isCharging = false
        }
    }

    init(id: Int, name: String, productCategory: String, hasExtendedGamepad: Bool = true, hasHaptics: Bool = false,
         batteryLevel: Float? = nil, isCharging: Bool = false) {
        self.id = id
        self.name = name
        self.productCategory = productCategory
        family = ControllerFamily.classify(productCategory: productCategory, vendorName: name)
        self.hasExtendedGamepad = hasExtendedGamepad
        self.hasHaptics = hasHaptics
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
    }

    /// Display name: "Xbox One" reads better than the vendor's "Controller".
    var displayName: String {
        name.caseInsensitiveCompare("Controller") == .orderedSame || name == productCategory
            ? productCategory : "\(name) · \(productCategory)"
    }
}

/// Live list of the controllers macOS exposes to MacHub, refreshed on every connect/disconnect.
@MainActor @Observable
final class ControllerMonitor {
    struct Event: Identifiable, Equatable {
        enum Kind: Equatable { case connected, disconnected }
        let id = UUID()
        let kind: Kind
        let name: String
        let date: Date
    }

    private(set) var controllers: [ConnectedController] = []
    /// Most recent first, at most a handful: shows the user that a plug/unplug was really seen.
    private(set) var events: [Event] = []
    private(set) var isSearchingWireless = false
    private(set) var lastRefresh: Date?

    private let source: @MainActor () -> [GCController]
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var live: [Int: GCController] = [:]
    private var started = false

    init(center: NotificationCenter = .default, source: @escaping @MainActor () -> [GCController] = { GCController.controllers() }) {
        self.center = center
        self.source = source
    }

    func start() {
        guard !started else { return }
        started = true
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Delivered on the main queue (queue: .main), where GCController objects live.
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    let controllerName = (object as? GCController).map { ConnectedController($0).displayName }
                    self?.handle(name == .GCControllerDidConnect ? .connected : .disconnected, name: controllerName)
                }
            })
        }
        refresh()
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers = []
        started = false
    }

    func refresh() {
        let found = source()
        live = Dictionary(found.map { (ObjectIdentifier($0).hashValue, $0) }, uniquingKeysWith: { a, _ in a })
        controllers = found.map(ConnectedController.init)
        lastRefresh = .now
    }

    /// The framework object behind a row, for the input test and haptics.
    func controller(id: ConnectedController.ID) -> GCController? { live[id] }

    /// Wireless discovery only finds MFi pads and Siri Remotes in pairing mode; Xbox and PlayStation pads
    /// pair through System Settings > Bluetooth. MacHub says so in the guide.
    func searchWireless() {
        isSearchingWireless = true
        GCController.startWirelessControllerDiscovery { [weak self] in
            Task { @MainActor in self?.isSearchingWireless = false; self?.refresh() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.isSearchingWireless else { return }
            GCController.stopWirelessControllerDiscovery()
        }
    }

    private func handle(_ kind: Event.Kind, name: String?) {
        let before = Set(controllers.map(\.id))
        refresh()
        let label = name ?? controllers.first { !before.contains($0.id) }?.displayName ?? "Controller"
        events.insert(Event(kind: kind, name: label, date: .now), at: 0)
        events = Array(events.prefix(5))
    }
}
