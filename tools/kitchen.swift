// kitchen: the wine-kitchen command-line tool. Built into every app as
// Resources/bin/kitchen and used by the build, the installer and agents.
//
//   kitchen scan <dir>                       JSON report on a game folder's executables
//   kitchen icon <exe> <out-dir>             rounded macOS icon from the exe's own icon
//   kitchen exe-icon <exe> <png-dir> <out>   put that icon into a copy of the exe, in place
//   kitchen displays                         JSON list of the connected displays
//   kitchen geometry <display|main> <mode> [align]
//                                            where the game window goes, in Win32
//                                            coordinates: "x y width height"
//   kitchen frame <display|main> <pid>       black backdrop behind the game's window
//   kitchen menubar hide|restore <marker>    auto-hide the menu bar while playing
//
// Subcommands are added as recipes need them (docs/RECIPES.md).
import Foundation
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
    return img
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
    let k = max(1, Int((Double(body) / Double(src.width)).rounded(.up)))
    let big = src.width * k
    let ctx = rgbaContext(canvas, canvas)
    let bodyRect = CGRect(x: offset, y: offset, width: body, height: body)
    ctx.addPath(squircle(in: bodyRect)); ctx.clip()
    ctx.interpolationQuality = .none
    let crop = (big - body) / 2
    ctx.draw(src, in: CGRect(x: offset - crop, y: offset - crop, width: big, height: big))
    return ctx.makeImage()!
}

