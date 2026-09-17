import Foundation
import SwiftUI
import UIKit

// Game library: what is installed in the prefix, what each executable needs,
// and the per-game profile that turns into a launch configuration.
//
// Everything here is plain data + file I/O. Launching lives in
// WineLauncher.swift, UI in LibraryUI.swift / GameSession.swift.

// MARK: - Paths

enum MadeiraPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var prefix: URL { documents.appendingPathComponent("wine") }
    static var driveC: URL { prefix.appendingPathComponent("drive_c") }
    static var library: URL { documents.appendingPathComponent("madeira-library.json") }
    static var covers: URL { documents.appendingPathComponent("madeira-covers") }
    /// Shader caches live in Documents, not Library/Caches: iOS purges Caches
    /// under storage pressure, and a purged cache means every shader compiles
    /// again on the next launch — the single biggest source of stutter.
    static func dxmtCache(_ id: String) -> URL {
        documents.appendingPathComponent("madeira-cache/dxmt/\(id)", isDirectory: true)
    }
    /// vkd3d-proton reads its cache path through the Windows environment, so it
    /// has to be a Windows path inside the prefix.
    static func vkd3dCacheUnix(_ id: String) -> URL {
        driveC.appendingPathComponent("madeira-cache/vkd3d/\(id)", isDirectory: true)
    }
    static func vkd3dCacheWindows(_ id: String) -> String { "C:\\madeira-cache\\vkd3d\\\(id)" }

    /// drive_c-relative unix path -> C:\ Windows path.
    static func windowsPath(forDriveCRelative rel: String) -> String {
        "C:\\" + rel.replacingOccurrences(of: "/", with: "\\")
    }
}

// MARK: - Detection

enum GameEngine: String, Codable {
    case unreal5, unreal4, unreal, unity, fna, source, other

    var label: String {
        switch self {
        case .unreal5: return "Unreal Engine 5"
        case .unreal4: return "Unreal Engine 4"
        case .unreal:  return "Unreal Engine"
        case .unity:   return "Unity"
        case .fna:     return "FNA / XNA"
        case .source:  return "Source"
        case .other:   return "Native"
        }
    }
    var isUnreal: Bool { self == .unreal5 || self == .unreal4 || self == .unreal }
}

struct DetectedInfo: Codable, Equatable {
    var engine: GameEngine = .other
    var machine: UInt16 = 0            // 0x8664 x86-64, 0x14c i386, 0xaa64 arm64
    var imports: [String] = []         // lower-cased DLL names from the import table
    var exeBytes: Int64 = 0
    var folderDLLBytes: Int64 = 0
    var hasAgilitySDK = false          // D3D12\D3D12Core.dll shipped next to the exe
    var projectName: String?           // Unreal: the project folder that owns Binaries/

    var is64Bit: Bool { machine == 0x8664 }
    var is32Bit: Bool { machine == 0x014c }
    var usesD3D12: Bool { imports.contains("d3d12.dll") || hasAgilitySDK }
    var usesD3D11: Bool { imports.contains("d3d11.dll") }
    var usesVulkan: Bool { imports.contains("vulkan-1.dll") }
    var usesD3D9: Bool { imports.contains("d3d9.dll") }
    var usesOpenGL: Bool { imports.contains("opengl32.dll") }

    /// API label for badges. Unreal loads its RHI dynamically, so imports alone
    /// understate it; an Unreal title shipping the Agility SDK is D3D12-capable.
    var apiLabels: [String] {
        var out: [String] = []
        if usesD3D12 { out.append("DX12") }
        if usesD3D11 || engine.isUnreal || engine == .unity { out.append("DX11") }
        if usesVulkan { out.append("Vulkan") }
        if usesD3D9 { out.append("DX9") }
        if usesOpenGL { out.append("OpenGL") }
        return out
    }
}

