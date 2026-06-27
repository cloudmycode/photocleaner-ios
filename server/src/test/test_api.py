#!/usr/bin/env python3
"""
PhotoCleaner Smart Search API 测试脚本（SearchPlan v2）

用法:
    python test_api.py                  # 测线上
    python test_api.py --local          # 测本地 :8081
    python test_api.py --query "猫猫"   # 单条查询
    python test_api.py --verbose        # 打印完整 JSON
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

import requests

DEFAULT_BASE = "https://cleaner.digsaw.cc"
LOCAL_BASE = "http://127.0.0.1:8081"
DEFAULT_SECRET = "4154b54de82723ca38aec922b3f6a7dfc104fde9"

# 模拟本机 visualTags 词表（含下划线复合 tag）
SAMPLE_TAGS = [
    "person", "people", "human", "beach", "ocean", "sea",
    "car", "vehicle", "automobile", "food", "cat", "kitten",
    "document", "clothing", "red_clothing", "gray_clothing", "white",
]

VALID_SENSITIVE_TYPES = {"id_card", "bank_card", "passport", "document"}

DEPRECATED_TOP_LEVEL = (
    "keywords",
    "visualConcepts",
    "should",
    "ocrKeywords",
    "ocrRegexes",
    "requiresOCR",
    "dateRange",
    "locationBounds",
    "mediaTypes",
    "assetTypes",
    "minSizeMB",
    "maxSizeMB",
    "sensitiveTypes",
    "visualTagsAll",
    "ocrContainsAll",
)

FILTER_KEYS = {
    "dateRange",
    "locationBounds",
    "mediaTypes",
    "assetTypes",
    "minSizeMB",
    "maxSizeMB",
    "minPixelWidth",
    "minPixelHeight",
    "hasLocation",
}


def calculate_sign(query: str, secret: str) -> str:
    return hashlib.md5(f"{query}{secret}".encode()).hexdigest()


def build_payload(
    query: str,
    secret: str,
    *,
    locale: str = "zh-Hans_CN",
    available_tags: Optional[list[str]] = None,
    include_tags: bool = True,
    sign: Optional[str] = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "query": query,
        "locale": locale,
        "appVersion": "1.0.0",
        "buildVersion": "100",
    }
    if include_tags:
        payload["availableTags"] = SAMPLE_TAGS if available_tags is None else available_tags
    if sign is not None:
        payload["sign"] = sign
    else:
        payload["sign"] = calculate_sign(query, secret)
    return payload


@dataclass
class SearchCase:
    query: str
    description: str = ""
    available_tags: Optional[list[str]] = None
    checks: list[Callable[[dict, list[str]], Optional[str]]] = field(default_factory=list)


def as_list(obj: Optional[dict], key: str) -> list:
    if not isinstance(obj, dict):
        return []
    value = obj.get(key)
    return value if isinstance(value, list) else []


def assert_search_plan(
    result: dict,
    available_tags: list[str],
) -> list[str]:
    errors: list[str] = []

    if not isinstance(result, dict):
        return ["response is not a JSON object"]

    if "summary" not in result or not str(result.get("summary", "")).strip():
        errors.append("missing or empty summary")

    if "must" not in result or not isinstance(result["must"], dict):
        errors.append("missing must object")
        return errors

    must = result["must"]
    for key in ("visualTagsAll", "sensitiveTypes", "ocrContainsAll"):
        if key not in must:
            errors.append(f"must.{key} missing")
        elif must[key] is None:
            errors.append(
                f"must.{key} is null (expected []) — 请确认已 deploy 含 MarshalJSON 修复的版本"
            )
        elif not isinstance(must[key], list):
            errors.append(f"must.{key} must be array")

    if "count" not in result:
        errors.append("missing count")
    else:
        count = result["count"]
        if not isinstance(count, int) or count < 1 or count > 1000:
            errors.append(f"count out of range (1-1000): {count}")

    conf = result.get("confidence")
    if conf is not None and (not isinstance(conf, (int, float)) or conf < 0 or conf > 1):
        errors.append(f"confidence out of range (0-1): {conf}")

    for field_name in DEPRECATED_TOP_LEVEL:
        if field_name in result:
            errors.append(f"deprecated top-level field: {field_name}")

    if "filters" in result:
        if not isinstance(result["filters"], dict):
            errors.append("filters must be object")
        else:
            unknown = set(result["filters"]) - FILTER_KEYS
            if unknown:
                errors.append(f"unknown filters keys: {sorted(unknown)}")

    allowed = set(available_tags)
    for tag in as_list(must, "visualTagsAll"):
        if not isinstance(tag, str):
            errors.append(f"visualTagsAll item not string: {tag!r}")
        elif tag not in allowed:
            errors.append(f"visualTagsAll tag not in availableTags: {tag!r}")

    for st in as_list(must, "sensitiveTypes"):
        if st not in VALID_SENSITIVE_TYPES:
            errors.append(f"invalid sensitiveTypes value: {st!r}")

    for ocr in as_list(must, "ocrContainsAll"):
        if not isinstance(ocr, str) or not ocr.strip():
            errors.append(f"ocrContainsAll item must be non-empty string: {ocr!r}")

    return errors


def check_sensitive(expected: str) -> Callable[[dict, list[str]], Optional[str]]:
    def _check(result: dict, _tags: list[str]) -> Optional[str]:
        got = as_list(result.get("must"), "sensitiveTypes")
        if expected not in got:
            return f"expected sensitiveTypes to contain {expected!r}, got {got}"
        return None

    return _check


def check_visual_tags_subset_of(*allowed: str) -> Callable[[dict, list[str]], Optional[str]]:
    allowed_set = set(allowed)

    def _check(result: dict, _tags: list[str]) -> Optional[str]:
        got = as_list(result.get("must"), "visualTagsAll")
        extra = [t for t in got if t not in allowed_set]
        if extra:
            return f"unexpected visualTagsAll {extra}, expected subset of {sorted(allowed_set)}"
        return None

    return _check


def check_has_filter(*keys: str) -> Callable[[dict, list[str]], Optional[str]]:
    def _check(result: dict, _tags: list[str]) -> Optional[str]:
        filters = result.get("filters") or {}
        for key in keys:
            if key not in filters:
                return f"expected filters.{key} to be set"
        return None

    return _check


def print_plan(result: dict, verbose: bool) -> None:
    must = result.get("must", {})
    filters = result.get("filters") or {}
    print(f"  summary: {result.get('summary')}")
    print(f"  must.visualTagsAll: {must.get('visualTagsAll')}")
    print(f"  must.sensitiveTypes: {must.get('sensitiveTypes')}")
    print(f"  must.ocrContainsAll: {must.get('ocrContainsAll')}")
    if filters:
        print(f"  filters: {json.dumps(filters, ensure_ascii=False)}")
    print(f"  count: {result.get('count')}, confidence: {result.get('confidence')}")
    if verbose:
        print(json.dumps(result, ensure_ascii=False, indent=2))


def post_search(
    base_url: str,
    payload: dict[str, Any],
    timeout: int = 90,
    retries: int = 2,
) -> requests.Response:
    url = f"{base_url}/smart-search"
    last_exc: Optional[Exception] = None
    for attempt in range(retries + 1):
        try:
            return requests.post(
                url,
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=timeout,
            )
        except (requests.exceptions.SSLError, requests.exceptions.ConnectionError) as exc:
            last_exc = exc
            if attempt < retries:
                time.sleep(2)
                continue
            raise
    raise last_exc  # pragma: no cover


def test_health(base_url: str, *, require_build: bool) -> bool:
    print("\n" + "=" * 50)
    print("健康检查 GET /health")
    print("=" * 50)
    try:
        resp = requests.get(f"{base_url}/health", timeout=15)
        print(f"状态码: {resp.status_code}")
        print(f"响应: {resp.text}")
        if resp.status_code != 200:
            return False
        data = resp.json()
        if data.get("service") != "smart-search":
            print("⚠️ service 字段不是 smart-search")
        version = data.get("version", "")
        build_version = data.get("buildVersion", "")
        build_time = data.get("buildTime", "")
        print(f"  API version: {version}, buildVersion: {build_version}, buildTime: {build_time}")
        if require_build and (not build_version or build_version == "dev"):
            print("❌ 线上缺少 buildVersion → 仍是旧二进制，请执行: cd server && ./deploy.sh")
            return False
        if version and not version.startswith("2."):
            print(f"⚠️ 服务端 version {version}，预期 v2.x")
        return True
    except Exception as exc:
        print(f"错误: {exc}")
        return False


def test_request_validation(base_url: str, secret: str) -> bool:
    print("\n" + "=" * 50)
    print("请求校验（不调用大模型语义）")
    print("=" * 50)

    cases = [
        ("缺少 availableTags 字段", build_payload("测试", secret, include_tags=False), 400),
        ("错误签名", {**build_payload("测试", secret), "sign": "bad"}, 401),
        ("缺少 sign", {k: v for k, v in build_payload("测试", secret).items() if k != "sign"}, 401),
        ("空 query", {**build_payload("  ", secret), "query": "  "}, 400),
    ]

    ok = True
    for name, payload, expect_status in cases:
        try:
            resp = post_search(base_url, payload, timeout=15)
            passed = resp.status_code == expect_status
            print(f"  {name}: {resp.status_code} ({'OK' if passed else f'期望 {expect_status}'})")
            if not passed:
                print(f"    body: {resp.text[:200]}")
                ok = False
        except Exception as exc:
            print(f"  {name}: 错误 {exc}")
            ok = False
    return ok


def test_empty_available_tags(base_url: str, secret: str) -> bool:
    """availableTags: [] 合法，应 200 且 visualTagsAll 只能为空"""
    print("\n" + "=" * 50)
    print("availableTags 空数组")
    print("=" * 50)
    query = "海边照片"
    payload = build_payload(query, secret, available_tags=[])
    try:
        resp = post_search(base_url, payload, timeout=60)
        print(f"状态码: {resp.status_code}")
        if resp.status_code != 200:
            print(resp.text)
            return False
        result = resp.json()
        tags = as_list(result.get("must"), "visualTagsAll")
        if tags:
            print(f"❌ 空词表时不应有 visualTagsAll: {tags}")
            return False
        print("OK — visualTagsAll 为空")
        return True
    except Exception as exc:
        print(f"错误: {exc}")
        return False


def test_smart_search(
    base_url: str,
    case: SearchCase,
    secret: str,
    verbose: bool,
) -> bool:
    tags = case.available_tags if case.available_tags is not None else SAMPLE_TAGS
    payload = build_payload(case.query, secret, available_tags=tags)

    try:
        resp = post_search(base_url, payload)
        print(f"状态码: {resp.status_code}")

        if resp.status_code != 200:
            print(f"响应: {resp.text}")
            return False

        result = resp.json()
        errors = assert_search_plan(result, tags)
        for check in case.checks:
            msg = check(result, tags)
            if msg:
                errors.append(msg)

        if errors:
            print("❌ SearchPlan 校验失败:")
            for err in errors:
                print(f"    - {err}")
            print_plan(result, verbose=True)
            return False

        print_plan(result, verbose)
        return True
    except Exception as exc:
        print(f"错误: {exc}")
        return False


DEFAULT_SEARCH_CASES = [
    SearchCase(
        "找几张去年去海南玩的照片",
        checks=[check_has_filter("dateRange")],
    ),
    SearchCase(
        "帮我看看上周拍的猫猫",
        checks=[check_visual_tags_subset_of("cat", "kitten")],
    ),
    SearchCase(
        "身份证照片",
        checks=[
            check_sensitive("id_card"),
            lambda r, _t: (
                "visualTagsAll should be empty for 身份证"
                if as_list(r.get("must"), "visualTagsAll")
                else None
            ),
        ],
    ),
    SearchCase(
        "穿红衣服的人",
        checks=[check_visual_tags_subset_of("person", "people", "human", "red_clothing", "clothing")],
    ),
    SearchCase(
        "找大于5M的视频",
        checks=[check_has_filter("mediaTypes", "minSizeMB")],
    ),
]


def main() -> None:
    parser = argparse.ArgumentParser(description="Smart Search API 测试 (SearchPlan v2)")
    parser.add_argument("--local", action="store_true", help="测试本地 http://127.0.0.1:8081")
    parser.add_argument("--base", default=None, help="自定义 base URL")
    parser.add_argument("--secret", default=DEFAULT_SECRET, help="签名密钥")
    parser.add_argument("--query", default=None, help="只跑一条查询")
    parser.add_argument("--verbose", "-v", action="store_true", help="打印完整 JSON")
    parser.add_argument("--skip-validation", action="store_true", help="跳过请求校验用例")
    args = parser.parse_args()

    base_url = (args.base or (LOCAL_BASE if args.local else DEFAULT_BASE)).rstrip("/")
    require_build = not args.local and args.base is None

    print("=" * 50)
    print("PhotoCleaner Smart Search API 测试 (SearchPlan v2)")
    print(f"服务器: {base_url}")
    print("=" * 50)

    if not test_health(base_url, require_build=require_build):
        print("\n❌ 健康检查失败（或线上未部署含 buildVersion 的新二进制）")
        sys.exit(1)

    validation_ok = True
    if not args.skip_validation:
        validation_ok = test_request_validation(base_url, args.secret)
        empty_tags_ok = test_empty_available_tags(base_url, args.secret)
        validation_ok = validation_ok and empty_tags_ok

    if args.query:
        cases = [SearchCase(args.query)]
    else:
        cases = DEFAULT_SEARCH_CASES

    print("\n" + "=" * 50)
    print("智能搜索 POST /smart-search")
    print("=" * 50)

    passed = 0
    for case in cases:
        title = case.description or case.query
        print(f"\n查询: {title}")
        print("-" * 40)
        if test_smart_search(base_url, case, args.secret, args.verbose):
            passed += 1
        time.sleep(1)

    total = len(cases)
    print(f"\n搜索通过 {passed}/{total}")
    if not validation_ok:
        print("⚠️ 部分请求校验未通过（可能尚未部署 v2）")
    if passed < total or (not args.skip_validation and not validation_ok):
        sys.exit(1)


if __name__ == "__main__":
    main()
