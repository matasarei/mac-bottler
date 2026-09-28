// bottler: the mac-bottler command-line tool. Built into every app as
// Resources/bin/bottler and used by the build, the installer and agents.
//
//   bottler scan <dir>                       JSON report on a game folder's executables
//   bottler hints <game name>                what Lutris' installer scripts know (hints only)
//   bottler icon <exe|image> <out-dir>       rounded macOS icon from the exe's own icon (or an image file)
//   bottler exe-icon <exe> <png-dir> <out>   put that icon into a copy of the exe, in place
//   bottler displays                         JSON list of the connected displays
//   bottler geometry <display|main> <mode> [align]
//                                            where the game window goes, in Win32
//                                            coordinates: "x y width height"
//   bottler frame <display|main> <pid | --wine <Resources>>
//                                            black backdrop behind the game's window
//   bottler prepare-launch <Resources> <variant> <display|main>
//                                            geometry + per-launch INI edits; prints
//                                            shell variables for core/launch.sh
//   bottler menubar hide                     auto-hide the menu bar while playing
//   bottler desktop save|restore <file>      the menu bar and Dock settings, recorded and put back
//   bottler recipe-check <recipe.json>       validate a recipe (docs/RECIPES.md)
//   bottler recipe-field <recipe.json> <field>   one value for the build: title,
//                                            bundleId, engine, proxy.dll, install.registry (one per line)
//   bottler fetch <recipe-dir> <cache> <out> build time: pinned downloads into <out>
//   bottler install <recipe-dir> <source> <game-dir> <icon-dir>
//                                            copy the player's game and apply the recipe
//   bottler ini-set <file> <section> key=value...   edit an INI file (CRLF kept)
//   bottler dock-name <wine dir> <name>      CrossOver engines: the running game shows
//                                            as <name> in the Dock and the menu bar
//
// Observing a running app (for agents; all read-only except click):
//   bottler windows <app>                    JSON: the app's windows (owner, pid, bounds, on screen)
//   bottler shot <out.png> [--app <app> | --window <n> | --rect x,y,w,h]
//                                            screenshot (default: the whole main display)
//   bottler cpu <app> [seconds]              JSON: CPU % per process of the app over an interval
//   bottler click <x> <y>                    a left click at screen point x,y
//   bottler log <app>                        the last launch log
//
// Subcommands are added as recipes need them (docs/RECIPES.md).
import Foundation
import zlib
import CryptoKit
import AppKit
import CoreGraphics
import ImageIO

// MARK: - PE reading

struct PEError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

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

    /// One leaf of the resource tree (type / id / language), numeric ids only.
    struct Resource {
        let type: UInt32, id: UInt32, lang: UInt32
        let entryOffset: Int      // file offset of its IMAGE_RESOURCE_DATA_ENTRY
        let rva: UInt32, size: UInt32
    }

    func resources() -> [Resource] {
        guard dataDirectories.count > 2, dataDirectories[2].rva != 0,
              let base = offset(ofRVA: dataDirectories[2].rva) else { return [] }
        func entries(_ dir: Int) -> [(id: UInt32, target: UInt32)] {
            guard dir + 16 <= data.count else { return [] }
            let count = Int(data.u16(dir + 12)) + Int(data.u16(dir + 14))
            return (0..<min(count, 4096)).compactMap { i in
                let e = dir + 16 + 8 * i
                guard e + 8 <= data.count, data.u32(e) & 0x8000_0000 == 0 else { return nil }  // skip named
                return (data.u32(e), data.u32(e + 4))
            }
        }
        var out: [Resource] = []
        for t in entries(base) where t.target & 0x8000_0000 != 0 {
            for n in entries(base + Int(t.target & 0x7FFF_FFFF)) where n.target & 0x8000_0000 != 0 {
                for l in entries(base + Int(n.target & 0x7FFF_FFFF)) where l.target & 0x8000_0000 == 0 {
                    let e = base + Int(l.target)
                    guard e + 16 <= data.count else { continue }
                    out.append(Resource(type: t.id, id: n.id, lang: l.id, entryOffset: e,
                                        rva: data.u32(e), size: data.u32(e + 4)))
                }
            }
        }
        return out
    }

    func bytes(of r: Resource) -> Data? {
        guard let o = offset(ofRVA: r.rva), o + Int(r.size) <= data.count else { return nil }
        return data.subdata(in: o..<o + Int(r.size))
    }

    /// File byte range of the section holding the resource directory.
    func resourceSectionFileRange() -> Range<Int>? {
        guard dataDirectories.count > 2 else { return nil }
        let rva = dataDirectories[2].rva
        for s in sections where rva >= s.rva && rva < s.rva &+ max(s.virtualSize, s.rawSize) {
            return Int(s.rawOffset)..<Int(s.rawOffset) + Int(s.rawSize)
        }
        return nil
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


// MARK: - icons

let rtIcon: UInt32 = 3, rtGroupIcon: UInt32 = 14

/// Entries of the first icon group: (width, bpp, icon resource id). 0 width means 256.
func iconGroup(_ pe: PEFile) -> (group: PEFile.Resource, entries: [(width: Int, bpp: Int, id: UInt32)])? {
    guard let g = pe.resources().filter({ $0.type == rtGroupIcon }).min(by: { $0.id < $1.id }),
          let d = pe.bytes(of: g), d.count >= 6 else { return nil }
    let count = Int(d.u16(4))
    var entries: [(Int, Int, UInt32)] = []
    for i in 0..<count where 6 + 14 * i + 14 <= d.count {
        let e = 6 + 14 * i
        let w = Int(d[e]) == 0 ? 256 : Int(d[e])
        entries.append((w, Int(d.u16(e + 6)), UInt32(d.u16(e + 12))))
    }
    return (g, entries.map { (width: $0.0, bpp: $0.1, id: $0.2) })
}

/// The exe's largest icon (then deepest colour), decoded with ImageIO's ICO reader.
func largestIcon(_ pe: PEFile) throws -> CGImage {
    guard let group = iconGroup(pe), !group.entries.isEmpty else { throw PEError(message: "no icon group") }
    let best = group.entries.max { ($0.width, $0.bpp) < ($1.width, $1.bpp) }!
    guard let res = pe.resources().first(where: { $0.type == rtIcon && $0.id == best.id }),
          let blob = pe.bytes(of: res) else { throw PEError(message: "icon \(best.id) missing") }
    // wrap the one image in an .ico container so ImageIO decodes BMP (with mask) and PNG alike
    var ico = Data()
    for v: UInt16 in [0, 1, 1] { withUnsafeBytes(of: v.littleEndian) { ico.append(contentsOf: $0) } }
    ico.append(contentsOf: [UInt8(best.width % 256), UInt8(best.width % 256), 0, 0])
    for v: UInt16 in [1, UInt16(best.bpp)] { withUnsafeBytes(of: v.littleEndian) { ico.append(contentsOf: $0) } }
    for v: UInt32 in [UInt32(blob.count), 22] { withUnsafeBytes(of: v.littleEndian) { ico.append(contentsOf: $0) } }
    ico.append(blob)
    guard let src = CGImageSourceCreateWithData(ico as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw PEError(message: "icon does not decode") }
    return blob.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? img : applyingANDMask(img, bmp: blob)
}

/// ImageIO ignores the AND mask of 24-bit BMP icons (it applies it to 4- and 8-bit
/// ones), so the transparent parts come out opaque. Clear the masked pixels here;
/// for icons ImageIO already masked, this changes nothing.
func applyingANDMask(_ img: CGImage, bmp: Data) -> CGImage {
    guard bmp.count >= 40 else { return img }
    let w = Int(bmp.u32(4)), h = Int(Int32(bitPattern: bmp.u32(8))) / 2, bpp = Int(bmp.u16(14))
    guard bpp < 32, w == img.width, h == img.height else { return img }
    let used = Int(bmp.u32(32))
    let palette = bpp <= 8 ? 4 * (used != 0 ? used : 1 << bpp) : 0
    let xorRow = ((w * bpp + 31) / 32) * 4, maskRow = ((w + 31) / 32) * 4
    let maskStart = Int(bmp.u32(0)) + palette + xorRow * h
    guard maskStart + maskRow * h <= bmp.count else { return img }
    let ctx = rgbaContext(w, h)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return img }
    let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    for row in 0..<h {   // memory row 0 is the top; BMP rows run bottom-up
        let m = maskStart + (h - 1 - row) * maskRow
        for x in 0..<w where bmp[m + x / 8] & (0x80 >> (x % 8)) != 0 {
            for c in 0..<4 { px[row * ctx.bytesPerRow + x * 4 + c] = 0 }
        }
    }
    return ctx.makeImage() ?? img
}

func rgbaContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Apple's macOS icon grid: a continuous-corner superellipse (n = 5).
func squircle(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * CGFloat(copysign(pow(abs(c), 2.0 / 5), c))
        let y = r.midY + r.height / 2 * CGFloat(copysign(pow(abs(s), 2.0 / 5), s))
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// The source icon, scaled by a whole factor with no smoothing (pixel art stays
/// sharp), centre-cropped to `body`, clipped to the squircle, on a transparent canvas.
func roundedIcon(_ src: CGImage, canvas: Int) -> CGImage {
    let body = Int((Double(canvas) * 824 / 1024).rounded())
    let offset = (canvas - body) / 2
    let ctx = rgbaContext(canvas, canvas)
    let bodyRect = CGRect(x: offset, y: offset, width: body, height: body)
    ctx.addPath(squircle(in: bodyRect)); ctx.clip()
    ctx.interpolationQuality = .none
    if transparentShare(src) >= 0.3 {
        // a figure on nothing (a mask, a logo): cropping would cut it and leave
        // holes, so it sits whole on a plate, at a whole-pixel scale
        ctx.setFillColor(CGColor(srgbRed: 170 / 255, green: 165 / 255, blue: 154 / 255, alpha: 1))
        ctx.fill(bodyRect)
        let target = Int(Double(body) * 0.78)
        let size = src.width <= target ? src.width * (target / src.width) : target
        if src.width > target { ctx.interpolationQuality = .high }   // a large image: scaled down
        let o = (canvas - size) / 2
        ctx.draw(src, in: CGRect(x: o, y: o, width: size, height: size))
    } else {
        // a picture: it fills the body, cropped by a few pixels at most; a large
        // image (a finished icon from a file) is scaled down to the body instead
        if src.width > body {
            ctx.interpolationQuality = .high
            ctx.draw(src, in: bodyRect)
            return ctx.makeImage()!
        }
        let big = src.width * max(1, Int((Double(body) / Double(src.width)).rounded(.up)))
        let crop = (big - body) / 2
        ctx.draw(src, in: CGRect(x: offset - crop, y: offset - crop, width: big, height: big))
    }
    return ctx.makeImage()!
}

/// The image cut to the square around what it draws (alpha >= 128), so transparent
/// margins do not count: an icon already drawn as a rounded card for macOS then
/// fills the body instead of going on a plate. Unchanged when there is no margin.
func trimmedToSquare(_ img: CGImage) -> CGImage {
    let w = img.width, h = img.height
    let ctx = rgbaContext(w, h)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return img }
    let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    var minX = w, minY = h, maxX = -1, maxY = -1   // rows from the top
    for row in 0..<h {
        for x in 0..<w where px[row * ctx.bytesPerRow + x * 4 + 3] >= 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, row); maxY = max(maxY, row)
        }
    }
    guard maxX >= 0 else { return img }
    let side = max(maxX - minX + 1, maxY - minY + 1)
    guard side < max(w, h) else { return img }
    let left = minX - (side - (maxX - minX + 1)) / 2, top = minY - (side - (maxY - minY + 1)) / 2
    let out = rgbaContext(side, side)
    out.interpolationQuality = .none
    out.draw(img, in: CGRect(x: -left, y: side + top - h, width: w, height: h))
    return out.makeImage() ?? img
}

/// The share of an image's pixels that are mostly transparent (alpha < 128).
func transparentShare(_ img: CGImage) -> Double {
    let w = img.width, h = img.height
    let ctx = rgbaContext(w, h)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data, w * h > 0 else { return 0 }
    let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    var clear = 0
    for row in 0..<h { for x in 0..<w where px[row * ctx.bytesPerRow + x * 4 + 3] < 128 { clear += 1 } }
    return Double(clear) / Double(w * h)
}

func downscaled(_ img: CGImage, _ size: Int) -> CGImage {
    let ctx = rgbaContext(size, size)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

/// A PNG as small as it can be without losing anything: indexed (with a tRNS
/// alpha table) when the image has at most 256 distinct colours, which pixel art
/// on a flat plate does; a normal PNG otherwise. Old exes have little room for icons.
func writeSmallPNG(_ img: CGImage, _ url: URL) throws {
    let w = img.width, h = img.height
    let ctx = rgbaContext(w, h)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return try writePNG(img, url) }
    let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
    var palette: [UInt32] = [], index: [UInt32: UInt8] = [:]
    var raw = [UInt8](); raw.reserveCapacity((w + 1) * h)
    for row in 0..<h {
        raw.append(0)   // filter: none
        for x in 0..<w {
            let o = row * ctx.bytesPerRow + x * 4
            var (r, g, b, a) = (UInt32(px[o]), UInt32(px[o + 1]), UInt32(px[o + 2]), UInt32(px[o + 3]))
            if a == 0 { (r, g, b) = (0, 0, 0) } else if a < 255 {   // un-premultiply
                (r, g, b) = (min(255, r * 255 / a), min(255, g * 255 / a), min(255, b * 255 / a))
            }
            let key = r << 24 | g << 16 | b << 8 | a
            if let i = index[key] { raw.append(i); continue }
            guard palette.count < 256 else { return try writePNG(img, url) }
            index[key] = UInt8(palette.count); raw.append(UInt8(palette.count)); palette.append(key)
        }
    }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        var c = Array(type.utf8) + body
        let crc = UInt32(crc32(0, &c, uInt(c.count)))
        return be32(UInt32(body.count)) + c + be32(crc)
    }
    func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    var zlen = compressBound(uLong(raw.count)); var z = [UInt8](repeating: 0, count: Int(zlen))
    guard compress2(&z, &zlen, raw, uLong(raw.count), 9) == Z_OK else { return try writePNG(img, url) }
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png += chunk("IHDR", be32(UInt32(w)) + be32(UInt32(h)) + [8, 3, 0, 0, 0])
    png += chunk("PLTE", palette.flatMap { [UInt8($0 >> 24), UInt8($0 >> 16 & 255), UInt8($0 >> 8 & 255)] })
    png += chunk("tRNS", palette.map { UInt8($0 & 255) })
    png += chunk("IDAT", Array(z[0..<Int(zlen)]))
    png += chunk("IEND", [])
    try Data(png).write(to: url)
}

func writePNG(_ img: CGImage, _ url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw PEError(message: "cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw PEError(message: "cannot write \(url.path)") }
}

/// The icon art in `url`: an exe's (or DLL's, whatever its name: Game.exe.bkp) largest
/// icon, or the largest image in an image file (.icns, .png, .ico, .jpg - a project's
/// own icon).
func iconSource(_ url: URL) throws -> CGImage {
    let data = try Data(contentsOf: url)
    if data.starts(with: [0x4D, 0x5A]) { return try largestIcon(try PEFile(data: data)) }   // "MZ": an exe or DLL
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PEError(message: "cannot read \(url.path)") }
    let images = (0..<CGImageSourceGetCount(src)).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil) }
    guard let best = images.max(by: { $0.width < $1.width }) else { throw PEError(message: "no image in \(url.path)") }
    return best
}

/// AppIcon.icns + icon_1024.png for the app, exe-icon-{256,48,32,16}.png for exe-icon.
func makeIcons(exe: URL, out: URL) throws {
    let src = trimmedToSquare(try iconSource(exe))
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let master = roundedIcon(src, canvas: 1024)
    try writePNG(master, out.appendingPathComponent("icon_1024.png"))
    let iconset = out.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
            try writePNG(downscaled(master, base * scale), iconset.appendingPathComponent(name))
        }
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
    try iconutil.run(); iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw PEError(message: "iconutil failed") }
    try FileManager.default.removeItem(at: iconset)
    // the exe's own icons: 256 drawn directly (sharp pixels), the small ones from the master
    try writeSmallPNG(roundedIcon(src, canvas: 256), out.appendingPathComponent("exe-icon-256.png"))
    for size in [48, 32, 16] {
        try writeSmallPNG(downscaled(master, size), out.appendingPathComponent("exe-icon-\(size).png"))
    }
}

struct RefusedError: Error { let message: String }

