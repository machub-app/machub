import GameController
import SwiftUI

/// Settings > Controllers: what macOS sees, a live input test, how to connect, and what reaches Windows games.
struct ControllersView: View {
    @Environment(ControllerMonitor.self) private var monitor
    @Environment(LibraryStore.self) private var store
    @State private var testedID: ConnectedController.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                PageHeader(title: "Controllers", subtitle: "What your Mac sees, a quick button test, and what Windows games receive through Whisky.")
                ControllerStatusPanel(testedID: $testedID)
                if let id = testedID ?? monitor.controllers.first(where: \.hasExtendedGamepad)?.id,
                   let controller = monitor.controller(id: id),
                   let info = monitor.controllers.first(where: { $0.id == id }) {
                    ControllerTestPanel(controller: controller, info: info)
                        .id(id)
                }
                WindowsGamesPanel()
                ConnectGuide()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .toolbar {
            Button("Check again", systemImage: "arrow.clockwise") { monitor.refresh() }
                .help("Check the connected controllers again")
        }
        .onAppear { store.spotlight = nil }
        .onChange(of: monitor.controllers) {
            if let testedID, !monitor.controllers.contains(where: { $0.id == testedID }) { self.testedID = nil }
        }
    }
}

// MARK: - Status

private struct ControllerStatusPanel: View {
    @Binding var testedID: ConnectedController.ID?
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if monitor.controllers.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No controller connected").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Turn your controller on and pair it in Bluetooth settings, or plug it in with a USB cable. This page updates by itself as soon as macOS sees it.")
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button {
                                SystemSettings.open(.bluetooth)
                            } label: {
                                Label("Open Bluetooth settings", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(SecondaryActionStyle())
                            Button {
                                monitor.refresh()
                            } label: {
                                Label("Check again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(SecondaryActionStyle())
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(20)
            } else {
                ForEach(monitor.controllers) { controller in
                    ControllerRow(controller: controller, isTested: (testedID ?? monitor.controllers.first(where: \.hasExtendedGamepad)?.id) == controller.id) {
                        testedID = controller.id
                    }
                    if controller.id != monitor.controllers.last?.id { Divider().overlay(Theme.stroke) }
                }
            }
            if let event = monitor.events.first {
                Divider().overlay(Theme.stroke)
                HStack(spacing: 8) {
                    Image(systemName: event.kind == .connected ? "link" : "link.badge.plus")
                        .symbolRenderingMode(.hierarchical)
                    Text(event.kind == .connected ? "\(event.name) connected" : "\(event.name) disconnected")
                    Text(event.date, style: .relative)
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .animation(.snappy, value: monitor.controllers)
    }
}

private struct ControllerRow: View {
    let controller: ConnectedController
    let isTested: Bool
    let test: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: controller.family.symbol)
                .font(.system(size: 26))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: controller.displayName).font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Label("Connected", systemImage: "circle.fill")
                        .labelStyle(StatusDotStyle())
                        .foregroundStyle(Compatibility.great.tint)
                }
                HStack(spacing: 14) {
                    Text(controller.hasExtendedGamepad ? "Full gamepad: two sticks and triggers" : "Limited controller: not a full gamepad")
                    if let level = controller.batteryLevel {
                        Label {
                            Text(level, format: .percent.precision(.fractionLength(0)))
                        } icon: {
                            Image(systemName: controller.isCharging ? "battery.100percent.bolt" : batterySymbol(level))
                        }
                    }
                    if controller.hasHaptics { Label("Vibration", systemImage: "waveform") }
                }
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if controller.hasExtendedGamepad {
                Button(isTested ? "Testing below" : "Test", action: test)
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(isTested)
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }

    private func batterySymbol(_ level: Float) -> String {
        switch level {
        case ..<0.2: "battery.0percent"
        case ..<0.45: "battery.25percent"
        case ..<0.7: "battery.50percent"
        case ..<0.9: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

private struct StatusDotStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title.font(.caption.weight(.semibold))
        }
    }
}

// MARK: - Live input test

