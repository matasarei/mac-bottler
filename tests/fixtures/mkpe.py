#!/usr/bin/env python3
"""Write minimal synthetic Windows PE files for the tests. No game data involved.

usage: mkpe.py <out-file> [--64] [--console] [--size N] [--imports a.dll,b.dll]
               [--broken-imports] [--text STRING] [--icons 16,32,48] [--figure | --card]

--broken-imports points the import directory outside every section, the way a
packed or encrypted executable looks to a reader. --text embeds a plain string.
--icons adds a .rsrc section with one icon group of 24-bit BMP icons (with AND
masks) at the given sizes, stored contiguously the way old games store them.
--figure makes the icons a plus sign on a transparent background (~44% transparent once trimmed).
--card makes them an opaque square over the middle 70%, with transparent margins.
"""
import argparse
import struct


def bmp_icon(n, figure=False):
    """A 24-bit n x n icon: a diagonal colour gradient, transparent 2 px border;
    with figure, only a centred plus sign is opaque; with card, a centred square."""
    row = (n * 3 + 3) & ~3
    pixels = bytearray()
    for y in range(n):
        line = bytearray()
        for x in range(n):
            r, g = (x * 255) // n, (y * 255) // n
            if figure:  # few colours, the way pixel art has them
                r, g = r & 0xC0, g & 0xC0
            line += bytes((r, g, 128))
        pixels += line + bytes(row - len(line))
    mask_row = ((n + 31) // 32) * 4
    mask = bytearray()
    for y in range(n):
        bits = bytearray(mask_row)
        for x in range(n):
            if figure == "card":
                m = round(n * 0.15)
                clear = x < m or y < m or x >= n - m or y >= n - m
            elif figure:  # a plus sign over the middle 60%, arms a third of that thick
                lo, hi = n * 0.2, n * 0.8
                t0, t1 = n * 0.4, n * 0.6
                cx, cy = x + 0.5, y + 0.5
                clear = not ((lo <= cx < hi and t0 <= cy < t1) or (lo <= cy < hi and t0 <= cx < t1))
            else:
                clear = x < 2 or y < 2 or x >= n - 2 or y >= n - 2
            if clear:
                bits[x // 8] |= 0x80 >> (x % 8)
        mask += bits
    header = struct.pack("<IiiHHIIiiII", 40, n, 2 * n, 1, 24, 0, len(pixels) + len(mask), 0, 0, 0, 0)
    return header + bytes(pixels) + bytes(mask)


def rsrc_section(rva, sizes, figure=False):
    """Resource tree: RT_ICON (3) ids 1..n and RT_GROUP_ICON (14) id 101, lang 1033."""
    icons = [bmp_icon(n, figure) for n in sizes]
    group = struct.pack("<HHH", 0, 1, len(icons)) + b"".join(
        struct.pack("<BBBBHHIH", n % 256, n % 256, 0, 0, 1, 24, len(ic), i + 1)
        for i, (n, ic) in enumerate(zip(sizes, icons)))

    def directory(entries):  # entries: [(id, offset_with_high_bit_or_data_entry)]
        return struct.pack("<IIHHHH", 0, 0, 0, 0, 0, len(entries)) + b"".join(
            struct.pack("<II", i, o) for i, o in entries)

    # fixed layout: root, type dirs, name dirs, lang dirs, data entries, data
    n = len(icons)
    root_size = 16 + 8 * 2
    type_icon_size = 16 + 8 * n
    type_group_size = 16 + 8
    lang_size = 16 + 8
    off_type_icon = root_size
    off_type_group = off_type_icon + type_icon_size
    off_langs = off_type_group + type_group_size
    off_entries = off_langs + lang_size * (n + 1)
    off_data = off_entries + 16 * (n + 1)
    off_data = (off_data + 15) & ~15
    blobs = icons + [group]
    data_offsets = []
    cursor = off_data
    for b in blobs:
        data_offsets.append(cursor)
        cursor += len(b)
        cursor = (cursor + 7) & ~7
    out = bytearray(cursor)
    out[0:root_size] = directory([(3, 0x80000000 | off_type_icon), (14, 0x80000000 | off_type_group)])
    out[off_type_icon:off_type_icon + type_icon_size] = directory(
        [(i + 1, 0x80000000 | (off_langs + lang_size * i)) for i in range(n)])
    out[off_type_group:off_type_group + type_group_size] = directory(
        [(101, 0x80000000 | (off_langs + lang_size * n))])
    for i in range(n + 1):
        lo = off_langs + lang_size * i
        out[lo:lo + lang_size] = directory([(1033, off_entries + 16 * i)])
        struct.pack_into("<IIII", out, off_entries + 16 * i, rva + data_offsets[i], len(blobs[i]), 0, 0)
        out[data_offsets[i]:data_offsets[i] + len(blobs[i])] = blobs[i]
    return bytes(out)


def build(is64, console, imports, broken, text, size, icons=(), figure=False):
    file_align = 0x200
    sect_rva = 0x1000
    # one section holding the import descriptors, the DLL names and any extra text
    body = bytearray()
    desc_off = 0
    names_off = 20 * (len(imports) + 1)
    body += bytes(names_off)
    name_rvas = []
    for dll in imports:
        name_rvas.append(sect_rva + len(body))
        body += dll.encode() + b"\0"
    for i, rva in enumerate(name_rvas):
        struct.pack_into("<IIIII", body, desc_off + 20 * i, 0, 0, 0, rva, 0)
    if text:
        body += text.encode() + b"\0"
    raw = bytes(body) + bytes((-len(body)) % file_align)
    rsrc_rva = sect_rva + 0x1000
    rsrc = rsrc_section(rsrc_rva, icons, figure) if icons else b""
    rsrc_raw = rsrc + bytes((-len(rsrc)) % file_align)
    nsect = 2 if icons else 1

    opt_size = 240 if is64 else 224
    pe_off = 0x80
    headers_size = pe_off + 24 + opt_size + 40 * nsect
    headers_size += (-headers_size) % file_align
    mz = bytearray(pe_off)
    mz[0:2] = b"MZ"
    struct.pack_into("<I", mz, 0x3C, pe_off)

    coff = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664 if is64 else 0x14C, nsect, 0, 0, 0,
                                   opt_size, 0x22 if is64 else 0x102)
    opt = bytearray(opt_size)
    struct.pack_into("<H", opt, 0, 0x20B if is64 else 0x10B)
    struct.pack_into("<I", opt, 32, 0x1000)       # SectionAlignment
    struct.pack_into("<I", opt, 36, file_align)   # FileAlignment
    struct.pack_into("<I", opt, 56, rsrc_rva + ((len(rsrc) + 0xFFF) & ~0xFFF) if icons else sect_rva + 0x1000)  # SizeOfImage
    struct.pack_into("<I", opt, 60, headers_size)  # SizeOfHeaders
    struct.pack_into("<H", opt, 68, 3 if console else 2)  # Subsystem
    dirs = 112 if is64 else 96
    struct.pack_into("<I", opt, dirs - 4, 16)      # NumberOfRvaAndSizes
    if imports or broken:
        import_rva = 0x7FFF0000 if broken else sect_rva
        struct.pack_into("<II", opt, dirs + 8, import_rva, 20 * (len(imports) + 1))
    if icons:
        struct.pack_into("<II", opt, dirs + 16, rsrc_rva, len(rsrc))
    section = struct.pack("<8sIIIIIIHHI", b".rdata", 0x1000, sect_rva, len(raw),
                          headers_size, 0, 0, 0, 0, 0x40000040)
    if icons:
        section += struct.pack("<8sIIIIIIHHI", b".rsrc", len(rsrc), rsrc_rva, len(rsrc_raw),
                               headers_size + len(raw), 0, 0, 0, 0, 0x40000040)
    headers = bytes(mz) + coff + bytes(opt) + section
    headers += bytes(headers_size - len(headers))
    out = headers + raw + rsrc_raw
    if size and size > len(out):
        out += bytes(size - len(out))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--64", dest="is64", action="store_true")
    p.add_argument("--console", action="store_true")
    p.add_argument("--size", type=int, default=0)
    p.add_argument("--imports", default="")
    p.add_argument("--broken-imports", action="store_true")
    p.add_argument("--text", default="")
    p.add_argument("--icons", default="")
    p.add_argument("--figure", action="store_const", const="figure", default=False)
    p.add_argument("--card", dest="figure", action="store_const", const="card")
    a = p.parse_args()
    imports = [x for x in a.imports.split(",") if x]
    with open(a.out, "wb") as f:
        icons = [int(x) for x in a.icons.split(",") if x]
        f.write(build(a.is64, a.console, imports, a.broken_imports, a.text, a.size, icons, a.figure))


if __name__ == "__main__":
    main()
