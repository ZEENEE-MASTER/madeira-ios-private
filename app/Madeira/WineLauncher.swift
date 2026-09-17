import Foundation
import SwiftUI
import UIKit
import os.log

// The Wine start sequence, shared by the game library and the developer tools.
//
// runFullSequence() is ContentView's former runWineFullSequence(), moved here
// verbatim apart from: logStore -> LogStore.shared, a pool-size parameter, and
// state publishing for the UI. Every ml-numbered note is kept because each one
// records why a step is the way it is.
//
// launch(_:) is the library path: it turns a GameEntry's profile into the
// environment the native side reads, then runs the same sequence.
final class WineLauncher: ObservableObject {
    static let shared = WineLauncher()

    enum State: Equatable {
        case idle
        case starting(String)
        case running
        case exited
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var activeGameID: String?

    /// Wine (and wineserver) run inside this process. Once started they cannot
    /// be restarted without relaunching the app.
    var hasStarted: Bool { state != .idle }

    private init() {}

    fileprivate func publish(_ s: State) {
        DispatchQueue.main.async { self.state = s }
    }

    // MARK: - Library launch

    struct Plan {
        var env: [String: String] = [:]
        var unset: [String] = []
        var poolMB: Int = 896
        var vsyncLocked = true
        var renderSize = CGSize(width: 1280, height: 720)
        var summary: [String] = []
    }

    /// Environment left behind by the developer buttons (Steam testing,
    /// probes). A library launch must start from a clean, fast baseline.
    private static let developerEnv = [
        "MADEIRA_DESKTOP", "MADEIRA_IRCAP_RVA", "MADEIRA_IRCAP_MODULE", "MADEIRA_SRCWATCH",
        "MADEIRA_SRCWATCH_ROWS", "MADEIRA_JITLESS", "MADEIRA_DEAD_RELEASE", "MADEIRA_SURF_SEQ",
        "MADEIRA_DUMP_SURFACES", "MADEIRA_SOCK_WIRE", "FEX_O0", "MADEIRA_NO_DFE", "MADEIRA_IR_TOPO",
        "MADEIRA_DEBUG_VERBOSE",
    ]

    static func nativeLandscapePixels() -> CGSize {
        let b = UIScreen.main.nativeBounds.size
        return CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
    }

    static func plan(for game: GameEntry) -> Plan {
        var p = Plan()
        let prof = game.profile
        let eff = prof.effective
        let native = nativeLandscapePixels()

        // Render size. Width is kept even; many swapchains and MetalFX dislike odd sizes.
        let h = max(360, eff.renderHeight)
        let ratio: Double
        switch prof.aspect {
        case .wide: ratio = 16.0 / 9.0
        case .classic: ratio = 4.0 / 3.0
        case .screen: ratio = Double(native.width / max(native.height, 1))
        }
        var w = Int((Double(h) * ratio).rounded())
        w -= w % 2
        p.renderSize = CGSize(width: w, height: h)

        p.env["MADEIRA_LAUNCHER"] = "1"
        p.env["MADEIRA_GAME_ID"] = game.id
        p.env["MADEIRA_EXE"] = game.windowsExe
        p.env["MADEIRA_SCREEN_W"] = String(w)
        p.env["MADEIRA_SCREEN_H"] = String(h)
        p.env["MADEIRA_REFRESH"] = eff.highRefresh ? "120" : "60"
        p.unset += developerEnv

        // Engine-aware command line. These are the engines' own documented switches.
        let api = game.resolvedAPI
        var args: [String] = []
        switch game.detected.engine {
        case .unreal5, .unreal4, .unreal:
            if let proj = game.detected.projectName { args.append(proj) }
            args.append(api == .dx12 ? "-dx12" : "-dx11")
            args += ["-windowed", "-ResX=\(w)", "-ResY=\(h)"]
        case .unity:
            args.append(api == .dx12 ? "-force-d3d12" : "-force-d3d11")
            args += ["-screen-width", String(w), "-screen-height", String(h),
                     "-screen-fullscreen", "0", "-popupwindow"]
        default:
            break
        }
        let extra = prof.extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { args.append(extra) }
        if args.isEmpty { p.unset.append("MADEIRA_ARGS") } else { p.env["MADEIRA_ARGS"] = args.joined(separator: " ") }

        // ---- DX11: DXMT ----
        var dxmt: [String] = []
        if eff.frameLimit > 0 { dxmt.append("d3d11.preferredMaxFrameRate=\(eff.frameLimit)") }
        let upscale = min(2.0, max(1.0, Double(native.height) / Double(h)))
        if eff.metalFX && upscale > 1.05 {
            p.env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            dxmt.append(String(format: "d3d11.metalSpatialUpscaleFactor=%.3f", upscale))
            p.summary.append(String(format: "MetalFX %dp → %dp", h, Int(Double(h) * upscale)))
        } else {
            p.unset.append("DXMT_METALFX_SPATIAL_SWAPCHAIN")
        }
        if prof.bcMipClamp > 0 { dxmt.append("d3d11.mipClampBC=\(min(prof.bcMipClamp, 4))") }
        if dxmt.isEmpty { p.unset.append("DXMT_CONFIG") } else { p.env["DXMT_CONFIG"] = dxmt.joined(separator: ";") }
        p.env["DXMT_SHADER_CACHE_PATH"] = MadeiraPaths.dxmtCache(game.id).path + "/"

        // ---- DX12: vkd3d-proton + MoltenVK ----
        p.env["VKD3D_SHADER_CACHE_PATH"] = MadeiraPaths.vkd3dCacheWindows(game.id)
        p.env["VKD3D_DEBUG"] = prof.verboseLogging ? "warn" : "none"
        p.env["VKD3D_SHADER_DEBUG"] = "none"
        if eff.frameLimit > 0 { p.env["VKD3D_FRAME_RATE"] = String(eff.frameLimit) } else { p.unset.append("VKD3D_FRAME_RATE") }
        p.env["MVK_CONFIG_LOG_LEVEL"] = prof.verboseLogging ? "2" : "1"
        p.env["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"] = "1"
        p.env["MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION"] = "1"
        p.env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        if prof.preset == .performance {
            p.env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] = "0"
        } else {
            p.unset.append("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS")
        }

