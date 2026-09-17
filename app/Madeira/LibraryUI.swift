import SwiftUI
import UIKit
import PhotosUI
import GameController
import os

// SteamOS-style front end: home with a hero banner and shelves, a library grid,
// a game page with per-game settings, a main menu, and controller navigation.
// The original tooling UI is still reachable as Developer Tools.

// MARK: - Theme

enum Deck {
    static let bg0 = Color(red: 0.047, green: 0.063, blue: 0.086)      // #0C1016
    static let bg1 = Color(red: 0.090, green: 0.114, blue: 0.145)      // #171D25
    static let panel = Color(red: 0.125, green: 0.141, blue: 0.173)    // #20242C
    static let panelHi = Color(red: 0.180, green: 0.200, blue: 0.239)  // #2E333D
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.102, green: 0.624, blue: 1.0)     // #1A9FFF
    static let accentDeep = Color(red: 0.020, green: 0.420, blue: 0.850)
    static let text = Color(red: 0.863, green: 0.871, blue: 0.875)
    static let dim = Color(red: 0.545, green: 0.573, blue: 0.604)
    static let good = Color(red: 0.365, green: 0.800, blue: 0.353)
    static let warn = Color(red: 1.0, green: 0.690, blue: 0.227)
    static let bad = Color(red: 0.937, green: 0.325, blue: 0.314)

    static var background: some View {
        ZStack {
            LinearGradient(colors: [bg1, bg0], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.10), .clear], center: .topLeading,
                           startRadius: 10, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

struct DeckButtonStyle: ButtonStyle {
    var prominent = false
    var focused = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Deck.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent
                          ? AnyShapeStyle(LinearGradient(colors: [Deck.accent, Deck.accentDeep],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Deck.panelHi))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(focused ? Color.white : Deck.stroke, lineWidth: focused ? 2 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Controller navigation

/// Game controllers drive the library UI directly (SwiftUI's focus engine does not
/// take gamepad input on iOS). Screens register a handler; the topmost wins.
@MainActor
final class ControllerHub: ObservableObject {
    static let shared = ControllerHub()

    enum Input { case up, down, left, right, confirm, back, menu, options, home, shoulderLeft, shoulderRight }

    @Published private(set) var connected: GCController?
    /// Disabled while a game session owns the screen.
    var enabled = true
    /// Selection haptics suit menus, not gameplay; the session turns them off.
    var feedback = true
    private var handlers: [(id: UUID, fn: (Input) -> Void)] = []
    private var repeatTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.attach(n.object as? GCController) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach(GCController.controllers().first) }
        }
        attach(GCController.controllers().first)
        GCController.startWirelessControllerDiscovery {}
    }

    func push(_ fn: @escaping (Input) -> Void) -> UUID {
        let id = UUID()
        handlers.append((id, fn))
        return id
    }
    func pop(_ id: UUID) { handlers.removeAll { $0.id == id } }

    private func send(_ i: Input) {
        guard enabled, let h = handlers.last else { return }
        if feedback { UISelectionFeedbackGenerator().selectionChanged() }
        h.fn(i)
    }

    private func attach(_ c: GCController?) {
        connected = c
        guard let pad = c?.extendedGamepad else { return }
        let bind: (GCControllerButtonInput?, Input) -> Void = { button, input in
            button?.pressedChangedHandler = { _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in ControllerHub.shared.send(input) }
            }
        }
        bind(pad.buttonA, .confirm)
        bind(pad.buttonB, .back)
        bind(pad.buttonMenu, .menu)
        bind(pad.buttonOptions, .options)
        bind(pad.buttonHome, .home)
        // The Home/Guide button opens Quick Access in game. Without this iOS
        // takes it for its own Game Center / launcher gesture.
        pad.buttonHome?.preferredSystemGestureState = .disabled
        bind(pad.leftShoulder, .shoulderLeft)
        bind(pad.rightShoulder, .shoulderRight)
        pad.dpad.valueChangedHandler = { _, x, y in
            let input: Input? = y > 0.5 ? .up : y < -0.5 ? .down : x > 0.5 ? .right : x < -0.5 ? .left : nil
            Task { @MainActor in ControllerHub.shared.directional(input) }
        }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in
            let input: Input? = y > 0.7 ? .up : y < -0.7 ? .down : x > 0.7 ? .right : x < -0.7 ? .left : nil
            Task { @MainActor in ControllerHub.shared.directional(input) }
        }
    }

    private var heldDirection: Input?
    /// One step on press, then auto-repeat after a short delay, like SteamOS.
    private func directional(_ input: Input?) {
        guard input != heldDirection else { return }
        heldDirection = input
        repeatTask?.cancel()
        guard let input else { return }
        send(input)
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            while !Task.isCancelled, heldDirection == input {
                send(input)
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }
}

// MARK: - Play coordination

@MainActor
final class PlayCoordinator: ObservableObject {
    static let shared = PlayCoordinator()

    @Published var sessionGame: GameEntry?
    @Published var waitingForJIT: GameEntry?
    @Published var alert: String?