/// Minimal, bounds-checked PE reader. Reads only the headers, section table and
/// import directory through a FileHandle, so a 700 MB executable costs a few KB.
enum PEInspector {
    static func inspect(_ url: URL) -> (machine: UInt16, imports: [String])? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        func read(_ offset: UInt64, _ count: Int) -> Data? {
            do {
                try fh.seek(toOffset: offset)
                guard let d = try fh.read(upToCount: count), d.count == count else { return nil }
                return d
            } catch { return nil }
        }
        func u16(_ d: Data, _ o: Int) -> UInt16 {
            guard o + 2 <= d.count else { return 0 }
            return UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8
        }
        func u32(_ d: Data, _ o: Int) -> UInt32 {
            guard o + 4 <= d.count else { return 0 }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(d[d.startIndex + o + i]) << (8 * UInt32(i)) }
            return v
        }

        guard let dos = read(0, 64), u16(dos, 0) == 0x5A4D else { return nil }
        let peOff = UInt64(u32(dos, 0x3C))
        guard peOff > 0, peOff < 16 * 1024 * 1024,
              let hdr = read(peOff, 24 + 240), u32(hdr, 0) == 0x0000_4550 else { return nil }
        let machine = u16(hdr, 4)
        let nsec = Int(u16(hdr, 6))
        let optSize = Int(u16(hdr, 20))
        let opt = 24
        let magic = u16(hdr, opt)
        // Data directories: PE32+ at 112, PE32 at 96. Import dir = entry 1.
        let dirs = opt + (magic == 0x20B ? 112 : 96)
        let importRVA = u32(hdr, dirs + 8)
        guard nsec > 0, nsec < 96,
              let secs = read(peOff + 24 + UInt64(optSize), nsec * 40) else { return (machine, []) }

        struct Sec { let va: UInt32; let vsize: UInt32; let raw: UInt32; let rawSize: UInt32 }
        var sections: [Sec] = []
        for i in 0..<nsec {
            let b = i * 40
            sections.append(Sec(va: u32(secs, b + 12), vsize: u32(secs, b + 8),
                                raw: u32(secs, b + 20), rawSize: u32(secs, b + 16)))
        }
        func rvaToOffset(_ rva: UInt32) -> UInt64? {
            for s in sections {
                let span = max(s.vsize, s.rawSize)
                if rva >= s.va && rva < s.va &+ span {
                    return UInt64(s.raw) + UInt64(rva - s.va)
                }
            }
            return nil
        }
        guard importRVA != 0, let impOff = rvaToOffset(importRVA) else { return (machine, []) }

        var names: [String] = []
        for i in 0..<512 {                      // 20-byte descriptors, null-terminated list
            guard let desc = read(impOff + UInt64(i * 20), 20) else { break }
            let nameRVA = u32(desc, 12)
            if nameRVA == 0 { break }
            guard let nOff = rvaToOffset(nameRVA), let raw = read(nOff, 64) else { continue }
            let bytes = raw.prefix { $0 != 0 }
            if let s = String(bytes: bytes, encoding: .ascii), !s.isEmpty {
                names.append(s.lowercased())
            }
        }
        return (machine, names)
    }
}

// MARK: - Profile

enum PerformancePreset: String, Codable, CaseIterable, Identifiable {
    case battery, balanced, performance, quality, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .battery: return "Battery"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        case .quality: return "Quality"
        case .custom: return "Custom"
        }
    }
    var symbol: String {
        switch self {
        case .battery: return "leaf"
        case .balanced: return "scalemass"
        case .performance: return "bolt"
        case .quality: return "sparkles"
        case .custom: return "slider.horizontal.3"
        }
    }
    var blurb: String {
        switch self {
        case .battery: return "540p, MetalFX, 30 FPS cap. Coolest and longest sessions."
        case .balanced: return "720p, MetalFX, 60 FPS cap. The sensible default."
        case .performance: return "540p, MetalFX, uncapped at 120 Hz. Highest frame rate."
        case .quality: return "900p, native scaling, 60 FPS cap. Sharpest image, most heat."
        case .custom: return "Your own settings below."
        }
    }
}

