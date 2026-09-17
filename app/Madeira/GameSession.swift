import SwiftUI
import UIKit
import GameController
import os

// In-game screen: the full-screen game surface plus a SteamOS-style Quick
// Access panel, loading card and performance HUD.
//
// The game's CAMetalLayer lives in a window-level host view (see MetalHostView
// in ContentView.swift), so SwiftUI content inside this view can never draw on
// top of the game. Everything that must appear over the game is hosted in its
// own UIWindow one level above the touch-controls window.

@MainActor
final class SessionOverlayModel: ObservableObject {
    static let shared = SessionOverlayModel()

    @Published var game: GameEntry?
    @Published var panelOpen = false
    @Published var launchError: String?
    @Published var showHUD: Bool = UserDefaults.standard.object(forKey: "madeira.hud") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showHUD, forKey: "madeira.hud") }
    }
    @Published var firstFrameSeen = false
    let startedAt = Date()

    /// Cards that need taps (errors) make the overlay window take input.
    var interactive: Bool { panelOpen || launchError != nil || failedState }

    var failedState: Bool {
        if case .failed = WineLauncher.shared.state { return true }
        return false
    }
}

final class SessionOverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let m = SessionOverlayModel.shared
        if m.interactive { return super.hitTest(point, with: event) }
        // The Quick Access button, top-right. Everything else belongs to the game.
        if CGRect(x: bounds.width - 96, y: 0, width: 96, height: 80).contains(point) {
            return super.hitTest(point, with: event)
        }
        return nil
    }
}

@MainActor
enum SessionOverlayHost {
    private static var window: SessionOverlayWindow?

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        if window == nil {
            let w = SessionOverlayWindow(windowScene: scene)
            w.windowLevel = .normal + 102          // above touch controls (+101) and joystick pad (+100)
            w.backgroundColor = .clear
            w.isHidden = false
            let host = UIHostingController(rootView: SessionOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.frame = scene.coordinateSpace.bounds
    }
}

struct GameSessionView: View {
    let game: GameEntry
    @ObservedObject private var launcher = WineLauncher.shared

    var body: some View {
        ZStack {
            Color.black
            MadeiraMetalView()
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: start)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            SessionOverlayHost.attach()
            if game.profile.touchControls { TouchControlsHost.attach() }
            MetalBackedView.refreshGameLayout()
        }
        .modifier(ControllerHandler { input in
            let m = SessionOverlayModel.shared
            // Menu and View belong to the game (Start / Back via XInput); the
            // Home/Guide button is ours.
            switch input {
            case .home: withAnimation(.easeOut(duration: 0.22)) { m.panelOpen.toggle() }
            case .back: if m.panelOpen { withAnimation(.easeOut(duration: 0.22)) { m.panelOpen = false } }
            default: break
            }
        })
    }

    private func start() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        }
        ControllerHub.shared.feedback = false
        let m = SessionOverlayModel.shared
        m.game = game
        m.launchError = nil
        SessionOverlayHost.attach()
        if game.profile.touchControls { TouchControlsHost.attach() }
        GamepadBridge.shared.start()
        GamepadBridge.shared.virtualPadEnabled = game.profile.touchControls
            && TouchControlsModel.shared.controls.contains { $0.action.isPad }
        guard !launcher.hasStarted else { return }
        // The layer is registered with DXMT in MetalBackedView.didMoveToWindow;
        // give the hierarchy a moment to attach before the game can ask for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !WineLauncher.shared.launch(game) {
                m.launchError = jit_check_debugged()
                    ? "Madeira could not start this game. Open Developer Tools for the log."
                    : "JIT is not enabled. Enable it with StikDebug and relaunch Madeira."
            }
            MetalBackedView.refreshGameLayout()
        }
    }
}

// MARK: - Overlay

struct SessionOverlay: View {
    @ObservedObject private var m = SessionOverlayModel.shared
    @ObservedObject private var launcher = WineLauncher.shared
    @State private var presents: UInt64 = 0
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if m.showHUD && presents > 0 {
                    FPSOverlay(compact: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .padding(.leading, max(geo.safeAreaInsets.leading, 14))
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }

                quickAccessButton
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.trailing, max(geo.safeAreaInsets.trailing, 16))
                    .padding(.top, 12)

                if presents == 0 || m.launchError != nil || m.failedState {
                    LoadingCard(presents: presents)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }

                if m.panelOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.22)) { m.panelOpen = false } }
                        .transition(.opacity)
                    QuickAccessPanel()
                        .frame(width: min(360, geo.size.width * 0.5))
                        .frame(maxHeight: .infinity)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.35), value: presents == 0)
        .onReceive(tick) { _ in
            presents = madeira_get_present_count()
            if presents > 0 && !m.firstFrameSeen { m.firstFrameSeen = true }
        }
    }

    private var quickAccessButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.22)) { m.panelOpen.toggle() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(.black.opacity(0.45)))
                .overlay(Circle().stroke(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .opacity(m.panelOpen ? 0 : 0.75)
    }
}

