#!/usr/bin/env python3
"""Dump Objective-C classes/methods/ivars from a (chained-fixup) Mach-O slice.

Usage: objc_dump.py <macho> [arch] [--filter SUBSTR] [--methods] [--ivars]
"""
import sys

MASK64 = (1 << 64) - 1


def u64(b, o):
    return int.from_bytes(b[o:o + 8], "little")


def u32(b, o):
    return int.from_bytes(b[o:o + 4], "little")


def u16(b, o):
    return int.from_bytes(b[o:o + 2], "little")


def si32(b, o):
    return int.from_bytes(b[o:o + 4], "little", signed=True)


class MachO:
    def __init__(self, path, arch="arm64e"):
        data = open(path, "rb").read()
        magic = int.from_bytes(data[:4], "big")
        slices = []
        if magic in (0xCAFEBABE, 0xCAFEBABF):
            n = int.from_bytes(data[4:8], "big")
            for i in range(n):
                base = 8 + i * 20
                cs = int.from_bytes(data[base + 4:base + 8], "big")
                off = int.from_bytes(data[base + 8:base + 12], "big")
                size = int.from_bytes(data[base + 12:base + 16], "big")
                nm = "arm64e" if (cs & 0xFFFFFF) == 2 else "arm64"
                slices.append((nm, off, size))
        else:
            slices.append(("arm64e", 0, len(data)))
        nm, off, size = [s for s in slices if s[0] == arch][0]
        self.img = data[off:off + size]
        img = self.img
        self.sections = []
        self.segs = []
        self.fixups = None
        p = 32
        ncmds = u32(img, 16)
        for _ in range(ncmds):
            cmd = u32(img, p)
            cmdsize = u32(img, p + 4)
            if cmd == 0x19:  # LC_SEGMENT_64
                seg = img[p + 8:p + 24].rstrip(b"\0").decode()
                vmaddr = u64(img, p + 24)
                vmsize = u64(img, p + 32)
                fo = u64(img, p + 40)
                fs = u64(img, p + 48)
                self.segs.append((seg, vmaddr, vmsize, fo, fs))
                ns = u32(img, p + 64)
                sp = p + 72
                for _ in range(ns):
                    s = img[sp:sp + 16].rstrip(b"\0").decode()
                    sg = img[sp + 16:sp + 32].rstrip(b"\0").decode()
                    a = u64(img, sp + 32)
                    sz = u64(img, sp + 40)
                    f = u32(img, sp + 48)
                    self.sections.append((sg, s, a, sz, f))
                    sp += 80
            elif cmd == 0x80000034:  # LC_DYLD_CHAINED_FIXUPS
                doff = u32(img, p + 8)
                self.fixups = {
                    "doff": doff,
                    "starts_off": u32(img, doff + 4),
                    "imports_off": u32(img, doff + 8),
                    "symbols_off": u32(img, doff + 12),
                    "imports_count": u32(img, doff + 16),
                    "imports_format": u32(img, doff + 20),
                }
            p += cmdsize
        self.chains = []
        if self.fixups:
            self._parse_starts()

    # ---------- sections ----------
    def sec(self, name):
        for sg, s, a, sz, f in self.sections:
            if s == name:
                return (sg, s, a, sz, f)
        return None

    def in_sec(self, vm, name):
        s = self.sec(name)
        return s is not None and s[2] <= vm < s[2] + s[3]

    def sec_of(self, vm):
        for sg, s, a, sz, f in self.sections:
            if a <= vm < a + sz:
                return (sg, s, a, sz, f)
        for sg, a, vsz, fo, fs in self.segs:
            if a <= vm < a + vsz:
                return (sg, "SEG", a, vsz, fo)
        return None

    def fileoff(self, vm):
        s = self.sec_of(vm)
        if not s:
            return None
        sg, name, a, sz, f = s
        delta = vm - a
        if delta >= sz:
            return None
        return f + delta

    # ---------- chained fixups ----------
    def _parse_starts(self):
        img = self.img
        h = self.fixups
        si = h["doff"] + h["starts_off"]
        segcount = u32(img, si)
        for i in range(segcount):
            sioff = u32(img, si + 4 + 4 * i)
            if sioff == 0:
                continue
            q = si + sioff
            # dyld_chained_starts_in_segment: size, page_size, pointer_format,
            # segment_offset, max_valid_pointer, page_count, page_start[]
            page = u16(img, q + 4)
            ptrfmt = u16(img, q + 6)
            segoff = u64(img, q + 8)
            pagecount = u16(img, q + 20)
            starts = [u16(img, q + 22 + 2 * j) for j in range(pagecount)]
            self.chains.append({"seg_index": i, "segoff": segoff,
                                "ptrfmt": ptrfmt, "page": page, "starts": starts})

    def decode_entry(self, val, ptrfmt):
        if ptrfmt in (1, 7, 9, 10, 11, 12):
            auth = (val >> 63) & 1
            bind = (val >> 62) & 1
            nxt = (val >> 51) & 0x7FF
            if bind:
                return ("bind", val & 0xFFFF, nxt * 8)
            if auth:
                return ("rebase_auth", val & 0xFFFFFFFF, nxt * 8)
            target = val & ((1 << 43) - 1)
            high8 = (val >> 43) & 0xFF
            return ("rebase", target | (high8 << 56), nxt * 8)
        if ptrfmt in (2, 6):
            bind = (val >> 63) & 1
            nxt = (val >> 51) & 0xFFF
            if bind:
                return ("bind", val & 0xFFFFFF, nxt * 8)
            target = val & ((1 << 36) - 1)
            if ptrfmt == 6:
                return ("rebase_off", target, nxt * 8)
            high8 = (val >> 36) & 0xFF
            return ("rebase", target | (high8 << 56), nxt * 8)
        raise Exception("unknown pointer format %d" % ptrfmt)

    def ptr(self, vm):
        """Resolve the pointer stored at vm -> target vmaddr, or ('BIND', n)."""
        img = self.img
        fo = self.fileoff(vm)
        if fo is None:
            return None
        if not self.fixups:
            return u64(img, fo)
        val = u64(img, fo)
        for ch in self.chains:
            page_size = ch["page"]
            for pi, st in enumerate(ch["starts"]):
                if st == 0xFFFF:
                    continue
                page_base = ch["segoff"] + pi * page_size
                if not (page_base <= vm < page_base + page_size):
                    continue
                cur = page_base + st
                while True:
                    f = self.fileoff(cur)
                    if f is None:
                        return None
                    v = u64(img, f)
                    kind, tgt, delta = self.decode_entry(v, ch["ptrfmt"])
                    if cur == vm:
                        if kind in ("rebase", "rebase_auth"):
                            return tgt
                        if kind == "rebase_off":
                            return tgt
                        return ("BIND", tgt)
                    if delta == 0:
                        return None
                    cur += delta
        return None

    def cstr(self, vm):
        f = self.fileoff(vm)
        if f is None:
            return None
        e = self.img.find(b"\0", f)
        if e < 0:
            return None
        return self.img[f:e].decode("utf-8", "replace")

    # ---------- objc ----------
    def classes(self):
        out = []
        s = self.sec("__objc_classlist")
        if not s:
            return out
        sg, name, a, sz, f = s
        for i in range(sz // 8):
            v = self.ptr(a + 8 * i)
            if not isinstance(v, int):
                continue
            out.append(v)
        return out

    def class_info(self, cls_vm):
        fo = self.fileoff(cls_vm)
        if fo is None:
            return None
        img = self.img
        sup = self.ptr(cls_vm + 8)
        data = self.ptr(cls_vm + 32)
        if not isinstance(data, int):
            data = u64(img, fo + 32)
        ro = data & (MASK64 ^ 0x7)
        # on-disk data pointer may be a chained fixup or a signed pointer; try both
        rfo = self.fileoff(ro)
        if rfo is None:
            return None
        # class_ro_t
        flags = u32(img, rfo)
        instanceStart = u32(img, rfo + 4)
        instanceSize = u32(img, rfo + 8)
        namep = self.ptr(ro + 24)
        methods = self.ptr(ro + 32)
        protocols = self.ptr(ro + 40)
        ivars = self.ptr(ro + 48)
        props = self.ptr(ro + 64)
        name = self.cstr(namep) if isinstance(namep, int) else None
        if name is None:
            # fall back: objc_class may have ro pointer with auth bits
            alt = data
            rfo2 = self.fileoff(alt)
            if rfo2 is not None and alt != ro:
                pass
        supname = None
        if isinstance(sup, int):
            si = self.class_info_shallow(sup)
            if si:
                supname = si
        return {
            "cls": cls_vm, "name": name, "super": supname,
            "flags": flags, "instanceStart": instanceStart, "instanceSize": instanceSize,
            "ro": ro, "methods": methods if isinstance(methods, int) else None,
            "ivars": ivars if isinstance(ivars, int) else None,
            "props": props if isinstance(props, int) else None,
        }

    def class_info_shallow(self, cls_vm):
        fo = self.fileoff(cls_vm)
        if fo is None:
            return None
        data = self.ptr(cls_vm + 32)
        if not isinstance(data, int):
            data = u64(self.img, fo + 32)
        ro = data & (MASK64 ^ 0x7)
        if self.fileoff(ro) is None:
            return None
        namep = self.ptr(ro + 16)
        if isinstance(namep, int):
            return self.cstr(namep)
        return None

    def method_list(self, list_vm):
        out = []
        fo = self.fileoff(list_vm)
        if fo is None:
            return out
        img = self.img
        entsize_flags = u32(img, fo)
        count = u32(img, fo + 4)
        entsize = entsize_flags & 0xFFFC
        relative = bool(entsize_flags & 0x80000000) or bool(entsize_flags & 0x1)
        if relative:
            for i in range(count):
                e = list_vm + 8 + i * entsize
                efo = self.fileoff(e)
                if efo is None:
                    continue
                no = si32(img, efo)
                to = si32(img, efo + 4)
                io = si32(img, efo + 8)
                namev = self.name_at(e, no, list_vm)
                typesv = self._pick(e + 4, to, list_vm, "__objc_methtype")
                impv = self._pick(e + 8, io, list_vm, "__text")
                out.append({
                    "name": self.cstr(namev) if namev else None,
                    "types": self.cstr(typesv) if typesv else None,
                    "imp": impv,
                })
        else:
            for i in range(count):
                e = list_vm + 8 + i * entsize
                namev = self.ptr(e)
                typesv = self.ptr(e + 8)
                impv = self.ptr(e + 16)
                out.append({
                    "name": self.cstr(namev) if isinstance(namev, int) else None,
                    "types": self.cstr(typesv) if isinstance(typesv, int) else None,
                    "imp": impv if isinstance(impv, int) else None,
                })
        return out

    def _pick(self, entry_vm, off, list_vm, want_sec):
        """Relative method offsets: test entry-relative then list-relative."""
        cand = entry_vm + off
        if self.in_sec(cand, want_sec):
            return cand
        cand2 = list_vm + off
        if self.in_sec(cand2, want_sec):
            return cand2
        return None

    def name_at(self, entry_vm, off, list_vm):
        """Selector name: may be a direct string or a selref indirection."""
        for cand in (entry_vm + off, list_vm + off):
            if self.in_sec(cand, "__objc_methname"):
                return cand
            if self.in_sec(cand, "__objc_selrefs"):
                v = self.ptr(cand)
                if isinstance(v, int) and self.in_sec(v, "__objc_methname"):
                    return v
        return None

    def ivar_list(self, list_vm):
        out = []
        fo = self.fileoff(list_vm)
        if fo is None:
            return out
        img = self.img
        entsize = u32(img, fo)
        count = u32(img, fo + 4)
        for i in range(count):
            e = list_vm + 8 + i * entsize
            efo = self.fileoff(e)
            if efo is None:
                continue
            offp = self.ptr(e)
            namep = self.ptr(e + 8)
            typep = self.ptr(e + 16)
            name = self.cstr(namep) if isinstance(namep, int) else None
            typ = self.cstr(typep) if isinstance(typep, int) else None
            out.append({"name": name, "type": typ,
                        "offset": offp if isinstance(offp, int) else None})
        return out

    def prop_list(self, list_vm):
        out = []
        fo = self.fileoff(list_vm)
        if fo is None:
            return out
        img = self.img
        entsize = u32(img, fo)
        count = u32(img, fo + 4)
        for i in range(count):
            e = list_vm + 8 + i * entsize
            namep = self.ptr(e)
            attrs = self.ptr(e + 8)
            name = self.cstr(namep) if isinstance(namep, int) else None
            at = self.cstr(attrs) if isinstance(attrs, int) else None
            out.append({"name": name, "attrs": at})
        return out


def main():
    argv = sys.argv[1:]
    path = argv[0]
    arch = "arm64e"
    filt = None
    show_methods = False
    show_ivars = False
    show_props = False
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--filter":
            filt = argv[i + 1]
            i += 2
        elif a == "--methods":
            show_methods = True
            i += 1
        elif a == "--ivars":
            show_ivars = True
            i += 1
        elif a.startswith("--arch="):
            arch = a.split("=", 1)[1]
            i += 1
        else:
            i += 1
    m = MachO(path, arch)
    print("segments:", [(s[0], hex(s[1]), hex(s[2])) for s in m.segs])
    print("chains:", [(hex(c["segoff"]), c["ptrfmt"]) for c in m.chains])
    infos = []
    for c in m.classes():
        info = m.class_info(c)
        if info and info["name"]:
            infos.append(info)
    infos.sort(key=lambda x: x["name"])
    print("classes:", len(infos))
    for info in infos:
        nm = info["name"]
        if filt and filt.lower() not in nm.lower():
            continue
        print("\nclass %s : %s  size=%d" % (nm, info["super"], info["instanceSize"]))
        if show_ivars and info["ivars"]:
            for iv in m.ivar_list(info["ivars"]):
                print("   ivar %-28s %-10s off=%s" % (iv["name"], iv["type"], iv["offset"]))
        if show_props and info["props"]:
            for p in m.prop_list(info["props"]):
                print("   prop %-28s %s" % (p["name"], p["attrs"]))
        if show_methods and info["methods"]:
            for me in m.method_list(info["methods"]):
                imp = me["imp"]
                print("   - %-42s %-18s imp=%s" % (
                    me["name"], me["types"] or "",
                    hex(imp) if isinstance(imp, int) else str(imp)))


if __name__ == "__main__":
    main()