    func play(_ game: GameEntry) {
        let launcher = WineLauncher.shared
        if launcher.hasStarted {
            if launcher.activeGameID == game.id {
                sessionGame = game
            } else {
                alert = "Windows is already running another title in this session. Close Madeira from the Quick Access menu, reopen it, then launch \(game.title)."
            }
            return
        }
        if game.detected.is32Bit {
            alert = "\(game.title) is a 32-bit executable. Madeira runs x86-64 programs only."
            return
        }
        guard FileManager.default.fileExists(atPath: game.unixExe.path) else {
            alert = "The executable is missing:\n\(game.windowsExe)"
            return
        }
        if jit_check_debugged() {
            sessionGame = game
            return
        }
        waitingForJIT = game
        StikJITHelper.enableJIT { ok in
            DispatchQueue.main.async {
                guard self.waitingForJIT?.id == game.id else { return }
                self.waitingForJIT = nil
                if ok { self.sessionGame = game }
                else { self.alert = "StikDebug did not attach. Open StikDebug, make sure Madeira is enabled for JIT, and try again." }
            }
        }
    }
}

// MARK: - Root

struct RootView: View {
    enum Route: Hashable { case home, library, settings }

    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var play = PlayCoordinator.shared
    @ObservedObject private var controller = ControllerHub.shared
    @State private var route: Route = .home
    @State private var menuOpen = false
    @State private var detailGame: GameEntry?
    @State private var showAddGame = false
    @State private var showDeveloper = false

    var body: some View {
        ZStack(alignment: .leading) {
            Deck.background
            VStack(spacing: 0) {
                DeckTopBar(menuOpen: $menuOpen)
                Group {
                    switch route {
                    case .home:
                        HomeScreen(openGame: { detailGame = $0 }, addGame: { showAddGame = true })
                    case .library:
                        LibraryScreen(openGame: { detailGame = $0 }, addGame: { showAddGame = true })
                    case .settings:
                        SettingsScreen(openDeveloper: { showDeveloper = true })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if controller.connected != nil {
                    ControllerHintBar(hints: [("A", "Select"), ("B", "Back"), ("☰", "Menu")])
                }
            }
            if menuOpen {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { menuOpen = false } }
                    .transition(.opacity)
                MainMenu(route: $route, open: $menuOpen,
                         addGame: { showAddGame = true },
                         developer: { showDeveloper = true })
                    .transition(.move(edge: .leading))
            }
        }
        .preferredColorScheme(.dark)
        .tint(Deck.accent)
        .fullScreenCover(item: $detailGame) { g in
            GameDetailScreen(gameID: g.id)
        }
        .fullScreenCover(item: $play.sessionGame) { g in
            GameSessionView(game: g)
        }
        .sheet(isPresented: $showAddGame) { AddGameSheet() }
        .fullScreenCover(isPresented: $showDeveloper) { DeveloperToolsHost() }
        .overlay { if let g = play.waitingForJIT { JITWaitOverlay(game: g) } }
        .alert("Madeira", isPresented: Binding(get: { play.alert != nil }, set: { if !$0 { play.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(play.alert ?? "") }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            jit_install_trap_handler()
            GamepadBridge.shared.start()   // before any launch: publishes MADEIRA_PAD_SHM
        }
        .modifier(ControllerHandler { input in
            if input == .menu || input == .home { withAnimation(.easeOut(duration: 0.2)) { menuOpen.toggle() } }
        })
    }
}

/// Registers a controller handler for the lifetime of a view.
struct ControllerHandler: ViewModifier {
    let fn: (ControllerHub.Input) -> Void
    @State private var token: UUID?
    func body(content: Content) -> some View {
        content
            .onAppear { token = ControllerHub.shared.push(fn) }
            .onDisappear { if let t = token { ControllerHub.shared.pop(t) } }
    }
}

// MARK: - Top bar

struct DeckTopBar: View {
    @Binding var menuOpen: Bool
    @ObservedObject private var controller = ControllerHub.shared
    @State private var jitAttached = isDebuggerAttached()
    @State private var battery: Float = UIDevice.current.batteryLevel
    @State private var charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    @State private var availableMB = Int(os_proc_available_memory() / 1_048_576)
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 14) {
            Button { withAnimation(.easeOut(duration: 0.2)) { menuOpen.toggle() } } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Deck.text)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Deck.panel))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: "hexagon.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Deck.accent, Deck.accentDeep], startPoint: .top, endPoint: .bottom))
                Text("MADEIRA")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(Deck.text)
            }

            Spacer(minLength: 8)

            jitPill
            statusPill(icon: "memorychip", text: String(format: "%.1f GB", Double(availableMB) / 1024), tint: Deck.dim)
            if controller.connected != nil {
                Image(systemName: "gamecontroller.fill").foregroundStyle(Deck.text).font(.system(size: 15))
            }
            batteryView
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Deck.text)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Deck.bg0.opacity(0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(Deck.stroke).frame(height: 1) }
        .onReceive(tick) { _ in
            jitAttached = isDebuggerAttached()
            battery = UIDevice.current.batteryLevel
            charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            availableMB = Int(os_proc_available_memory() / 1_048_576)
        }
    }

    private var jitPill: some View {
        Button {
            if !jitAttached { StikJITHelper.enableJIT { _ in } }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(jitAttached ? Deck.good : Deck.warn).frame(width: 8, height: 8)
                Text(jitAttached ? "JIT" : "Enable JIT")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Deck.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Deck.panel))
        }
        .buttonStyle(.plain)
    }

    private func statusPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Deck.panel))
    }

    private var batteryView: some View {
        let pct = battery < 0 ? nil : Int((battery * 100).rounded())
        let symbol: String = {
            guard let p = pct else { return "battery.100" }
            if charging { return "battery.100.bolt" }
            switch p { case ..<13: return "battery.0"; case ..<38: return "battery.25"; case ..<63: return "battery.50"
                       case ..<88: return "battery.75"; default: return "battery.100" }
        }()
        return HStack(spacing: 4) {
            if let p = pct { Text("\(p)%").font(.system(size: 13, weight: .semibold)).monospacedDigit() }
            Image(systemName: symbol).font(.system(size: 15))
        }
        .foregroundStyle((pct ?? 100) <= 15 && !charging ? Deck.bad : Deck.text)
    }
}