private struct ControllerTestPanel: View {
    let controller: GCController
    let info: ConnectedController
    @State private var tester = GamepadTester()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Button test").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(tester.checklist.completed) of \(tester.checklist.expected.count) checked")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(tester.checklist.isComplete ? Compatibility.great.tint : Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            Text("Press each button and push both sticks. Each control lights up when macOS receives it. MacHub must be the frontmost app for this test.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 28) {
                StickView(label: tester.labels[.leftStick]?.name ?? "Left stick", value: tester.reading.leftStick,
                          checked: tester.checklist.seen.contains(.leftStick))
                VStack(alignment: .leading, spacing: 10) {
                    TriggerBar(label: tester.labels[.leftTrigger]?.name ?? "LT", value: tester.reading.leftTrigger,
                               checked: tester.checklist.seen.contains(.leftTrigger))
                    TriggerBar(label: tester.labels[.rightTrigger]?.name ?? "RT", value: tester.reading.rightTrigger,
                               checked: tester.checklist.seen.contains(.rightTrigger))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(GamepadControl.allCases.filter { $0 != .leftStick && $0 != .rightStick && $0 != .leftTrigger && $0 != .rightTrigger }, id: \.self) { control in
                            if let label = tester.labels[control] {
                                ControlChip(name: Self.shortName(control).map { Text($0) } ?? Text(verbatim: label.name), symbol: label.symbol,
                                            pressed: tester.reading.pressed.contains(control),
                                            checked: tester.checklist.seen.contains(control))
                            }
                        }
                    }
                }
                StickView(label: tester.labels[.rightStick]?.name ?? "Right stick", value: tester.reading.rightStick,
                          checked: tester.checklist.seen.contains(.rightStick))
            }
            .padding(20)
            .background(Theme.surface, in: .rect(cornerRadius: 14))

            HStack(spacing: 12) {
                Button("Start over") { tester.reset() }.buttonStyle(SecondaryActionStyle())
                if info.hasHaptics {
                    Button {
                        tester.pulse()
                    } label: {
                        Label("Test vibration", systemImage: "waveform")
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(tester.hapticsState == .playing)
                }
                switch tester.hapticsState {
                case .unavailable: Text("This controller doesn't accept vibration from macOS.").foregroundStyle(Theme.textSecondary)
                case .failed: Text("Vibration couldn't start.").foregroundStyle(Compatibility.issues.tint)
                default: EmptyView()
                }
                Spacer()
                if tester.checklist.isComplete {
                    Label("All controls received by macOS", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Compatibility.great.tint)
                        .transition(.opacity)
                }
            }
            .font(.callout)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: tester.reading)
        .onAppear { tester.attach(controller) }
        .onDisappear { tester.detach() }
    }

    /// macOS names D-pad directions with long phrases ("Directional pad (up)"); the arrow symbol says the rest.
    static func shortName(_ control: GamepadControl) -> LocalizedStringKey? {
        switch control {
        case .dpadUp: "D-pad up"
        case .dpadDown: "D-pad down"
        case .dpadLeft: "D-pad left"
        case .dpadRight: "D-pad right"
        default: nil
        }
    }
}

private struct ControlChip: View {
    let name: Text
    let symbol: String
    let pressed: Bool
    let checked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15))
            name.font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if checked { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Compatibility.great.tint) }
        }
        .foregroundStyle(pressed ? Theme.ground : Theme.textPrimary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(pressed ? Theme.textPrimary : Theme.surfaceRaised, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(pressed ? Text("Pressed") : (checked ? Text("Checked") : Text("Not yet pressed")))
    }
}

private struct StickView: View {
    let label: String
    let value: CGPoint
    let checked: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.surfaceRaised)
                Circle().strokeBorder(Theme.stroke)
                Path { p in
                    p.move(to: CGPoint(x: 60, y: 6)); p.addLine(to: CGPoint(x: 60, y: 114))
                    p.move(to: CGPoint(x: 6, y: 60)); p.addLine(to: CGPoint(x: 114, y: 60))
                }
                .stroke(Theme.stroke, lineWidth: 1)
                Circle()
                    .fill(checked ? Compatibility.great.tint : Theme.textPrimary)
                    .frame(width: 22, height: 22)
                    .offset(x: value.x * 46, y: -value.y * 46)
            }
            .frame(width: 120, height: 120)
            HStack(spacing: 4) {
                Text(verbatim: label)
                if checked { Image(systemName: "checkmark").foregroundStyle(Compatibility.great.tint) }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: String(format: "x %.2f, y %.2f", value.x, value.y)))
    }
}

