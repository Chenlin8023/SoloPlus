#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""arm64e 终审断言：__cfstring 的 isa 必须全部为 auth bind24（plain 为 0）。

用法: python3 verify_fixups.py <macho>
退出码 0 = 通过；1 = 仍有 plain 指针；2 = 用法/格式问题。
仅检查 FAT 中的 arm64e 切片（subtype 0x80000002）。
"""
import struct
import sys

CHAINED = 0x80000034
SEGMENT64 = 0x19


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def u64(d, o):
    return struct.unpack_from("<Q", d, o)[0]


def check_slice(d, off):
    ncmds = u32(d, off + 16)
    q = off + 32
    segs = []
    fixups = None
    for _ in range(ncmds):
        cmd, csz = u32(d, q), u32(d, q + 4)
        if cmd == SEGMENT64:
            name = bytes(d[q + 8:q + 24]).rstrip(b"\0").decode()
            vmaddr = u64(d, q + 24)
            vmsize = u64(d, q + 32)
            fileoff = u64(d, q + 40)
            filesize = u64(d, q + 48)
            nsects = u32(d, q + 64)
            secs = []
            for j in range(nsects):
                b = q + 72 + j * 80
                sname = bytes(d[b:b + 16]).rstrip(b"\0").decode()
                size = u64(d, b + 40)
                soff = u32(d, b + 48)
                secs.append((sname, size, off + soff))
            segs.append((name, vmaddr, vmsize, fileoff, filesize, secs))
        elif cmd == CHAINED:
            fixups = u32(d, q + 8)
        q += csz

    if fixups is None:
        return 0, 0

    def section_at(file_offset):
        for name, _vmaddr, _vmsize, _fo, _fs, secs in segs:
            for sname, size, soff in secs:
                if soff <= file_offset < soff + size:
                    return "%s,%s" % (name, sname)
        return None

    base = off + fixups
    starts_off = u32(d, base + 4)
    seg_count = u32(d, base + starts_off)
    auth_cf = plain_cf = 0

    for si in range(seg_count):
        so = u32(d, base + starts_off + 4 + si * 4)
        if so == 0:
            continue
        sbase = base + starts_off + so
        page_size = u16(d, sbase + 4)
        seg_offset = u64(d, sbase + 8)
        page_count = u16(d, sbase + 20)
        for pi in range(page_count):
            ps = u16(d, sbase + 22 + pi * 2)
            if ps == 0xFFFF:
                continue
            cur = off + seg_offset + pi * page_size + ps
            guard = 0
            while guard < 100000:
                guard += 1
                raw = u64(d, cur)
                bind = (raw >> 62) & 1
                auth = (raw >> 63) & 1
                nxt = (raw >> 51) & 0x7FF
                sec = section_at(cur)
                if sec and sec.endswith("__cfstring") and bind:
                    if auth:
                        auth_cf += 1
                    else:
                        plain_cf += 1
                        print("  PLAIN __cfstring isa @ file 0x%x" % cur)
                if nxt == 0:
                    break
                cur += 8 * nxt
    return auth_cf, plain_cf


def main(path):
    d = bytearray(open(path, "rb").read())
    if struct.unpack_from(">I", d, 0)[0] != 0xCAFEBABE:
        print("!! 不是 FAT: %s" % path)
        return 2
    total_auth = total_plain = 0
    nfat = struct.unpack_from(">I", d, 4)[0]
    for i in range(nfat):
        ct, sub, off, _sz, _al = struct.unpack_from(">IIIII", d, 8 + i * 20)
        if ct != 0x0100000C or sub != 0x80000002:
            continue
        a, p = check_slice(d, off)
        total_auth += a
        total_plain += p
    print("  arm64e __cfstring isa: auth=%d plain=%d" % (total_auth, total_plain))
    if total_auth == 0 and total_plain == 0:
        print("!! 未找到 __cfstring 链（可能需要检查是否 FAT/arm64e）")
        return 2
    if total_plain != 0:
        print("!! 断言失败：仍有 plain isa")
        return 1
    print("  OK: auth>0 plain=0")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: verify_fixups.py <macho>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
