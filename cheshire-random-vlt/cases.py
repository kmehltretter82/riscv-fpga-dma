#!/usr/bin/env python3
"""Generate the exact descriptors used by dma_random_test.c."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


BOUNDARY_LENGTHS = [
    1, 2, 7, 8, 9, 15, 16, 17,
    31, 32, 33, 63, 64, 65, 127, 128,
    129, 255, 256, 257, 511, 512, 513, 1023,
    1024, 1025, 2047, 2048, 2049, 4095, 4096, 4097,
]
DURATION_LENGTHS = [
    1, 2, 7, 8, 9, 15, 16, 17,
    31, 32, 33, 63, 64, 65, 127, 128,
    129, 255, 256, 257, 3, 5, 6, 10,
    14, 18, 30, 34, 62, 66, 126, 130,
]
CONF_NAMES = ["none", "aw", "rw", "all"]


def u32(value: int) -> int:
    return value & 0xFFFFFFFF


def rng_next(state: int) -> int:
    x = state or 0x6D2B79F5
    x = u32(x ^ u32(x << 13))
    x = u32(x ^ (x >> 17))
    x = u32(x ^ u32(x << 5))
    return x


def fnv_word(value_hash: int, value: int) -> int:
    for shift in range(0, 32, 8):
        value_hash ^= (value >> shift) & 0xFF
        value_hash = u32(value_hash * 16777619)
    return value_hash


def generate(seed: int, count: int, profile: str = "full"):
    state = u32(seed)
    value_hash = 2166136261
    cases = []
    for index in range(count):
        draws = []
        for _ in range(9):
            state = rng_next(state)
            draws.append(state)
        (r_kind, r_len_mode, r_len, r_src_lane, r_dst_lane,
         r_page, r_rows, r_src_gap, r_dst_gap) = draws
        src_lane = r_src_lane & 7
        dst_lane = r_dst_lane & 7
        if dst_lane == src_lane:
            dst_lane ^= 1
        if r_len_mode & 3:
            lengths = DURATION_LENGTHS if profile == "duration" else BOUNDARY_LENGTHS
            length = lengths[r_len & 31]
        else:
            length = (r_len & (255 if profile == "duration" else 4095)) + 1
        kind = 2 if (r_kind & 3) == 0 else 1
        conf = index & 3
        src_stride = dst_stride = length
        rows = 1
        if kind == 2:
            if profile == "full" and length > 1025:
                length = 514 + ((r_len >> 8) & 511)
            rows = 1 + (r_rows & (3 if profile == "duration" else 7))
            gap_mask = 31 if profile == "duration" else 127
            src_stride = length + (r_src_gap & gap_mask)
            dst_stride = length + (r_dst_gap & gap_mask)
            if (r_page & 3) == 0:
                src = 0x40001FF8 + src_lane
                dst = 0x40009FF8 + dst_lane
            else:
                src = 0x40001040 + src_lane
                dst = 0x40009040 + dst_lane
        else:
            src_slot = (r_page >> 4) & 3
            dst_slot = (r_page >> 6) & 1
            if (r_page & 3) == 0:
                src = 0x40001FF8 + src_slot * 0x1000 + src_lane
                dst = 0x40009FF8 + dst_slot * 0x1000 + dst_lane
            else:
                src = 0x40001200 + src_slot * 0x1000 + src_lane
                dst = 0x40009200 + dst_slot * 0x1000 + dst_lane
        row = {
            "index": index,
            "kind": kind,
            "conf": conf,
            "conf_name": CONF_NAMES[conf],
            "src": src,
            "dst": dst,
            "len": length,
            "src_stride": src_stride,
            "dst_stride": dst_stride,
            "rows": rows,
            "rng_state": state,
        }
        for field in ("index", "kind", "conf", "src", "dst", "len",
                      "src_stride", "dst_stride", "rows"):
            value_hash = fnv_word(value_hash, row[field])
        row["descriptor_hash"] = value_hash
        cases.append(row)
    return cases, value_hash, state


def span(row, source: bool) -> int:
    if row["kind"] == 1:
        return row["len"]
    stride = row["src_stride"] if source else row["dst_stride"]
    if source:
        return (row["rows"] - 1) * stride + row["len"]
    return row["rows"] * stride


def crosses_page(address: int, size: int) -> bool:
    return (address >> 12) != ((address + size - 1) >> 12)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", required=True, type=lambda x: int(x, 0))
    parser.add_argument("--count", required=True, type=int)
    parser.add_argument("--profile", choices=("full", "duration"), default="full")
    parser.add_argument("--tsv", type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--hash-only", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.count <= 1024:
        parser.error("count must be in 1..1024")
    seed = u32(args.seed)
    cases, value_hash, state = generate(seed, args.count, args.profile)
    for row in cases:
        src_span = span(row, True)
        dst_span = span(row, False)
        assert 0x40000020 <= row["src"]
        assert row["src"] + src_span + 32 < 0x40008000
        assert 0x40008020 <= row["dst"]
        assert row["dst"] + dst_span + 32 < 0x4000F000
    summary = {
        "seed": seed,
        "seed_hex": f"0x{seed:08x}",
        "count": args.count,
        "profile": args.profile,
        "descriptor_hash": value_hash,
        "descriptor_hash_hex": f"0x{value_hash:08x}",
        "final_rng_state": state,
        "one_d": sum(row["kind"] == 1 for row in cases),
        "two_d": sum(row["kind"] == 2 for row in cases),
        "decouple": {name: sum(row["conf_name"] == name for row in cases)
                     for name in CONF_NAMES},
        "source_page_crossings": sum(crosses_page(row["src"], span(row, True))
                                     for row in cases),
        "destination_page_crossings": sum(crosses_page(row["dst"], span(row, False))
                                          for row in cases),
        "minimum_length": min(row["len"] for row in cases),
        "maximum_length": max(row["len"] for row in cases),
    }
    if args.tsv:
        args.tsv.parent.mkdir(parents=True, exist_ok=True)
        with args.tsv.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(cases[0]))
            writer.writeheader()
            writer.writerows(cases)
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    if args.hash_only:
        print(f"{value_hash:08x}")
    else:
        print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