enum GraphicsAPIChoice: String, Codable, CaseIterable, Identifiable {
    case auto, dx11, dx12
    var id: String { rawValue }
    var label: String {
        switch self { case .auto: return "Auto"; case .dx11: return "DirectX 11"; case .dx12: return "DirectX 12" }
    }
}

enum AspectChoice: String, Codable, CaseIterable, Identifiable {
    case wide, screen, classic
    var id: String { rawValue }
    var label: String {
        switch self { case .wide: return "16:9"; case .screen: return "Full screen"; case .classic: return "4:3" }
    }
}

/// x86 memory-ordering (TSO) emulation. FEX's own description: disabling it is
/// "highly likely to break any multithreaded application", so the fast mode is
/// an explicit, per-game opt-in — never part of a preset.
enum TSOChoice: String, Codable, CaseIterable, Identifiable {
    case accurate, fast
    var id: String { rawValue }
    var label: String { self == .accurate ? "Accurate" : "Fast (unsafe)" }
}

struct GameProfile: Codable, Equatable {
    var preset: PerformancePreset = .balanced
    var api: GraphicsAPIChoice = .auto
    var aspect: AspectChoice = .wide

    // Custom-only (presets supply their own values)
    var renderHeight: Int = 720
    var metalFX: Bool = true
    var frameLimit: Int = 60            // 0 = uncapped
    var highRefresh: Bool = false       // unlock presents to ProMotion 120 Hz

    // CPU
    var x87Reduced: Bool = true
    var tso: TSOChoice = .accurate
    var multiblock: Bool = true

    // Memory
    var jitPoolMB: Int = 0              // 0 = sized automatically from the binaries
    var bcMipClamp: Int = 0             // drop this many top mips from BC textures (DX11)

    // Launch
    var extraArgs: String = ""
    var extraEnv: String = ""           // KEY=VALUE per line
    var verboseLogging: Bool = false
    var touchControls: Bool = true

    struct Effective {
        var renderHeight: Int
        var metalFX: Bool
        var frameLimit: Int
        var highRefresh: Bool
    }

    var effective: Effective {
        switch preset {
        case .battery:     return .init(renderHeight: 540, metalFX: true, frameLimit: 30, highRefresh: false)
        case .balanced:    return .init(renderHeight: 720, metalFX: true, frameLimit: 60, highRefresh: false)
        case .performance: return .init(renderHeight: 540, metalFX: true, frameLimit: 0, highRefresh: true)
        case .quality:     return .init(renderHeight: 900, metalFX: false, frameLimit: 60, highRefresh: false)
        case .custom:      return .init(renderHeight: renderHeight, metalFX: metalFX,
                                        frameLimit: frameLimit, highRefresh: highRefresh)
        }
    }
}

// Tolerant decoding: settings saved by one version must load in the next, so a
// missing or unrecognised field falls back to its default instead of dropping
// the whole library.
extension GameProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameProfile()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        preset = v(.preset, d.preset)
        api = v(.api, d.api)
        aspect = v(.aspect, d.aspect)
        renderHeight = v(.renderHeight, d.renderHeight)
        metalFX = v(.metalFX, d.metalFX)
        frameLimit = v(.frameLimit, d.frameLimit)
        highRefresh = v(.highRefresh, d.highRefresh)
        x87Reduced = v(.x87Reduced, d.x87Reduced)
        tso = v(.tso, d.tso)
        multiblock = v(.multiblock, d.multiblock)
        jitPoolMB = v(.jitPoolMB, d.jitPoolMB)
        bcMipClamp = v(.bcMipClamp, d.bcMipClamp)
        extraArgs = v(.extraArgs, d.extraArgs)
        extraEnv = v(.extraEnv, d.extraEnv)
        verboseLogging = v(.verboseLogging, d.verboseLogging)
        touchControls = v(.touchControls, d.touchControls)
    }
}