struct LoadingCard: View {
    let presents: UInt64
    @ObservedObject private var m = SessionOverlayModel.shared
    @ObservedObject private var launcher = WineLauncher.shared
    @State private var elapsed = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if let g = m.game {
                CoverArt(game: g, cornerRadius: 0)
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.6))
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            VStack(spacing: 18) {
                if let g = m.game {
                    CoverArt(game: g)
                        .frame(width: 110, height: 165)
                        .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
                    Text(g.title)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
                if let err = errorText {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Deck.warn)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    Button { exit(0) } label: { Label("Quit Madeira", systemImage: "power") }
                        .buttonStyle(DeckButtonStyle(prominent: true))
                } else {
                    ProgressView().controlSize(.large).tint(Deck.accent)
                    Text(statusText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Deck.text)
                    Text("\(elapsed)s · The first launch translates and compiles the most; later launches reuse the shader cache.")
                        .font(.system(size: 13))
                        .foregroundStyle(Deck.dim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
            }
            .padding(30)
        }
        .onReceive(tick) { _ in elapsed = Int(Date().timeIntervalSince(m.startedAt)) }
    }

    private var statusText: String {
        switch launcher.state {
        case .starting(let s): return s
        case .running: return "Waiting for the first frame…"
        case .exited: return "The game exited."
        case .idle: return "Preparing…"
        case .failed(let s): return s
        }
    }

    private var errorText: String? {
        if let e = m.launchError { return e }
        if case .failed(let s) = launcher.state { return s }
        if case .exited = launcher.state, presents == 0 {
            return "The game closed before drawing anything. Developer Tools has the full log."
        }
        return nil
    }
}

struct QuickAccessPanel: View {
    @ObservedObject private var m = SessionOverlayModel.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @ObservedObject private var input = InputSettings.shared
    @State private var unlocked = madeira_get_vsync_locked() == 0
    @State private var footprintMB = 0
    @State private var availableMB = 0
    @State private var confirmQuit = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QUICK ACCESS").font(.system(size: 12, weight: .bold)).tracking(1.5).foregroundStyle(Deck.accent)
                    Text(m.game?.title ?? "Madeira").font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white).lineLimit(1)
                }
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.22)) { m.panelOpen = false } } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Deck.text)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Deck.panelHi))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("Performance") {
                        HStack {
                            FPSOverlay(compact: true)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(footprintMB) MB used").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                Text("\(availableMB) MB free").font(.system(size: 11)).foregroundStyle(Deck.dim).monospacedDigit()
                            }
                            .foregroundStyle(Deck.text)
                        }
                        toggle("Performance overlay", $m.showHUD)
                        toggle("120 Hz (unlock pacing)", Binding(get: { unlocked }, set: { v in
                            unlocked = v
                            madeira_set_vsync_locked(v ? 0 : 1)
                            ProMotionIntent.shared.setActive(v)
                        }))
                    }
                    group("Controls") {
                        toggle("Touch controls", $controls.visible)
                        toggle("Mouse look (relative)", $input.relative)
                        HStack(spacing: 8) {
                            key("Esc", 0x1B); key("Enter", 0x0D); key("Tab", 0x09); key("Space", 0x20)
                            Button { MetalBackedView.toggleKeyboard() } label: {
                                Image(systemName: "keyboard").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(DeckButtonStyle())
                        }
                    }
                    group("Session") {
                        Text("Controllers reach the game as XInput players 1-4. The Home button opens this panel.")
                            .font(.system(size: 12)).foregroundStyle(Deck.dim)
                        Text("Frame limit, resolution and API are set per game on its page and apply at the next launch.")
                            .font(.system(size: 12)).foregroundStyle(Deck.dim)
                        Button(role: .destructive) { confirmQuit = true } label: {
                            Label("Close game", systemImage: "power").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(DeckButtonStyle())
                    }
                }
            }
        }
        .padding(20)
        .background(
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(Deck.bg0.opacity(0.72)))
                .ignoresSafeArea()
        )
        .overlay(alignment: .leading) { Rectangle().fill(Deck.stroke).frame(width: 1).ignoresSafeArea() }
        .confirmationDialog("Close the game?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Close and quit Madeira", role: .destructive) { exit(0) }
        } message: {
            Text("Windows runs inside Madeira, so closing the game quits the app. Unsaved progress is lost.")
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { footprintMB = Int(info.phys_footprint / 1_048_576) }
        availableMB = Int(os_proc_available_memory() / 1_048_576)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.3).foregroundStyle(Deck.dim)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Deck.panel.opacity(0.9)))
    }

    private func toggle(_ label: String, _ value: Binding<Bool>) -> some View {
        Toggle(label, isOn: value)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Deck.text)
            .tint(Deck.accent)
    }

    private func key(_ label: String, _ vk: Int32) -> some View {
        Button {
            winios_post_key(vk, 1)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { winios_post_key(vk, 0) }
        } label: {
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(DeckButtonStyle())
    }
}