struct ControllerHintBar: View {
    let hints: [(String, String)]
    var body: some View {
        HStack(spacing: 22) {
            Spacer()
            ForEach(hints, id: \.0) { h in
                HStack(spacing: 7) {
                    Text(h.0)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Deck.bg0)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Deck.text))
                    Text(h.1).font(.system(size: 13, weight: .medium)).foregroundStyle(Deck.text)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Deck.bg0.opacity(0.7))
    }
}

// MARK: - Main menu

struct MainMenu: View {
    @Binding var route: RootView.Route
    @Binding var open: Bool
    let addGame: () -> Void
    let developer: () -> Void
    @State private var focus = 0
    @State private var confirmQuit = false

    private var items: [(String, String, () -> Void)] {
        [("house.fill", "Home", { route = .home; close() }),
         ("square.grid.2x2.fill", "Library", { route = .library; close() }),
         ("plus.app.fill", "Add a Game", { close(); addGame() }),
         ("gearshape.fill", "Settings", { route = .settings; close() }),
         ("wrench.and.screwdriver.fill", "Developer Tools", { close(); developer() }),
         ("power", "Quit Madeira", { confirmQuit = true })]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "hexagon.fill").font(.system(size: 26)).foregroundStyle(Deck.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MADEIRA").font(.system(size: 18, weight: .heavy, design: .rounded)).tracking(2)
                    Text("Windows games on iPhone").font(.system(size: 12)).foregroundStyle(Deck.dim)
                }
            }
            .padding(.bottom, 18)
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button(action: item.2) {
                    HStack(spacing: 14) {
                        Image(systemName: item.0).font(.system(size: 17)).frame(width: 26)
                        Text(item.1).font(.system(size: 17, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(i == focus ? Color.white : Deck.text)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(i == focus ? Deck.accent.opacity(0.9) : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(appVersion).font(.system(size: 11)).foregroundStyle(Deck.dim)
        }
        .padding(22)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Deck.bg0.shadow(.drop(color: .black.opacity(0.6), radius: 24)))
        .ignoresSafeArea(edges: .vertical)
        .confirmationDialog("Quit Madeira?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Quit", role: .destructive) { exit(0) }
        } message: { Text("Any running game is closed without saving.") }
        .modifier(ControllerHandler { input in
            switch input {
            case .up: focus = (focus + items.count - 1) % items.count
            case .down: focus = (focus + 1) % items.count
            case .confirm: items[focus].2()
            case .back, .menu: close()
            default: break
            }
        })
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "Madeira \(v) · private build"
    }

    private func close() { withAnimation(.easeOut(duration: 0.2)) { open = false } }
}

// MARK: - Cover art

@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, UIImage>()
    func image(for id: String, version: Int) -> UIImage? {
        let key = "\(id)#\(version)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = GameLibrary.shared.coverImage(id) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

struct GeneratedCover: View {
    let title: String
    let seed: String
    let subtitle: String

    var body: some View {
        let h = Double(UInt64(seed.prefix(8), radix: 16) ?? 0) / Double(UInt32.max)
        let c1 = Color(hue: h, saturation: 0.55, brightness: 0.42)
        let c2 = Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.16)
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "hexagon")
                    .resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.06))
                    .frame(width: geo.size.width * 1.1)
                    .offset(x: geo.size.width * 0.35, y: -geo.size.height * 0.15)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: max(13, geo.size.width * 0.11), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    Text(subtitle.uppercased())
                        .font(.system(size: max(8, geo.size.width * 0.05), weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(geo.size.width * 0.08)
            }
        }
    }
}

struct CoverArt: View {
    let game: GameEntry
    var cornerRadius: CGFloat = 10
    @ObservedObject private var library = GameLibrary.shared
    @AppStorage("coverVersion") private var coverVersion = 0