private struct TriggerBar: View {
    let label: String
    let value: Float
    let checked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: label).font(.caption).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceRaised)
                    Capsule().fill(checked ? Compatibility.great.tint : Theme.textPrimary)
                        .frame(width: max(0, geo.size.width * CGFloat(value)))
                }
            }
            .frame(height: 8)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary).frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Windows games

/// The honest part: macOS seeing a controller doesn't prove a Windows game will. Wine's own panel is the check.
private struct WindowsGamesPanel: View {
    @Environment(LibraryStore.self) private var store
    @State private var opening: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("In Windows games").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            Text("Seeing a controller here means macOS receives it. A Windows game gets it through Wine inside the Whisky bottle, which presents it to Windows as an XInput or DirectInput device. To check that step, open Windows' own Game Controllers panel in the bottle: your controller should be listed there.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                let bottles = store.registeredBottles.filter(\.hasDriveC)
                if bottles.isEmpty {
                    Text("No set-up Whisky bottle yet, so there is nothing to check on the Windows side.")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(20)
                }
                ForEach(bottles) { bottle in
                    let name = bottle.name ?? "—"
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: name).font(.headline).foregroundStyle(Theme.textPrimary)
                            if let input = bottle.input {
                                Text(input.isDefault ? "Whisky controller options: default" : "Whisky controller options: customised")
                                    .font(.callout).foregroundStyle(Theme.textSecondary)
                                if !input.isDefault {
                                    VStack(alignment: .leading, spacing: 2) {
                                        if input.compatibilityMode { Text("Controller compatibility mode on") }
                                        if input.disableHIDAPI { Text("HIDAPI off (SDL_JOYSTICK_HIDAPI=0)") }
                                        if input.allowBackgroundEvents { Text("Input when unfocused (SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1)") }
                                        if input.useButtonLabels { Text("Native button labels (SDL_GAMECONTROLLER_USE_BUTTON_LABELS=1)") }
                                        if input.disableControllerMapping { Text("Controller mapping off") }
                                    }
                                    .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        Spacer()
                        Button {
                            opening = name
                            Task {
                                await store.openWindowsControllerPanel(bottle: name)
                                opening = nil
                            }
                        } label: {
                            if opening == name {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Opening…") }
                            } else {
                                Label("Check in Windows", systemImage: "macwindow.badge.plus")
                            }
                        }
                        .buttonStyle(SecondaryActionStyle())
                        .disabled(opening != nil || store.whiskyInstall == nil)
                        .help("Opens Wine's Game Controllers panel (joy.cpl) in this bottle. It changes nothing.")
                    }
                    .padding(20)
                    if bottle.id != bottles.last?.id { Divider().overlay(Theme.stroke) }
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: 14))

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    TroubleshootingItem(symbol: "list.bullet.rectangle", text: "Not listed in the Windows panel: quit the game and Steam in the bottle, reconnect the controller, then open the panel again. Wine only sees controllers connected when the bottle starts.")
                    TroubleshootingItem(symbol: "cable.connector", text: "Bluetooth trouble: try a USB cable. Some controllers expose more features over USB.")
                    TroubleshootingItem(symbol: "gearshape.2", text: "Listed but the game ignores it: check the game's own controller settings, and in Steam for Windows, Settings > Controller (Steam Input can take over the controller).")
                    TroubleshootingItem(symbol: "slider.horizontal.3", text: "Still nothing: Whisky's bottle settings have a Controller & Input section (compatibility mode, HIDAPI, button labels). MacHub shows them here but leaves them to Whisky.")
                    Button {
                        if let app = store.whiskyInstall?.appURL { NSWorkspace.shared.open(app) }
                    } label: {
                        Label("Open Whisky", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.link)
                    .disabled(store.whiskyInstall?.appURL == nil)
                }
                .padding(.top, 8)
            } label: {
                Text("If the game doesn't respond").font(.headline).foregroundStyle(Theme.textPrimary)
            }
            Text("MacHub can't tell whether a specific game supports controllers: no game is marked compatible until it has been checked.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct TroubleshootingItem: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(Theme.textPrimary.opacity(0.9))
    }
}