/// Replace an exe's icons without moving anything: a full resource rebuild (rcedit)
/// broke a game with self-modifying code. The new PNG icons go into the existing
/// block of RT_ICON data; when they do not fit there and .rsrc is the file's last
/// section (unsigned, nothing after it), they are appended at its end instead and
/// only its size fields grow. The RT_ICON entries are re-pointed and the group is
/// rewritten in its own slot. Refuses unless every changed byte is inside .rsrc (or,
/// when growing, one of those size fields).
func patchExeIcon(exe: URL, pngDir: URL, out: URL) throws {
    let original = try Data(contentsOf: exe)
    let pe = try PEFile(data: original)
    guard let rsrcRange = pe.resourceSectionFileRange(), let group = iconGroup(pe) else {
        throw RefusedError(message: "no icon resources")
    }
    let all = pe.resources()
    let icons = all.filter { $0.type == rtIcon }.sorted { $0.id < $1.id }
    let available: [(size: Int, data: Data)] = try [256, 48, 32, 16].compactMap { size in
        let url = pngDir.appendingPathComponent("exe-icon-\(size).png")
        return FileManager.default.fileExists(atPath: url.path) ? (size, try Data(contentsOf: url)) : nil
    }
    guard !available.isEmpty else { throw RefusedError(message: "no exe-icon-*.png in \(pngDir.path)") }
    // the block the icon data occupies, which must hold nothing else
    let start = icons.map { $0.rva }.min()!, end = icons.map { $0.rva + $0.size }.max()!
    for r in all where r.type != rtIcon && r.rva < end && r.rva + r.size > start {
        throw RefusedError(message: "icon data is interleaved with other resources")
    }
    // Where the new icons go: in the old block when they fit; otherwise, when .rsrc is
    // the file's last section (nothing after it, no signature), appended at its end,
    // which moves nothing; otherwise as many sizes as fit in the old block.
    let priority = [256, 32, 48, 16]   // the Dock shows the largest, title bars 32 px
    func choose(room: Int?) -> [(size: Int, data: Data)] {
        var chosen: [(size: Int, data: Data)] = [], used = 0
        for size in priority {
            guard chosen.count < icons.count, let png = available.first(where: { $0.size == size }) else { continue }
            let need = (png.data.count + 3) & ~3
            if room == nil || used + need <= room! { chosen.append(png); used += need }
        }
        return chosen.sorted { $0.size > $1.size }
    }
    let secStart = Int(original.u32(0x3C)) + 24 + Int(original.u16(Int(original.u32(0x3C)) + 20))
    let rsrcIndex = pe.sections.firstIndex { $0.name == ".rsrc" }
    let canGrow: Bool = {
        guard let k = rsrcIndex else { return false }
        let r = pe.sections[k]
        let last = pe.sections.allSatisfy { $0.rva <= r.rva && $0.rawOffset <= r.rawOffset }
        let signed = pe.dataDirectories.count > 4 && pe.dataDirectories[4].rva != 0
        return last && !signed && Int(r.rawOffset + r.rawSize) == original.count
    }()
    var pngs = choose(room: Int(end - start))
    let ideal = choose(room: nil)
    let grow = canGrow && ideal.map { $0.size } != pngs.map { $0.size }
    if grow { pngs = ideal }
    guard !pngs.isEmpty else {
        let least = available.map { ($0.data.count + 3) & ~3 }.min()!
        throw RefusedError(message: "new icons need at least \(least) bytes, the icon block has \(end - start)")
    }
    if pngs.count < available.count {
        let kept = pngs.map { "\($0.size)" }.joined(separator: ", ")
        FileHandle.standardError.write("note: the exe has room for \(kept) px icons only\n".data(using: .utf8)!)
    }
    guard let groupSize = pe.bytes(of: group.group)?.count, 6 + 14 * pngs.count <= groupSize,
          let groupOffset = pe.offset(ofRVA: group.group.rva), let blockOffset = pe.offset(ofRVA: start) else {
        throw RefusedError(message: "the icon group slot is too small")
    }

    var d = original
    func put32(_ v: UInt32, _ o: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(o..<o + 4, with: $0) } }
    var placed: [(size: Int, rva: UInt32, length: Int, id: UInt32)] = []
    var headerFields: [Range<Int>] = []   // header bytes growing is allowed to change
    if grow, let k = rsrcIndex {
        let r = pe.sections[k]
        // new data from the end of what the section maps (raw or virtual, whichever is
        // larger), so RVA and file offset keep the section's fixed relation
        let from = (Int(max(r.virtualSize, r.rawSize)) + 3) & ~3
        d.append(Data(count: from - Int(r.rawSize)))
        for (i, png) in pngs.enumerated() {
            placed.append((png.size, r.rva + UInt32(d.count - Int(r.rawOffset)), png.data.count, icons[i].id))
            d.append(png.data); d.append(Data(count: (4 - png.data.count % 4) % 4))
        }
        let opt = Int(original.u32(0x3C)) + 24
        let fileAlign = Int(original.u32(opt + 36)), sectAlign = Int(original.u32(opt + 32))
        let virtualSize = d.count - Int(r.rawOffset)
        d.append(Data(count: (fileAlign - d.count % fileAlign) % fileAlign))
        let header = secStart + 40 * k
        put32(UInt32(virtualSize), header + 8)                       // VirtualSize
        put32(UInt32(d.count - Int(r.rawOffset)), header + 16)       // SizeOfRawData
        let image = (Int(r.rva) + virtualSize + sectAlign - 1) / sectAlign * sectAlign
        put32(UInt32(max(Int(original.u32(opt + 56)), image)), opt + 56)   // SizeOfImage
        let dirs = opt + (pe.is64 ? 112 : 96)
        let resDir = pe.dataDirectories[2]
        put32(UInt32(Int(r.rva) + virtualSize) - resDir.rva, dirs + 2 * 8 + 4)   // resource directory size
        headerFields = [header + 8..<header + 12, header + 16..<header + 20, opt + 56..<opt + 60, dirs + 20..<dirs + 24]
    } else {
        d.replaceSubrange(blockOffset..<blockOffset + Int(end - start), with: Data(count: Int(end - start)))
        var rva = start
        for (i, png) in pngs.enumerated() {
            let o = blockOffset + Int(rva - start)
            d.replaceSubrange(o..<o + png.data.count, with: png.data)
            placed.append((png.size, rva, png.data.count, icons[i].id))
            rva = (rva + UInt32(png.data.count) + 3) & ~3
        }
    }
    for (i, icon) in icons.enumerated() {
        let p = placed[min(i, placed.count - 1)]   // spare slots point at the smallest icon
        put32(p.rva, icon.entryOffset); put32(UInt32(p.length), icon.entryOffset + 4)
    }
    var g = Data()
    for v: UInt16 in [0, 1, UInt16(placed.count)] { withUnsafeBytes(of: v.littleEndian) { g.append(contentsOf: $0) } }
    for p in placed {
        g.append(contentsOf: [UInt8(p.size % 256), UInt8(p.size % 256), 0, 0])
        for v: UInt16 in [1, 32] { withUnsafeBytes(of: v.littleEndian) { g.append(contentsOf: $0) } }
        withUnsafeBytes(of: UInt32(p.length).littleEndian) { g.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(p.id).littleEndian) { g.append(contentsOf: $0) }
    }
    d.replaceSubrange(groupOffset..<groupOffset + groupSize, with: g + Data(count: groupSize - g.count))
    put32(UInt32(g.count), group.group.entryOffset + 4)

    guard grow || d.count == original.count else { throw RefusedError(message: "size changed") }
    for i in 0..<original.count where d[i] != original[i] && !rsrcRange.contains(i) && !headerFields.contains(where: { $0.contains(i) }) {
        throw RefusedError(message: String(format: "byte 0x%x outside .rsrc would change", i))
    }
    try d.write(to: out, options: .atomic)
}


// MARK: - displays and geometry

/// A display as the geometry needs it, in Cocoa coordinates (origin bottom-left of
/// the primary display, y up).
struct Screen {
    var id: UInt32
    var name: String
    var frame: CGRect
    var visible: CGRect
    var safeTop: CGFloat      // the notch; the menu bar is not counted (it auto-hides)
    var modes: [CGSize] = []  // the display's modes in points (fullscreen picks one)
}

func connectedScreens() -> [Screen] {
    NSScreen.screens.map { s in
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let modes = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? [])
            .map { CGSize(width: $0.width, height: $0.height) }
        return Screen(id: id, name: s.localizedName, frame: s.frame, visible: s.visibleFrame,
                      safeTop: s.safeAreaInsets.top, modes: modes)
    }
}

/// The game window's rect in Win32 virtual-screen coordinates (origin top-left of
/// the primary display, y down) for `screen`, where `primary` is NSScreen.screens[0].
///   mode "native": the whole usable area; "pillarbox:<w>:<h>": the largest area of
///   that aspect ratio, centred. Both sides are rounded down to a multiple of `align`.
///   "fullscreen": the display's full width by the height below the notch, snapped
///   to the tallest display mode that fits (1728x1080 on a 14" MacBook Pro): the size
///   a game switching to full screen should ask for, so the scale stays the same.
/// Usable area: the display minus the notch and a visible Dock; the menu bar is
/// ignored because the launcher auto-hides it while the game runs.
func gameRect(screen: Screen, primary: Screen, mode: String, align: Int) throws -> (x: Int, y: Int, w: Int, h: Int) {
    let f = screen.frame, v = screen.visible
    if mode == "fullscreen" {
        let w = Int(f.width), limit = Int(f.height - screen.safeTop)
        let h = screen.modes.filter { Int($0.width) == w && Int($0.height) <= limit }.map { Int($0.height) }.max() ?? limit
        return (Int(f.minX - primary.frame.minX), Int(primary.frame.maxY - f.maxY), w, h)
    }
    // Dock insets: where the visible frame is smaller than the frame on left, right, bottom
    let left = v.minX - f.minX, right = f.maxX - v.maxX, bottom = v.minY - f.minY
    let area = CGRect(x: f.minX + left, y: f.minY + bottom,
                      width: f.width - left - right, height: f.height - bottom - screen.safeTop)
    let a = max(1, align)
    var w = Int(area.width) / a * a, h = Int(area.height) / a * a
    if mode.hasPrefix("pillarbox:") {
        let parts = mode.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw PEError(message: "bad mode \(mode)") }
        let (rw, rh) = (parts[0], parts[1])
        h = Int(area.height) / a * a
        w = h * rw / rh / a * a
        if w > Int(area.width) {
            w = Int(area.width) / a * a
            h = w * rh / rw / a * a
        }
    } else if mode != "native" {
        throw PEError(message: "unknown mode \(mode) (native | fullscreen | pillarbox:<w>:<h>)")
    }
    // centre in the usable area, then flip to Win32 coordinates
    let cocoaX = area.minX + (area.width - CGFloat(w)) / 2
    let cocoaTop = area.maxY - (area.height - CGFloat(h)) / 2
    let x = Int((cocoaX - primary.frame.minX).rounded(.down))
    let y = Int((primary.frame.maxY - cocoaTop).rounded(.up))
    return (x, y, w, h)
}

func pickScreen(_ which: String, _ screens: [Screen]) throws -> Screen {
    guard !screens.isEmpty else { throw PEError(message: "no displays") }
    if which == "main" { return screens[0] }
    guard let id = UInt32(which), let s = screens.first(where: { $0.id == id }) else {
        throw PEError(message: "no display \(which) (see bottler displays)")
    }
    return s
}

/// Test hook: "x,y,w,h" into a CGRect.
func rect(_ s: String) throws -> CGRect {
    let p = s.split(separator: ",").compactMap { Double($0) }
    guard p.count == 4 else { throw PEError(message: "bad rect \(s)") }
    return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
}

// MARK: - frame (black backdrop)

final class Backdrop: NSWindow {
    var onClick: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Keeps a black window over the display directly behind the game's largest
/// window whenever the game is frontmost; hides it while the game is minimised;
/// quits when the game exits. Clicking the black area brings the game back.
/// Executable path of a process ("" when unknown).
func processPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

/// Every process running an executable under `root` (an app's wine folder).
func processes(under root: String) -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(n) * 2)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(0, got))).filter { $0 > 0 && processPath($0).hasPrefix(root) }
}

final class FrameKeeper: NSObject, NSApplicationDelegate {
    /// Either one process, or every process of an app's wine (a game started by
    /// its own launcher has a pid the caller never sees).
    let pid: pid_t?
    let wineRoot: String?
    let screenFrame: CGRect
    var backdrop: Backdrop!
    var owner: pid_t = 0
    var lastAliveCheck = Date.distantPast
    var seenAlive = false
    let started = Date()

    init(pid: pid_t?, wineRoot: String?, screenFrame: CGRect) {
        self.pid = pid; self.wineRoot = wineRoot; self.screenFrame = screenFrame
    }

    func owns(_ p: pid_t) -> Bool {
        if let pid { return p == pid }
        return processPath(p).hasPrefix(wineRoot!)
    }

