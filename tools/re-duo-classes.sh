#!/bin/bash
# 开发辅助：dump Solo.dylib 的 __objc_classname 全量类名 + 关键段信息。
set -eu
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/solo-re}"
[ -f "$OUT/Solo.dylib" ] || { echo "!! 先跑 re-duo-strings.sh"; exit 1; }

python3 - "$OUT/Solo.dylib" <<'PY'
import struct, sys

path = sys.argv[1]
data = open(path, "rb").read()
magic = struct.unpack_from(">I", data, 0)[0]
assert magic in (0xCAFEBABE, 0xCAFEBABF), "not FAT"
n = struct.unpack_from(">I", data, 4)[0]
slices = {}
for i in range(n):
    ct, cs, off, size, al = struct.unpack_from(">iiIII", data, 8 + i * 20)
    name = "arm64e" if (cs & 0x00FFFFFF) == 2 else "arm64"
    slices[name] = (off, size)

def parse(off, size):
    hdr = data[off:off + size]
    magic64 = struct.unpack_from("<I", hdr, 0)[0]
    assert magic64 == 0xFEEDFACF, hex(magic64)
    ncmds = struct.unpack_from("<I", hdr, 16)[0]
    p = 32
    sections = {}
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", hdr, p)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", hdr, p + 64)[0]
            sp = p + 72
            for _ in range(nsects):
                sectname = hdr[sp:sp + 16].rstrip(b"\0").decode()
                segname = hdr[sp + 16:sp + 32].rstrip(b"\0").decode()
                addr, sz, offset = struct.unpack_from("<QQI", hdr, sp + 32)
                sections[(segname, sectname)] = (addr, sz, offset)
                sp += 80
        p += cmdsize
    return sections

for arch in ("arm64e",):
    off, size = slices[arch]
    secs = parse(off, size)
    print("== sections (%s) ==" % arch)
    for (seg, sect), (addr, sz, fo) in sorted(secs.items()):
        if "objc" in sect.lower() or "cstring" in sect.lower():
            print("  %-24s %-22s addr=0x%x size=%d file=0x%x" % (seg, sect, addr, sz, fo))
    addr, sz, fo = secs[("__TEXT", "__objc_classname")]
    names = data[off + fo: off + fo + sz].split(b"\0")
    names = [x.decode("utf-8", "replace") for x in names if x]
    print("\n== class names (%d) ==" % len(names))
    for nm in sorted(set(names)):
        print(" ", nm)
PY