// MARK: - Guide

private struct ConnectGuide: View {
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect a controller").font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            HStack(alignment: .top, spacing: 16) {
                GuideCard(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth", steps: [
                    "Put the controller in pairing mode (see below).",
                    "Open Bluetooth settings and click Connect next to it.",
                    "Come back here: it appears on its own.",
                ]) {
                    Button { SystemSettings.open(.bluetooth) } label: {
                        Label("Open Bluetooth settings", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(SecondaryActionStyle())
                }
                GuideCard(symbol: "cable.connector", title: "USB", steps: [
                    "Plug the controller in with a data cable (some cables only charge).",
                    "Turn it on if it doesn't light up.",
                    "It appears here within a few seconds.",
                ]) {
                    Button { SystemSettings.open(.gameControllers) } label: {
                        Label("Game Controllers settings", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(SecondaryActionStyle())
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                PairingRow(symbol: "xbox.logo", name: "Xbox Wireless Controller", how: "Hold the pairing button on top until the Xbox button flashes quickly.")
                Divider().overlay(Theme.stroke)
                PairingRow(symbol: "playstation.logo", name: "DualSense (PS5)", how: "Hold Create and the PS button until the light bar flashes.")
                Divider().overlay(Theme.stroke)
                PairingRow(symbol: "playstation.logo", name: "DualShock 4 (PS4)", how: "Hold Share and the PS button until the light bar flashes.")
                Divider().overlay(Theme.stroke)
                PairingRow(symbol: "gamecontroller", name: "Nintendo Switch Pro Controller", how: "Hold the small sync button on top until the lights scroll.")
                Divider().overlay(Theme.stroke)
                PairingRow(symbol: "gamecontroller", name: "MFi controllers", how: "Put the controller in pairing mode, then search from here.") {
                    Button(monitor.isSearchingWireless ? "Searching…" : "Search") { monitor.searchWireless() }
                        .disabled(monitor.isSearchingWireless)
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: 14))
            Text("These are the families macOS supports. MacHub lists any controller macOS exposes, but only checks what macOS itself reports.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct GuideCard<Action: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let steps: [LocalizedStringKey]
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "\(index + 1)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        Text(step).foregroundStyle(Theme.textPrimary.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            action
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
    }
}

private struct PairingRow<Accessory: View>: View {
    let symbol: String
    let name: LocalizedStringKey
    let how: LocalizedStringKey
    @ViewBuilder var accessory: Accessory

    init(symbol: String, name: LocalizedStringKey, how: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.symbol = symbol
        self.name = name
        self.how = how
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.textSecondary)
            Text(name).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary).frame(width: 250, alignment: .leading)
            Text(how).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Deep links into System Settings panes. Only opens; MacHub never changes system settings.
enum SystemSettings {
    case bluetooth, gameControllers

    var url: URL {
        switch self {
        case .bluetooth: URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
        case .gameControllers: URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!
        }
    }

    static func open(_ pane: SystemSettings) { NSWorkspace.shared.open(pane.url) }
}

/// A compact summary for the main Settings page, linking to the full Controllers page.
struct ControllerSettingsSection: View {
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        Section {
            NavigationLink(value: SettingsPage.controllers) {
                HStack(spacing: 12) {
                    Image(systemName: monitor.controllers.first?.family.symbol ?? "gamecontroller")
                        .font(.title2)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        if let first = monitor.controllers.first {
                            Text(verbatim: first.displayName)
                            Text(monitor.controllers.count > 1 ? "\(monitor.controllers.count) controllers connected" : "Connected")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No controller connected")
                            Text("Connect, test and check in Windows games").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Controllers")
        }
    }
}

enum SettingsPage: Hashable {
    case controllers
}