    func alive() -> Bool {
        if let pid { return kill(pid, 0) == 0 }
        return !processes(under: wineRoot!).isEmpty
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        backdrop = Backdrop(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = .black
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.collectionBehavior = [.managed, .fullScreenNone]
        backdrop.isReleasedWhenClosed = false
        backdrop.onClick = { [weak self] in
            guard let self, self.owner != 0 else { return }
            NSRunningApplication(processIdentifier: self.owner)?.activate()
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// The game's largest normal window: its number, owner and whether it is on screen.
    func gameWindow() -> (number: Int, owner: pid_t, onScreen: Bool)? {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (Int, pid_t, Bool, CGFloat)?
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let p = w[kCGWindowOwnerPID as String] as? pid_t, owns(p),
                  let n = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
            guard area >= 640 * 480 else { continue }
            let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if best == nil || area > best!.3 { best = (n, p, on, area) }
        }
        return best.map { (number: $0.0, owner: $0.1, onScreen: $0.2) }
    }

    func tick() {
        if Date().timeIntervalSince(lastAliveCheck) > 1 {
            lastAliveCheck = Date()
            // started before the game: wait for it (2 minutes), then follow it until it is gone
            if alive() { seenAlive = true }
            else if seenAlive || Date().timeIntervalSince(started) > 120 { NSApp.terminate(nil); return }
        }
        guard let g = gameWindow(), g.onScreen else { backdrop.orderOut(nil); return }
        owner = g.owner
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == g.owner {
            backdrop.order(.below, relativeTo: g.number)
        }
    }
}

// MARK: - menu bar and Dock

/// The preference domains the desktop settings live in. BOTTLER_TEST_PREFS=<id>
/// swaps them for <id>.global and <id>.dock, so tests never touch the player's own.
func prefDomains() -> (global: CFString, dock: CFString, test: Bool) {
    if let t = ProcessInfo.processInfo.environment["BOTTLER_TEST_PREFS"], !t.isEmpty {
        return ("\(t).global" as CFString, "\(t).dock" as CFString, true)
    }
    return (kCFPreferencesAnyApplication, "com.apple.dock" as CFString, false)
}

private let menubarKey = "_HIHideMenuBar" as CFString, dockKey = "autohide" as CFString

func readPref(_ key: CFString, _ domain: CFString) -> Bool? {
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
}

func writePref(_ key: CFString, _ value: Bool?, _ domain: CFString) {
    CFPreferencesSetValue(key, value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }, domain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

/// Tell the running system the menu bar setting changed, and let the screens settle.
func announceMenubar() {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil,
        deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.5)
}

/// menubar hide: turn on "automatically hide the menu bar" for the game's session.
/// What to go back to is `desktop`'s job.
func menubar(_ action: String) throws {
    guard action == "hide" else { throw PEError(message: "menubar hide") }
    let d = prefDomains()
    writePref(menubarKey, true, d.global)
    if !d.test { announceMenubar() }
}

/// desktop save <file>: record how the menu bar and Dock are set (auto-hide or not)
/// before a game runs. A snapshot that is already there was left by a run that never
/// restored (a crash, a killed launch, a rebuilt app): it holds the player's real
/// settings, so it is kept, not overwritten.
/// desktop restore <file>: put both back as recorded, then delete the snapshot. The
/// Dock is restarted only when its setting actually changes.
func desktop(_ action: String, file: URL) throws {
    let d = prefDomains(), fm = FileManager.default
    switch action {
    case "save":
        guard !fm.fileExists(atPath: file.path) else { return }
        var snap: [String: Any] = [:]
        if let m = readPref(menubarKey, d.global) { snap["menubarAutohide"] = m }
        if let a = readPref(dockKey, d.dock) { snap["dockAutohide"] = a }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: snap).write(to: file, options: .atomic)
    case "restore":
        guard fm.fileExists(atPath: file.path) else { return }
        let snap = (try JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        let menubarWas = snap["menubarAutohide"] as? Bool, dockWas = snap["dockAutohide"] as? Bool
        if readPref(menubarKey, d.global) != menubarWas {
            writePref(menubarKey, menubarWas, d.global)
            if !d.test { announceMenubar() }
        }
        if readPref(dockKey, d.dock) != dockWas {
            writePref(dockKey, dockWas, d.dock)
            if !d.test {   // the Dock reads its settings when it starts
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); p.arguments = ["Dock"]
                try? p.run(); p.waitUntilExit()
            }
        }
        try fm.removeItem(at: file)
    default:
        throw PEError(message: "desktop save|restore <file>")
    }
}


// MARK: - recipes

/// Allowed keys per object path; anything else in a recipe is a typo.
let recipeKeys: [String: Set<String>] = [
    "": ["schema", "title", "bundleId", "engine", "detect", "install", "launch"],
    "detect": ["required", "fingerprint", "builds", "unknown"],
    "detect.builds.*": ["status", "label", "message"],
    "install": ["exclude", "rename", "downloads", "ini", "proxy", "appIcon", "exeIcon", "registry"],
    "install.downloads[]": ["url", "sha256", "files"],
    "install.ini[]": ["file", "section", "set"],
    "install.proxy": ["dll"],
    "launch": ["variants", "window", "ini", "registry", "env", "dllOverrides"],
    "launch.variants[]": ["label", "exe", "args"],
    "launch.window": ["mode", "align", "backdrop", "menubar", "title"],
    "launch.ini[]": ["file", "section", "set"],
]
/// Objects whose keys are free-form (maps).
let recipeMaps: Set<String> = ["detect.builds", "install.rename", "install.downloads[].files",
                               "install.ini[].set", "launch.ini[].set", "launch.env", "launch.dllOverrides"]

struct Recipe: Codable {
    struct Build: Codable { var status: String; var label: String?; var message: String? }
    struct Detect: Codable {
        var required: [String]; var fingerprint: String
        var builds: [String: Build]?; var unknown: String?
    }
    struct Download: Codable { var url: String; var sha256: String; var files: [String: String] }
    struct IniEdit: Codable { var file: String; var section: String; var set: [String: String] }
    struct Proxy: Codable { var dll: String }
    struct Install: Codable {
        var exclude: [String]?; var rename: [String: String]?; var downloads: [Download]?
        var ini: [IniEdit]?; var proxy: Proxy?; var appIcon: String?; var exeIcon: String?
        var registry: [String]?
    }
    struct Variant: Codable { var label: String; var exe: String; var args: [String]? }
    struct Window: Codable {
        var mode: String; var align: Int?; var backdrop: Bool?; var menubar: String?; var title: String?
    }
    struct RegistryEdit: Codable { var key: String; var set: [String: String] }
    struct Launch: Codable {
        var variants: [Variant]; var window: Window; var ini: [IniEdit]?; var registry: [RegistryEdit]?
        var env: [String: String]?; var dllOverrides: [String: String]?
    }
    var schema: Int; var title: String; var bundleId: String; var engine: String
    var detect: Detect; var install: Install?; var launch: Launch
}

func isHex(_ s: String, _ n: Int) -> Bool { s.count == n && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
func isSafeRelative(_ p: String) -> Bool {
    !p.isEmpty && !p.hasPrefix("/") && !p.split(separator: "/").contains("..")
}

/// Every problem in a recipe, as readable lines; empty means valid.
func checkRecipe(_ url: URL) -> [String] {
    var errors: [String] = []
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) else { return ["not valid JSON: \(url.path)"] }
    func walk(_ v: Any, _ path: String, _ shape: String) {
        if let d = v as? [String: Any] {
            if recipeMaps.contains(shape) {
                if shape == "detect.builds" { for (k, b) in d { walk(b, "\(path).\(k)", "detect.builds.*") } }
                return
            }
            guard let allowed = recipeKeys[shape] else { return }
            for (k, child) in d {
                let childShape = shape.isEmpty ? k : "\(shape).\(k)"
                if !allowed.contains(k) { errors.append("unknown key \"\(k)\" in \(path.isEmpty ? "the recipe" : path)") }
                else { walk(child, path.isEmpty ? k : "\(path).\(k)", childShape) }
            }
        } else if let a = v as? [Any] {
            for (i, e) in a.enumerated() { walk(e, "\(path)[\(i)]", "\(shape)[]") }
        }
    }
    walk(json, "", "")
    let recipe: Recipe
    do { recipe = try JSONDecoder().decode(Recipe.self, from: data) }
    catch { return errors + ["does not match the schema: \(error)"] }
    if recipe.schema != 1 { errors.append("schema must be 1") }
    if recipe.detect.required.isEmpty { errors.append("detect.required is empty") }
    for p in recipe.detect.required + [recipe.detect.fingerprint] where !isSafeRelative(p) {
        errors.append("not a relative path inside the game: \(p)")
    }
    for (md5, b) in recipe.detect.builds ?? [:] {
        if !isHex(md5, 32) { errors.append("detect.builds key is not a lowercase md5: \(md5)") }
        if !["verified", "unverified", "refuse"].contains(b.status) { errors.append("build \(md5): status must be verified, unverified or refuse") }
        if b.status == "refuse" && (b.message ?? "").isEmpty { errors.append("build \(md5): refuse needs a message") }
    }
    if let u = recipe.detect.unknown, !["warn", "refuse"].contains(u) { errors.append("detect.unknown must be warn or refuse") }
    for d in recipe.install?.downloads ?? [] {
        if !(d.url.hasPrefix("https://") || d.url.hasPrefix("file://")) { errors.append("download url must be https:// or file://: \(d.url)") }
        if !d.url.lowercased().hasSuffix(".zip") { errors.append("only .zip downloads are supported: \(d.url)") }
        if !isHex(d.sha256, 64) { errors.append("download sha256 is not 64 lowercase hex: \(d.url)") }
        for (from, to) in d.files where !isSafeRelative(from) || !isSafeRelative(to) { errors.append("download files entry is not relative: \(from) -> \(to)") }
    }
    for (from, to) in recipe.install?.rename ?? [:] where !isSafeRelative(from) || !isSafeRelative(to) {
        errors.append("rename entry is not relative: \(from) -> \(to)")
    }
    if let p = recipe.install?.proxy {
        if !p.dll.lowercased().hasSuffix(".dll") || !isSafeRelative(p.dll) { errors.append("proxy dll must be a .dll inside the game: \(p.dll)") }
    }
    if recipe.launch.variants.isEmpty { errors.append("launch.variants is empty") }
    for v in recipe.launch.variants where !isSafeRelative(v.exe) { errors.append("variant exe is not relative: \(v.exe)") }
    let mode = recipe.launch.window.mode
    if mode != "native" && mode != "fullscreen" {
        let p = mode.split(separator: ":")
        if !(p.count == 3 && p[0] == "pillarbox" && Int(p[1]) ?? 0 > 0 && Int(p[2]) ?? 0 > 0) {
            errors.append("launch.window.mode must be native, fullscreen or pillarbox:<w>:<h>: \(mode)")
        }
    }
    for edit in recipe.launch.registry ?? [] {
        if !(edit.key.hasPrefix("HKCU\\") || edit.key.hasPrefix("HKLM\\")) {
            errors.append("launch.registry key must start with HKCU\\ or HKLM\\: \(edit.key)")
        }
        for (name, value) in edit.set where value.hasPrefix("dword:") && Int(value.dropFirst(6)) == nil
            && !value.contains("{") {
            errors.append("launch.registry \(name): dword:<decimal number or {w} {h} {x} {y}>, got \(value)")
        }
    }
    if let m = recipe.launch.window.menubar, !["hide", "keep"].contains(m) { errors.append("launch.window.menubar must be hide or keep") }
    return errors
}

func loadRecipe(_ url: URL) throws -> Recipe {
    let errors = checkRecipe(url)
    guard errors.isEmpty else { throw PEError(message: "invalid recipe \(url.path):\n  " + errors.joined(separator: "\n  ")) }
    return try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: url))
}