        // ---- CPU: FEX ----
        p.env["FEX_X87REDUCEDPRECISION"] = prof.x87Reduced ? "1" : "0"
        p.env["FEX_TSOENABLED"] = prof.tso == .fast ? "0" : "1"
        p.env["FEX_MULTIBLOCK"] = prof.multiblock ? "1" : "0"

        // ---- Logging ----
        p.env["MADEIRA_WINEDEBUG"] = prof.verboseLogging ? "err+all,warn+module,warn+loaddll" : "-all"

        // ---- Steam identity, per title (WineProcessBridge no longer forces Thumper's) ----
        let exeDir = (game.windowsExe as NSString).deletingLastPathComponent
        p.env["SteamAppPath"] = exeDir
        var appID: String?
        var dir = game.unixExe.deletingLastPathComponent()
        for _ in 0..<5 {
            let f = dir.appendingPathComponent("steam_appid.txt")
            if let s = try? String(contentsOf: f, encoding: .utf8) {
                let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if Int(v) != nil { appID = v; break }
            }
            dir = dir.deletingLastPathComponent()
        }
        if let appID { p.env["SteamAppId"] = appID; p.env["SteamGameId"] = appID }
        else { p.unset += ["SteamAppId", "SteamGameId"] }

        // ---- JIT pool: sized from what will actually be copied into it ----
        if prof.jitPoolMB > 0 {
            p.poolMB = min(1152, max(256, prof.jitPoolMB))
        } else {
            let exeMB = Int(game.detected.exeBytes / (1024 * 1024))
            let dllMB = Int(game.detected.folderDLLBytes / (1024 * 1024))
            var mb = exeMB + dllMB / 2 + 320
            mb = ((mb + 63) / 64) * 64
            p.poolMB = min(1152, max(384, mb))
        }

        p.vsyncLocked = !eff.highRefresh

        // ---- User overrides last ----
        for line in prof.extraEnv.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            p.env[parts[0]] = parts[1]
        }

