// kitchen: the wine-kitchen command-line tool. Built into every app as
// Resources/bin/kitchen and used by the build, the installer and agents.
//
//   kitchen scan <dir>        JSON report on a game folder's executables
//
// Subcommands are added as recipes need them (docs/RECIPES.md).
import Foundation
import CryptoKit

// MARK: - PE reading

struct PEError: Error { let message: String }

/// Minimal read-only view of a Windows PE file: headers, sections, imports, version.
struct PEFile {
    let data: Data
    let is64: Bool
    let machine: UInt16
    let subsystem: UInt16
    let sections: [(name: String, rva: UInt32, virtualSize: UInt32, rawSize: UInt32, rawOffset: UInt32)]
    let dataDirectories: [(rva: UInt32, size: UInt32)]

    init(data: Data) throws {
        self.data = data
        guard data.count >= 0x40, data.u16(0) == 0x5A4D else { throw PEError(message: "not an MZ file") }
        let pe = Int(data.u32(0x3C))
        guard pe > 0, pe + 24 <= data.count, data.u32(pe) == 0x0000_4550 else { throw PEError(message: "no PE header") }
        machine = data.u16(pe + 4)
        let sectionCount = Int(data.u16(pe + 6))
        let optionalSize = Int(data.u16(pe + 20))
        let opt = pe + 24
        guard opt + 2 <= data.count else { throw PEError(message: "truncated optional header") }
        let magic = data.u16(opt)
        guard magic == 0x10B || magic == 0x20B else { throw PEError(message: "unknown optional header magic") }
        is64 = magic == 0x20B
        subsystem = data.u16(opt + 68)
        let dirStart = opt + (is64 ? 112 : 96)
        let dirCount = min(Int(data.u32(dirStart - 4)), 16)
        var dirs: [(UInt32, UInt32)] = []
        for i in 0..<dirCount where dirStart + 8 * i + 8 <= data.count {
            dirs.append((data.u32(dirStart + 8 * i), data.u32(dirStart + 8 * i + 4)))
        }
        dataDirectories = dirs
        var secs: [(String, UInt32, UInt32, UInt32, UInt32)] = []
        let secStart = opt + optionalSize
        for i in 0..<sectionCount {
            let s = secStart + 40 * i
            guard s + 40 <= data.count else { break }
            let nameBytes = data.subdata(in: s..<s + 8).prefix { $0 != 0 }
            secs.append((String(decoding: nameBytes, as: UTF8.self),
                         data.u32(s + 12), data.u32(s + 8), data.u32(s + 16), data.u32(s + 20)))
        }
        sections = secs.map { (name: $0.0, rva: $0.1, virtualSize: $0.2, rawSize: $0.3, rawOffset: $0.4) }
    }

    /// File offset for an RVA, or nil when it falls outside every section's file data.
    func offset(ofRVA rva: UInt32) -> Int? {
        for s in sections {
            let size = max(s.virtualSize, s.rawSize)
            if rva >= s.rva, rva < s.rva &+ size {
                let off = Int(rva - s.rva) + Int(s.rawOffset)
                return off < data.count ? off : nil
            }
        }
        return nil
    }

