#!/usr/bin/env python3
"""
用 App 导出的 smart-search-index-*.json 在电脑上离线测试本地检索（SearchEngine 逻辑）。

导出方式：App 内触发 exportSmartSearchDebugIndex()，分享 JSON 到 Mac。

用法:
    python test_search_local.py index.json
    python test_search_local.py index.json --plan plan.json
    python test_search_local.py index.json --query 身份证   # 调线上拿 SearchPlan 再本地匹配
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import requests

DEFAULT_SECRET = "4154b54de82723ca38aec922b3f6a7dfc104fde9"
API_URL = "https://cleaner.digsaw.cc/smart-search"

VISUAL_SYNONYMS: dict[str, set[str]] = {
    "person": {"person", "people", "human"},
    "people": {"person", "people", "human"},
    "human": {"person", "people", "human"},
    "beach": {"beach", "sea", "ocean", "coast", "shore"},
    "sea": {"beach", "sea", "ocean", "coast", "shore"},
    "ocean": {"beach", "sea", "ocean", "coast", "shore"},
    "cat": {"cat", "kitten", "feline"},
    "kitten": {"cat", "kitten", "feline"},
    "dog": {"dog", "canine"},
    "car": {"car", "vehicle", "automobile"},
    "vehicle": {"car", "vehicle", "automobile"},
    "automobile": {"car", "vehicle", "automobile"},
}

ID_NUMBER_RE = re.compile(
    r"[1-9]\d{5}(18|19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\d{3}[\dXx]"
)
MRZ_ID_RE = re.compile(r"[IAC]<[A-Z]{3}[A-Z0-9<]{20,}")
PERSON_TAGS = {"person", "people", "human", "adult"}
DOCUMENT_TAGS = {"document", "printed_page", "text", "card"}

ID_CARD_TITLE_KEYWORDS = [
    "身份证", "居民身份证", "公民身份",
    "identity card", "identification card", "national id", "national identity",
    "identity document", "id card", "photo id", "photo identification",
    "driver's license", "drivers license", "driver license", "driving licence",
    "driving license", "learner permit",
    "身分証", "身分証明書", "運転免許", "運転経歴",
    "주민등록증", "신분증", "운전면허",
    "documento de identidad", "documento nacional", "cédula", "cedula", "dni",
    "carteira de identidade", "carteira nacional", "registro geral",
    "carte d'identité", "carte identité", "carte nationale d'identité", "permis de conduire",
    "personalausweis", "ausweis", "führerschein", "fuehrerschein",
    "carta d'identità", "carta identita", "patente di guida",
    "identiteitskaart", "identiteitsbewijs", "rijbewijs",
    "aadhaar", "aadhar", "uidai",
    "ktp", "kartu tanda penduduk", "mykad", "identity card no",
    "удостоверение личности",
]

ID_CARD_FIELD_LABELS = [
    "姓名", "性别", "民族", "出生", "住址", "公民", "公民身份号码", "签发",
    "surname", "given name", "given names", "date of birth", "place of birth",
    "nationality", "sex", "document no", "document number", "id no", "id number",
    "identity no", "identity number", "expires", "expiry", "valid until", "issuing",
    "nom", "prénom", "prenom", "né le", "ne le", "nationalité", "nationalite",
    "nombre", "apellido", "apellidos", "fecha de nacimiento", "nacionalidad",
    "geburtsdatum", "geburtsort", "staatsangehörigkeit", "staatsangehoerigkeit",
    "氏名", "生年月日", "国籍", "住所",
    "성명", "생년월일", "국적",
    "data de nascimento", "naturalidade",
]


def detect_sensitive_types(ocr_text: str | None, visual_tags: list[str] | None) -> list[str]:
    """与 iOS SensitiveTypeDetector 对齐的离线规则"""
    text = (ocr_text or "").strip().lower()
    types: list[str] = []

    if _is_id_card(text, visual_tags):
        types.append("id_card")
    if any(k in text for k in ("银行卡", "bank card", "credit card", "debit card")):
        types.append("bank_card")
    if "护照" in text or "passport" in text:
        types.append("passport")
    if any(k in text for k in ("合同", "发票", "invoice", "receipt")):
        types.append("document")
    return sorted(set(types))


def _is_id_card(text: str, visual_tags: list[str] | None) -> bool:
    if not text:
        return False
    if any(k in text for k in ID_CARD_TITLE_KEYWORDS):
        return True

    upper = text.upper()
    if "P<" not in upper and MRZ_ID_RE.search(upper):
        return True

    label_hits = sum(1 for label in ID_CARD_FIELD_LABELS if label in text)
    if ID_NUMBER_RE.search(text) and (label_hits >= 1 or "姓名" in text):
        return True
    if label_hits >= 3:
        return True

    tags = {t.lower() for t in (visual_tags or [])}
    if label_hits >= 2 and tags & PERSON_TAGS:
        return True
    if label_hits >= 1 and tags & PERSON_TAGS and tags & DOCUMENT_TAGS:
        return True
    return False


def enrich_sensitive_types(entries: list[dict]) -> None:
    """从 OCR + visualTags 重算 sensitiveTypes（旧导出或未跑 L3 时有用）"""
    for row in entries:
        row["sensitiveTypes"] = detect_sensitive_types(
            row.get("ocrText"),
            row.get("visualTags"),
        )


def searchable_ocr(row: dict) -> str:
    parts = [
        row.get("ocrText") or "",
        row.get("idCardName") or "",
        row.get("idCardNumber") or "",
    ]
    return "\n".join(p.strip() for p in parts if p and str(p).strip())


def expand_tag(tag: str) -> set[str]:
    key = tag.strip().lower()
    return VISUAL_SYNONYMS.get(key, {key})


def build_postings(entries: list[dict]) -> tuple[dict[str, set[str]], dict[str, set[str]], dict[str, dict]]:
    tag_postings: dict[str, set[str]] = {}
    sensitive_postings: dict[str, set[str]] = {}
    by_id: dict[str, dict] = {}

    for row in entries:
        pid = row["localIdentifier"]
        by_id[pid] = row
        for tag in row.get("visualTags") or []:
            tag_postings.setdefault(tag, set()).add(pid)
        for st in row.get("sensitiveTypes") or []:
            sensitive_postings.setdefault(st, set()).add(pid)

    return tag_postings, sensitive_postings, by_id


def intersect_groups(
    visual_tags: list[str],
    sensitive_types: list[str],
    indexed_ids: set[str],
    tag_postings: dict[str, set[str]],
    sensitive_postings: dict[str, set[str]],
) -> set[str]:
    result: Optional[set[str]] = None

    for tag in visual_tags:
        group: set[str] = set()
        for syn in expand_tag(tag):
            group |= tag_postings.get(syn, set())
        result = group if result is None else result & group

    for st in sensitive_types:
        group = sensitive_postings.get(st, set())
        result = group if result is None else result & group

    base = result if result is not None else indexed_ids
    return base & indexed_ids


def parse_day(s: str) -> Optional[datetime]:
    try:
        return datetime.strptime(s, "%Y-%m-%d")
    except ValueError:
        return None


def passes_filters(row: dict, filters: Optional[dict]) -> bool:
    if not filters:
        return True

    created = row.get("creationDate")
    if created:
        day = parse_day(created[:10])
        dr = filters.get("dateRange") or {}
        if dr.get("start") and day:
            start = parse_day(dr["start"])
            if start and day.date() < start.date():
                return False
        if dr.get("end") and day:
            end = parse_day(dr["end"])
            if end and day.date() > end.date():
                return False

    bounds = filters.get("locationBounds") or []
    if bounds:
        lat, lon = row.get("latitude"), row.get("longitude")
        if lat is None or lon is None:
            if filters.get("hasLocation") is True:
                return False
        else:
            ok = False
            for b in bounds:
                if (
                    b.get("minLatitude") is not None
                    and b.get("maxLatitude") is not None
                    and b.get("minLongitude") is not None
                    and b.get("maxLongitude") is not None
                    and lat >= b["minLatitude"]
                    and lat <= b["maxLatitude"]
                    and lon >= b["minLongitude"]
                    and lon <= b["maxLongitude"]
                ):
                    ok = True
                    break
            if not ok:
                return False
    elif filters.get("hasLocation") is True:
        if row.get("latitude") is None or row.get("longitude") is None:
            return False

    media_types = filters.get("mediaTypes") or []
    if media_types and row.get("mediaType") not in media_types:
        return False

    asset_types = filters.get("assetTypes") or []
    if asset_types:
        entry_types = set(row.get("assetTypes") or [])
        if not any(t in entry_types for t in asset_types):
            return False

    storage = row.get("storageBytes") or 0
    if filters.get("minSizeMB") is not None:
        if storage < int(filters["minSizeMB"] * 1024 * 1024):
            return False
    if filters.get("maxSizeMB") is not None:
        if storage > int(filters["maxSizeMB"] * 1024 * 1024):
            return False

    if filters.get("minPixelWidth") and (row.get("pixelWidth") or 0) < filters["minPixelWidth"]:
        return False
    if filters.get("minPixelHeight") and (row.get("pixelHeight") or 0) < filters["minPixelHeight"]:
        return False
    return True


def search_local(export: dict, plan: dict) -> list[dict]:
    entries = export.get("entries") or []
    tag_postings, sensitive_postings, by_id = build_postings(entries)
    indexed_ids = set(by_id)

    must = plan.get("must") or {}
    ids = intersect_groups(
        must.get("visualTagsAll") or [],
        must.get("sensitiveTypes") or [],
        indexed_ids,
        tag_postings,
        sensitive_postings,
    )

    for text in must.get("ocrContainsAll") or []:
        needle = text.lower()
        if not needle:
            continue
        ids = {
            pid
            for pid in ids
            if needle in searchable_ocr(by_id[pid]).lower()
        }

    limit = max(1, min(plan.get("count") or 1000, 1000))
    filters = plan.get("filters") or {}

    matched = [
        by_id[pid]
        for pid in ids
        if passes_filters(by_id[pid], filters if filters else None)
    ]
    matched.sort(key=lambda r: r.get("creationDate") or "", reverse=True)
    return matched[:limit]


def fetch_plan(query: str, available_tags: list[str], secret: str) -> dict:
    sign = hashlib.md5(f"{query}{secret}".encode()).hexdigest()
    resp = requests.post(
        API_URL,
        json={
            "query": query,
            "locale": "zh-Hans_CN",
            "appVersion": "1.0.0",
            "buildVersion": "100",
            "availableTags": available_tags[:1000],
            "sign": sign,
        },
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()


def print_stats(export: dict) -> None:
    entries = export.get("entries") or []
    tag_postings, sensitive_postings, _ = build_postings(entries)
    print(f"导出: {len(entries)} 条, 已索引 visual: {export.get('indexedAssetCount')}")
    print(f"OCR 空: {export.get('missingOCRCount')}, id_card: {export.get('idCardCount', 'N/A')}")
    print(f"倒排 tag 数: {len(tag_postings)}, sensitive keys: {sorted(sensitive_postings)}")
    for st, ids in sorted(sensitive_postings.items()):
        print(f"  sensitivePostings[{st!r}]: {len(ids)} 张")


def main() -> None:
    parser = argparse.ArgumentParser(description="离线测试 SearchEngine")
    parser.add_argument("index_json", help="App 导出的 smart-search-index-*.json")
    parser.add_argument("--plan", help="SearchPlan JSON 文件")
    parser.add_argument("--query", help="调线上 API 获取 SearchPlan")
    parser.add_argument("--secret", default=DEFAULT_SECRET)
    parser.add_argument(
        "--recompute-sensitive",
        action="store_true",
        help="从 OCR/visualTags 重算 sensitiveTypes（与 App L3 规则一致）",
    )
    args = parser.parse_args()

    export = json.loads(Path(args.index_json).read_text(encoding="utf-8"))
    if args.recompute_sensitive:
        enrich_sensitive_types(export.get("entries") or [])
        export["idCardCount"] = sum(
            1 for e in export["entries"] if "id_card" in (e.get("sensitiveTypes") or [])
        )
    print_stats(export)
    print()

    if args.plan:
        plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
    elif args.query:
        tags = sorted(
            {t for e in export.get("entries", []) for t in (e.get("visualTags") or [])},
            key=lambda t: sum(1 for e in export["entries"] if t in (e.get("visualTags") or [])),
            reverse=True,
        )[:1000]
        print(f"请求 SearchPlan: {args.query!r}")
        plan = fetch_plan(args.query, tags, args.secret)
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        print()
    else:
        plan = {
            "must": {"visualTagsAll": [], "sensitiveTypes": ["id_card"], "ocrContainsAll": []},
            "count": 1000,
        }
        print("未指定 --plan / --query，默认测试 sensitiveTypes: [id_card]")
        print()

    matched = search_local(export, plan)
    print(f"匹配 {len(matched)} 张")
    for row in matched[:10]:
        name = row.get("filename") or row.get("localIdentifier")
        ocr = (row.get("ocrText") or "")[:40].replace("\n", " ")
        print(f"  - {name}  sensitive={row.get('sensitiveTypes')}  ocr={ocr!r}")
    if len(matched) > 10:
        print(f"  … 还有 {len(matched) - 10} 张")


if __name__ == "__main__":
    main()
