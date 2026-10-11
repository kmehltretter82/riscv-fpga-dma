#!/usr/bin/env python3
"""Fail-closed source contract for the deliberate DMA-API misuse cell."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FILES = {
    "client": ROOT / "client/cheshire-idma-api-negative.c",
    "init": ROOT / "init/init-tiny.c",
    "dts": ROOT / "dts/cheshire-linux-dma-api-negative.dts",
    "rtl": ROOT / "rtl/tb_cheshire_linux_dma_mapping.sv",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"negative DMA-API contract failed: {message}")


texts = {name: path.read_text() for name, path in FILES.items()}
client = texts["client"]
init = texts["init"]
dts = texts["dts"]
rtl = texts["rtl"]

for case in (
    "unchecked_map_case",
    "wrong_size_case",
    "wrong_direction_case",
    "wrong_sg_count_case",
    "double_unmap_case",
):
    require(len(re.findall(rf"\b{case}\s*\(", client)) == 2,
            f"{case} must have one definition and one call")

require(client.count("dma_mapping_error(dev, address)") == 3,
        "exactly three single mappings must check map errors")
require("address == DMA_MAPPING_ERROR" in client,
        "unchecked direct mapping must retain a fail-safe address comparison")
require("dma_unmap_single(dev, address, MAP_SIZE / 2, DMA_TO_DEVICE);" in client,
        "wrong-size unmap missing")
require("dma_sync_single_for_device(dev, address, MAP_SIZE, DMA_FROM_DEVICE);" in client,
        "wrong-direction sync missing")
require("dma_sync_sg_for_device(dev, list, 1, DMA_TO_DEVICE);" in client,
        "wrong SG-count sync missing")
require(client.count(
    "dma_unmap_single(dev, address, MAP_SIZE, DMA_TO_DEVICE);") == 4,
    "expected unchecked, direction-case and duplicate-unmap cleanup calls")
for forbidden in (
    "dmaengine_prep_", "dmaengine_submit", "dma_async_issue_pending",
    "writel(", "writeq(", "memcpy_toio(",
):
    require(forbidden not in client,
            f"negative client must not issue hardware work: {forbidden}")

for token in (
    "dma_debug_entries=1024",
    "dma_debug_driver=cheshire-idma-irq-investigation",
    "dma_api_negative=1",
):
    require(dts.count(token) == 1, f"DT must contain exactly one {token}")
require("swiotlb=4096,force" not in dts,
        "negative cell must remain direct-only")

for signature in (
    "device driver failed to check map error",
    "device driver frees DMA memory with different size",
    "device driver syncs DMA memory with different direction",
    "device driver syncs DMA sg list with different entry count",
    "device driver tries to free DMA memory it has not allocated",
):
    require(init.count(signature) == 1,
            f"PID 1 must gate exactly one source occurrence of {signature}")
require("errors != 5 || free_before != free_after" in init,
        "PID 1 must gate exact error and cleanup accounting")
require("FPGA-LINUX-DMA-API-NEGATIVE-PASS" in init,
        "dedicated userspace pass token missing")

for token in (
    '$test$plusargs("NEGATIVE")',
    "FPGA-LINUX-DMA-MAPPING-NEGATIVE-PASS",
    "negative DMA-API test touched iDMA",
    "iDMA jobs=0/0 busy=0 ar=0 aw=0 r=0 w=0 b=0",
):
    require(token in rtl, f"RTL negative gate missing: {token}")

record = {
    "schema_version": 1,
    "checks": 28,
    "files": {
        name: {
            "path": str(path),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
        for name, path in FILES.items()
    },
    "result": "pass",
}
print(json.dumps(record, indent=2, sort_keys=True))