    var body: some View {
        ZStack {
            if let img = CoverCache.shared.image(for: game.id, version: coverVersion) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                GeneratedCover(title: game.title, seed: game.id, subtitle: game.detected.engine.label)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct CapsuleCard: View {
    let game: GameEntry
    var focused = false
    var width: CGFloat = 138

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverArt(game: game)
                .frame(width: width, height: width * 1.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(focused ? Color.white : Color.white.opacity(0.06), lineWidth: focused ? 3 : 1)
                )
                .shadow(color: focused ? Deck.accent.opacity(0.55) : .black.opacity(0.4),
                        radius: focused ? 16 : 6, y: focused ? 0 : 4)
                .overlay(alignment: .topTrailing) { apiBadge.padding(6) }
            Text(game.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(focused ? Color.white : Deck.text)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: focused)
    }

    private var apiBadge: some View {
        let dx12 = game.resolvedAPI == .dx12
        return Text(dx12 ? "DX12" : "DX11")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(dx12 ? Color.purple.opacity(0.85) : Deck.accentDeep.opacity(0.9)))
    }
}

// MARK: - Home

struct HomeScreen: View {
    let openGame: (GameEntry) -> Void
    let addGame: () -> Void
    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var play = PlayCoordinator.shared
    @State private var focusIndex = 0

    private var ordered: [GameEntry] {
        var seen = Set<String>()
        return (library.recent + library.alphabetical).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        if library.games.isEmpty {
            EmptyLibraryView(addGame: addGame)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if let hero = ordered.first {
                            HeroBanner(game: hero, focused: focusIndex == 0,
                                       play: { play.play(hero) }, details: { openGame(hero) })
                                .id("hero")
                        }
                        shelf(title: "Recent games", games: Array(library.recent.prefix(12)), offset: 1)
                        libraryGrid
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .onChange(of: focusIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(focusID(new), anchor: .center) }
                }
            }
            .modifier(ControllerHandler { input in handle(input) })
        }
    }

    // Focus order: hero (0), recent shelf, then the alphabetical grid.
    private var focusables: [GameEntry] {
        [ordered.first].compactMap { $0 } + Array(library.recent.prefix(12)) + library.alphabetical
    }
    private func focusID(_ i: Int) -> String {
        guard i > 0, i < focusables.count else { return "hero" }
        let recentCount = min(12, library.recent.count)
        return i <= recentCount ? "recent-\(focusables[i].id)" : "grid-\(focusables[i].id)"
    }

    private func handle(_ input: ControllerHub.Input) {
        let n = focusables.count
        guard n > 0 else { return }
        let recentCount = min(12, library.recent.count)
        switch input {
        case .left: focusIndex = max(0, focusIndex - 1)
        case .right: focusIndex = min(n - 1, focusIndex + 1)
        case .down:
            if focusIndex == 0 { focusIndex = min(n - 1, 1) }
            else if focusIndex <= recentCount { focusIndex = min(n - 1, recentCount + 1) }
            else { focusIndex = min(n - 1, focusIndex + 5) }
        case .up:
            if focusIndex > recentCount + 5 { focusIndex -= 5 }
            else if focusIndex > recentCount { focusIndex = recentCount > 0 ? 1 : 0 }
            else { focusIndex = 0 }
        case .confirm: openGame(focusables[min(focusIndex, n - 1)])
        case .options: play.play(focusables[min(focusIndex, n - 1)])
        default: break
        }
    }

    @ViewBuilder
    private func shelf(title: String, games: [GameEntry], offset: Int) -> some View {
        if !games.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(Array(games.enumerated()), id: \.element.id) { i, g in
                            Button { openGame(g) } label: {
                                CapsuleCard(game: g, focused: focusIndex == offset + i)
                            }
                            .buttonStyle(.plain)
                            .id("recent-\(g.id)")
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private var libraryGrid: some View {
        let recentCount = min(12, library.recent.count)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Library", trailing: "\(library.games.count) games")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138, maximum: 170), spacing: 18)], spacing: 22) {
                ForEach(Array(library.alphabetical.enumerated()), id: \.element.id) { i, g in
                    Button { openGame(g) } label: {
                        CapsuleCard(game: g, focused: focusIndex == 1 + recentCount + i)
                    }
                    .buttonStyle(.plain)
                    .id("grid-\(g.id)")
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Deck.dim)
            Spacer()
            if let t = trailing {
                Text(t).font(.system(size: 13)).foregroundStyle(Deck.dim)
            }
        }
    }
}

struct HeroBanner: View {
    let game: GameEntry
    var focused = false
    let play: () -> Void
    let details: () -> Void
    @ObservedObject private var launcher = WineLauncher.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverArt(game: game, cornerRadius: 0)
                .frame(maxWidth: .infinity)
                .frame(height: 250)
                .blur(radius: 26)
                .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.85)],
                                        startPoint: .top, endPoint: .bottom))
                .clipped()
            HStack(alignment: .bottom, spacing: 22) {
                CoverArt(game: game)
                    .frame(width: 130, height: 195)
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
                VStack(alignment: .leading, spacing: 10) {
                    Text(heroCaption)
                        .font(.system(size: 12, weight: .bold)).tracking(1.5)
                        .foregroundStyle(Deck.accent)
                    Text(game.title)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    BadgeRow(game: game)
                    HStack(spacing: 12) {
                        Button(action: play) {
                            Label(playLabel, systemImage: "play.fill").frame(minWidth: 120)
                        }
                        .buttonStyle(DeckButtonStyle(prominent: true, focused: focused))
                        Button(action: details) {
                            Image(systemName: "gearshape.fill")
                        }
                        .buttonStyle(DeckButtonStyle())
                    }
                }
                Spacer()
            }
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(focused ? Color.white.opacity(0.9) : Deck.stroke, lineWidth: focused ? 2 : 1))
    }

    private var heroCaption: String {
        if launcher.activeGameID == game.id { return "NOW RUNNING" }
        if let d = game.lastPlayed {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return "LAST PLAYED \(f.localizedString(for: d, relativeTo: Date()).uppercased())"
        }
        return "READY TO PLAY"
    }
    private var playLabel: String { launcher.activeGameID == game.id ? "Resume" : "Play" }
}

