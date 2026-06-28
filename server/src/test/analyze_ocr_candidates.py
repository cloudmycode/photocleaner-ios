#!/usr/bin/env python3
"""
用 App 导出的 smart-search-index-*.json 分析：哪些图「需要 OCR」、哪些可跳过。

与 iOS SearchOCRSettings 标签策略对齐，便于调规则。

用法:
    python3 analyze_ocr_candidates.py ../../script/smart-search-index-*.json
    python3 analyze_ocr_candidates.py index.json --samples 20
    python3 analyze_ocr_candidates.py index.json --csv ocr-plan.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

PERSON_TAGS = {
    "person", "people", "human", "adult", "child", "baby", "man", "woman",
    "face", "portrait", "selfie", "head", "teen",
}
SCENERY_TAGS = {
    "landscape", "scenery", "mountain", "beach", "ocean", "sea", "lake", "river",
    "forest", "tree", "flower", "plant", "sky", "sunset", "sunrise", "cloud", "cloudy",
    "nature", "outdoor", "valley", "snow", "desert", "field", "grass", "meadow",
    "waterfall", "coast", "canyon", "glacier", "horizon", "wilderness", "garden",
    "park", "trail", "rock", "cliff", "island", "wave", "underwater", "coral",
    "blue_sky", "land", "hill", "shrub", "water", "water_body", "fence",
}
NEUTRAL_TAGS = {
    "gray", "white", "black", "brown", "structure", "wood_processed", "monochrome",
    "pattern", "texture", "art", "orange", "blue", "yellow", "red", "green",
}
DOCUMENT_TAGS = {
    "text", "document", "printed_page", "card", "label", "sign", "poster",
    "business_card", "receipt", "envelope", "paper", "license", "menu",
    "book", "publication", "whiteboard", "handwriting", "calendar", "chart",
    "diagram", "illustrations", "screenshot",
}
ID_NUMBER_RE = re.compile(
    r"[1-9]\d{5}(18|19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\d{3}[\dXx]"
)
OCR_NOISE = set("*#@$%^&•¢¥…\"'`~|\\[]{}<>:;=_+·.,-")


def norm_tags(tags: list[str]) -> set[str]:
    return {t.lower().strip() for t in tags if t}


def is_portrait_or_scenery(tags: set[str]) -> bool:
    return bool(tags & PERSON_TAGS) or bool(tags & SCENERY_TAGS)


def is_document_like(tags: set[str]) -> bool:
    return bool(tags & DOCUMENT_TAGS)


def is_screenshot(entry: dict[str, Any]) -> bool:
    return "screenshot" in entry.get("assetTypes", [])


def ocr_len(entry: dict[str, Any]) -> int:
    return len((entry.get("ocrText") or "").strip())


def ocr_quality(entry: dict[str, Any]) -> str:
    text = (entry.get("ocrText") or "").strip()
    if not text:
        return "empty"
    if entry.get("idCardNumber") or entry.get("sensitiveTypes"):
        return "valuable"
    if ID_NUMBER_RE.search(text):
        return "valuable"
    if len(text) > 50 and _meaningful_ratio(text) >= 0.55:
        return "good"
    if _noise_ratio(text) > 0.18:
        return "garbage"
    if len(text) <= 3:
        return "garbage"
    return "weak"


def _meaningful_ratio(text: str) -> float:
    if not text:
        return 0.0
    meaningful = sum(1 for c in text if c.isalnum() or "\u4e00" <= c <= "\u9fff")
    return meaningful / len(text)


def _noise_ratio(text: str) -> float:
    if not text:
        return 0.0
    noise = sum(1 for c in text if c in OCR_NOISE)
    return noise / len(text)


def ocr_decision(entry: dict[str, Any]) -> tuple[str, str]:
    """
    返回 (decision, reason) — 与 iOS SearchOCRSettings.ocrGateDecision 对齐（Rule D）
    decision: skip | ocr
    """
    tags = norm_tags(entry.get("visualTags") or [])
    if is_screenshot(entry):
        return "ocr", "screenshot"
    if is_document_like(tags):
        return "ocr", "document_tag"
    if tags & SCENERY_TAGS:
        return "skip", "skip-scenery"
    if tags & PERSON_TAGS:
        return "skip", "skip-portrait"
    if tags and tags <= NEUTRAL_TAGS:
        return "skip", "skip-neutral"
    return "ocr", "other"


def load_index(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def analyze(payload: dict[str, Any]) -> dict[str, Any]:
    entries = [e for e in payload.get("entries", []) if e.get("mediaType") == "image"]
    rows: list[dict[str, Any]] = []

    decision_counter: Counter[str] = Counter()
    reason_counter: Counter[str] = Counter()
    quality_by_decision: Counter[tuple[str, str]] = Counter()
    mismatch: list[dict[str, Any]] = []

    for entry in entries:
        decision, reason = ocr_decision(entry)
        quality = ocr_quality(entry)
        decision_counter[decision] += 1
        reason_counter[reason] += 1
        quality_by_decision[(decision, quality)] += 1

        actual_ran = entry.get("ocrIndexedAt") is not None
        valuable = quality in {"good", "valuable"}

        if decision == "skip" and valuable:
            mismatch.append({
                "kind": "skip_but_valuable",
                "filename": entry.get("filename"),
                "tags": entry.get("visualTags"),
                "ocrLen": ocr_len(entry),
                "idCardNumber": entry.get("idCardNumber"),
            })
        if decision == "ocr" and quality == "empty" and not is_screenshot(entry):
            mismatch.append({
                "kind": "ocr_but_empty",
                "filename": entry.get("filename"),
                "tags": entry.get("visualTags"),
                "reason": reason,
            })

        rows.append({
            "filename": entry.get("filename") or "",
            "localIdentifier": entry.get("localIdentifier") or "",
            "decision": decision,
            "reason": reason,
            "ocr_quality": quality,
            "ocrLen": ocr_len(entry),
            "idCardNumber": entry.get("idCardNumber") or "",
            "idCardName": entry.get("idCardName") or "",
            "visualTags": "|".join(entry.get("visualTags") or []),
            "assetTypes": "|".join(entry.get("assetTypes") or []),
        })

    return {
        "meta": {
            "algorithmVersion": payload.get("algorithmVersion"),
            "assetCount": payload.get("assetCount", len(entries)),
            "imageEntries": len(entries),
            "idCardCount": payload.get("idCardCount"),
        },
        "decision_counter": dict(decision_counter),
        "reason_counter": dict(reason_counter),
        "quality_by_decision": {f"{d}/{q}": c for (d, q), c in quality_by_decision.items()},
        "mismatch": mismatch,
        "rows": rows,
    }


def print_report(result: dict[str, Any], samples: int) -> None:
    meta = result["meta"]
    total = meta["imageEntries"]
    skip = result["decision_counter"].get("skip", 0)
    ocr = result["decision_counter"].get("ocr", 0)

    print("=== OCR 候选分析（标签策略） ===")
    print(f"文件: algorithmVersion={meta.get('algorithmVersion')} images={total}")
    if meta.get("idCardCount") is not None:
        print(f"导出 idCardCount={meta['idCardCount']}")
    print()
    print(f"建议跳过 OCR: {skip:5d} ({100 * skip / max(total, 1):.1f}%)")
    print(f"建议运行 OCR: {ocr:5d} ({100 * ocr / max(total, 1):.1f}%)")
    print()
    print("跳过/运行 原因分布:")
    for reason, count in sorted(result["reason_counter"].items(), key=lambda x: -x[1]):
        print(f"  {reason:24s} {count:5d}")
    print()
    print("决策 × 当前 OCR 质量:")
    for key, count in sorted(result["quality_by_decision"].items(), key=lambda x: -x[1]):
        print(f"  {key:28s} {count:5d}")

    valuable_skip = [m for m in result["mismatch"] if m["kind"] == "skip_but_valuable"]
    empty_ocr = [m for m in result["mismatch"] if m["kind"] == "ocr_but_empty"]

    print()
    print(f"⚠️  应跳过但实际有价值 OCR: {len(valuable_skip)}（规则漏检，需兜底）")
    for item in valuable_skip[:samples]:
        print(f"    {item.get('filename')} tags={item.get('tags')} idNo={item.get('idCardNumber')}")

    print()
    print(f"ℹ️  建议 OCR 但当前为空: {len(empty_ocr)}（可能尚未扫完或 OCR 失败）")
    for item in empty_ocr[:samples]:
        print(f"    {item.get('filename')} reason={item.get('reason')} tags={item.get('tags')}")


def write_csv(rows: list[dict[str, Any]], path: Path) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description="分析 smart-search-index JSON 的 OCR 候选")
    parser.add_argument("index_json", type=Path, help="导出的 smart-search-index-*.json")
    parser.add_argument("--samples", type=int, default=10, help="打印漏检/空 OCR 样例数")
    parser.add_argument("--csv", type=Path, help="输出每张图的 decision/reason 到 CSV")
    args = parser.parse_args()

    if not args.index_json.exists():
        print(f"文件不存在: {args.index_json}", file=sys.stderr)
        return 1

    payload = load_index(args.index_json)
    result = analyze(payload)
    print_report(result, args.samples)

    if args.csv:
        write_csv(result["rows"], args.csv)
        print(f"\n已写入 CSV: {args.csv}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
