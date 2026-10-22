#!/usr/bin/env python3
"""Extract one partition image from a remote Android OTA payload.bin.

The ROM is a 2.65 GB A/B OTA: the zip holds no `boot.img`, only `payload.bin`.
Downloading the whole payload to get a 64 MB boot image is wasteful, so this
parses the update manifest and range-fetches only the blobs the target
partition's install operations reference.

This device's payload does not use AOSP's exact field numbers (operations sit in
field 8, not 7, and `new_partition_info` in field 7), so the operation list is
detected by shape instead of hard-coded, and the extracted image is checked
against the partition hash from the manifest.

Usage:
    fetch-payload-image.py <payload-url> --list
    fetch-payload-image.py <payload-url> --extract boot -o boot.img
"""
import argparse
import bz2
import hashlib
import lzma
import struct
import sys
import urllib.request

UA = {"User-Agent": "curl/8"}
OP_REPLACE, OP_REPLACE_BZ, OP_MOVE, OP_BSDIFF, OP_SOURCE_COPY = 0, 1, 2, 3, 4
OP_SOURCE_BSDIFF, OP_ZERO, OP_DISCARD, OP_REPLACE_XZ = 5, 6, 7, 8


def read_varint(buf, pos):
    shift = 0
    value = 0
    while True:
        b = buf[pos]
        pos += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, pos
        shift += 7


def parse_fields(buf):
    """Return {field_number: [raw values]} for one protobuf message."""
    out = {}
    pos = 0
    n = len(buf)
    while pos < n:
        key, pos = read_varint(buf, pos)
        field, wire = key >> 3, key & 7
        if wire == 0:
            val, pos = read_varint(buf, pos)
            out.setdefault(field, []).append(("varint", val))
        elif wire == 2:
            ln, pos = read_varint(buf, pos)
            out.setdefault(field, []).append(("bytes", buf[pos:pos + ln]))
            pos += ln
        elif wire == 5:
            out.setdefault(field, []).append(("fixed32", buf[pos:pos + 4]))
            pos += 4
        elif wire == 1:
            out.setdefault(field, []).append(("fixed64", buf[pos:pos + 8]))
            pos += 8
        else:
            raise SystemExit(f"unsupported wire type {wire} at {pos}")
    return out


def ints(msg, field, default=0):
    vals = msg.get(field)
    return vals[0][1] if vals else default


def blobs(msg, field):
    return [v for t, v in msg.get(field, []) if t == "bytes"]


BASE = 0


def fetch(url, start, end):
    req = urllib.request.Request(url, headers=dict(UA))
    req.add_header("Range", f"bytes={BASE + start}-{BASE + end}")
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def looks_like_op(msg):
    if 1 not in msg or not msg[1] or msg[1][0][0] != "varint":
        return False
    typ = msg[1][0][1]
    if typ > 12:
        return False
    # dst extents are a repeated nested message; every real op has at least one.
    return 6 in msg and bool(blobs(msg, 6))


def ops_of(part):
    """Pick the partition field that holds install operations."""
    best = None
    for field, values in part.items():
        msgs = []
        for t, v in values:
            if t != "bytes":
                continue
            try:
                msgs.append(parse_fields(v))
            except (SystemExit, IndexError):
                msgs = []
                break
        if not msgs or not all(looks_like_op(m) for m in msgs):
            continue
        if best is None or len(msgs) > len(best[1]):
            best = (field, msgs)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--extract")
    ap.add_argument("-o", "--out")
    ap.add_argument("--base", type=int, default=0,
                    help="add this to every range offset (payload inside a zip)")
    a = ap.parse_args()
    global BASE
    BASE = a.base

    header = fetch(a.url, 0, 23)
    assert header[:4] == b"CrAU", "not an Android OTA payload"
    version, = struct.unpack(">Q", header[4:12])
    manifest_size, = struct.unpack(">Q", header[12:20])
    sig_size, = struct.unpack(">I", header[20:24])
    print(f"payload v{version} manifest={manifest_size} B metadata_sig={sig_size} B")
    manifest = fetch(a.url, 24, 24 + manifest_size - 1)
    data_start = 24 + manifest_size + sig_size

    m = parse_fields(manifest)
    parts = [parse_fields(b) for b in blobs(m, 13)] or [
        parse_fields(b) for b in blobs(m, 12)
    ]
    if not parts:
        sys.exit("no partitions in manifest")

    table = {}
    for p in parts:
        name = blobs(p, 1)[0].decode() if blobs(p, 1) else "?"
        found = ops_of(p)
        if not found:
            table[name] = (p, [], 0)
            continue
        _field, ops = found
        size = sum(
            ints(e, 2) * 4096
            for op in ops
            for e in (parse_fields(b) for b in blobs(op, 6))
        )
        table[name] = (p, ops, size)

    if a.list:
        for name, (_p, ops, size) in sorted(table.items()):
            kinds = sorted({ints(o, 1) for o in ops})
            print(f"  {name:<28} {size/1e6:>8.1f} MB  ops={len(ops)} types={kinds}")
        return

    name = a.extract
    if not name or name not in table:
        sys.exit(f"no partition {name!r} (use --list)")
    p, ops, size = table[name]
    print(f"{name}: {len(ops)} ops, {size/1e6:.1f} MB")

    out = bytearray(size)
    fetched = 0
    for i, op in enumerate(ops):
        typ = ints(op, 1)
        dsts = [parse_fields(b) for b in blobs(op, 6)]
        if typ in (OP_REPLACE, OP_REPLACE_BZ, OP_REPLACE_XZ):
            off, ln = ints(op, 2), ints(op, 3)
            raw = fetch(a.url, data_start + off, data_start + off + ln - 1)
            fetched += ln
            if typ == OP_REPLACE_BZ:
                raw = bz2.decompress(raw)
            elif typ == OP_REPLACE_XZ:
                raw = lzma.decompress(raw)
        elif typ == OP_ZERO:
            raw = bytes(sum(ints(e, 2) * 4096 for e in dsts))
        else:
            sys.exit(f"op {i} uses unsupported type {typ} for {name}")
        pos = 0
        for e in dsts:
            start = ints(e, 1) * 4096
            length = ints(e, 2) * 4096
            out[start:start + length] = raw[pos:pos + length]
            pos += length
        if pos != len(raw):
            sys.exit(f"op {i}: consumed {pos} of {len(raw)} bytes")
        print(f"  op {i+1}/{len(ops)} type={typ} fetched={fetched/1e6:.1f} MB", flush=True)

    digest = hashlib.sha256(out).hexdigest()
    info_blobs = blobs(p, 7)
    if info_blobs and info_blobs[0][:1] == b"\x08":
        expected = blobs(parse_fields(info_blobs[0]), 2)
        if expected:
            print(f"sha256 {digest}\nmanifest {expected[0].hex()}")
            if expected[0].hex() != digest:
                sys.exit("partition hash does not match the manifest")

    dest = a.out or f"{name}.img"
    open(dest, "wb").write(out)
    print(f"wrote {dest}: {len(out)} bytes")


if __name__ == "__main__":
    main()