struct BadgeRow: View {
    let game: GameEntry
    var body: some View {
        HStack(spacing: 6) {
            badge(game.detected.engine.label, Deck.panelHi)
            ForEach(game.detected.apiLabels, id: \.self) { a in
                badge(a, a == "DX12" ? Color.purple.opacity(0.6) : Deck.accentDeep.opacity(0.7))
            }
            badge(game.profile.preset.label, Deck.panelHi)
            if game.detected.is32Bit { badge("32-bit", Deck.bad.opacity(0.7)) }
        }
    }
    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(c))
    }
}

struct EmptyLibraryView: View {
    let addGame: () -> Void
    @ObservedObject private var library = GameLibrary.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Deck.dim)
            Text("Your library is empty")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Copy an installed Windows game folder into\nFiles › On My iPhone › Madeira › wine › drive_c\nthen scan, or add its executable directly.")
                .multilineTextAlignment(.center)
                .font(.system(size: 15))
                .foregroundStyle(Deck.dim)
            HStack(spacing: 12) {
                Button { library.rescan() } label: {
                    Label(library.scanning ? "Scanning…" : "Scan drive_c", systemImage: "magnifyingglass")
                }
                .buttonStyle(DeckButtonStyle(prominent: true))
                .disabled(library.scanning)
                Button(action: addGame) { Label("Add executable", systemImage: "plus") }
                    .buttonStyle(DeckButtonStyle())
            }
            if let m = library.lastScanMessage {
                Text(m).font(.system(size: 13)).foregroundStyle(Deck.dim)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Library screen

struct LibraryScreen: View {
    let openGame: (GameEntry) -> Void
    let addGame: () -> Void
    @ObservedObject private var library = GameLibrary.shared
    @State private var filter = "All"
    @State private var query = ""
    @State private var focusIndex = 0

    private let filters = ["All", "DirectX 12", "DirectX 11", "Unreal", "Unity"]

    private var shown: [GameEntry] {
        library.alphabetical.filter { g in
            let f: Bool
            switch filter {
            case "DirectX 12": f = g.resolvedAPI == .dx12 || g.detected.usesD3D12
            case "DirectX 11": f = g.resolvedAPI == .dx11
            case "Unreal": f = g.detected.engine.isUnreal
            case "Unity": f = g.detected.engine == .unity
            default: f = true
            }
            return f && (query.isEmpty || g.title.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ForEach(filters, id: \.self) { f in
                    Button { filter = f; focusIndex = 0 } label: {
                        Text(f)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(filter == f ? Color.white : Deck.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(filter == f ? Deck.accent : Deck.panel))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Deck.dim)
                    TextField("Search", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(width: 160)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Deck.panel))
                Button { library.rescan() } label: {
                    Image(systemName: library.scanning ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(DeckButtonStyle())
                Button(action: addGame) { Image(systemName: "plus") }
                    .buttonStyle(DeckButtonStyle())
            }
            if library.games.isEmpty {
                EmptyLibraryView(addGame: addGame)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 138, maximum: 170), spacing: 18)], spacing: 22) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { i, g in
                                Button { openGame(g) } label: { CapsuleCard(game: g, focused: i == focusIndex) }
                                    .buttonStyle(.plain)
                                    .id(g.id)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .onChange(of: focusIndex) { _, i in
                        guard i < shown.count else { return }
                        withAnimation { proxy.scrollTo(shown[i].id, anchor: .center) }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .modifier(ControllerHandler { input in
            let n = shown.count
            guard n > 0 else { return }
            switch input {
            case .left: focusIndex = max(0, focusIndex - 1)
            case .right: focusIndex = min(n - 1, focusIndex + 1)
            case .up: focusIndex = max(0, focusIndex - 5)
            case .down: focusIndex = min(n - 1, focusIndex + 5)
            case .shoulderLeft, .shoulderRight:
                let i = filters.firstIndex(of: filter) ?? 0
                let next = input == .shoulderRight ? (i + 1) % filters.count : (i + filters.count - 1) % filters.count
                filter = filters[next]; focusIndex = 0
            case .confirm: openGame(shown[min(focusIndex, n - 1)])
            case .options: PlayCoordinator.shared.play(shown[min(focusIndex, n - 1)])
            default: break
            }
        })
    }
}

// MARK: - Game page

struct GameDetailScreen: View {
    let gameID: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var launcher = WineLauncher.shared
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmRemove = false
    @AppStorage("coverVersion") private var coverVersion = 0

    var body: some View {
        if let game = library.game(gameID) {
            content(game)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func binding(_ game: GameEntry) -> Binding<GameProfile> {
        Binding(get: { library.game(gameID)?.profile ?? game.profile },
                set: { p in
                    guard var g = library.game(gameID) else { return }
                    g.profile = p
                    library.update(g)
                })
    }

    @ViewBuilder
    private func content(_ game: GameEntry) -> some View {
        let profile = binding(game)
        ZStack(alignment: .topLeading) {
            Deck.background
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(game)
                    if !game.compatibilityNotes.isEmpty { notes(game) }
                    ProfileEditor(game: game, profile: profile)
                    launchPlan(game)
                    infoPanel(game)
                }
                .padding(.bottom, 40)
            }
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .padding(18)
        }
        .preferredColorScheme(.dark)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    library.setCover(gameID, data: data)
                    coverVersion += 1
                }
            }
        }
        .confirmationDialog("Remove \(game.title) from the library?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { library.remove(gameID); dismiss() }
        } message: { Text("Game files stay in drive_c. Only the library entry, settings and cover are removed.") }
        .modifier(ControllerHandler { input in
            switch input {
            case .back: dismiss()
            case .confirm, .options: PlayCoordinator.shared.play(game)
            default: break
            }
        })
    }

    private func header(_ game: GameEntry) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverArt(game: game, cornerRadius: 0)
                .frame(maxWidth: .infinity).frame(height: 300)
                .blur(radius: 30)
                .overlay(LinearGradient(colors: [.black.opacity(0.1), Deck.bg0], startPoint: .top, endPoint: .bottom))
                .clipped()
            HStack(alignment: .bottom, spacing: 24) {
                CoverArt(game: game)
                    .frame(width: 150, height: 225)
                    .shadow(color: .black.opacity(0.7), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 12) {
                    Text(game.title)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    BadgeRow(game: game)
                    HStack(spacing: 12) {
                        Button { PlayCoordinator.shared.play(game) } label: {
                            Label(launcher.activeGameID == game.id ? "Resume" : "Play", systemImage: "play.fill")
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(DeckButtonStyle(prominent: true))
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Cover", systemImage: "photo")
                        }
                        .buttonStyle(DeckButtonStyle())
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(DeckButtonStyle())
                    }
                    if let d = game.lastPlayed {
                        Text("Played \(game.launches)× · last \(d.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(Deck.dim)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)
        }
    }

    private func notes(_ game: GameEntry) -> some View {
        DeckPanel(title: "Compatibility", symbol: "exclamationmark.triangle.fill", tint: Deck.warn) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(game.compatibilityNotes, id: \.self) { n in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Deck.warn).frame(width: 5, height: 5).padding(.top, 7)
                        Text(n).font(.system(size: 14)).foregroundStyle(Deck.text)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
    }

    private func launchPlan(_ game: GameEntry) -> some View {
        let plan = WineLauncher.plan(for: game)
        return DeckPanel(title: "Launch plan", symbol: "list.bullet.rectangle", tint: Deck.accent) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.summary, id: \.self) { s in
                    Text(s).font(.system(size: 14, weight: .semibold)).foregroundStyle(Deck.text)
                }
                Text("\(game.windowsExe) \(plan.env["MADEIRA_ARGS"] ?? "")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Deck.dim)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 28)
    }

    private func infoPanel(_ game: GameEntry) -> some View {
        DeckPanel(title: "Details", symbol: "info.circle", tint: Deck.dim) {
            VStack(alignment: .leading, spacing: 6) {
                infoRow("Executable", game.windowsExe)
                infoRow("Size", ByteCountFormatter.string(fromByteCount: game.detected.exeBytes, countStyle: .file))
                infoRow("Architecture", game.detected.is64Bit ? "x86-64" : game.detected.is32Bit ? "x86 (32-bit)" : "unknown")
                infoRow("Imports", game.detected.imports.filter { !$0.hasPrefix("api-ms-") }.prefix(24).joined(separator: ", "))
            }
        }
        .padding(.horizontal, 28)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.dim).frame(width: 110, alignment: .leading)
            Text(v).font(.system(size: 13)).foregroundStyle(Deck.text).textSelection(.enabled)
        }
    }
}

