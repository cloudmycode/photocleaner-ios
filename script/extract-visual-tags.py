#!/usr/bin/env python3
import json

with open("smart-search-index-2026-06-25_09-34-53.json", "r") as f:
    data = json.load(f)

tags = set()
for entry in data.get("entries", []):
    for t in entry.get("visualTags", []):
        tags.add(t)

words = sorted(tags)
out = "visual-tags.txt"
with open(out, "w") as f:
    f.write("\n".join(words))
print(f"共 {len(words)} 个不重复标签，已输出到 {out}")