    func cString(atRVA rva: UInt32) -> String? {
        guard let start = offset(ofRVA: rva) else { return nil }
        guard let end = data[start...].firstIndex(of: 0), end - start < 512 else { return nil }
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    /// Imported DLL names, or nil when the import table cannot be read (packed or
    /// encrypted executables, such as the Half-Life engine DLLs).
    func importedDLLs() -> [String]? {
        guard dataDirectories.count > 1 else { return [] }
        let dir = dataDirectories[1]
        if dir.rva == 0 { return [] }
        guard var desc = offset(ofRVA: dir.rva) else { return nil }
        var names: [String] = []
        while desc + 20 <= data.count, names.count < 256 {
            let nameRVA = data.u32(desc + 12)
            if nameRVA == 0 && data.u32(desc) == 0 && data.u32(desc + 16) == 0 { return names }
            guard let name = cString(atRVA: nameRVA), !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && !$0.isNewline }) else { return nil }
            names.append(name)
            desc += 20
        }
        return nil
    }

    /// FileVersion from VS_FIXEDFILEINFO plus a few StringFileInfo values.
    func versionInfo() -> [String: String] {
        var info: [String: String] = [:]
        let fixedSig = Data([0xBD, 0x04, 0xEF, 0xFE])
        guard let r = resourceSection(), let sig = data.range(of: fixedSig, in: r) else { return info }
        let f = sig.lowerBound
        if f + 16 <= data.count {
            let ms = data.u32(f + 8), ls = data.u32(f + 12)
            info["FileVersion"] = "\(ms >> 16).\(ms & 0xFFFF).\(ls >> 16).\(ls & 0xFFFF)"
        }
        for key in ["ProductName", "FileDescription", "CompanyName", "OriginalFilename"] {
            if let value = stringFileInfo(key, in: r) { info[key] = value }
        }
        return info
    }

    private func resourceSection() -> Range<Int>? {
        guard dataDirectories.count > 2, dataDirectories[2].rva != 0,
              let start = offset(ofRVA: dataDirectories[2].rva) else { return nil }
        return start..<min(data.count, start + Int(dataDirectories[2].size))
    }

    private func stringFileInfo(_ key: String, in range: Range<Int>) -> String? {
        let keyData = (key + "\0").data(using: .utf16LittleEndian)!
        guard let k = data.range(of: keyData, in: range) else { return nil }
        var p = (k.upperBound + 3) & ~3          // value is DWORD-aligned after the key
        var chars: [UInt16] = []
        while p + 2 <= range.upperBound, chars.count < 200 {
            let c = data.u16(p)
            if c == 0 { break }
            chars.append(c); p += 2
        }
        let s = String(decoding: chars, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

extension Data {
    func u16(_ o: Int) -> UInt16 { o + 2 <= count ? UInt16(self[o]) | UInt16(self[o + 1]) << 8 : 0 }
    func u32(_ o: Int) -> UInt32 { o + 4 <= count ? UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 : 0 }
}

// MARK: - scan

/// What an imported (or bundled) DLL says about a game's needs.
let apiClasses: [(category: String, api: String, dlls: [String])] = [
    ("graphics", "ddraw", ["ddraw.dll"]),
    ("graphics", "d3d8", ["d3d8.dll"]),
    ("graphics", "d3d9", ["d3d9.dll", "d3dx9_*.dll"]),
    ("graphics", "d3d10-11", ["d3d10*.dll", "d3d11.dll", "dxgi.dll", "d3dx10*.dll", "d3dx11*.dll"]),
    ("graphics", "d3d12", ["d3d12.dll"]),
    ("graphics", "opengl", ["opengl32.dll"]),
    ("graphics", "glide", ["glide*.dll"]),
    ("graphics", "gdi", ["gdi32.dll"]),
    ("audio", "directsound", ["dsound.dll"]),
    ("audio", "winmm", ["winmm.dll"]),
    ("audio", "xaudio2", ["xaudio2*.dll"]),
    ("audio", "miles", ["mss32.dll", "mss16.dll"]),
    ("audio", "fmod", ["fmod*.dll"]),
    ("audio", "openal", ["openal32.dll"]),
    ("input", "directinput", ["dinput.dll", "dinput8.dll"]),
    ("input", "xinput", ["xinput*.dll"]),
    ("network", "winsock", ["wsock32.dll", "ws2_32.dll"]),
    ("network", "directplay", ["dplayx.dll", "dplay.dll"]),
    ("video", "bink", ["binkw32.dll", "binkw64.dll"]),
    ("video", "smacker", ["smackw32.dll"]),
    ("video", "vfw", ["msvfw32.dll"]),
]

/// Files whose presence in a game folder matters, by what they are.
let knownFiles: [(kind: String, pattern: String, note: String)] = [
    ("wrapper", "ddraw.dll", "local DirectDraw wrapper (e.g. cnc-ddraw, dgVoodoo): loaded even when the game runs in GDI mode"),
    ("wrapper", "d3d8.dll", "local Direct3D 8 wrapper"),
    ("wrapper", "d3d9.dll", "local Direct3D 9 wrapper (e.g. DXVK)"),
    ("wrapper", "dxgi.dll", "local DXGI wrapper (e.g. DXVK)"),
    ("wrapper", "d3d11.dll", "local Direct3D 11 wrapper"),
    ("wrapper", "opengl32.dll", "local OpenGL replacement"),
    ("wrapper", "dinput.dll", "local DirectInput wrapper"),
    ("wrapper", "dinput8.dll", "local DirectInput 8 wrapper"),
    ("wrapper", "winmm.dll", "local WinMM replacement (often a CD-audio emulator)"),
    ("wrapper", "glide*.dll", "Glide wrapper (e.g. nGlide, dgVoodoo)"),
    ("protection", "secdrv.sys", "SafeDisc driver leftover: not needed, cannot run"),
    ("protection", "drvmgt.dll", "SafeDisc leftover"),
    ("protection", "clcd16.dll", "SafeDisc leftover"),
    ("protection", "clcd32.dll", "SafeDisc leftover"),
    ("protection", "*.icd", "SafeDisc encrypted executable leftover"),
    ("store", "steam_api.dll", "Steam API: the game may need Steam running"),
    ("store", "steam_api64.dll", "Steam API: the game may need Steam running"),
    ("store", "goggame*.dll", "GOG Galaxy integration (usually optional)"),
]

func matches(_ name: String, _ pattern: String) -> Bool {
    fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
}

func classify(_ dlls: [String]) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for dll in dlls {
        for c in apiClasses where c.dlls.contains(where: { matches(dll, $0) }) {
            if !(out[c.category]?.contains(c.api) ?? false) { out[c.category, default: []].append(c.api) }
        }
    }
    return out
}

/// Evidence for packed executables: which API DLL names appear as plain strings.
func stringHints(_ data: Data) -> [String] {
    let wanted = apiClasses.flatMap { $0.dlls }.filter { !$0.contains("*") } + ["d3d11.dll", "vulkan-1.dll"]
    let lower = String(decoding: data.map { (0x41...0x5A).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    return Array(Set(wanted.filter { lower.contains($0) })).sorted()
}

func md5(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func scan(_ given: URL) throws -> [String: Any] {
    // The walker returns symlink-resolved paths (a Wineskin drive_c is a link), so
    // resolve the root the same way before cutting paths relative to it.
    let root = given.resolvingSymlinksInPath()
    let fm = FileManager.default
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
        throw PEError(message: "cannot read \(root.path)")
    }
    var executables: [[String: Any]] = []
    var found: [[String: String]] = []
    for case let url as URL in walker {
        let full = url.resolvingSymlinksInPath().path
        guard full.hasPrefix(root.path + "/") else { continue }
        let rel = String(full.dropFirst(root.path.count + 1))
        if rel.split(separator: "/").count > 4 { walker.skipDescendants(); continue }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        let name = url.lastPathComponent
        for k in knownFiles where matches(name, k.pattern) {
            found.append(["path": rel, "kind": k.kind, "note": k.note])
        }
        let ext = url.pathExtension.lowercased()
        guard ext == "exe" || ext == "dll", let data = try? Data(contentsOf: url) else { continue }
        var entry: [String: Any] = ["path": rel, "size": data.count, "md5": md5(data)]
        do {
            let pe = try PEFile(data: data)
            entry["arch"] = pe.machine == 0x8664 ? "x86_64" : pe.machine == 0x14C ? "i386" : String(format: "0x%04x", pe.machine)
            entry["subsystem"] = pe.subsystem == 2 ? "gui" : pe.subsystem == 3 ? "console" : "other(\(pe.subsystem))"
            if let imports = pe.importedDLLs() {
                entry["imports"] = imports
                entry["apis"] = classify(imports)
            } else {
                entry["imports"] = "unreadable"
                let hints = stringHints(data)
                entry["stringHints"] = hints
                entry["apis"] = classify(hints)
            }
            let version = pe.versionInfo()
            if !version.isEmpty { entry["version"] = version }
        } catch let e as PEError {
            // not a readable PE at all (encrypted engine DLLs): keep the string evidence
            entry["error"] = e.message
            let hints = stringHints(data)
            entry["stringHints"] = hints
            entry["apis"] = classify(hints)
        }
        executables.append(entry)
    }
    executables.sort { ($0["path"] as! String) < ($1["path"] as! String) }
    return ["dir": root.path, "executables": executables, "found": found,
            "suggestion": suggest(executables, found)]
}

/// A starting point for a recipe, never applied automatically.
func suggest(_ exes: [[String: Any]], _ found: [[String: String]]) -> [String: Any] {
    func apis(_ e: [String: Any], _ cat: String) -> [String] { (e["apis"] as? [String: [String]])?[cat] ?? [] }
    func isGame(_ e: [String: Any]) -> Bool {
        (e["path"] as! String).lowercased().hasSuffix(".exe") && e["subsystem"] as? String == "gui"
    }
    let rank = ["d3d12", "d3d10-11", "d3d9", "d3d8", "opengl", "glide", "ddraw", "gdi"]
    // Uninstallers, setup and settings tools import the same APIs as the game.
    let utilityNames = ["unins*", "uninstal*", "setup*", "*conf*", "*tweak*", "*settings*",
                        "dxsetup*", "vcredist*", "dotnet*", "*crashreport*", "*updater*",
                        "hlds*", "srcds*", "*server*", "*dedicated*"]
    func score(_ e: [String: Any]) -> Int {
        let g = apis(e, "graphics")
        let best = rank.firstIndex { g.contains($0) } ?? rank.count
        let name = ((e["path"] as! String) as NSString).lastPathComponent
        let utility = utilityNames.contains { matches(name, $0) } ? 100 : 0
        return (rank.count - best) * 10 + (apis(e, "audio").isEmpty ? 0 : 3) + (apis(e, "input").isEmpty ? 0 : 1) - utility
    }
    // Equal scores are common (a game, its editor and an autorun menu import the
    // same APIs), so the largest executable wins the tie and every executable with
    // the top score is listed for the recipe to choose from.
    func depth(_ e: [String: Any]) -> Int { (e["path"] as! String).split(separator: "/").count }
    let candidates = exes.filter(isGame).sorted {
        if score($0) != score($1) { return score($0) > score($1) }
        if depth($0) != depth($1) { return depth($0) < depth($1) }
        return ($0["size"] as? Int ?? 0) > ($1["size"] as? Int ?? 0)
    }
    var notes: [String] = []
    var out: [String: Any] = [:]
    if let top = candidates.first {
        out["mainExe"] = top["path"]
        out["candidates"] = candidates.filter { score($0) == score(top) }.map { $0["path"]! }
        out["arch"] = top["arch"]
        let g = apis(top, "graphics")
        out["graphics"] = rank.first { g.contains($0) } ?? "unknown"
        let topRenders = !apis(top, "graphics").filter({ $0 != "gdi" }).isEmpty
        if !topRenders {
            let renderers = exes.filter { ($0["path"] as! String).lowercased().hasSuffix(".dll") && !apis($0, "graphics").filter({ $0 != "gdi" }).isEmpty }
            let names = renderers.map { $0["path"] as! String }.joined(separator: ", ")
            notes.append("no executable imports a graphics API beyond GDI: the renderer lives in a DLL" + (names.isEmpty ? "" : " (\(names))") + "; the main exe is a best guess")
        } else {
            for e in candidates.dropFirst() where (e["size"] as? Int ?? 0) < 200_000 && apis(e, "graphics").filter({ $0 != "gdi" }).isEmpty {
                notes.append("\(e["path"]!) looks like a launcher stub; the game is probably \(top["path"]!)")
            }
        }
    }
    for exe in exes where exe["imports"] as? String == "unreadable" || exe["error"] != nil {
        notes.append("\(exe["path"]!) is packed or not a plain PE: its apis come from string hints only")
    }
    for f in found where f["kind"] != nil {
        notes.append("\(f["path"]!): \(f["note"]!)")
    }
    out["notes"] = notes
    return out
}

// MARK: - main

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "scan":
    guard args.count == 3 else { fail("usage: kitchen scan <dir>") }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: args[2], isDirectory: &isDir), isDir.boolValue else {
        fail("kitchen scan: not a folder: \(args[2])")
    }
    do {
        let report = try scan(URL(fileURLWithPath: args[2]).standardizedFileURL)
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(json + "\n".data(using: .utf8)!)
    } catch {
        fail("kitchen scan: \(error)")
    }
default:
    fail("usage: kitchen scan <dir>")
}
