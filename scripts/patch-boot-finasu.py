#!/usr/bin/env python3
"""Install the FinaSU LKM payload into a boot image's ramdisk.

This device already boots root as a loadable module: the ramdisk carries an
`init` shim, the real Android init as `init.real`, and `kernelsu.ko` which the
shim insmods before exec'ing `init.real`.  Rebuilding the kernel was tried and
rejected by the ROM, so that ramdisk is the unit this tool rewrites:

    init                  <- the FinaSU ksuinit (loads the modules)
    kernelsu.ko           <- custom FinaSU module for android12-5.10
    susfs_guard_lkm.ko    <- SUSFS 2.3.0 kernel side, loaded by ksuinit
    ksu_config            <- "bundled=1"
    init.real             <- kept byte-for-byte

Nothing else in the ramdisk is touched, and the result is checked by
decompressing and re-parsing what was written before the boot image is built.

Usage:
    patch-boot-finasu.py <boot.img> <payload-dir> <out.img>
"""
import argparse
import hashlib
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile

PAGE = 4096
PAYLOAD_FILES = ("kernelsu.ko", "susfs_guard_lkm.ko", "ksuinit")


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def align(n, a=PAGE):
    return (n + a - 1) // a * a


def header_from(template_hdr, name, payload, mode):
    """Reuse a real entry's header fields, patching only name/size."""
    h = bytearray(template_hdr)
    nm = name.encode() + b"\0"
    # newc header: ino at 6, mode at 14.  Only the mode is ours to set; the
    # inode number stays whatever the template entry had.
    struct.pack_into(">8s", h, 14, b"%08x" % mode)
    struct.pack_into(">8s", h, 54, b"%08x" % len(payload))
    struct.pack_into(">8s", h, 94, b"%08x" % len(nm))
    return bytes(h)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", help="stock/known-good boot image")
    ap.add_argument("payload", help="directory with kernelsu.ko, susfs_guard_lkm.ko, ksuinit")
    ap.add_argument("out")
    ap.add_argument("--repack", default=None, help="path to repack-boot-image.py")
    ap.add_argument("--no-susfs", action="store_true",
                    help="leave the SUSFS guard out (bisect image)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    rt = load_module(os.path.join(here, "ramdisk-tool.py"), "ramdisk_tool")
    repack = args.repack or os.path.join(here, "repack-boot-image.py")
    if not os.path.isfile(repack):
        sys.exit(f"repack helper not found: {repack}")

    payload = {}
    for name in PAYLOAD_FILES:
        p = os.path.join(args.payload, name)
        if not os.path.isfile(p):
            sys.exit(f"payload file missing: {p}")
        payload[name] = open(p, "rb").read()
        print(f"payload {name:<20} {len(payload[name]):>9} B  "
              f"md5={hashlib.md5(payload[name]).hexdigest()}")

    data = open(args.image, "rb").read()
    assert data[:8] == b"ANDROID!", "not an Android boot image"
    hdr_version, = struct.unpack_from("<I", data, 40)
    kernel_size, ramdisk_size = struct.unpack_from("<II", data, 8)
    ramdisk_off = PAGE + align(kernel_size)
    ramdisk = data[ramdisk_off:ramdisk_off + ramdisk_size]
    print(f"template: header v{hdr_version} kernel={kernel_size} B "
          f"ramdisk={ramdisk_size} B at {ramdisk_off}")

    raw = rt.decompress_ramdisk(ramdisk)
    entries = rt.cpio_parse(raw)
    names = [n for n, _m, _h, _p in entries]
    print(f"ramdisk: {len(raw)} B decompressed, {len(entries)} cpio entries")
    print(f"  init present={('init' in names)}  init.real present={'init.real' in names}  "
          f"kernelsu.ko present={'kernelsu.ko' in names}")

    by_name = {n: e for n, e in zip(names, entries)}
    # A stock ramdisk has a single init; the LKM one has init + init.real.
    if "init.real" not in by_name:
        print("  * no init.real: renaming the current init to init.real")
        init_entry = by_name["init"]
        entries = [("init.real", init_entry[1], init_entry[2], init_entry[3])
                   if n == "init" else (n, m, h, p) for n, m, h, p in entries]
        by_name["init.real"] = init_entry
        template_hdr = init_entry[2]
        template_mode = init_entry[1]
        add_init = True
    else:
        init_entry = by_name["init"]
        template_hdr = init_entry[2]
        template_mode = init_entry[1]
        add_init = False

    if "kernelsu.ko" in by_name:
        template_hdr_mod = by_name["kernelsu.ko"][2]
        template_mode_mod = by_name["kernelsu.ko"][1]
    else:
        template_hdr_mod = by_name["init.real"][2]
        template_mode_mod = 0o100644

    out_entries = []
    for n, m, h, p in entries:
        if n == "init":
            print(f"  * init <- FinaSU ksuinit ({len(payload['ksuinit'])} B, was {len(p)} B)")
            out_entries.append((n, m, h, payload["ksuinit"]))
        elif n == "kernelsu.ko":
            print(f"  * kernelsu.ko <- custom FinaSU module ({len(payload['kernelsu.ko'])} B, was {len(p)} B)")
            out_entries.append((n, m, h, payload["kernelsu.ko"]))
        elif n == "susfs_guard_lkm.ko":
            print(f"  * susfs_guard_lkm.ko <- SUSFS 2.3.0 guard ({len(payload['susfs_guard_lkm.ko'])} B)")
            out_entries.append((n, m, h, payload["susfs_guard_lkm.ko"]))
        elif n == "ksu_config":
            out_entries.append((n, m, h, b"bundled=1"))
        else:
            out_entries.append((n, m, h, p))

    def add(name, payload_bytes, mode):
        hdr = header_from(template_hdr_mod, name, payload_bytes, mode)
        out_entries.insert(len(out_entries) - 1, (name, mode, hdr, payload_bytes))
        print(f"  * {name} added ({len(payload_bytes)} B)")

    now = {n for n, *_ in out_entries}
    if add_init:
        add("init", payload["ksuinit"], template_mode)
    if "susfs_guard_lkm.ko" not in now and not args.no_susfs:
        add("susfs_guard_lkm.ko", payload["susfs_guard_lkm.ko"], 0o100644)
    if "kernelsu.ko" not in now:
        add("kernelsu.ko", payload["kernelsu.ko"], 0o100644)
    if "ksu_config" not in now:
        add("ksu_config", b"bundled=1", 0o100644)

    new_raw = rt.cpio_build(out_entries)
    back = rt.cpio_parse(new_raw)
    if [n for n, *_ in back] != [n for n, *_ in out_entries]:
        sys.exit("cpio rebuild is lossy -- refusing to write")
    if {n: p for n, _m, _h, p in back} != {n: p for n, _m, _h, p in out_entries}:
        sys.exit("cpio rebuild changed payloads -- refusing to write")

    comp = rt.lz4_legacy_compress(new_raw)
    if rt.lz4_legacy_decompress(comp) != new_raw:
        sys.exit("lz4 roundtrip is not exact -- refusing to write")
    print(f"ramdisk rebuilt: {len(new_raw)} B cpio -> {len(comp)} B lz4-legacy")

    with tempfile.TemporaryDirectory() as td:
        kz = os.path.join(td, "kernel.gz")
        # The repack helper expects a gzip kernel; reuse the template's own bytes.
        kb = data[PAGE:PAGE + kernel_size]
        if kb[:2] != b"\x1f\x8b":
            sys.exit(f"template kernel is not gzip (magic {kb[:2].hex()}); "
                     "extend this tool before using a non-gzip boot image")
        open(kz, "wb").write(kb)
        rd = os.path.join(td, "ramdisk.lz4")
        open(rd, "wb").write(comp)
        print("\n--- repack-boot-image.py ---")
        subprocess.run([sys.executable, repack, args.image, kz, args.out,
                        "--ramdisk", rd], check=True)

    # Verify the written boot image, not the intermediate ramdisk.
    out = open(args.out, "rb").read()
    ks, rs = struct.unpack_from("<II", out, 8)
    roff = PAGE + align(ks)
    check_entries = rt.cpio_parse(rt.decompress_ramdisk(out[roff:roff + rs]))
    check = {n: p for n, _m, _h, p in check_entries}
    ok = True
    verified = ("ksuinit", "kernelsu.ko") if args.no_susfs else (
        "ksuinit", "kernelsu.ko", "susfs_guard_lkm.ko")
    if args.no_susfs:
        print(f"  verify susfs_guard_lkm.ko   SKIPPED (--no-susfs)")
    for name in verified:
        want = payload[name]
        got = check.get("init" if name == "ksuinit" else name)
        good = got == want
        ok &= good
        print(f"  verify {name:<20} {'OK' if good else 'MISMATCH'}")
    real_kept = check.get("init.real") == by_name["init.real"][3]
    print(f"  verify init.real kept       {'OK' if real_kept else 'MISMATCH'}")
    print(f"  verify ksu_config={check.get('ksu_config')!r}")
    ok &= real_kept
    print(f"  output: {args.out} {len(out)} B sha256={hashlib.sha256(out).hexdigest()}")
    if not ok:
        sys.exit("verification failed")


if __name__ == "__main__":
    main()
