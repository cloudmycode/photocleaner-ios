# PhotoCleaner 智能搜索 — 完整实现方案

> **主文档**：[smart-search-guide.md](./smart-search-guide.md)（倒排交集检索、filters 验正排、无 should、开发步骤）  
> 本文为历史草稿，实现以主文档为准。

> 版本：v2 实现规格  
> 关联文档：[design.md](./design.md)（设计原则与问题分析）  
> 目标：**自然语言理解意图，本地可验证检索**；仅搜索文本上云，图片与索引不出设备。

---

## 目录

1. [概述](#1-概述)
2. [系统架构](#2-系统架构)
3. [数据模型](#3-数据模型)
4. [离线索引实现](#4-离线索引实现)
5. [在线搜索实现](#5-在线搜索实现)
6. [服务端实现](#6-服务端实现)
7. [客户端模块划分](#7-客户端模块划分)
8. [视觉同义词表](#8-视觉同义词表)
9. [敏感类型检测规则](#9-敏感类型检测规则)
10. [匹配与打分算法](#10-匹配与打分算法)
11. [查询路由器](#11-查询路由器)
12. [兼容与迁移](#12-兼容与迁移)
13. [分阶段交付计划](#13-分阶段交付计划)
14. [测试与验收](#14-测试与验收)
15. [附录](#15-附录)

---

## 1. 概述

### 1.1 产品能力

用户用自然语言或语音描述想找的照片（如「去年海南的海边照」「身份证」「大于 5M 的视频」），App：

1. 理解查询意图（本地规则 + 可选云端大模型）；
2. 在本机已建立的图片索引中检索；
3. 返回匹配结果，按相关度排序。

### 1.2 与现版本对比

| 维度 | 当前实现（v1） | 本方案（v2） |
|------|----------------|--------------|
| 索引 | L0 元数据 + L1 视觉 + 全库 fast OCR | L0～L3 分级索引 |
| 敏感证件 | API 有 `sensitiveTypes`，客户端未实现 | 索引期检测 + 搜索期硬匹配 |
| 查询结构 | `keywords` + `visualConcepts` 双轨 | 统一 `SearchPlan` |
| OCR | 900px + `.fast`，大量空文本 | 文档类 `.accurate` + 大图 |
| 词表 | 易与单机导出 `visual-tags.txt` 混淆 | 全局同义词 + 本机动态 tags |
| 结果上限 | 默认 1000 | 默认 1000（可配置） |

### 1.3 核心设计结论

- **`visualTags`**：离散标签，来自 Apple Vision，每台手机自动索引，**不需要用户维护词表**。
- **`ocrText`**：每张图的全文，**不做 OCR 词表**；搜索时对 `ocrText` 做子串/正则匹配。
- **`visual-tags.txt`**：仅从某次索引导出 JSON 排重得到的调试统计，**不是**产品配置。
- **准确度**：证件类靠 L3 敏感检测；视觉类靠同义词 + 置信度；元数据类靠硬过滤。

---

## 2. 系统架构

### 2.1 端到端流程

```
┌─────────────────────────────────────────────────────────────────┐
│                        用户设备（iOS）                            │
│                                                                   │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │ 后台索引任务  │───▶│ PhotoSearch  │───▶│ index.json       │  │
│  │ L0→L1→L2→L3  │    │ IndexStore   │    │ (本地持久化)      │  │
│  └──────────────┘    └──────────────┘    └────────┬─────────┘  │
│                                                     │             │
│  ┌──────────────┐    ┌──────────────┐              │             │
│  │ 用户输入/语音 │───▶│ QueryRouter  │              │             │
│  └──────────────┘    └──────┬───────┘              │             │
│                             │                       │             │
│                    本地模板 │ 云端 LLM             │             │
│                             ▼                       ▼             │
│                      ┌──────────────┐    ┌──────────────────┐  │
│                      │ SearchPlan   │───▶│ SearchEngine     │  │
│                      └──────────────┘    │ (4 个检索器)      │  │
│                                          └────────┬─────────┘  │
│                                                   ▼             │
│                                          ┌──────────────────┐  │
│                                          │ 结果网格 + 原因   │  │
│                                          └──────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ POST /smart-search
                              │ body: query, locale, sign, [availableTags]
                              ▼
                    ┌──────────────────┐
                    │ Go 服务端         │
                    │ DeepSeek 解析意图 │
                    └──────────────────┘
```

### 2.2 四个检索器

| 检索器 | 负责字段 | 典型查询 |
|--------|----------|----------|
| **E1 元数据** | 时间、GPS 范围、mediaType、assetTypes、文件大小、像素 | 去年、海南、截图、大于 5M |
| **E2 视觉标签** | `visualTags` + `confidence` | 海边、红衣服、汽车 |
| **E3 OCR** | `ocrText` | 合同、店名、尾号 1234 |
| **E4 敏感类型** | `sensitiveTypes` | 身份证、银行卡、护照 |

---

## 3. 数据模型

### 3.1 本地索引条目（`PhotoSearchIndexEntry` v4）

**文件**：`PhotoCleaner/SimilarAnalysisCache.swift`  
**存储**：`Application Support/PhotoSearchIndex/index.json`  
**算法版本**：`algorithmVersion = 4`（升级时触发增量重扫策略）

```swift
struct PhotoSearchIndexEntry: Codable {
    // --- L0 元数据（已有）---
    let id: String                          // localIdentifier
    let signature: String                   // 变更检测
    let mediaType: String                   // image | video
    let assetTypes: [String]                // screenshot | live | screen_recording
    let creationDate: Date?
    let latitude: Double?
    let longitude: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let storageBytes: Int64

    // --- L1 视觉（扩展）---
    var visualTags: [String]?
    var visualConfidence: [String: Float]?   // 新增：tag → confidence
    var visualIndexedAt: Date?

    // --- L2 文档 / OCR（扩展）---
    var ocrText: String?
    var ocrQuality: String?                 // fast | accurate
    var ocrIndexedAt: Date?

    // --- L3 敏感（新增）---
    var sensitiveTypes: [String]?           // id_card | bank_card | passport | document
    var sensitiveSignals: [String]?         // 调试用命中原因
    var sensitiveIndexedAt: Date?
}
```

**导出调试 JSON**（设置页「导出智能找图索引」）字段与现格式兼容，增加 `sensitiveTypes`、`visualConfidence`、`ocrQuality`。

### 3.2 本机动态词表

```swift
// PhotoSearchIndexStore
func allVisualTags() -> [String]           // 去重、排序
func topVisualTags(limit: Int = 1000) -> [String]  // 默认全量去重，最多 limit
```

用途：搜索请求时作为 `availableTags` 发给服务端（P1 阶段）。

### 3.3 SearchPlan（查询计划）

服务端响应 / 本地路由器输出统一结构：

```json
{
  "summary": "身份证照片",
  "confidence": 0.95,
  "count": 1000,
  "filters": {
    "dateRange": { "start": "2025-01-01", "end": "2025-12-31" },
    "locationBounds": [{
      "name": "海南",
      "minLatitude": 18.0, "maxLatitude": 20.0,
      "minLongitude": 108.0, "maxLongitude": 111.0
    }],
    "mediaTypes": ["image"],
    "assetTypes": [],
    "minSizeMB": null,
    "maxSizeMB": null,
    "minPixelWidth": null,
    "minPixelHeight": null,
    "hasLocation": null
  },
  "mustMatch": {
    "sensitiveTypes": ["id_card"],
    "visualTagsAll": [],
    "ocrContainsAll": []
  },
  "shouldMatch": {
    "visualTags": ["person", "beach"],
    "ocrContains": [],
    "ocrRegexes": []
  }
}
```

| 区块 | 语义 |
|------|------|
| `filters` | 硬过滤，不满足则排除 |
| `mustMatch.*` | 语义硬条件，列表内 AND |
| `shouldMatch.*` | 软条件，用于加分；`visualTags` / `ocrContains` 为 OR |
| `count` | 返回上限，默认 1000，最大 1000 |

**废弃字段**（v2 不再生成，客户端 v1 兼容只读）：`keywords`、`visualConcepts`、`requiresOCR`。

字段映射（兼容期）：

| v1 字段 | v2 映射 |
|---------|---------|
| `keywords` | `shouldMatch.visualTags` |
| `visualConcepts[].matchAny` | `mustMatch.visualTagsAll` 中每组概念一组 AND 链；或拆成多 tag AND |
| `ocrKeywords` | `shouldMatch.ocrContains` |
| `ocrRegexes` | `shouldMatch.ocrRegexes` |
| `sensitiveTypes` | `mustMatch.sensitiveTypes` |

### 3.4 API 请求（`POST /smart-search`）

```json
{
  "query": "去年在海南拍的海边人物照",
  "locale": "zh-Hans_CN",
  "appVersion": "1.0.0",
  "buildVersion": "26",
  "sign": "md5(query + serverSecret)",
  "availableTags": ["beach", "person", "ocean", "document"]
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `query` | 是 | 用户原文（trim 后参与签名） |
| `locale` | 是 | 设备语言 |
| `appVersion` / `buildVersion` | 是 | 版本兼容 |
| `sign` | 是 | `MD5(query + serverSecret)` 小写 hex |
| `availableTags` | 是 | 本机 visualTags 全量去重，按频次排序，最多 1000 |

### 3.5 API 响应

响应体 = **SearchPlan**（见 3.3），HTTP 200。  
错误码见 [15.2](#152-api-错误码)。

---

## 4. 离线索引实现

### 4.1 索引任务入口

**现有入口**（保持）：

- `PhotoLibraryService.rebuildSearchIndexMetadata(for:)`
- `PhotoLibraryService.indexSearchImagesIfNeeded(for:)`

**改造**：将 `searchImageAnalysis` 拆为分级流水线。

### 4.2 L0 — 元数据

**时机**：相册授权后 / 增量变化时  
**实现**：`PhotoSearchIndexStore.rebuildMetadata(for:)`（已有）  
**产出**：`creationDate`、`latitude`、`longitude`、`mediaType`、`assetTypes`、`pixelWidth/Height`、`storageBytes`、`signature`

### 4.3 L1 — 视觉标签

**时机**：`imageAssetsNeedingVisualIndex` 返回的待处理列表  
**实现**：`PhotoLibraryService.searchVisualTags(for:)`（已有，需扩展）

```swift
// 改造 classificationTags：持久化 confidence
struct VisualTag { let name: String; let confidence: Float }

nonisolated private static func searchVisualTags(for image: CGImage) -> (tags: [String], confidence: [String: Float]) {
    var confidence: [String: Float] = [:]
    // VNClassifyImageRequest：confidence >= 0.25，top 8
    // VNDetectHumanRectanglesRequest → person/people/human
    // dominantColorTag → red/white/... + red_clothing 等
    return (tags.sorted(), confidence)
}
```

**图片尺寸**：保持 `targetSize: 900×900`（L1 够用）。

### 4.4 L2 — 文档 OCR（条件触发）

**触发条件**（满足任一）：

```swift
let documentTriggers: Set<String> = [
    "document", "printed_page", "credit_card", "receipt",
    "handwriting", "chart", "diagram", "whiteboard", "sign"
]
let needsAccurateOCR = tags.contains(where: documentTriggers.contains)
```

**实现要点**：

```swift
nonisolated private static func searchRecognizedTextAccurate(for cgImage: CGImage) -> String? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate          // 关键改动
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    // ...
}
```

**图片尺寸**：`targetSize: 2048×2048`（或长边 2048），`isNetworkAccessAllowed: true`（iCloud 照片）。

**产出**：覆盖 `ocrText`，`ocrQuality = "accurate"`。

未触发 L2 的图片：保留 L1 阶段的 fast OCR 结果（可为空），`ocrQuality = "fast"`。

### 4.5 L3 — 敏感类型检测

**时机**：L2 完成后，或 L1 含 `passport` / `credit_card`  
**实现**：新文件 `PhotoCleaner/SensitiveTypeDetector.swift`

```swift
enum SensitiveTypeDetector {
    static func detect(
        visualTags: [String],
        ocrText: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> (types: [String], signals: [String])
}
```

规则详见 [第 9 节](#9-敏感类型检测规则)。  
产出写入 `sensitiveTypes`、`sensitiveSignals`。

### 4.6 索引调度

```
for each pending asset:
  L0 metadata (if needed)
  L1 visual → tags + confidence
  if documentTriggers ∩ tags ≠ ∅:
      L2 accurate OCR
  L3 sensitive detect
  batch save every 12 assets
```

**性能**：

- L1 全库执行；
- L2 仅约 10%～30% 图片（含 document 类标签）；
- 后台 `Task` + `Task.yield()`，不阻塞 UI。

### 4.7 索引版本升级

`algorithmVersion` 3 → 4 时：

1. 保留 L0 元数据；
2. 清空 `sensitiveTypes`，标记需 L3 重跑；
3. 对 `documentTriggers` 命中条目排队 L2 重扫。

---

## 5. 在线搜索实现

### 5.1 主流程

**文件**：`PhotoCleaner/SmartSearchService.swift`（从 `SmartSearch.swift` 拆分）

```swift
enum SmartSearchService {
    static func search(query: String) async throws -> SearchResult {
        // 1. 路由
        let plan: SearchPlan
        if let local = QueryRouter.tryLocalPlan(query) {
            plan = local
        } else {
            let tags = await PhotoSearchIndexStore.shared.topVisualTags(limit: 1000)
            plan = try await SmartSearchClient.fetchPlan(query: query, availableTags: tags)
        }

        // 2. 取索引
        let assets = fetchAllAssets()
        let entries = await indexedEntries(for: assets)

        // 3. 检索 + 打分
        let scored = SearchEngine.execute(entries: entries, plan: plan)

        // 4. 转 PHAsset，保持相册排序
        return SearchResult(plan: plan, items: scored)
    }
}
```

### 5.2 SearchEngine

```swift
enum SearchEngine {
    static func execute(entries: [PhotoSearchIndexEntry], plan: SearchPlan) -> [ScoredEntry] {
        var list = entries

        list = MetadataFilter.apply(list, filters: plan.filters)
        list = MustMatcher.apply(list, must: plan.mustMatch)      // 含 E4 敏感
        let scored = ShouldScorer.score(list, should: plan.shouldMatch)

        let hasSemantic = plan.mustMatch.hasSemantic || plan.shouldMatch.hasSemantic
        let filtered = hasSemantic ? scored.filter { $0.score > 0 } : scored

        let limit = min(max(plan.count ?? 1000, 1), 1000)
        return filtered
            .sorted { $0.score != $1.score ? $0.score > $1.score
                     : ($0.entry.creationDate ?? .distantPast) > ($1.entry.creationDate ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}
```

### 5.3 视觉标签匹配

```swift
enum VisualTagMatcher {
    static let minConfidence: Float = 0.25

    static func matches(tag: String, entry: PhotoSearchIndexEntry) -> Bool {
        guard let tags = entry.visualTags, !tags.isEmpty else { return false }
        let normalized = normalize(tag)
        let synonyms = VisualSynonyms.expand(tag)   // 见第 8 节

        for synonym in synonyms {
            for (index, entryTag) in tags.enumerated() {
                let entryNorm = normalize(entryTag)
                // 1. 精确匹配
                if entryNorm == normalize(synonym) {
                    if confidence(entry, entryTag, at: index) >= minConfidence { return true }
                }
                // 2. 谨慎的子串匹配（同义词长度 >= 4 才启用）
                if synonym.count >= 4 && (entryNorm.contains(normalize(synonym)) || normalize(synonym).contains(entryNorm)) {
                    if confidence(entry, entryTag, at: index) >= minConfidence { return true }
                }
            }
        }
        return false
    }
}
```

### 5.4 OCR 匹配

```swift
enum OCRMatcher {
    static func contains(_ keyword: String, in entry: PhotoSearchIndexEntry) -> Bool {
        (entry.ocrText ?? "").localizedCaseInsensitiveContains(keyword)
    }

    static func matches(regex: String, in entry: PhotoSearchIndexEntry) -> Bool {
        guard let text = entry.ocrText, !text.isEmpty,
              let re = try? NSRegularExpression(pattern: regex, options: .caseInsensitive) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
```

**不做 OCR 词表**：查询词来自 SearchPlan，索引侧只存全文。

---

## 6. 服务端实现

### 6.1 目录结构

```
server/src/go/
├── main.go
├── handler.go          # 解析请求、校验 sign、返回 SearchPlan
├── prompt.go           # LLM 提示词（输出 SearchPlan JSON）
├── deepseek.go
├── config.go
└── normalize.go        # 新增：响应规范化
```

### 6.2 Prompt 输出 Schema

LLM 只返回 SearchPlan JSON，规则摘要：

1. `summary` 必填，英文简短描述；
2. `filters`：仅在有硬条件时填写；
3. `mustMatch.sensitiveTypes`：证件类查询优先；
4. 视觉类：`mustMatch.visualTagsAll` 表示 AND；单词粒度，禁止 `"white car"`；
5. 颜色类：拆成独立词并带近义词（`white` → `white, light, gray, silver, pale`）；
6. `shouldMatch`：宽泛召回 + 排序加分；
7. `availableTags` 若提供，优先从中选 tag，可补充同义词；
8. `count` 默认 1000。

### 6.3 normalize.go

```go
func normalizePlan(plan map[string]interface{}, cfg *Config) map[string]interface{} {
    // count: 默认 cfg.DefaultCount，上限 cfg.MaxCount
    // sensitiveTypes: 白名单 id_card|bank_card|passport|document
    // 剥离 visualConcepts / keywords（v1）若 LLM 误输出
    // confidence 限制 [0,1]
    return plan
}
```

### 6.4 配置

```go
DefaultCount: 1000
MaxCount:     1000
```

---

## 7. 客户端模块划分

| 文件 | 职责 |
|------|------|
| `SimilarAnalysisCache.swift` | `PhotoSearchIndexEntry` v4、`PhotoSearchIndexStore` |
| `SensitiveTypeDetector.swift` | L3 规则检测 |
| `PhotoLibraryService.swift` | L1/L2 索引流水线 |
| `VisualSynonyms.swift` | 全局中英同义词表 |
| `SmartSearchModels.swift` | `SearchPlan`、`SearchResult`、`ScoredEntry` |
| `SmartSearchClient.swift` | 网络请求、签名 |
| `QueryRouter.swift` | 本地模板解析 |
| `SearchEngine.swift` | 四检索器 + 打分 |
| `SmartSearchService.swift` | 对外 `search(query:)` |
| ` PhotoPreview.swift` | `SmartPhotoSearchView` UI（改动最小） |

---

## 8. 视觉同义词表

**文件**：`PhotoCleaner/VisualSynonyms.swift`  
**性质**：App 内置全局表，随版本更新；**不是**用户导出的 `visual-tags.txt`。

```swift
enum VisualSynonyms {
  private static let table: [String: [String]] = [
    "海边": ["beach", "shore", "seaside", "coast", "ocean", "sand"],
    "海":   ["beach", "ocean", "sea", "water", "coast"],
    "人":   ["person", "people", "human", "adult", "child"],
    "红":   ["red", "crimson", "scarlet"],
    "白":   ["white", "light", "gray", "silver", "pale"],
    "车":   ["car", "vehicle", "automobile", "automobile"],
    "狗":   ["dog"],
    "猫":   ["cat"],
    // ...
  ]

  static func expand(_ token: String) -> [String]  // 英/中 → 英文 tag 列表
}
```

**使用方式**：

- 查询路由器 / LLM 输出中文概念时，客户端 `expand` 后再与 `visualTags` 匹配；
- LLM 可直接输出英文 tag，客户端仍 `expand` 一轮（幂等）。

---

## 9. 敏感类型检测规则

### 9.1 `id_card`

满足任一信号即标记（建议收集 `signals` 便于调试）：

| 信号 ID | 条件 |
|---------|------|
| `ocr:居民身份证` | `ocrText` 含「居民身份证」 |
| `ocr:公民身份` | 含「公民身份号码」或「公民身份」 |
| `ocr:签发机关` | 含「签发机关」 |
| `regex:id18` | 正则 `\d{6}(19\|20)\d{2}(0[1-9]\|1[0-2])(0[1-9]\|[12]\d\|3[01])\d{3}[\dXx]` |
| `heuristic:document_ratio` | `document` ∈ visualTags 且宽高比 1.4～1.8 且 OCR 字数 > 30 |

### 9.2 `bank_card`

| 信号 | 条件 |
|------|------|
| `tag:credit_card` | visualTags 含 `credit_card` |
| `ocr:银联` | OCR 含「银联」「中国银行」「工商银行」等 |
| `regex:card16` | 16～19 位卡号正则（可选 Luhn 校验） |

### 9.3 `passport`

| 信号 | 条件 |
|------|------|
| `tag:passport` | visualTags 含 `passport` |
| `ocr:护照` | OCR 含「护照」或 `PASSPORT` |
| `regex:mrz` | MRZ 两行大写字母数字模式 |

### 9.4 `document`（泛化文档）

- 有 `document` / `printed_page` / `receipt` 等标签，且未命中更具体敏感类型时的兜底标记。

---

## 10. 匹配与打分算法

### 10.1 打分权重

```text
score = 0
foreach t in mustMatch.sensitiveTypes where entry.sensitiveTypes contains t:
    score += 100
foreach t in mustMatch.visualTagsAll where VisualTagMatcher.matches(t, entry):
    score += 50
foreach t in mustMatch.ocrContainsAll where OCRMatcher.contains(t, entry):
    score += 50
foreach t in shouldMatch.visualTags where VisualTagMatcher.matches(t, entry):
    score += 5 * confidenceWeight
foreach t in shouldMatch.ocrContains where OCRMatcher.contains(t, entry):
    score += 10
foreach r in shouldMatch.ocrRegexes where OCRMatcher.matches(regex: r, entry):
    score += 10
```

`confidenceWeight` = `entry.visualConfidence[tag] ?? 1.0`

### 10.2 入选规则

1. 先过 `filters`（硬过滤）；
2. 再过 `mustMatch`（全 AND，一项不满足即排除）；
3. 若 `mustMatch` 与 `shouldMatch` 皆空，仅 `filters` 生效；
4. 若 `shouldMatch` 非空且 `mustMatch` 为空，要求 `score > 0`；
5. 排序后取前 `count` 条。

### 10.3 命中原因（调试 / UI）

```swift
struct ScoredEntry {
    let entry: PhotoSearchIndexEntry
    let score: Double
    let reasons: [String]   // e.g. ["sensitive:id_card+100", "visual:beach+4.5"]
}
```

---

## 11. 查询路由器

**文件**：`PhotoCleaner/QueryRouter.swift`

本地模板（不调 LLM）：

| 正则 / 关键词 | 输出 SearchPlan |
|---------------|-----------------|
| `身份证|居民身份证|ID card` | `mustMatch.sensitiveTypes = ["id_card"]` |
| `银行卡|银行.*卡` | `mustMatch.sensitiveTypes = ["bank_card"]` |
| `护照` | `mustMatch.sensitiveTypes = ["passport"]` |
| `截图` | `filters.assetTypes = ["screenshot"]` |
| `live|实况` | `filters.assetTypes = ["live"]` |
| `>(\d+)\s*M` | `filters.minSizeMB` |
| `尾号\s*(\d{4})` | `shouldMatch.ocrRegexes = ["\\d{0,15}\(g1)\\b"]` |

未命中模板 → 走 `SmartSearchClient.fetchPlan`。

---

## 12. 兼容与迁移

### 12.1 API 兼容期（建议 1 个版本）

客户端同时支持解析 v1 响应：

```swift
// SmartSearchClient 解码后
if response.keywords != nil || response.visualConcepts != nil {
    plan = SearchPlan.migrate(from: legacyResponse)
}
```

`SearchPlan.migrate` 将 `keywords` → `shouldMatch.visualTags`，`visualConcepts` → `mustMatch.visualTagsAll` 分组。

### 12.2 索引兼容

- `algorithmVersion < 4`：启动时后台升级，分批 L2/L3 重扫；
- 旧字段 `visualTags` / `ocrText` 保留，新字段默认 `nil`。

### 12.3 现有文件影响

| 文件 | 动作 |
|------|------|
| `SmartSearch.swift` | 拆分为多文件或保留 facade |
| `server/smart-search-api.md` | 更新为 SearchPlan 规格 |
| `script/design.md` | 保留设计 rationale |
| **本文档** | 实现规格主文档 |

---

## 13. 分阶段交付计划

### Phase 0 — 修复断层（1～2 周）

- [ ] 实现 `SensitiveTypeDetector` + 索引写入 `sensitiveTypes`
- [ ] L2 条件触发 accurate OCR
- [ ] `SearchEngine` 实现 `mustMatch.sensitiveTypes`
- [ ] `QueryRouter` 证件类本地模板
- [ ] 索引 `algorithmVersion = 4` 升级逻辑

**验收**：「身份证」「护照」「银行卡」能稳定召回。

### Phase 1 — 统一 SearchPlan（1～2 周）

- [ ] 服务端 prompt 改为 SearchPlan 输出
- [ ] 客户端 `SearchPlan` 模型 + v1 migrate
- [ ] 废弃 `visualConcepts` 生成
- [ ] `VisualSynonyms` + 精确/置信度匹配
- [ ] 请求携带 `availableTags`

**验收**：视觉类误匹配下降；服务端响应可调试。

### Phase 2 — 体验与质量（持续）

- [ ] 索引进度 UI
- [ ] 结果命中原因展示
- [ ] 评测集自动化脚本（`script/eval-search.py`）
- [ ] 命中原因写入 Debug 日志

---

## 14. 测试与验收

### 14.1 评测集格式

**文件**：`script/search-eval.json`

```json
{
  "cases": [
    {
      "query": "身份证",
      "expectIds": ["E84F2EE5-...", "D1D78706-..."],
      "minRecall": 0.8
    }
  ]
}
```

### 14.2 指标

| 指标 | 说明 |
|------|------|
| Recall@50 | 期望结果出现在前 50 条的比例 |
| Precision@20 | 前 20 条中相关结果比例 |
| P95 延迟 | 搜索端到端 < 3s（含 LLM） |

### 14.3 手工测试清单

- [ ] 身份证 / 银行卡 / 护照
- [ ] 去年 + 地点 + 视觉组合
- [ ] 大于 5M 视频
- [ ] 截图 / Live Photo
- [ ] 银行卡尾号正则
- [ ] 无网络时本地模板仍可用
- [ ] 索引未完成时提示或降级

---

## 15. 附录

### 15.1 现有关键代码位置

| 功能 | 路径 |
|------|------|
| 索引存储 | `PhotoCleaner/SimilarAnalysisCache.swift` |
| 视觉/OCR 索引 | `PhotoCleaner/PhotoLibraryService.swift` → `searchVisualTags` / `searchRecognizedText` |
| 搜索 UI | `PhotoCleaner/ PhotoPreview.swift` → `SmartPhotoSearchView` |
| 搜索客户端 | `PhotoCleaner/SmartSearch.swift` |
| 服务端 | `server/src/go/` |
| 调试索引导出 | `PhotoLibraryService.exportSmartSearchDebugIndex()` |

### 15.2 API 错误码

| HTTP | 响应 | 客户端处理 |
|------|------|------------|
| 400 | `invalid_request` | 提示重试 |
| 401 | `unauthorized` | 检查 `SmartSearchSecret` |
| 200 | `keywords:[]`, `confidence:0` | 解析失败，显示无结果 |
| 超时 15s | — | 提示网络超时 |

### 15.3 隐私与安全

- 上传：仅 `query` 文本 + 可选 `availableTags`（英文标签，无照片内容）；
- 不上传：`ocrText`、GPS 明细、图片；
- `sign` 防止请求篡改；`serverSecret` 存于 `Info.plist`（发布时考虑混淆）。

### 15.4 常见问题

**Q：每台手机的 visualTags 不一样怎么办？**  
A：正常。Vision 标签体系一致，但用户相册内容不同，出现的标签子集不同。搜索时用全局同义词 + 可选 `availableTags` 对齐，不需要用户整理词表。

**Q：要不要给 OCR 建词表？**  
A：不要。OCR 是自由文本，查询时用 `ocrContains` / 正则对全文匹配。

**Q：`visual-tags.txt` 有什么用？**  
A：仅开发调试，从某次 `smart-search-index-*.json` 排重导出，不代表产品词表。

---

## 变更记录

| 日期 | 版本 | 说明 |
|------|------|------|
| 2026-06-26 | v2.0 | 首版完整实现方案 |