// MARK: - INI files

/// Set keys in one section of an INI file, keeping its line endings. Keys match
/// case-insensitively; missing keys go at the end of the section, a missing
/// section at the end of the file. Returns whether the file changed.
@discardableResult
func iniSet(_ url: URL, section: String, _ values: [String: String]) throws -> Bool {
    let original = (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
    let eol = original.contains("\r\n") ? "\r\n" : "\n"
    var lines = original.isEmpty ? [] : original.components(separatedBy: eol)
    if lines.last == "" { lines.removeLast() }
    func header(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && t.hasSuffix("]") ? String(t.dropFirst().dropLast()) : nil
    }
    var remaining = values
    var start: Int? = lines.firstIndex { header($0)?.caseInsensitiveCompare(section) == .orderedSame }
    if start == nil {
        lines.append("[\(section)]"); start = lines.count - 1
    }
    var end = lines.count
    for i in (start! + 1)..<lines.count where header(lines[i]) != nil { end = i; break }
    for i in (start! + 1)..<end {
        guard let eq = lines[i].firstIndex(of: "=") else { continue }
        let key = lines[i][..<eq].trimmingCharacters(in: .whitespaces)
        if let match = remaining.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            lines[i] = "\(key)=\(remaining[match]!)"
            remaining.removeValue(forKey: match)
        }
    }
    var insertAt = end
    while insertAt > start! + 1 && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
    for k in remaining.keys.sorted() { lines.insert("\(k)=\(remaining[k]!)", at: insertAt); insertAt += 1 }
    let updated = lines.joined(separator: eol) + eol
    guard updated != original else { return false }
    try updated.write(to: url, atomically: true, encoding: .isoLatin1)
    return true
}

// MARK: - fetch (build time)

func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw PEError(message: "\(tool) failed (\(p.terminationStatus))") }
}

func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

/// Download (or reuse from the cache), verify and unpack each pinned download,
/// then copy the mapped files into `out`.
func fetch(recipeDir: URL, cache: URL, out: URL) throws {
    let recipe = try loadRecipe(recipeDir.appendingPathComponent("recipe.json"))
    let fm = FileManager.default
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    for d in recipe.install?.downloads ?? [] {
        let archive = cache.appendingPathComponent("\(d.sha256).zip")
        let cached = fm.fileExists(atPath: archive.path) ? try sha256(archive) : ""
        if cached != d.sha256 {
            print("==> downloading \(d.url)")
            let part = archive.appendingPathExtension("part")
            try run("/usr/bin/curl", ["-fsSL", "-o", part.path, d.url])
            try? fm.removeItem(at: archive)
            try fm.moveItem(at: part, to: archive)
        }
        guard try sha256(archive) == d.sha256 else {
            try? fm.removeItem(at: archive)
            throw PEError(message: "checksum mismatch for \(d.url)")
        }
        let unpacked = cache.appendingPathComponent(d.sha256)
        if !fm.fileExists(atPath: unpacked.path) {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        }
        for (from, to) in d.files {
            let src = unpacked.appendingPathComponent(from), dst = out.appendingPathComponent(to)
            guard fm.fileExists(atPath: src.path) else { throw PEError(message: "\(from) is not in \(d.url)") }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
    }
}

// MARK: - install

/// Names a PE file exports, for checking a proxy's .def against the real DLL.
func exportNames(_ pe: PEFile) -> Set<String> {
    guard pe.dataDirectories.count > 0, pe.dataDirectories[0].rva != 0,
          let e = pe.offset(ofRVA: pe.dataDirectories[0].rva) else { return [] }
    let count = Int(pe.data.u32(e + 24)), namesRVA = pe.data.u32(e + 32)
    guard let names = pe.offset(ofRVA: namesRVA) else { return [] }
    return Set((0..<min(count, 65536)).compactMap { pe.cString(atRVA: pe.data.u32(names + 4 * $0)) })
}

func defNames(_ url: URL) throws -> Set<String> {
    Set(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").compactMap { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\""), let close = t.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(t[t.index(after: t.startIndex)..<close])
    })
}

struct InstallRefused: Error { let message: String }

