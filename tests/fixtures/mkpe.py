#!/usr/bin/env python3
"""Write minimal synthetic Windows PE files for the tests. No game data involved.

usage: mkpe.py <out-file> [--64] [--console] [--size N] [--imports a.dll,b.dll]
               [--broken-imports] [--text STRING]

--broken-imports points the import directory outside every section, the way a
packed or encrypted executable looks to a reader. --text embeds a plain string.
"""
import argparse
import struct


def build(is64, console, imports, broken, text, size):
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

    opt_size = 240 if is64 else 224
    pe_off = 0x80
    headers_size = pe_off + 24 + opt_size + 40
    headers_size += (-headers_size) % file_align
    mz = bytearray(pe_off)
    mz[0:2] = b"MZ"
    struct.pack_into("<I", mz, 0x3C, pe_off)

    coff = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664 if is64 else 0x14C, 1, 0, 0, 0,
                                   opt_size, 0x22 if is64 else 0x102)
    opt = bytearray(opt_size)
    struct.pack_into("<H", opt, 0, 0x20B if is64 else 0x10B)
    struct.pack_into("<I", opt, 32, 0x1000)       # SectionAlignment
    struct.pack_into("<I", opt, 36, file_align)   # FileAlignment
    struct.pack_into("<I", opt, 56, sect_rva + 0x1000)  # SizeOfImage
    struct.pack_into("<I", opt, 60, headers_size)  # SizeOfHeaders
    struct.pack_into("<H", opt, 68, 3 if console else 2)  # Subsystem
    dirs = 112 if is64 else 96
    struct.pack_into("<I", opt, dirs - 4, 16)      # NumberOfRvaAndSizes
    if imports or broken:
        import_rva = 0x7FFF0000 if broken else sect_rva
        struct.pack_into("<II", opt, dirs + 8, import_rva, 20 * (len(imports) + 1))
    section = struct.pack("<8sIIIIIIHHI", b".rdata", 0x1000, sect_rva, len(raw),
                          headers_size, 0, 0, 0, 0, 0x40000040)
    headers = bytes(mz) + coff + bytes(opt) + section
    headers += bytes(headers_size - len(headers))
    out = headers + raw
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
    a = p.parse_args()
    imports = [x for x in a.imports.split(",") if x]
    with open(a.out, "wb") as f:
        f.write(build(a.is64, a.console, imports, a.broken_imports, a.text, a.size))


if __name__ == "__main__":
    main()