struct DeckPanel<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = Deck.accent
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title.uppercased()).font(.system(size: 13, weight: .bold)).tracking(1.4).foregroundStyle(Deck.dim)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Deck.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Deck.stroke))
    }
}

struct ProfileEditor: View {
    let game: GameEntry
    @Binding var profile: GameProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeckPanel(title: "Performance", symbol: "gauge.with.dots.needle.67percent") {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(PerformancePreset.allCases) { p in presetCard(p) }
                    }
                    Text(profile.preset.blurb).font(.system(size: 13)).foregroundStyle(Deck.dim)
                }
            }
            DeckPanel(title: "Graphics", symbol: "display") {
                VStack(alignment: .leading, spacing: 14) {
                    row("Graphics API") {
                        Picker("", selection: $profile.api) {
                            ForEach(GraphicsAPIChoice.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented).frame(maxWidth: 360)
                    }
                    row("Aspect") {
                        Picker("", selection: $profile.aspect) {
                            ForEach(AspectChoice.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented).frame(maxWidth: 360)
                    }
                    if profile.preset == .custom {
                        row("Render resolution") {
                            Picker("", selection: $profile.renderHeight) {
                                ForEach([480, 540, 720, 900, 1080], id: \.self) { Text("\($0)p").tag($0) }
                            }.pickerStyle(.segmented).frame(maxWidth: 360)
                        }
                        toggleRow("MetalFX upscaling", "Renders low, upscales to the panel on the GPU.", $profile.metalFX)
                        row("Frame limit") {
                            Picker("", selection: $profile.frameLimit) {
                                Text("30").tag(30); Text("40").tag(40); Text("60").tag(60); Text("120").tag(120); Text("Off").tag(0)
                            }.pickerStyle(.segmented).frame(maxWidth: 360)
                        }
                        toggleRow("120 Hz ProMotion", "Present as fast as frames arrive instead of pacing to 60.", $profile.highRefresh)
                    }
                    row("BC texture mip clamp") {
                        Stepper(profile.bcMipClamp == 0 ? "Off" : "Drop \(profile.bcMipClamp) level\(profile.bcMipClamp == 1 ? "" : "s")",
                                value: $profile.bcMipClamp, in: 0...4)
                            .frame(maxWidth: 260)
                    }
                    Text("DirectX 11 only. This GPU cannot sample BC textures, so they are expanded 4-8×; dropping the largest mips saves the most memory.")
                        .font(.system(size: 12)).foregroundStyle(Deck.dim)
                }
            }
            DeckPanel(title: "Processor", symbol: "cpu") {
                VStack(alignment: .leading, spacing: 14) {
                    toggleRow("Reduced-precision x87", "64-bit x87 floats. Faster; modern games rarely notice.", $profile.x87Reduced)
                    toggleRow("Multiblock translation", "Larger translated blocks run faster but compile longer.", $profile.multiblock)
                    row("Memory ordering (TSO)") {
                        Picker("", selection: $profile.tso) {
                            ForEach(TSOChoice.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented).frame(maxWidth: 300)
                    }
                    if profile.tso == .fast {
                        Label("Fast mode skips x86 memory-ordering emulation. Multithreaded games are likely to crash.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13)).foregroundStyle(Deck.warn)
                    }
                }
            }
            DeckPanel(title: "Memory", symbol: "memorychip") {
                VStack(alignment: .leading, spacing: 12) {
                    row("JIT pool") {
                        Picker("", selection: $profile.jitPoolMB) {
                            Text("Auto (\(autoPool) MB)").tag(0)
                            ForEach([384, 512, 640, 768, 896, 1024, 1152], id: \.self) { Text("\($0) MB").tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    Text("Every loaded Windows module is copied into this pool and the whole pool counts against the iOS memory limit from the start. Auto sizes it from this game's executable and DLLs.")
                        .font(.system(size: 12)).foregroundStyle(Deck.dim)
                }
            }
            DeckPanel(title: "Launch options", symbol: "terminal") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Extra arguments").font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.dim)
                    TextField("-nosplash", text: $profile.extraArgs)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 14, design: .monospaced))
                        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Deck.bg0))
                    Text("Environment (KEY=VALUE per line)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.dim)
                    TextEditor(text: $profile.extraEnv)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 70)
                        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Deck.bg0))
                    toggleRow("Touch controls", "Show the on-screen control overlay in game.", $profile.touchControls)
                    toggleRow("Verbose logging", "Wine, vkd3d and MoltenVK diagnostics. Costs performance.", $profile.verboseLogging)
                }
            }
        }
        .padding(.horizontal, 28)
    }

    private var autoPool: Int {
        var g = game
        g.profile.jitPoolMB = 0
        return WineLauncher.plan(for: g).poolMB
    }

    private func presetCard(_ p: PerformancePreset) -> some View {
        let selected = profile.preset == p
        return Button { profile.preset = p } label: {
            HStack(spacing: 10) {
                Image(systemName: p.symbol).font(.system(size: 17)).frame(width: 22)
                Text(p.label).font(.system(size: 15, weight: .semibold))
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill") }
            }
            .foregroundStyle(selected ? Color.white : Deck.text)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Deck.accent.opacity(0.85) : Deck.panelHi))
        }
        .buttonStyle(.plain)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 16) {
            Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(Deck.text)
            Spacer(minLength: 10)
            control()
        }
    }

    private func toggleRow(_ label: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(Deck.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Deck.dim)
            }
        }
        .tint(Deck.accent)
    }
}