/// Copy the player's game from `source` into `game` and apply the recipe. Nothing
/// in `source` is ever written. Files already in `game` are not overwritten (the
/// player's saves and our edits survive a re-run), so a second run changes nothing.
/// Returns the number of changes made.
func install(recipeDir: URL, source: URL, game: URL, iconDir: URL) throws -> Int {
    let recipe = try loadRecipe(recipeDir.appendingPathComponent("recipe.json"))
    let files = recipeDir.appendingPathComponent("files")
    let fm = FileManager.default
    var changes = 0
    func note(_ s: String) { print("==> \(s)"); changes += 1 }

    // 1. which build is this
    for r in recipe.detect.required where !fm.fileExists(atPath: source.appendingPathComponent(r).path) {
        throw InstallRefused(message: "\(r) is missing: this does not look like a \(recipe.title) folder")
    }
    // the build imports these into the prefix after install (core/build-app.sh)
    for r in recipe.install?.registry ?? [] where !fm.fileExists(atPath: source.appendingPathComponent(r).path) {
        throw InstallRefused(message: "\(r) (install.registry) is missing from the game folder")
    }
    let fingerprint = md5(try Data(contentsOf: source.appendingPathComponent(recipe.detect.fingerprint)))
    let build = recipe.detect.builds?[fingerprint]
    switch build?.status {
    case "refuse": throw InstallRefused(message: build?.message ?? "this build is not supported")
    case "verified": print("build: \(build?.label ?? fingerprint) (verified)")
    case "unverified": print("warning: build \(build?.label ?? fingerprint) has not been tested")
    default:
        if recipe.detect.unknown == "refuse" { throw InstallRefused(message: "unknown build \(fingerprint)") }
        print("warning: unknown build \(fingerprint) of \(recipe.detect.fingerprint): not tested")
    }

    // 2. copy the game (never overwriting; renamed and proxied files count as present)
    let excluded = Set((recipe.install?.exclude ?? []).map { $0.lowercased() })
    let renames = recipe.install?.rename ?? [:]
    let proxyDLL = recipe.install?.proxy?.dll
    try fm.createDirectory(at: game, withIntermediateDirectories: true)
    let src = source.resolvingSymlinksInPath()
    var copied = 0, expected = 0
    if let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
        for case let url as URL in walker {
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(src.path.count + 1))
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if excluded.contains(String(rel.split(separator: "/").first ?? "").lowercased()) {
                // skipDescendants only for a folder: called on a file, it skips the most
                // recently opened folder instead, silently losing a whole folder
                if values.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory != true { expected += 1 }
            let dst = game.appendingPathComponent(rel)
            if values.isDirectory == true {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true); continue
            }
            if fm.fileExists(atPath: dst.path) { continue }
            if let to = renames[rel], fm.fileExists(atPath: game.appendingPathComponent(to).path) { continue }
            try fm.copyItem(at: url, to: dst); copied += 1
        }
    }
    if copied > 0 { note("copied \(copied) files") }
    // every file the source has (minus exclusions) must now be in the game folder
    var missing: [String] = []
    if let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
        for case let url as URL in walker {
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(src.path.count + 1))
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if excluded.contains(String(rel.split(separator: "/").first ?? "").lowercased()) {
                if values.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values.isDirectory == true || values.isSymbolicLink == true { continue }
            let present = fm.fileExists(atPath: game.appendingPathComponent(rel).path)
                || renames[rel].map { fm.fileExists(atPath: game.appendingPathComponent($0).path) } ?? false
                || (rel == proxyDLL && fm.fileExists(atPath: game.appendingPathComponent(
                        (rel as NSString).deletingPathExtension + "_orig.dll").path))
            if !present { missing.append(rel) }
        }
    }
    guard missing.isEmpty else {
        throw PEError(message: "\(missing.count) of \(expected) files did not arrive, e.g. \(missing.prefix(3).joined(separator: ", "))")
    }

    // 3. renames (e.g. set a bundled wrapper DLL aside)
    for (from, to) in renames.sorted(by: { $0.key < $1.key }) {
        let a = game.appendingPathComponent(from), b = game.appendingPathComponent(to)
        if fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: b.path) {
            try fm.moveItem(at: a, to: b); note("renamed \(from) -> \(to)")
        }
    }

    // 4. the proxy DLL: the original becomes <name>_orig.dll
    if let proxy = recipe.install?.proxy {
        let dll = game.appendingPathComponent(proxy.dll)
        let stem = (proxy.dll as NSString).deletingPathExtension
        let orig = game.appendingPathComponent(stem + "_orig.dll")
        let ours = files.appendingPathComponent(proxy.dll)
        guard fm.fileExists(atPath: ours.path) else { throw PEError(message: "the app was built without the \(proxy.dll) proxy") }
        if !fm.fileExists(atPath: orig.path) {
            guard fm.fileExists(atPath: dll.path) else { throw InstallRefused(message: "\(proxy.dll) is missing") }
            // written at build time from the project's own copy of the DLL (win/proxy.sh def)
            let def = recipeDir.appendingPathComponent(stem + ".def")
            let wanted = try defNames(def)
            let have = exportNames(try PEFile(data: Data(contentsOf: dll)))
            guard wanted == have else {
                throw InstallRefused(message: "\(proxy.dll) in this copy exports something else than the app was built for (\(stem).def)")
            }
            try fm.moveItem(at: dll, to: orig); note("kept the original \(proxy.dll) as \(stem)_orig.dll")
        }
        let current = fm.fileExists(atPath: dll.path) ? md5(try Data(contentsOf: dll)) : ""
        if current != md5(try Data(contentsOf: ours)) {
            try? fm.removeItem(at: dll)
            try fm.copyItem(at: ours, to: dll); note("installed the \(proxy.dll) proxy")
        }
    }

    // 5. files from the recipe's downloads (built into the app), replacing what differs
    if let walker = fm.enumerator(at: files, includingPropertiesForKeys: [.isDirectoryKey]) {
        for case let url as URL in walker {
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(files.resolvingSymlinksInPath().path.count + 1))
            if rel == proxyDLL { continue }
            let dst = game.appendingPathComponent(rel)
            if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true); continue
            }
            if fm.fileExists(atPath: dst.path), md5(try Data(contentsOf: dst)) == md5(try Data(contentsOf: url)) { continue }
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: url, to: dst); note("added \(rel)")
        }
    }

    // 6. INI edits
    for edit in recipe.install?.ini ?? [] {
        if try iniSet(game.appendingPathComponent(edit.file), section: edit.section, edit.set) {
            note("set \(edit.set.keys.sorted().joined(separator: ", ")) in \(edit.file)")
        }
    }

    // 7. icons: the app icon, and the same icon inside the running exe (for the Dock).
    // A project's own icon (the build copies projects/<name>/icon.* in as
    // project-icon.*) wins over the one made from the recipe's appIcon exe.
    let icns = iconDir.appendingPathComponent("AppIcon.icns")
    let projectIcon = (try? fm.contentsOfDirectory(at: recipeDir, includingPropertiesForKeys: nil))?
        .first { $0.deletingPathExtension().lastPathComponent == "project-icon" }
    if !fm.fileExists(atPath: icns.path) {
        if let custom = projectIcon {
            try makeIcons(exe: custom, out: iconDir); note("made the app icon from the project's \(custom.lastPathComponent)")
        } else if let from = recipe.install?.appIcon {
            // the stock exe, when exeIcon has already put the made icon into it
            let stock = game.appendingPathComponent(from + ".bkp")
            let exe = fm.fileExists(atPath: stock.path) ? stock : game.appendingPathComponent(from)
            try makeIcons(exe: exe, out: iconDir); note("made the app icon from \(from)")
        }
    }
    if let target = recipe.install?.exeIcon, fm.fileExists(atPath: icns.path) {
        // always from the stock copy, so a changed icon reaches the exe too
        let exe = game.appendingPathComponent(target), bkp = game.appendingPathComponent(target + ".bkp")
        let fresh = !fm.fileExists(atPath: bkp.path)
        if fresh { try fm.copyItem(at: exe, to: bkp) }
        let before = try Data(contentsOf: exe)
        do {
            let patched = iconDir.appendingPathComponent("patched.exe")
            try patchExeIcon(exe: bkp, pngDir: iconDir, out: patched)
            if try Data(contentsOf: patched) != before {
                _ = try fm.replaceItemAt(exe, withItemAt: patched)
                note("put the icon into \(target) (stock kept as \(target).bkp)")
            } else {
                try fm.removeItem(at: patched)
            }
        } catch let e as RefusedError {
            if fresh { try? fm.removeItem(at: bkp) }   // so a later install (a fixed tool) tries again
            print("warning: \(target) keeps its own icon: \(e.message)")
        }
    }

    // 8. what was installed, for the launcher and for a re-install
    let stamp = try JSONSerialization.data(withJSONObject: [
        "recipe": recipe.title, "fingerprint": fingerprint, "build": build?.status ?? "unknown",
    ], options: [.prettyPrinted, .sortedKeys])
    let stampURL = game.appendingPathComponent(".bottler-install.json")
    if (try? Data(contentsOf: stampURL)) != stamp { try stamp.write(to: stampURL); note("wrote .bottler-install.json") }
    return changes
}


// MARK: - launch

/// POSIX shell single-quoted word.
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Resolve the recipe's launch for one variant on one display: compute the window
/// rect, apply the per-launch INI edits and args ({x} {y} {w} {h}), and return shell
/// variable assignments for core/launch.sh. BOTTLER_TEST_SCREENS="frame;visible;safeTop;primary"
/// replaces the real displays (tests).
func prepareLaunch(res: URL, variant: Int, display: String) throws -> String {
    let recipe = try loadRecipe(res.appendingPathComponent("recipe/recipe.json"))
    guard recipe.launch.variants.indices.contains(variant) else {
        throw PEError(message: "no variant \(variant): the recipe has \(recipe.launch.variants.count)")
    }
    let v = recipe.launch.variants[variant], w = recipe.launch.window
    let screen: Screen, primary: Screen
    if let t = ProcessInfo.processInfo.environment["BOTTLER_TEST_SCREENS"] {
        let p = t.split(separator: ";").map(String.init)
        guard p.count == 4 else { throw PEError(message: "BOTTLER_TEST_SCREENS needs 4 parts") }
        screen = Screen(id: 0, name: "test", frame: try rect(p[0]), visible: try rect(p[1]), safeTop: CGFloat(Double(p[2]) ?? 0))
        primary = Screen(id: 0, name: "primary", frame: try rect(p[3]), visible: try rect(p[3]), safeTop: 0)
    } else {
        let screens = connectedScreens()
        screen = try pickScreen(display, screens); primary = screens[0]
    }
    let r = try gameRect(screen: screen, primary: primary, mode: w.mode, align: w.align ?? 1)
    let game = res.appendingPathComponent("game")
    func geometry(_ s: String) -> String {
        s.replacingOccurrences(of: "{x}", with: "\(r.x)").replacingOccurrences(of: "{y}", with: "\(r.y)")
            .replacingOccurrences(of: "{w}", with: "\(r.w)").replacingOccurrences(of: "{h}", with: "\(r.h)")
    }
    for edit in recipe.launch.ini ?? [] {
        try iniSet(game.appendingPathComponent(edit.file), section: edit.section, edit.set.mapValues(geometry))
    }
    // registry values for this launch, as one .reg file on drive C: that launch.sh imports
    var regFile = ""
    if let edits = recipe.launch.registry, !edits.isEmpty {
        var reg = "REGEDIT4\r\n"
        for edit in edits {
            let key = edit.key.replacingOccurrences(of: "HKCU\\", with: "HKEY_CURRENT_USER\\")
                .replacingOccurrences(of: "HKLM\\", with: "HKEY_LOCAL_MACHINE\\")
            reg += "\r\n[\(key)]\r\n"
            for (name, raw) in edit.set.sorted(by: { $0.key < $1.key }) {
                let value = geometry(raw)
                if value.hasPrefix("dword:"), let n = UInt32(value.dropFirst(6)) {
                    reg += "\"\(name)\"=dword:" + String(format: "%08x", n) + "\r\n"
                } else {
                    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    reg += "\"\(name)\"=\"\(escaped)\"\r\n"
                }
            }
        }
        try reg.write(to: res.appendingPathComponent("prefix/drive_c/bottler-launch.reg"), atomically: true, encoding: .utf8)
        regFile = "C:\\bottler-launch.reg"
    }
    // fullscreen: the game owns its window, so bottler-place gets no rect and never moves it
    let place = w.mode == "fullscreen" ? (x: 0, y: 0, w: 0, h: 0) : r
    let overrides = (recipe.launch.dllOverrides ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var out = [
        "GX=\(place.x)", "GY=\(place.y)", "GW=\(place.w)", "GH=\(place.h)",
        "REG_FILE=" + shq(regFile),
        "GAME_EXE=" + shq("C:\\Game\\" + v.exe.replacingOccurrences(of: "/", with: "\\")),
        "GAME_ARGS=(" + (v.args ?? []).map { shq(geometry($0)) }.joined(separator: " ") + ")",
        "WIN_TITLE=" + shq(w.title ?? ""),
        "BACKDROP=" + ((w.backdrop ?? false) ? "1" : "0"),
        "MENUBAR=" + shq(w.menubar ?? "keep"),
        "RECIPE_OVERRIDES=" + shq(overrides.joined(separator: ";")),
    ]
    for (k, val) in (recipe.launch.env ?? [:]).sorted(by: { $0.key < $1.key }) {
        guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw PEError(message: "bad environment variable name in the recipe: \(k)")
        }
        out.append("export \(k)=\(shq(val))")
    }
    return out.joined(separator: "\n")
}