extension DetectedInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DetectedInfo()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        engine = v(.engine, d.engine)
        machine = v(.machine, d.machine)
        imports = v(.imports, d.imports)
        exeBytes = v(.exeBytes, d.exeBytes)
        folderDLLBytes = v(.folderDLLBytes, d.folderDLLBytes)
        hasAgilitySDK = v(.hasAgilitySDK, d.hasAgilitySDK)
        projectName = v(.projectName, d.projectName)
    }
}

// MARK: - Entry

struct GameEntry: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var relExe: String                 // path relative to drive_c, "/"-separated
    var detected: DetectedInfo
    var profile = GameProfile()
    var addedAt = Date()
    var lastPlayed: Date?
    var launches: Int = 0

    static func == (a: GameEntry, b: GameEntry) -> Bool {
        a.id == b.id && a.title == b.title && a.relExe == b.relExe && a.detected == b.detected
            && a.profile == b.profile && a.lastPlayed == b.lastPlayed && a.launches == b.launches
    }
    func hash(into h: inout Hasher) { h.combine(id) }

    var windowsExe: String { MadeiraPaths.windowsPath(forDriveCRelative: relExe) }
    var unixExe: URL { MadeiraPaths.driveC.appendingPathComponent(relExe) }
    var exeName: String { (relExe as NSString).lastPathComponent }

    var resolvedAPI: GraphicsAPIChoice {
        switch profile.api {
        case .dx11, .dx12: return profile.api
        case .auto:
            // DXMT (D3D11) is the mature path on this device. Only pick D3D12
            // when the title cannot do D3D11 at all.
            if detected.usesD3D12 && !detected.usesD3D11 && !detected.engine.isUnreal && detected.engine != .unity {
                return .dx12
            }
            return .dx11
        }
    }

    /// Plain-language warnings, shown on the game page. Honest limits, not guesses.
    var compatibilityNotes: [String] {
        var n: [String] = []
        if detected.is32Bit {
            n.append("32-bit (x86) executable. This build runs x86-64 only, so it will not start.")
        }
        if detected.usesVulkan && !detected.usesD3D11 && !detected.usesD3D12 {
            n.append("Vulkan-only titles need winevulkan with MoltenVK, which is only exercised by DX12 here.")
        }
        if detected.usesOpenGL && !detected.usesD3D11 && !detected.usesD3D12 {
            n.append("OpenGL has no backend on iOS.")
        }
        if detected.exeBytes > 400 * 1024 * 1024 {
            n.append("Very large executable (\(ByteCountFormatter.string(fromByteCount: detected.exeBytes, countStyle: .file))). Its image is copied into the JIT pool, which counts against the memory limit.")
        }
        if detected.engine.isUnreal && profile.api == .auto {
            n.append("Unreal picks its renderer at launch. If the game reports a DirectX error, set Graphics API to DirectX 12.")
        }
        if resolvedAPI == .dx12 {
            n.append("DirectX 12 runs through vkd3d-proton and MoltenVK: no mesh shaders, no ray tracing, feature level 12_1 at most.")
        }
        return n
    }
}

// MARK: - Store