func downscaled(_ img: CGImage, _ size: Int) -> CGImage {
    let ctx = rgbaContext(size, size)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw PEError(message: "cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw PEError(message: "cannot write \(url.path)") }
}

/// AppIcon.icns + icon_1024.png for the app, exe-icon-{256,48,32,16}.png for exe-icon.
func makeIcons(exe: URL, out: URL) throws {
    let src = try largestIcon(try PEFile(data: Data(contentsOf: exe)))
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
    try writePNG(roundedIcon(src, canvas: 256), out.appendingPathComponent("exe-icon-256.png"))
    for size in [48, 32, 16] {
        try writePNG(downscaled(master, size), out.appendingPathComponent("exe-icon-\(size).png"))
    }
}

struct RefusedError: Error { let message: String }

/// Replace an exe's icons in place: the new PNG icons go into the existing block
/// of RT_ICON data, the RT_ICON entries are re-pointed and the group is rewritten
/// in its own slot. Nothing moves: a full resource rebuild (rcedit) broke a game
/// with self-modifying code. Refuses unless everything fits, the size is unchanged
/// and every changed byte is inside the resource section.
func patchExeIcon(exe: URL, pngDir: URL, out: URL) throws {
    let original = try Data(contentsOf: exe)
    let pe = try PEFile(data: original)
    guard let rsrcRange = pe.resourceSectionFileRange(), let group = iconGroup(pe) else {
        throw RefusedError(message: "no icon resources")
    }
    let all = pe.resources()
    let icons = all.filter { $0.type == rtIcon }.sorted { $0.id < $1.id }
    let pngs: [(size: Int, data: Data)] = try [256, 48, 32, 16].compactMap { size in
        let url = pngDir.appendingPathComponent("exe-icon-\(size).png")
        return FileManager.default.fileExists(atPath: url.path) ? (size, try Data(contentsOf: url)) : nil
    }
    guard !pngs.isEmpty else { throw RefusedError(message: "no exe-icon-*.png in \(pngDir.path)") }
    guard icons.count >= pngs.count else {
        throw RefusedError(message: "the exe has \(icons.count) icon slots, \(pngs.count) needed")
    }
    // the block the icon data occupies, which must hold nothing else
    let start = icons.map { $0.rva }.min()!, end = icons.map { $0.rva + $0.size }.max()!
    for r in all where r.type != rtIcon && r.rva < end && r.rva + r.size > start {
        throw RefusedError(message: "icon data is interleaved with other resources")
    }
    let aligned = pngs.reduce(0) { ($0 + $1.data.count + 3) & ~3 }
    guard aligned <= Int(end - start) else {
        throw RefusedError(message: "new icons need \(aligned) bytes, the icon block has \(end - start)")
    }
    guard let groupSize = pe.bytes(of: group.group)?.count, 6 + 14 * pngs.count <= groupSize,
          let groupOffset = pe.offset(ofRVA: group.group.rva), let blockOffset = pe.offset(ofRVA: start) else {
        throw RefusedError(message: "the icon group slot is too small")
    }

    var d = original
    d.replaceSubrange(blockOffset..<blockOffset + Int(end - start), with: Data(count: Int(end - start)))
    var rva = start
    var placed: [(size: Int, rva: UInt32, length: Int, id: UInt32)] = []
    for (i, png) in pngs.enumerated() {
        let o = blockOffset + Int(rva - start)
        d.replaceSubrange(o..<o + png.data.count, with: png.data)
        placed.append((png.size, rva, png.data.count, icons[i].id))
        rva = (rva + UInt32(png.data.count) + 3) & ~3
    }
    func put32(_ v: UInt32, _ o: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(o..<o + 4, with: $0) } }
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

    guard d.count == original.count else { throw RefusedError(message: "size changed") }
    for i in 0..<d.count where d[i] != original[i] && !rsrcRange.contains(i) {
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
}

func connectedScreens() -> [Screen] {
    NSScreen.screens.map { s in
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return Screen(id: id, name: s.localizedName, frame: s.frame, visible: s.visibleFrame,
                      safeTop: s.safeAreaInsets.top)
    }
}

/// The game window's rect in Win32 virtual-screen coordinates (origin top-left of
/// the primary display, y down) for `screen`, where `primary` is NSScreen.screens[0].
///   mode "native": the whole usable area; "pillarbox:<w>:<h>": the largest area of
///   that aspect ratio, centred. Both sides are rounded down to a multiple of `align`.
/// Usable area: the display minus the notch and a visible Dock; the menu bar is
/// ignored because the launcher auto-hides it while the game runs.
func gameRect(screen: Screen, primary: Screen, mode: String, align: Int) throws -> (x: Int, y: Int, w: Int, h: Int) {
    let f = screen.frame, v = screen.visible
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
        throw PEError(message: "unknown mode \(mode) (native | pillarbox:<w>:<h>)")
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
        throw PEError(message: "no display \(which) (see kitchen displays)")
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
final class FrameKeeper: NSObject, NSApplicationDelegate {
    let pid: pid_t
    let screenFrame: CGRect
    var backdrop: Backdrop!

    init(pid: pid_t, screenFrame: CGRect) { self.pid = pid; self.screenFrame = screenFrame }

    func applicationDidFinishLaunching(_ note: Notification) {
        backdrop = Backdrop(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = .black
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.collectionBehavior = [.managed, .fullScreenNone]
        backdrop.isReleasedWhenClosed = false
        backdrop.onClick = { [weak self] in
            guard let self else { return }
            NSRunningApplication(processIdentifier: self.pid)?.activate()
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// The game's largest normal window: its number and whether it is on screen.
    func gameWindow() -> (number: Int, onScreen: Bool)? {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (Int, Bool, CGFloat)?
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let n = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
            guard area >= 640 * 480 else { continue }
            let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if best == nil || area > best!.2 { best = (n, on, area) }
        }
        return best.map { (number: $0.0, onScreen: $0.1) }
    }

    func tick() {
        guard kill(pid, 0) == 0 else { NSApp.terminate(nil); return }
        guard let g = gameWindow(), g.onScreen else { backdrop.orderOut(nil); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            backdrop.order(.below, relativeTo: g.number)
        }
    }
}

// MARK: - menu bar

/// The global "automatically hide the menu bar" preference, set for the session.
/// hide: turns it on unless the user already has it on, leaving a marker file;
/// restore: turns it off again only if the marker exists, then deletes it. A marker
/// left by a crashed run is restored by the next run's restore.
func menubar(_ action: String, marker: String) throws {
    let key = "_HIHideMenuBar" as CFString
    let current = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                         kCFPreferencesAnyHost) as? Bool ?? false
    let fm = FileManager.default
    switch action {
    case "hide":
        guard !current else { return }
        fm.createFile(atPath: marker, contents: Data())
        CFPreferencesSetValue(key, kCFBooleanTrue, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    case "restore":
        guard fm.fileExists(atPath: marker) else { return }
        CFPreferencesSetValue(key, nil, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try fm.removeItem(atPath: marker)
    default:
        throw PEError(message: "menubar hide|restore <marker>")
    }
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil,
        deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.5)   // let the screens' usable area settle
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
case "icon":
    guard args.count == 4 else { fail("usage: kitchen icon <exe> <out-dir>") }
    do { try makeIcons(exe: URL(fileURLWithPath: args[2]), out: URL(fileURLWithPath: args[3])) }
    catch { fail("kitchen icon: \(error)") }
case "exe-icon":
    guard args.count == 5 else { fail("usage: kitchen exe-icon <exe> <png-dir> <out-exe>") }
    do {
        try patchExeIcon(exe: URL(fileURLWithPath: args[2]), pngDir: URL(fileURLWithPath: args[3]),
                         out: URL(fileURLWithPath: args[4]))
    } catch let e as RefusedError {
        FileHandle.standardError.write("kitchen exe-icon: refused: \(e.message)\n".data(using: .utf8)!)
        exit(3)
    } catch { fail("kitchen exe-icon: \(error)") }
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
    // kitchen geometry <display|main> <mode> [align]
    // test form: kitchen geometry --screen x,y,w,h --visible x,y,w,h --safe-top n --primary x,y,w,h <mode> [align]
    do {
        var rest = Array(args.dropFirst(2))
        var screen: Screen, primary: Screen
        if rest.first == "--screen" {
            guard rest.count >= 9 else { fail("usage: kitchen geometry --screen R --visible R --safe-top N --primary R <mode> [align]") }
            screen = Screen(id: 0, name: "test", frame: try rect(rest[1]), visible: try rect(rest[3]),
                            safeTop: CGFloat(Double(rest[5]) ?? 0))
            primary = Screen(id: 0, name: "primary", frame: try rect(rest[7]), visible: try rect(rest[7]), safeTop: 0)
            rest = Array(rest.dropFirst(8))
        } else {
            guard rest.count >= 2 else { fail("usage: kitchen geometry <display|main> <mode> [align]") }
            let screens = connectedScreens()
            screen = try pickScreen(rest[0], screens); primary = screens[0]
            rest = Array(rest.dropFirst(1))
        }
        guard let mode = rest.first else { fail("kitchen geometry: missing mode") }
        let align = rest.count > 1 ? Int(rest[1]) ?? 1 : 1
        let r = try gameRect(screen: screen, primary: primary, mode: mode, align: align)
        print("\(r.x) \(r.y) \(r.w) \(r.h)")
    } catch { fail("kitchen geometry: \(error)") }
case "frame":
    guard args.count == 4, let pid = pid_t(args[3]) else { fail("usage: kitchen frame <display|main> <pid>") }
    do {
        let screen = try pickScreen(args[2], connectedScreens())
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let keeper = FrameKeeper(pid: pid, screenFrame: screen.frame)
        app.delegate = keeper
        app.run()
    } catch { fail("kitchen frame: \(error)") }
case "menubar":
    guard args.count == 4 else { fail("usage: kitchen menubar hide|restore <marker>") }
    do { try menubar(args[2], marker: args[3]) } catch { fail("kitchen menubar: \(error)") }
default:
    fail("usage: kitchen scan | icon | exe-icon | displays | geometry | frame | menubar (see the header of tools/kitchen.swift)")
}
