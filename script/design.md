# 智能搜索 — 设计说明（归档）

> **主文档（最新技术方案与开发步骤）**：[smart-search-guide.md](./smart-search-guide.md)

---

## 检索模型（定稿）

```
SearchPlan → 倒排多组照片 ID → 组间交集 → 对交集 ID 验 filters（正排元数据）→ 按时间取前 N
```

- **视觉 tag**：`tagPostings`，组内同义词并集，组间交集；`availableTags`（全量≤1000）发给大模型。  
- **敏感类型**：`sensitivePostings`，固定枚举，不进 `availableTags`，不进 metadata filters。  
- **filters**：仅时间、地点、大小、类型等；查正排，不建倒排。  
- **无 should 打分**；tag 与 filters 顺序可调，结果为 `TagCandidates ∩ F`。

## 索引模型（定稿）

- 正排 `index.json` 增量维护；Vision/OCR 只跑新图与变更图。  
- 倒排内存增量 patch；冷启动可从正排一次性重建；删图在 `rebuildMetadata` 主动清理。

## 语义理解

- 每次搜索调用大模型；无本地 QueryRouter。

详细 API、例子、模块划分、开发步骤见主文档。