@MainActor
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    @Published private(set) var games: [GameEntry] = []
    @Published var scanning = false
    @Published var lastScanMessage: String?

    private init() { load() }

    var recent: [GameEntry] {
        games.filter { $0.lastPlayed != nil }
             .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }
    var alphabetical: [GameEntry] {
        games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func game(_ id: String) -> GameEntry? { games.first { $0.id == id } }

    func update(_ entry: GameEntry) {
        if let i = games.firstIndex(where: { $0.id == entry.id }) { games[i] = entry } else { games.append(entry) }
        save()
    }

    func remove(_ id: String) {
        games.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: coverURL(id))
        save()
    }

    func markLaunched(_ id: String) {
        guard var g = game(id) else { return }
        g.lastPlayed = Date()
        g.launches += 1
        update(g)
    }

    // MARK: covers

    func coverURL(_ id: String) -> URL { MadeiraPaths.covers.appendingPathComponent("\(id).jpg") }

    func coverImage(_ id: String) -> UIImage? {
        UIImage(contentsOfFile: coverURL(id).path)
    }

    func setCover(_ id: String, data: Data) {
        guard let img = UIImage(data: data) else { return }
        // Store a bounded JPEG: covers are drawn at most ~600 pt tall.
        let maxSide: CGFloat = 1200
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let r = UIGraphicsImageRenderer(size: size)
        let out = r.jpegData(withCompressionQuality: 0.88) { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        try? FileManager.default.createDirectory(at: MadeiraPaths.covers, withIntermediateDirectories: true)
        try? out.write(to: coverURL(id), options: .atomic)
        objectWillChange.send()
    }

    // MARK: persistence

    private func load() {
        guard let d = try? Data(contentsOf: MadeiraPaths.library) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([GameEntry].self, from: d) { games = list }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(games) else { return }
        try? d.write(to: MadeiraPaths.library, options: .atomic)
    }

    // MARK: scanning

    /// Adds one executable (drive_c-relative path). Returns the entry.
    @discardableResult
    func addExecutable(relPath: String, title: String? = nil) -> GameEntry {
        let id = GameScanner.stableID(relPath)
        if let existing = game(id) { return existing }
        let url = MadeiraPaths.driveC.appendingPathComponent(relPath)
        let entry = GameEntry(id: id,
                              title: title ?? GameScanner.title(forExe: url),
                              relExe: relPath,
                              detected: GameScanner.detect(exe: url))
        update(entry)
        return entry
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        lastScanMessage = nil
        let known = Set(games.map(\.relExe))
        Task.detached(priority: .userInitiated) {
            let found = GameScanner.scan(root: MadeiraPaths.driveC)
            await MainActor.run {
                var added = 0
                for f in found where !known.contains(f.relExe) {
                    self.update(f)
                    added += 1
                }
                self.scanning = false
                self.lastScanMessage = added == 0
                    ? "No new games found in drive_c."
                    : "Added \(added) game\(added == 1 ? "" : "s")."
            }
        }
    }
}

enum GameScanner {
    /// Executables that are never the game itself.
    private static let ignoredNames: [String] = [
        "unins", "uninstall", "setup", "install", "crashreport", "crashhandler", "crashpad",
        "redist", "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "directx", "ue4prereq",
        "ueprereq", "epicwebhelper", "unitycrashhandler", "quicksfv", "dotnet", "steamerrorreporter",
        "cefprocess", "helper", "launcherpatcher", "easyanticheat", "battleye", "7z", "notification",
        "update", "bugreport", "cleanup", "benchmark_tool", "cmd.exe", "explorer.exe",
    ]
    private static let skippedDirs: Set<String> = [
        "windows", "programdata", "content", "paks", "movies", "_commonredist", "_redist",
        "redist", "directx", "dotnet", "logs", "saved", "madeira-cache", "__installer",
        "engine/content", "engine/extras", "shadercache", "cache",
    ]

    static func stableID(_ rel: String) -> String {
        // FNV-1a over the lower-cased path: stable across launches and reinstalls.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in rel.lowercased().utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        return String(format: "%016llx", h)
    }