// MARK: - Dock name (CrossOver engines)

/// A macOS process is named after the file it runs, and a CrossOver 23 engine runs
/// every Windows program through bin/wine64-preloader, so the Dock says
/// "wine64-preloader". Renaming the loader is not enough: ntdll.so builds the
/// loader's path from one string, which is patched (NUL-padded, so the name must be
/// ASCII and at most 16 bytes). The loaders' embedded Info.plist gets the name for
/// the menu bar. A symlink keeps the old name working. Idempotent.
func dockName(wine: URL, name: String) throws {
    let fm = FileManager.default
    let original = "wine64-preloader"
    guard !name.isEmpty, name.utf8.count <= original.utf8.count, name.allSatisfy({ $0.isASCII && $0 != "/" }) else {
        throw RefusedError(message: "\"\(name)\" is not usable as a loader name (ASCII, at most 16 bytes)")
    }
    let bin = wine.appendingPathComponent("bin")
    let loader = bin.appendingPathComponent(original), renamed = bin.appendingPathComponent(name)
    let ntdll = wine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
    guard fm.fileExists(atPath: ntdll.path) else { throw RefusedError(message: "not a CrossOver engine (no ntdll.so)") }

    // 1. ntdll.so: the one "wine64-preloader" path string
    var n = try Data(contentsOf: ntdll)
    let from = Data([0] + Array(original.utf8) + [0])
    let to = Data([0] + Array(name.utf8) + [UInt8](repeating: 0, count: original.utf8.count - name.utf8.count + 1))
    let already = Data([0] + Array(name.utf8) + [0])
    if let r = n.range(of: from) {
        guard n.range(of: from, in: r.upperBound..<n.count) == nil else { throw RefusedError(message: "ntdll.so names the loader more than once") }
        n.replaceSubrange(r, with: to)
        try n.write(to: ntdll, options: .atomic)
        try? run("/usr/bin/codesign", ["--force", "--sign", "-", ntdll.path])   // it ships ad-hoc signed
        print("==> ntdll.so starts \(name)")
    } else if n.range(of: already) == nil {
        throw RefusedError(message: "ntdll.so does not name wine64-preloader")
    }

    // 2. the loader file, with the old name kept as a symlink
    if (try? loader.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
        guard fm.fileExists(atPath: loader.path) else { throw RefusedError(message: "no bin/\(original)") }
        if name != original {
            try? fm.removeItem(at: renamed)
            try fm.moveItem(at: loader, to: renamed)
            try fm.createSymbolicLink(atPath: loader.path, withDestinationPath: name)
            print("==> bin/\(original) is now bin/\(name)")
        }
    }

    // 3. CFBundleName in the loaders' embedded Info.plist (the menu bar's app name)
    for file in [renamed, bin.appendingPathComponent("wine64")] where fm.fileExists(atPath: file.path) {
        var d = try Data(contentsOf: file)
        guard let key = d.range(of: Data("<key>CFBundleName</key>".utf8)),
              let open = d.range(of: Data("<string>".utf8), in: key.upperBound..<min(d.count, key.upperBound + 64)),
              let close = d.range(of: Data("</string>".utf8), in: open.upperBound..<min(d.count, open.upperBound + 256)),
              let plistEnd = d.range(of: Data("</plist>".utf8), in: close.upperBound..<d.count) else { continue }
        let current = String(decoding: d[open.upperBound..<close.lowerBound], as: UTF8.self)
        if current == name { continue }
        // everything from the value to the end of the plist is rewritten in the same
        // space; whitespace between XML elements is free, so a longer name fits by
        // dropping indentation after it
        let tail = String(decoding: d[close.lowerBound..<plistEnd.upperBound], as: UTF8.self)
        let compactTail = tail.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "    ", with: "")
        let newBytes = Data((name + compactTail).utf8)
        let space = plistEnd.upperBound - open.upperBound
        guard newBytes.count <= space else { print("warning: \(file.lastPathComponent): no room for the name"); continue }
        d.replaceSubrange(open.upperBound..<plistEnd.upperBound, with: newBytes + Data(repeating: 0x20, count: space - newBytes.count))
        try d.write(to: file, options: .atomic)
        print("==> \(file.lastPathComponent) is called \(name) in the menu bar")
    }
}



// MARK: - hints (Lutris)

/// Lutris' public API: games by name, then each game's community installer scripts.
/// Printed as hints for a recipe, never applied. BOTTLER_LUTRIS_API replaces the
/// API root (tests point it at local files).
func lutrisHints(_ name: String) -> String {
    let api = ProcessInfo.processInfo.environment["BOTTLER_LUTRIS_API"] ?? "https://lutris.net/api"
    func get(_ path: String) -> Any? {
        guard let url = URL(string: api + path) else { return nil }
        if url.isFileURL { return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("mac-bottler", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { body = data }
            done.signal()
        }.resume()
        done.wait()
        return body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
    let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
    guard let found = get("/games?search=\(query)") as? [String: Any], let games = found["results"] as? [[String: Any]] else {
        return "warning: Lutris is not reachable; no hints (nothing else depends on them)\n"
    }
    // exact name, then all query words as whole words, then substrings; among
    // equals, fewer extra words first
    func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    let wanted = words(name)
    func score(_ g: [String: Any]) -> (Int, Int) {
        let n = g["name"] as? String ?? "", w = words(n)
        if w == wanted { return (3, 0) }
        if wanted.allSatisfy(w.contains) { return (2, -(w.count - wanted.count)) }
        if wanted.allSatisfy({ q in n.lowercased().contains(q) }) { return (1, -(w.count - wanted.count)) }
        return (0, 0)
    }
    let matches = games.filter { score($0).0 > 0 }.sorted { score($0) > score($1) }.prefix(5)
    guard !matches.isEmpty else { return "no Lutris game matches \"\(name)\"\n" }
    var out = ""
    for g in matches {
        let slug = g["slug"] as? String ?? ""
        let year = (g["year"] as? Int).map(String.init) ?? "?"
        out += "\(g["name"] as? String ?? slug) (\(year), lutris.net/games/\(slug))\n"
        guard let inst = get("/installers/\(slug)") as? [String: Any], let list = inst["results"] as? [[String: Any]], !list.isEmpty else {
            out += "  no installer scripts\n"; continue
        }
        for i in list {
            let script = i["script"] as? [String: Any] ?? [:]
            let game = script["game"] as? [String: Any] ?? [:]
            out += "  - \(i["version"] as? String ?? "?") (runner: \(i["runner"] as? String ?? "?"))\n"
            if let exe = game["exe"] { out += "      exe: \(exe)\n" }
            if let args = game["args"] { out += "      args: \(args)\n" }
            for key in ["wine", "system"] {
                if let v = script[key], !(v is NSNull),
                   let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) {
                    out += "      \(key): \(String(decoding: d, as: UTF8.self))\n"
                }
            }
            let tasks = (script["installer"] as? [Any] ?? []).compactMap { t -> String? in
                guard let d = t as? [String: Any], let k = d.keys.first else { return nil }
                if k == "task", let task = d[k] as? [String: Any] {
                    let what = task["name"] as? String ?? "task"
                    return what == "winetricks" ? "winetricks \(task["app"] as? String ?? "")" : what
                }
                return k
            }
            if !tasks.isEmpty { out += "      installer: \(tasks.joined(separator: ", "))\n" }
        }
    }
    return out
}

// MARK: - observing a running app (agents)

/// The app bundle's resolved path with a trailing slash; every process of the app
/// (launcher, wine, the game, helpers) runs an executable under it.
func appRoot(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents").path) else {
        throw PEError(message: "not an app bundle: \(path)")
    }
    return url.path + "/"
}

struct WindowInfo {
    let number: Int, owner: String, pid: pid_t, title: String, frame: CGRect, layer: Int, onScreen: Bool
    var json: [String: Any] {
        ["number": number, "owner": owner, "pid": pid, "title": title, "layer": layer, "onScreen": onScreen,
         "frame": [frame.minX, frame.minY, frame.width, frame.height]]
    }
}

/// Windows of processes running from `root` (titles need Screen Recording permission).
func appWindows(_ root: String) -> [WindowInfo] {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, processPath(pid).hasPrefix(root),
              let n = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        guard frame.width >= 50, frame.height >= 50 else { return nil }   // skip status-item slivers
        return WindowInfo(number: n, owner: w[kCGWindowOwnerName as String] as? String ?? "", pid: pid,
                          title: w[kCGWindowName as String] as? String ?? "", frame: frame,
                          layer: w[kCGWindowLayer as String] as? Int ?? 0,
                          onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}

/// Total CPU time used by a process, in nanoseconds.
func cpuNanos(_ pid: pid_t) -> UInt64? {
    var info = rusage_info_v2()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    guard ok == 0 else { return nil }
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    return (info.ri_user_time + info.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
}

/// CPU % per process of the app, measured over `seconds` (100 = one full core).
func appCPU(_ root: String, seconds: Double) -> [[String: Any]] {
    let pids = processes(under: root)
    let before = Dictionary(uniqueKeysWithValues: pids.compactMap { p in cpuNanos(p).map { (p, $0) } })
    Thread.sleep(forTimeInterval: seconds)
    return pids.compactMap { p -> [String: Any]? in
        guard let a = before[p], let b = cpuNanos(p) else { return nil }
        let pct = Double(b &- a) / (seconds * 1e9) * 100
        let path = processPath(p)
        return ["pid": p, "cpu": (pct * 10).rounded() / 10,
                "process": String(path.dropFirst(root.count)), "name": (path as NSString).lastPathComponent]
    }.sorted { ($0["cpu"] as! Double) > ($1["cpu"] as! Double) }
}

func click(_ x: Double, _ y: Double) {
    let p = CGPoint(x: x, y: y)
    for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
    }
}

func printJSON(_ v: Any) {
    let json = try! JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(json + "\n".data(using: .utf8)!)
}

// MARK: - main

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "scan":
    guard args.count == 3 else { fail("usage: bottler scan <dir>") }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: args[2], isDirectory: &isDir), isDir.boolValue else {
        fail("bottler scan: not a folder: \(args[2])")
    }
    do {
        let report = try scan(URL(fileURLWithPath: args[2]).standardizedFileURL)
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(json + "\n".data(using: .utf8)!)
    } catch {
        fail("bottler scan: \(error)")
    }
