#!/usr/bin/env python3
"""Extract one entry from a remote ZIP without downloading the whole archive.

The Infinity-X ROM is 2.65 GB and only a boot image is wanted from it. HTTP
range requests let us read the end-of-central-directory record, then the
central directory, then just that entry's compressed bytes.

Usage:
    fetch-rom-image.py <url> --list
    fetch-rom-image.py <url> --extract boot.img -o boot.img
"""
import argparse
import struct
import sys
import urllib.request
import zlib

UA = {"User-Agent": "curl/8"}


def fetch(url, start=None, end=None):
    req = urllib.request.Request(url, headers=dict(UA))
    if start is not None:
        req.add_header("Range", f"bytes={start}-{end if end is not None else ''}")
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def total_size(url):
    req = urllib.request.Request(url, method="HEAD", headers=dict(UA))
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers["Content-Length"])


def parse_eocd(tail, base):
    i = tail.rfind(b"PK\x05\x06")
    while i >= 0:
        if i + 22 <= len(tail):
            (disk, cd_disk, n_disk, n_total, cd_size, cd_off, clen) = struct.unpack_from(
                "<HHHHIIH", tail, i + 4
            )
            if cd_off != 0xFFFFFFFF and cd_size != 0xFFFFFFFF:
                return cd_off, cd_size, n_total
        i = tail.rfind(b"PK\x05\x06", 0, i)
    raise SystemExit("no usable EOCD (zip64 archive?)")


def parse_cd(cd):
    entries = {}
    i = 0
    while i + 46 <= len(cd) and cd[i:i + 4] == b"PK\x01\x02":
        # 4 sig | 6 x H (version made, version needed, flags, method, time,
        # date) | crc, csize, usize | name, extra, comment, disk, iattr |
        # eattr | local header offset
        (_vmade, _vneed, _flags, method, _time, _date, crc, csize, usize,
         nlen, elen, clen, _disk, _iattr, _eattr, loff) = struct.unpack_from(
            "<4x6H3I5H2I", cd, i)
        name = cd[i + 46:i + 46 + nlen].decode("utf-8", "replace")
        if name.endswith("/"):
            entries[name] = None
        else:
            entries[name] = dict(method=method, csize=csize, usize=usize,
                                 crc=crc, loff=loff, nlen=nlen, elen=elen)
        i += 46 + nlen + elen + clen
    return entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--extract")
    ap.add_argument("-o", "--out")
    a = ap.parse_args()

    size = total_size(a.url)
    print(f"archive: {size} bytes")
    tail_start = max(0, size - (1 << 20))
    tail = fetch(a.url, tail_start, size - 1)
    # EOCD offsets are relative to the start of the archive, and the tail we
    # fetched may not start at 0, so translations are needed below.
    cd_off, cd_size, n_total = parse_eocd(tail, tail_start)
    print(f"central directory: {cd_size} bytes at {cd_off}, {n_total} entries")
    cd = fetch(a.url, cd_off, cd_off + cd_size - 1)
    entries = parse_cd(cd)

    if a.list:
        for name, e in entries.items():
            if e and (name.endswith(".img") or "boot" in name.lower()):
                print(f"  {e['usize']:>12} -> {e['csize']:>12}  m{e['method']}  {name}")
        return

    if not a.extract:
        sys.exit("--extract or --list required")
    if a.extract not in entries or entries[a.extract] is None:
        sys.exit(f"no entry {a.extract!r}")
    e = entries[a.extract]
    print(f"entry: {a.extract} method={e['method']} csize={e['csize']} usize={e['usize']}")

    hdr = fetch(a.url, e["loff"], e["loff"] + 30 + e["nlen"] + e["elen"] - 1)
    if hdr[:4] != b"PK\x03\x04":
        sys.exit("bad local header")
    data_off = e["loff"] + 30 + e["nlen"] + e["elen"]
    blob = fetch(a.url, data_off, data_off + e["csize"] - 1)
    if len(blob) != e["csize"]:
        sys.exit(f"short read: {len(blob)} != {e['csize']}")
    if e["method"] == 0:
        out = blob
    elif e["method"] == 8:
        out = zlib.decompress(blob, -15)
    else:
        sys.exit(f"unsupported compression method {e['method']}")
    if len(out) != e["usize"]:
        sys.exit(f"size mismatch after decompress: {len(out)} != {e['usize']}")
    if zlib.crc32(out) & 0xFFFFFFFF != e["crc"]:
        sys.exit("crc mismatch")
    dest = a.out or a.extract.replace("/", "_")
    open(dest, "wb").write(out)
    print(f"wrote {dest}: {len(out)} bytes, crc32 ok")


if __name__ == "__main__":
    main()