// MARK: - Add game

struct AddGameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = GameLibrary.shared

    var body: some View {
        NavigationStack {
            FolderBrowser(relPath: "", onPick: { rel in
                library.addExecutable(relPath: rel)
                dismiss()
            })
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { library.rescan() } label: {
                        Label(library.scanning ? "Scanning…" : "Scan all", systemImage: "magnifyingglass")
                    }.disabled(library.scanning)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct FolderBrowser: View {
    let relPath: String
    let onPick: (String) -> Void

    private struct Item: Identifiable { let id: String; let name: String; let isDir: Bool; let size: Int64 }

    private var items: [Item] {
        let fm = FileManager.default
        let url = relPath.isEmpty ? MadeiraPaths.driveC : MadeiraPaths.driveC.appendingPathComponent(relPath)
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        return names.compactMap { n -> Item? in
            if n.hasPrefix(".") { return nil }
            var isDir: ObjCBool = false
            let p = url.appendingPathComponent(n).path
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
            if !isDir.boolValue && !n.lowercased().hasSuffix(".exe") { return nil }
            let size = isDir.boolValue ? 0 : ((try? fm.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0)
            return Item(id: n, name: n, isDir: isDir.boolValue, size: size)
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Text("Nothing here. Put game folders in drive_c using the Files app.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                let childRel = relPath.isEmpty ? item.name : relPath + "/" + item.name
                if item.isDir {
                    NavigationLink {
                        FolderBrowser(relPath: childRel, onPick: onPick)
                    } label: {
                        Label(item.name, systemImage: "folder.fill")
                    }
                } else {
                    Button { onPick(childRel) } label: {
                        HStack {
                            Label(item.name, systemImage: "app.badge")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle(relPath.isEmpty ? "drive_c" : (relPath as NSString).lastPathComponent)
    }
}

// MARK: - Settings

struct SettingsScreen: View {
    let openDeveloper: () -> Void
    @ObservedObject private var library = GameLibrary.shared
    @State private var cacheBytes: Int64 = 0
    @State private var entitlements = EntitlementStatus.check()
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DeckPanel(title: "System", symbol: "iphone") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow("JIT (StikDebug)", isDebuggerAttached())
                        statusRow("Increased memory limit", entitlements.increasedMemory)
                        statusRow("Extended virtual addressing", entitlements.extendedVA)
                        HStack {
                            Text("Memory available to Madeira").foregroundStyle(Deck.text)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(os_proc_available_memory()), countStyle: .memory))
                                .foregroundStyle(Deck.dim).monospacedDigit()
                        }
                        Button { StikJITHelper.enableJIT { _ in } } label: { Label("Enable JIT", systemImage: "bolt.fill") }
                            .buttonStyle(DeckButtonStyle(prominent: true))
                    }
                }
                DeckPanel(title: "Library", symbol: "square.grid.2x2") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(library.games.count) games in drive_c").foregroundStyle(Deck.text)
                        HStack {
                            Button { library.rescan() } label: {
                                Label(library.scanning ? "Scanning…" : "Rescan drive_c", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(DeckButtonStyle())
                            if let m = library.lastScanMessage { Text(m).font(.system(size: 13)).foregroundStyle(Deck.dim) }
                        }
                    }
                }
                DeckPanel(title: "Shader caches", symbol: "square.stack.3d.down.right") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Compiled shaders are kept per game so later launches skip the stutter of compiling them again.")
                            .font(.system(size: 13)).foregroundStyle(Deck.dim)
                        HStack {
                            Text("Using \(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))").foregroundStyle(Deck.text)
                            Spacer()
                            Button(role: .destructive) { confirmClear = true } label: { Text("Clear") }
                                .buttonStyle(DeckButtonStyle())
                        }
                    }
                }
                DeckPanel(title: "Advanced", symbol: "wrench.and.screwdriver") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The original Madeira tooling: test programs, Steam and desktop experiments, and the live log.")
                            .font(.system(size: 13)).foregroundStyle(Deck.dim)
                        Button(action: openDeveloper) { Label("Developer Tools", systemImage: "hammer.fill") }
                            .buttonStyle(DeckButtonStyle())
                    }
                }
            }
            .padding(22)
        }
        .onAppear { cacheBytes = Self.directorySize(Self.cacheRoots) }
        .confirmationDialog("Clear all shader caches?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                for u in Self.cacheRoots { try? FileManager.default.removeItem(at: u) }
                cacheBytes = Self.directorySize(Self.cacheRoots)
            }
        } message: { Text("Games will compile shaders again on their next launch.") }
    }

    static var cacheRoots: [URL] {
        [MadeiraPaths.documents.appendingPathComponent("madeira-cache"),
         MadeiraPaths.driveC.appendingPathComponent("madeira-cache")]
    }

    static func directorySize(_ roots: [URL]) -> Int64 {
        var total: Int64 = 0
        for r in roots {
            guard let en = FileManager.default.enumerator(at: r, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let u as URL in en {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    private func statusRow(_ label: String, _ ok: Bool) -> some View {
        HStack {
            Text(label).foregroundStyle(Deck.text)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Deck.good : Deck.warn)
        }
    }
}

// MARK: - JIT wait + developer host

struct JITWaitOverlay: View {
    let game: GameEntry
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(Deck.accent)
                Text("Waiting for StikDebug").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Madeira needs a debugger attached to translate x86 code.\n\(game.title) starts as soon as JIT is enabled.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 14))
                    .foregroundStyle(Deck.dim)
                Button("Cancel") { PlayCoordinator.shared.waitingForJIT = nil }
                    .buttonStyle(DeckButtonStyle())
            }
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 18).fill(Deck.panel))
        }
    }
}

struct DeveloperToolsHost: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ContentView()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(.top, 6)
            .padding(.trailing, 12)
        }
    }
}