case "icon":
    guard args.count == 4 else { fail("usage: bottler icon <exe|image> <out-dir>") }
    do { try makeIcons(exe: URL(fileURLWithPath: args[2]), out: URL(fileURLWithPath: args[3])) }
    catch { fail("bottler icon: \(error)") }
case "exe-icon":
    guard args.count == 5 else { fail("usage: bottler exe-icon <exe> <png-dir> <out-exe>") }
    do {
        try patchExeIcon(exe: URL(fileURLWithPath: args[2]), pngDir: URL(fileURLWithPath: args[3]),
                         out: URL(fileURLWithPath: args[4]))
    } catch let e as RefusedError {
        FileHandle.standardError.write("bottler exe-icon: refused: \(e.message)\n".data(using: .utf8)!)
        exit(3)
    } catch { fail("bottler exe-icon: \(error)") }
case "displays":
    let list: [[String: Any]] = connectedScreens().enumerated().map { i, s in
        ["id": s.id, "name": s.name, "main": i == 0,
         "frame": [s.frame.minX, s.frame.minY, s.frame.width, s.frame.height],
         "visible": [s.visible.minX, s.visible.minY, s.visible.width, s.visible.height],
         "safeTop": s.safeTop]
    }
    let json = try! JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(json + "\n".data(using: .utf8)!)
case "geometry":
    // bottler geometry <display|main> <mode> [align]
    // test form: bottler geometry --screen x,y,w,h --visible x,y,w,h --safe-top n --primary x,y,w,h <mode> [align]
    do {
        var rest = Array(args.dropFirst(2))
        var screen: Screen, primary: Screen
        if rest.first == "--screen" {
            guard rest.count >= 9 else { fail("usage: bottler geometry --screen R --visible R --safe-top N --primary R <mode> [align]") }
            screen = Screen(id: 0, name: "test", frame: try rect(rest[1]), visible: try rect(rest[3]),
                            safeTop: CGFloat(Double(rest[5]) ?? 0))
            primary = Screen(id: 0, name: "primary", frame: try rect(rest[7]), visible: try rect(rest[7]), safeTop: 0)
            rest = Array(rest.dropFirst(8))
        } else {
            guard rest.count >= 2 else { fail("usage: bottler geometry <display|main> <mode> [align]") }
            let screens = connectedScreens()
            screen = try pickScreen(rest[0], screens); primary = screens[0]
            rest = Array(rest.dropFirst(1))
        }
        guard let mode = rest.first else { fail("bottler geometry: missing mode") }
        let align = rest.count > 1 ? Int(rest[1]) ?? 1 : 1
        let r = try gameRect(screen: screen, primary: primary, mode: mode, align: align)
        print("\(r.x) \(r.y) \(r.w) \(r.h)")
    } catch { fail("bottler geometry: \(error)") }
case "frame":
    let usage = "usage: bottler frame <display|main> <pid | --wine <Resources>>"
    var pid: pid_t?, wineRoot: String?
    if args.count == 4, let p = pid_t(args[3]) { pid = p }
    else if args.count == 5, args[3] == "--wine" {
        wineRoot = URL(fileURLWithPath: args[4]).appendingPathComponent("wine").resolvingSymlinksInPath().path + "/"
    } else { fail(usage) }
    do {
        let screen = try pickScreen(args[2], connectedScreens())
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let keeper = FrameKeeper(pid: pid, wineRoot: wineRoot, screenFrame: screen.frame)
        app.delegate = keeper
        app.run()
    } catch { fail("bottler frame: \(error)") }
case "menubar":
    guard args.count == 3 else { fail("usage: bottler menubar hide") }
    do { try menubar(args[2]) } catch { fail("bottler menubar: \(error)") }
case "desktop":
    guard args.count == 4 else { fail("usage: bottler desktop save|restore <file>") }
    do { try desktop(args[2], file: URL(fileURLWithPath: args[3])) } catch { fail("bottler desktop: \(error)") }
case "prepare-launch":
    guard args.count == 5, let variant = Int(args[3]) else { fail("usage: bottler prepare-launch <Resources> <variant> <display|main>") }
    do { print(try prepareLaunch(res: URL(fileURLWithPath: args[2]), variant: variant, display: args[4])) }
    catch { fail("bottler prepare-launch: \(error)") }
case "recipe-field":
    guard args.count == 4 else { fail("usage: bottler recipe-field <recipe.json> <field>") }
    do {
        let r = try loadRecipe(URL(fileURLWithPath: args[2]))
        switch args[3] {
        case "title": print(r.title)
        case "bundleId": print(r.bundleId)
        case "engine": print(r.engine)
        case "proxy.dll": print(r.install?.proxy?.dll ?? "")
        case "install.registry": for f in r.install?.registry ?? [] { print(f) }
        default: fail("bottler recipe-field: unknown field \(args[3])")
        }
    } catch { fail("bottler recipe-field: \(error)") }
case "dock-name":
    guard args.count == 4 else { fail("usage: bottler dock-name <wine dir> <name>") }
    do { try dockName(wine: URL(fileURLWithPath: args[2]), name: args[3]) }
    catch let e as RefusedError {
        FileHandle.standardError.write("bottler dock-name: refused: \(e.message)\n".data(using: .utf8)!)
        exit(3)
    } catch { fail("bottler dock-name: \(error)") }
case "hints":
    guard args.count >= 3 else { fail("usage: bottler hints <game name>") }
    print(lutrisHints(args.dropFirst(2).joined(separator: " ")), terminator: "")
case "windows":
    guard args.count == 3 else { fail("usage: bottler windows <app>") }
    do { printJSON(appWindows(try appRoot(args[2])).map { $0.json }) } catch { fail("bottler windows: \(error)") }
case "cpu":
    guard args.count == 3 || args.count == 4 else { fail("usage: bottler cpu <app> [seconds]") }
    do { printJSON(appCPU(try appRoot(args[2]), seconds: args.count == 4 ? Double(args[3]) ?? 3 : 3)) }
    catch { fail("bottler cpu: \(error)") }
case "shot":
    guard args.count == 3 || args.count == 5 else { fail("usage: bottler shot <out.png> [--app <app> | --window <n> | --rect x,y,w,h]") }
    var captureArgs = ["-x"]
    do {
        if args.count == 5 {
            switch args[3] {
            case "--window": captureArgs += ["-o", "-l", args[4]]
            case "--rect":
                let r = try rect(args[4]); captureArgs += ["-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
            case "--app":
                guard let w = appWindows(try appRoot(args[4])).filter({ $0.onScreen && $0.layer == 0 })
                        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    fail("bottler shot: the app has no window on screen")
                }
                captureArgs += ["-R\(Int(w.frame.minX)),\(Int(w.frame.minY)),\(Int(w.frame.width)),\(Int(w.frame.height))"]
            default: fail("bottler shot: unknown option \(args[3])")
            }
        }
        try run("/usr/sbin/screencapture", captureArgs + [args[2]])
        print(args[2])
    } catch { fail("bottler shot: \(error) (the terminal needs Screen Recording permission)") }
case "click":
    guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]) else { fail("usage: bottler click <x> <y>") }
    click(x, y)
case "log":
    guard args.count == 3 else { fail("usage: bottler log <app>") }
    let log = URL(fileURLWithPath: args[2]).appendingPathComponent("Contents/Resources/logs/last-launch.log")
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { fail("bottler log: no launch log yet at \(log.path)") }
    print(text, terminator: "")
case "recipe-check":
    guard args.count == 3 else { fail("usage: bottler recipe-check <recipe.json>") }
    let errors = checkRecipe(URL(fileURLWithPath: args[2]))
    if errors.isEmpty { print("recipe ok: \(args[2])") }
    else { fail("recipe-check \(args[2]):\n  " + errors.joined(separator: "\n  ")) }
case "fetch":
    guard args.count == 5 else { fail("usage: bottler fetch <recipe-dir> <cache> <out>") }
    do { try fetch(recipeDir: URL(fileURLWithPath: args[2]), cache: URL(fileURLWithPath: args[3]), out: URL(fileURLWithPath: args[4])) }
    catch { fail("bottler fetch: \(error)") }
case "install":
    guard args.count == 6 else { fail("usage: bottler install <recipe-dir> <source> <game-dir> <icon-dir>") }
    do {
        let n = try install(recipeDir: URL(fileURLWithPath: args[2]), source: URL(fileURLWithPath: args[3]),
                            game: URL(fileURLWithPath: args[4]), iconDir: URL(fileURLWithPath: args[5]))
        print(n == 0 ? "already installed: nothing to change" : "installed: \(n) changes")
    } catch let e as InstallRefused {
        FileHandle.standardError.write("bottler install: refused: \(e.message)\n".data(using: .utf8)!)
        exit(3)
    } catch { fail("bottler install: \(error)") }
case "ini-set":
    guard args.count >= 5 else { fail("usage: bottler ini-set <file> <section> key=value...") }
    var values: [String: String] = [:]
    for kv in args.dropFirst(4) {
        guard let eq = kv.firstIndex(of: "=") else { fail("bottler ini-set: not key=value: \(kv)") }
        values[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
    }
    do { try iniSet(URL(fileURLWithPath: args[2]), section: args[3], values) } catch { fail("bottler ini-set: \(error)") }
default:
    fail("usage: bottler scan | icon | exe-icon | displays | geometry | frame | menubar | recipe-check | fetch | install | ini-set (see the header of tools/bottler.swift)")
}