        p.summary.insert("\(w)×\(h) · \(api == .dx12 ? "DirectX 12" : "DirectX 11") · pool \(p.poolMB) MB", at: 0)
        return p
    }

    /// Returns false (having logged why) when the launch cannot start.
    @discardableResult
    func launch(_ game: GameEntry) -> Bool {
        guard !hasStarted else {
            LogStore.shared.log("A game is already running in this session. Relaunch Madeira to switch games.", level: .error)
            return false
        }
        guard jit_check_debugged() else {
            LogStore.shared.log("JIT not enabled. Enable JIT first.", level: .error)
            return false
        }
        let p = Self.plan(for: game)
        // Pure plan above (the game page previews it on every redraw); side effects here.
        for dir in [MadeiraPaths.dxmtCache(game.id), MadeiraPaths.vkd3dCacheUnix(game.id)] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for k in p.unset where p.env[k] == nil { unsetenv(k) }
        for (k, v) in p.env { setenv(k, v, 1) }
        madeira_set_vsync_locked(p.vsyncLocked ? 1 : 0)
        ProMotionIntent.shared.setActive(!p.vsyncLocked)
        madeira_set_diag_enabled(game.profile.verboseLogging ? 1 : 0)

        LogStore.shared.log("Launching \(game.title)", level: .success)
        for s in p.summary { LogStore.shared.log("  \(s)") }
        LogStore.shared.log("  \(game.windowsExe) \(p.env["MADEIRA_ARGS"] ?? "")")

        activeGameID = game.id
        Task { @MainActor in GameLibrary.shared.markLaunched(game.id) }
        runFullSequence(poolMB: p.poolMB)
        return true
    }

    // MARK: - Shared start sequence (moved from ContentView)

    /// Full sequence: allocate JIT pool, start wineserver, start Wine.
    /// Debugger stays attached during PE loading so mprotect_exec can use BRK
    /// to prepare code pages. Detach happens after Wine finishes + recovery.
    func runFullSequence(poolMB: Int? = nil) {
        guard jit_check_debugged() else {
            LogStore.shared.log("JIT not enabled. Press 'Enable JIT' first.", level: .error)
            publish(.failed("JIT is not enabled."))
            return
        }

        LogStore.shared.log("Running full Wine sequence...")
        publish(.starting("Reserving memory for the x86 translator…"))

        // Start a main thread heartbeat to diagnose hang
        var heartbeatCount = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            heartbeatCount += 1
            os_log("[HEARTBEAT] main thread alive #%d", heartbeatCount)
        }

        // Pause UI flushing — prevents ALL SwiftUI re-renders during Wine execution,
        // so zero main thread hang time accumulates while debugger is attached
        LogStore.shared.uiPaused = true

        // Suppress os_log from wineserver — hundreds of messages/sec cause os_log buffer
        // contention that blocks the main thread RunLoop, triggering iOS hang detection
        ws_log_quiet = 1

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Allocate JIT pool (BRK suspends entire process)
            // 128 MB was enough for cube but Thumper exhausts it (more PE
            // copies + larger FEX block cache). Desktop mode holds the
            // session's aarch64 image set AND every child's x64 set AND the
            // FEX code buffers in ONE pool: Thumper-under-desktop hit 199MB
            // of image copies alone (2026-07-06), leaving the FEX tail carve
            // colliding with the head. 384 MB fits both plus slack; the pool
            // is dual-map + NO_FOOTPRINT so unwritten pages cost nothing.
            //
            // 2026-07-10 (Steam S3): 384 MB is VIRTUAL-exhausted by Steam's
            // pseudo-process fan-out — steam.exe + services + rpcss + cmd +
            // conhost + steamerrorreporter64 each copy their whole DLL set
            // (owner-keyed, no .text sharing yet) → 138 image copies hit
            // ~365 MB and the crash reporter's ntdll can't fit → the load
            // fails and execution BUS-faults on the un-committed image. Since
            // the pool is jetsam-exempt + demand-committed (unwritten pages
            // cost nothing), raising the VIRTUAL cap is a cheap, safe unblock.
            // 640 MB clears the current fan-out with headroom to reach the
            // ole32 delay-load (FEX riprel probe) and beyond. The real fix for
            // the PHYSICAL duplication is .text sharing (deferred project).
            //
            // 2026-07-10 pm (task #34 / CEF): 896 MB — libcef.dll's 212MB
            // pool copy EXHAUSTED 640 (bump 412MB + no contiguous 212MB →
            // libcef load degraded → init CHECK). Pure-x64 skip-copy was
            // trialed and reverted (broke x18-trampoline layout, ml68);
            // until skip-copy or .text sharing lands, buy headroom. Virtual
            // is jetsam-exempt; the copy itself is ~212MB real RSS when
            // written.
            // 2026-08-01 (ml364): 1152 MB — ml363 died at MSM depth on pool
            // EXHAUSTION (bump 858MB, freelist 0, tail-reserve 64MB) when
            // Chrome's in-proc GPU thread requested a doubled 32MB EC code
            // buffer; the fallback landed non-executable in the guest band and
            // FEX scribbled through a garbage CodeBuffer. NOTE the jetsam
            // ledger note above is STALE: the pool was never exempt and
            // arrives FULLY DIRTY from StikDebug's TXM blessing writes, so
            // this +256MB costs +256MB of the 4096MB budget up front. The
            // ml362/ml363 footprint work (peak 3804→3190) is what pays for
            // it. The real fix for both sides is still .text sharing.
            // 2026-08-01 (ml367): back to 896 MB. ml364 needed 1152 because the
            // shipped PE DLLs carried DWARF debug sections (llvm-mingw links
            // -Wl,-debug:dwarf) and the pool copies the ENTIRE image, so 42% of
            // every copy was debug info with no runtime purpose. Stripping them
            // (llvm-strip --strip-debug over the bundle) drops projected peak
            // pool use 894 -> ~653 MB, so 896 restores the ml364-equivalent
            // headroom (~243 MB) while returning 256 MB of footprint — the pool
            // is dirty from birth, so its SIZE is what costs, not its usage.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-02 (ml421): 1024 MB. ml420 (post-#69-fix, deepest run yet:
            // cycle 41) refilled the stripped 896 pool anyway — head 768MB of
            // copies + 176MB tail of EC code buffers collided; the doubled 32MB
            // GPU-thread buffer was refused and the ml361/ml363 ClearCache
            // wild-write returned (now also honestly REFUSED unix-side,
            // rev=ml421). +128MB is the depth lever that fits under jetsam:
            // ml420 peaked 3837 phys; 3837+128=3965 < 4096. Tight — if jetsam
            // returns, the durable fix is .text sharing, not more pool.
            // 2026-08-02 (ml423): BACK to 896. Jetsam DID return — ml422 died a
            // silent EXC_RESOURCE kill at 2.5min (peak 3904, log stops mid-line),
            // exactly the predicted cost of the +128MB dirty-at-birth pool.
            // ml421's honest EC_CODE refusal makes pool exhaustion GRACEFUL now
            // (ctor halving, worst case one thread's 0xdead fault) while jetsam
            // kills the whole app — 896 + graceful degradation strictly beats
            // 1024 + jetsam roulette. Durable fix remains .text sharing.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-03 (ml458): STAY at 896 — growth is closed for good.
            // jetsam killed 1024 twice (ml422 peak 3904) and the no-footprint
            // exemption is unreachable: all four (entry-flags, owner) variants
            // return kr=4, and the plain ones expose why — the named entry
            // covers 16KB of the 896MB object, i.e. the kernel wants an entry
            // naming the WHOLE object, which we can never build over memory
            // whose object StikDebug created. Pool stays dirty-from-birth and
            // jetsam-counted, so SIZE is the cost and 896 is the ceiling.
            // ⛔ ml457 re-trialed pure-x64 skip-copy (already dead per ml68
            // above) and it failed again for a different reason: x64 guest
            // RIPs ARE pool-copy aliases, so the copy is the execution
            // substrate — steam.exe died in seconds. Do not try a third time.
            // The remaining levers are USE-side: the 276MB of duplicate copies
            // (.text sharing) and the 214MB tail of EC code buffers.
            // ml668: RUNTIME-SELECTABLE. 896 stays the default and the only
            // value proven for Steam/CEF. 384 is the direct-game experiment:
            // the last good Book of the Dead run used ~139MB of head + ~48MB
            // of tail, so 384 leaves ~197MB of observed slack while returning
            // ~512MB of footprint -- and the pool is dirty from birth, so its
            // SIZE is the cost, not its usage. The VA floor is no longer a
            // hand-paired constant (ml668 derives it from the pool actually
            // allocated), so changing this is now a one-line change.
            // Override lives in Documents/madeira-pool.txt (a bare number of MB)
            // so it can be swapped between runs without a rebuild, and deleting
            // the file reverts to the proven default. Clamped to sane values --
            // a typo here would otherwise move the VA floor with it.
            var poolSizeMB = poolMB ?? 896
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-pool.txt"), encoding: .utf8),
               let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               mb >= 256, mb <= 1152 {
                poolSizeMB = mb
                LogStore.shared.log("JIT pool overridden to \(mb)MB via madeira-pool.txt")
            }
            // ml694: W^X A/B switch. Documents/madeira-wx.txt containing "0"
            // disables page demotion for the SAME binary, so the on/off
            // comparison needs one rebuild, not two. The previous gate read
            // container paths that can never exist, so it silently forced
            // ENABLED and no A/B was actually possible.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-wx.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_WX", v, 1)
                LogStore.shared.log("W^X override: MADEIRA_WX=\(v) via madeira-wx.txt")
            }

            // ml727: wine-mono backpatcher bridge A/B. Documents/madeira-mono-bridge.txt
            // == "1" sets MADEIRA_WINEMONO_BRIDGE, which arms FEX's Mono code-patching
            // optimisation for wine-mono (recognised since ml712 but activation left
            // opt-in because the bridge reclassifies an XCHG from a true atomic exchange
            // into an alias-directed plain write).
            //
            // Worth arming here: the dominant fault site emits SWPAL, which is exactly
            // what FEX generates for a guest XCHG, and the patching XCHGs sit inside
            // libmono -- so the bridge's "RIP must lie inside Mono" test should pass.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-mono-bridge.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_WINEMONO_BRIDGE", v, 1)
                    LogStore.shared.log("Mono bridge: MADEIRA_WINEMONO_BRIDGE=\(v) via madeira-mono-bridge.txt")
                }
            }

            // ml716: syscall-frame context A/B. Documents/madeira-ctx-frame.txt == "1"
            // makes ios_fill_thread_context() report a thread parked inside a syscall
            // using its saved Wine syscall frame (TEB+0x378) instead of the Mach-O
            // registers it happens to be executing. Off by default; native code reads
            // only the environment variable.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-ctx-frame.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_CTX_FRAME", v, 1)
                    LogStore.shared.log("Context source: MADEIRA_CTX_FRAME=\(v) via madeira-ctx-frame.txt")
                }
            }

            // ml744: DXMT options passthrough. Documents/madeira-dxmt.txt is copied
            // verbatim into DXMT_CONFIG, which the renderer's config parser reads as
            // inline "key=value" lines, so options can be tried without a rebuild.
            // d3d11.mipClampBC=N is the one that matters for memory: this GPU cannot
            // sample BC, so those textures are expanded to uncompressed and cost 2-8x
            // their shipped size.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-dxmt.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("DXMT_CONFIG", v, 1)
                    LogStore.shared.log("DXMT config: \(v) via madeira-dxmt.txt")
                }
            }

            // ml734: Theorafile call tracer. Documents/madeira-tf-trace.txt == "1"
            // redirects libtheorafile's tf_* exports through wrappers in
            // tftrace-x64.dll that call the original and report the RETURN
            // value. The intro decodes and plays, the stream reaches a clean
            // end of file, the decoder stops reading -- and the game never
            // leaves VideoContext. File EOF is not decoder EOS, and a call
            // count cannot tell "tf_eos returns false forever" from "it returns
            // true and the managed side ignores it". Only the return value can.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-tf-trace.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_TF_TRACE", v, 1)
                    LogStore.shared.log("Theorafile tracer: MADEIRA_TF_TRACE=\(v) via madeira-tf-trace.txt")
                }
            }

            // ml731: Windows shared-data clock A/B. Documents/madeira-usd-time.txt == "1"
            // makes wineserver update KUSER_SHARED_DATA's SystemTime, InterruptTime
            // and TickCount again. Without it those stay frozen at their init values,
            // so GetTickCount/Environment.TickCount/DateTime.UtcNow never advance and
            // every time-gated transition in a managed game waits forever while the
            // renderer keeps drawing. Opt-in only because the old code claimed the
            // write faulted; this should become unconditional once proven.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-usd-time.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_USD_TIME", v, 1)
                    LogStore.shared.log("Shared-data clock: MADEIRA_USD_TIME=\(v) via madeira-usd-time.txt")
                }
            }

            // ml730: REAL thread suspension A/B. Documents/madeira-real-suspend.txt == "1"
            // makes a Wine suspend actually stop the Mach thread and keep it stopped
            // until the matching resume, instead of only snapshotting its registers
            // and bumping a counter while the target keeps running.
            //
            // Off by default and reversible on purpose: wineserver is a thread inside
            // this same Mach process and shares the allocator with the guest, so truly
            // freezing a thread that holds the malloc lock or FEX's CodeInvalidationMutex
            // can deadlock whoever suspended it. Windows apps tolerate preemptive suspend
            // because the suspender does not share their heap; here it does.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-real-suspend.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_REAL_SUSPEND", v, 1)
                    LogStore.shared.log("Thread suspension: MADEIRA_REAL_SUSPEND=\(v) via madeira-real-suspend.txt")
                }
            }

            // ml713: Mono suspend-policy A/B. Documents/madeira-mono-suspend.txt
            // containing "preemptive" (or "coop"/"hybrid") sets MONO_THREADS_SUSPEND
            // for wine-mono, so the comparison needs no rebuild.
            //
            // EXPERIMENT, NOT A FIX, and deliberately not a default. Marvel Cosmic
            // Invasion deadlocks with one thread owning a Mono critical section while
            // looping on mono_lls_find/usleep waiting for a thread-info record, and six
            // threads queued behind that section. Preemptive suspend would sidestep the
            // handshake -- but it needs SuspendThread + GetThreadContext to yield a
            // coherent x86-64 context for a guest thread stopped anywhere, including
            // mid-JIT-block, and that path has never been exercised under FEX. It may
            // trade a deadlock for a worse failure. If it does get in-game, that is NOT
            // evidence for any particular theory of the deadlock.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-mono-suspend.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MONO_THREADS_SUSPEND", v, 1)
                    LogStore.shared.log("Mono suspend policy: MONO_THREADS_SUSPEND=\(v) via madeira-mono-suspend.txt")
                }
            }

            winios_phase("pool-alloc-begin")
            LogStore.shared.log("Allocating \(poolSizeMB)MB JIT pool (BRK will suspend process)...")
            let t0 = CFAbsoluteTimeGetCurrent()
            let pool = StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            winios_phase("pool-ready")
            LogStore.shared.log("BRK suspension lasted \(String(format: "%.2f", elapsed))s")

            // ml762: remote Metal backend. Documents/madeira-remote.txt holds
            // "<host-ip> <token>" and routes winemetal to a Metal daemon on that
            // host instead of the local device. The mode is decided ONCE per
            // process: flipping it later would leave handles from two address
            // spaces alive at the same time, which is precisely what the handle
            // tag exists to make impossible.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-remote.txt"), encoding: .utf8) {
                let parts = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    setenv("DXMT_REMOTE_METAL", parts[0], 1)
                    setenv("RMETAL_TOKEN", parts[1], 1)
                    LogStore.shared.log("remote Metal: host=\(parts[0]) via madeira-remote.txt", level: .success)
                } else if !parts.isEmpty {
                    LogStore.shared.log("madeira-remote.txt needs '<host-ip> <token>'", level: .error)
                }
            }

            // ml761: top-level API census. Documents/madeira-apicensus.txt == "1"
            // counts every call across the PE->unix winemetal boundary and
            // classifies each as producer, consumer, lifetime, query, sync,
            // presentation or bulk-memory. Needed because a packed command
            // batch carries GUEST handles -- raw pointer casts, meaningless on
            // another machine -- so every handle producer and consumer has to
            // be redirected together.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-apicensus.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_API_CENSUS", v, 1)
                LogStore.shared.log("API census: DXMT_API_CENSUS=\(v) via madeira-apicensus.txt")
            }

            // ml760: shadow-pack mode. Documents/madeira-shadow.txt == "1" packs
            // and validates every real render batch into the remote wire format,
            // then discards it and renders locally as normal. Exercises the
            // packer against live traffic where being wrong costs nothing. The
            // check that matters is packed counts equalling census counts: a
            // silently skipped command would otherwise surface as a subtly wrong
            // frame on another machine.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-shadow.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_SHADOW_PACK", v, 1)
                LogStore.shared.log("shadow pack: DXMT_SHADOW_PACK=\(v) via madeira-shadow.txt")
            }

            // ml758: wmtcmd census. Documents/madeira-census.txt == "1" counts
            // which of the 59 render/compute/blit command types a workload
            // actually emits, and how large their sidecar data gets. Needed
            // before serialising wmtcmd_* for the remote Metal transport --
            // building a schema for all 59 on speculation would be weeks of
            // work for commands no title may ever issue.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-census.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_CMD_CENSUS", v, 1)
                LogStore.shared.log("wmtcmd census: DXMT_CMD_CENSUS=\(v) via madeira-census.txt")
            }

            // ml757: FEX arena placeholder. Documents/madeira-arena.txt == "1"
            // makes Wine reserve FEX's host arena before any PE loads. OFF by
            // default: FEX still selects its own band, and on hardware that
            // band IS the reservation, so enabling it starves FEX and kills
            // x64 before the first window. Proven correct on the research VM
            // (8GB held, 0 of 123 guest images inside it) -- turn on only once
            // FEX consumes WINE_IOS_FEX_ARENA_BASE/SIZE instead of choosing.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-arena.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_FEX_ARENA", v, 1)
                LogStore.shared.log("FEX arena placeholder: MADEIRA_FEX_ARENA=\(v) via madeira-arena.txt")
            }

            // ml748: W^X A/B probe. Documents/madeira-wxprobe.txt == "1" runs it.
            // Loading xtajit64.dll faults writing its .rdata on the jailbroken
            // research VM and not on this phone, with CS_DEBUGGED live in both,
            // so attachment is not the variable. Either the VM is stricter than
            // real hardware (its patchVmMapProtect() was removed, and that is
            // what forces W to stick on file-backed pages), or hardware masks a
            // genuine bug and the loader must stop holding RWX over image pages.
            // Reasoning cannot separate those; the SAME build reporting on both
            // machines can. Runs here because it needs the real container, the
            // real sandbox and a live cs_wx_enabled map -- a standalone binary
            // over SSH already answered this wrongly once.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-wxprobe.txt"), encoding: .utf8),
               txt.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                LogStore.shared.log("W^X probe armed via madeira-wxprobe.txt", level: .success)
                jit_wx_probe()
            }

            if let pool = pool {
                LogStore.shared.log("JIT pool: RX=\(String(format: "%p", Int(bitPattern: pool.rx))), RW=\(String(format: "%p", Int(bitPattern: pool.rw))), size=\(pool.size / 1024 / 1024)MB", level: .success)
                setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
                setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
                setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
            } else {
                // ml596: ABORT. "Continuing without it" produced ml595 — a run that
                // looked like an ARM64EC/optimizer regression but was only Wine
                // executing with no JIT pool, and it cost a diagnostic cycle plus a
                // wrong conclusion I wrote into the source. A run without the pool can
                // only manufacture misleading secondary crashes, so refuse to start one.
                LogStore.shared.log("JIT pool allocation FAILED — not starting Wine.", level: .error)
                self.publish(.failed("The JIT pool could not be placed. Force-quit Madeira and launch again."))
                LogStore.shared.log("  All placements landed in the forbidden guest 64G window.", level: .info)
                LogStore.shared.log("  Force-quit and relaunch: placement is chosen by the kernel", level: .info)
                LogStore.shared.log("  and depends on current memory layout, so a fresh process", level: .info)
                LogStore.shared.log("  usually lands somewhere valid.", level: .info)
                LogStore.shared.uiPaused = false
                return
            }

            // Step 1b (ml524, #67): DETACH THE DEBUGGER NOW, while the VM map is small.
            //
            // Every ~54s whole-app stall coincides with StikDebug DEPARTING — clean
            // exit(0) and jetsam-kill alike (12:07:43 exit(0) -> GAP 54.0s at 12:07:49;
            // 12:13:58 cpulimit kill -> GAP 53.8s starting 64ms BEFORE the kill log).
            // Departure is the trigger; the manner of death is irrelevant. StikDebug
            // burns its 48s-CPU-per-60s budget in ~52s every single run, so an
            // UNCONTROLLED departure mid-game is guaranteed. Detaching here pays the
            // cost ONCE, at a moment we choose, before anything is on screen.
            //
            // Why it may also be CHEAPER here: on attach the kernel unnests the DYLD
            // shared region in OUR map ("increases system memory footprint until the
            // target exits"), so teardown plausibly scales with VM-map complexity —
            // and right now the map is a fraction of what it becomes under Steam
            // (91 threads / 2512MB). The [early-detach] timing below tests exactly that.
            //
            // Safe NOW and not before: ml522/ml523 made US the task-level Mach handler
            // for bad-access + bad-instruction + breakpoint, so the fault backstop that
            // used to require a live debugger (madeira-jit.js: "NEVER detach here ... every
            // later escalated fault parks its thread forever", the ml345 wedge) is ours.
            // And all executable memory already comes from the pool granted above —
            // virtual_ios.c copies every PE .text into it rather than mprotecting,
            // because iOS/TXM blocks mprotect(PROT_EXEC) outright.
            //
            // ORDERING MATTERS: our task-port claim installs at wine's first thread
            // setup, which is AFTER this point, so this BRK still reaches StikDebug.
            // Flip to false to A/B against the old attached-for-the-whole-run behaviour.
            let earlyDetach = true
            if earlyDetach, pool != nil {
                let dt0 = CFAbsoluteTimeGetCurrent()
                StikJITHelper.detachDebugger()
                let dms = (CFAbsoluteTimeGetCurrent() - dt0) * 1000.0
                LogStore.shared.log(String(format: "[early-detach] rev=ml524 took %.0f ms", dms),
                             level: dms > 5000 ? .error : .success)
            } else if !earlyDetach {
                LogStore.shared.log("[early-detach] rev=ml524 DISABLED — debugger stays attached all run")
            }

            winios_phase("detach-done")

            // Step 2: Start wineserver
            self.startWineserver()
            winios_phase("wineserver-up")
            self.publish(.starting("Starting Windows…"))

            // Step 3: Start Wine (debugger still attached for PE loading BRK calls)
            Thread.sleep(forTimeInterval: 2.0)
            winios_phase("wine-start")
            self.publish(.starting("Loading game…"))
            self.startWineProcess()

            // Step 4: Wait for Wine to finish instead of fixed timer
            // Poll wine_process_is_running() — it clears when __wine_main returns
            // For real games this never returns (message loop runs forever), so
            // the cap is what matters. After detach, the dual-mapped JIT pool
            // keeps existing blocks executable; only NEW BRK-based compiles
            // fail.
            //
            // 2026-05-13 first-frame: Thumper splash renders at ~50s but JIT is
            // STILL compiling new FMOD blocks 3M log lines later — audio init
            // is huge (~14k unique RIPs in fmod64.dll alone). Bumped to 300s
            // to let FMOD finish init before debugger detach; otherwise main
            // game loop never engages because Present is gated on audio ready.
            LogStore.shared.log("Waiting for Wine to finish PE loading...")
            // 2026-07-03 early detach: attached-mode runs the whole guest
            // ~2x slower (measured 1.2s → 0.74s per present at detach) and
            // on iOS 27 presented frames only reliably reach glass after
            // detach. Post-detach is safe now: trap-mode JIT writes go via
            // the Mach emulator (no debugger), pool pages are pre-executable
            // (dual map), page0 runs once on the first thread, and a
            // post-detach compile was observed working (real_compiles
            // 7093→7094, no faults). So: detach once the game is actually
            // presenting (present #2 = first post-splash frame) plus a
            // settle window, instead of waiting out the full 1200s cap.
            let maxWait = 1200.0  // hard safety cap (unchanged)
            // 2026-07-03 second iteration: detach on present #1 (splash shown)
            // instead of #2. The 3-minute splash-hold is the game loading —
            // running it detached should roughly halve it. Riskier than #2
            // (thousands of load-time compiles + worker-thread spawns happen
            // post-detach) but all known dependencies are covered: trap-mode
            // writes, pre-executable pool, page0 once-guard.
            let settleAfterFirstPresent = 20.0
            var presentingSince: CFAbsoluteTime? = nil
            let pollStart = CFAbsoluteTimeGetCurrent()
            var lastHeartbeat = CFAbsoluteTimeGetCurrent()
            while wine_process_is_running() != 0 {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CFAbsoluteTimeGetCurrent()
                // Diagnostic heartbeat: 2026-07-03's detach-at-#1 run never
                // triggered despite presents visibly counting — log what this
                // loop actually observes so that can't happen silently again.
                if now - lastHeartbeat > 30 {
                    lastHeartbeat = now
                    LogStore.shared.log("detach-wait: presents=\(madeira_get_present_count()) running=\(wine_process_is_running()) elapsed=\(Int(now - pollStart))s")
                }
                // Task #25: the present heuristic is meaningless in desktop
                // mode — ANY child presenting (cube, a game window) trips it
                // mid-session, and later program launches still need the
                // attached-debugger facilities. Desktop sessions stay
                // attached until the desktop exits (or the safety cap).
                let isDesktopSession = getenv("MADEIRA_DESKTOP").map { $0.pointee == 49 } ?? false
                if !isDesktopSession {
                    if presentingSince == nil && madeira_get_present_count() >= 1 {
                        presentingSince = now
                        self.publish(.running)
                        LogStore.shared.log("Game is presenting (#1, splash) — early detach in \(Int(settleAfterFirstPresent))s")
                    }
                    if let t = presentingSince, now - t > settleAfterFirstPresent {
                        LogStore.shared.log("Early detach: game presenting and settled", level: .success)
                        break
                    }
                }
                if now - pollStart > maxWait {
                    LogStore.shared.log("Wine still running after \(Int(maxWait))s, proceeding with detach", level: .error)
                    break
                }
            }
            let wineElapsed = CFAbsoluteTimeGetCurrent() - pollStart
            LogStore.shared.log("Wine finished after \(String(format: "%.1f", wineElapsed))s")
            if wine_process_is_running() == 0 { self.publish(.exited) }

            // Step 5: Resume UI + os_log, give main thread time to recover before detach
            DispatchQueue.main.async {
                ws_log_quiet = 0
                LogStore.shared.uiPaused = false
            }
            Thread.sleep(forTimeInterval: 2.0)

            // Step 6: Detach debugger — main thread should have zero accumulated hang time
            LogStore.shared.log("Detaching debugger...")
            StikJITHelper.detachDebugger()

            DispatchQueue.main.async { heartbeat.invalidate() }
        }
    }

    private func startWineserver() {
        LogStore.shared.log("Starting wineserver...")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        LogStore.shared.log("Wine prefix: \(winePrefixPath)")

        let result = wineserver_start(winePrefixPath)
        if result == 0 {
            LogStore.shared.log("Wineserver thread launched successfully", level: .success)
        } else {
            LogStore.shared.log("Failed to start wineserver (error: \(result))", level: .error)
        }
    }

    private func startWineProcess() {
        LogStore.shared.log("Starting Wine process...")

        if wineserver_is_running() == 0 {
            LogStore.shared.log("Wineserver not running! Start it first.", level: .error)
            return
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        // Call synchronously — caller already waited for wineserver to be ready
        let result = wine_process_start(winePrefixPath)
        if result == 0 {
            LogStore.shared.log("Wine process thread launched", level: .success)
        } else {
            LogStore.shared.log("Failed to start Wine process (error: \(result))", level: .error)
        }
    }
}