    static func title(forExe url: URL) -> String {
        let generic: Set<String> = ["bin", "binaries", "win64", "x64", "win32", "game", "build", "release", "shipping"]
        var dir = url.deletingLastPathComponent()
        // Unreal: <Root>/<Project>/Binaries/Win64/<exe> -> <Root>
        if url.lastPathComponent.lowercased().contains("-win64-shipping") {
            dir = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        while generic.contains(dir.lastPathComponent.lowercased()), dir.pathComponents.count > 2 {
            dir = dir.deletingLastPathComponent()
        }
        var name = dir.lastPathComponent
        if name.lowercased() == "drive_c" || name.lowercased().hasPrefix("program files") {
            name = url.deletingPathExtension().lastPathComponent
        }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    static func detect(exe url: URL) -> DetectedInfo {
        var info = DetectedInfo()
        let fm = FileManager.default
        if let pe = PEInspector.inspect(url) {
            info.machine = pe.machine
            info.imports = pe.imports
        }
        info.exeBytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let dir = url.deletingLastPathComponent()
        let siblings = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let lower = Set(siblings.map { $0.lowercased() })
        var dllBytes: Int64 = 0
        for s in siblings where s.lowercased().hasSuffix(".dll") {
            dllBytes += (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(s).path)[.size] as? Int64) ?? 0
        }
        info.folderDLLBytes = dllBytes
        info.hasAgilitySDK = fm.fileExists(atPath: dir.appendingPathComponent("D3D12/D3D12Core.dll").path)

        let name = url.lastPathComponent.lowercased()
        if name.contains("-win64-shipping") || name.contains("-wingdk-shipping") {
            // <Root>/<Project>/Binaries/Win64
            let project = dir.deletingLastPathComponent().deletingLastPathComponent()
            info.projectName = project.lastPathComponent
            let root = project.deletingLastPathComponent()
            // UE5 ships Engine/Binaries/ThirdParty/... and D3D12 Agility SDK by default;
            // UE5-only markers make the split reliable enough for a badge.
            let engineDir = root.appendingPathComponent("Engine")
            let ue5Markers = ["Engine/Binaries/ThirdParty/Windows/WinPixEventRuntime",
                              "Engine/Plugins/Runtime/Nvidia/Streamline",
                              "Engine/Binaries/ThirdParty/DbgHelp"]
            let hasUE5 = ue5Markers.contains { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
            if fm.fileExists(atPath: engineDir.path) {
                info.engine = (hasUE5 && info.hasAgilitySDK) ? .unreal5 : .unreal4
            } else {
                info.engine = .unreal
            }
        } else if lower.contains("unityplayer.dll") {
            info.engine = .unity
        } else if lower.contains("fna3d.dll") || lower.contains("fna.dll") || lower.contains("microsoft.xna.framework.dll") {
            info.engine = .fna
        } else if lower.contains("engine.dll") && lower.contains("tier0.dll") {
            info.engine = .source
        }
        return info
    }

    /// Walks drive_c for game executables, one entry per game root.
    static func scan(root: URL) -> [GameEntry] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var candidates: [URL] = []
        for case let url as URL in en {
            let depth = url.standardizedFileURL.pathComponents.count - rootDepth
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let n = url.lastPathComponent.lowercased()
                if depth > 6 || skippedDirs.contains(n) || (depth == 1 && n == "users") {
                    en.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let n = url.lastPathComponent.lowercased()
            if ignoredNames.contains(where: { n.contains($0) }) { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size < 150 * 1024 { continue }          // stubs and tools
            candidates.append(url)
        }

        // Group by title (which already collapses Unreal's launcher + shipping exe),
        // then prefer the Shipping binary, else the largest executable.
        var byTitle: [String: [URL]] = [:]
        for c in candidates { byTitle[title(forExe: c), default: []].append(c) }
        var out: [GameEntry] = []
        let rootPath = root.standardizedFileURL.path
        for (t, urls) in byTitle {
            let best = urls.first { $0.lastPathComponent.lowercased().contains("-shipping") }
                ?? urls.max { a, b in
                    ((try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        < ((try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            guard let exe = best else { continue }
            var rel = exe.standardizedFileURL.path
            if rel.hasPrefix(rootPath) { rel.removeFirst(rootPath.count) }
            while rel.hasPrefix("/") { rel.removeFirst() }
            let info = detect(exe: exe)
            if info.machine != 0 && !info.is64Bit && !info.is32Bit { continue }   // not x86
            out.append(GameEntry(id: stableID(rel), title: t, relExe: rel, detected: info))
        }
        return out.sorted { $0.title < $1.title }
    }
}
