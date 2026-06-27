# Smart Search Client-Server API

## Overview

客户端智能搜索的完整流程：

1. **客户端**：用户输入搜索文本 → 发送原文到服务器
2. **服务器**：调用大模型解析搜索意图 → 返回 **SearchPlan**（`filters` 元数据 + `must` 倒排交集条件）
3. **客户端**：用 SearchPlan 在本地倒排表做交集检索 → `filters` 验正排档案 → 按时间排序取 Top N

---

## 客户端开发任务拆解

### 任务总览

| 阶段 | 任务 | 优先级 | 状态 |
|------|------|--------|------|
| 1 | 创建配置管理 | 高 | ✅ 已完成 |
| 2 | 创建网络请求工具 | 高 | ✅ 已完成 |
| 3 | 创建数据模型 | 高 | ✅ 已完成 |
| 4 | 实现签名算法 | 高 | ✅ 已完成 |
| 5 | 实现智能搜索服务 | 高 | ✅ 已完成 |
| 6 | 实现本地匹配算法 | 高 | ✅ 已完成 |
| 7 | 集成到 UI | 中 | 待开发 |

---

### 任务 1：创建配置管理

**目标**：统一管理服务器地址和密钥配置

**文件位置**：`PhotoCleaner/SmartSearchConfig.swift`

**实现内容**：
- 从 `Info.plist` 读取 `SmartSearchEndpoint` 和 `SmartSearchSecret`
- 提供配置访问的静态方法

**配置项**（需在 Info.plist 中添加）：
```xml
<key>SmartSearchEndpoint</key>
<string>https://cleaner.digsaw.cc/smart-search</string>
<key>SmartSearchSecret</key>
<string>your-secret-key-here</string>
```

---

### 任务 2：创建网络请求工具

**目标**：封装 HTTP 请求逻辑

**文件位置**：`PhotoCleaner/SmartSearchClient.swift`

**实现内容**：
- `fetchSearchCondition(query:) async throws -> SmartSearchCondition`
- 处理请求体构建（query, locale, appVersion, buildVersion, sign）
- 处理响应解析和错误处理
- 15 秒超时

---

### 任务 3：创建数据模型

**目标**：定义搜索条件的数据结构

**文件位置**：`PhotoCleaner/SmartSearchModels.swift`

**实现内容**：
- `SmartSearchCondition` - 搜索条件
- `SmartSearchDateRange` - 日期范围
- `SmartSearchLocationBound` - 位置边界
- `SmartSearchVisualConcept` - 视觉概念

---

### 任务 4：实现签名算法

**目标**：计算 MD5 签名

**文件位置**：在 `SmartSearchClient.swift` 中实现

**实现内容**：
```swift
import CommonCrypto

func calculateSign(query: String, secret: String) -> String {
    let raw = query + secret
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    raw.withCString { cString in
        CC_MD5(cString, CC_LONG(raw.utf8.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}
```

---

### 任务 5：实现智能搜索服务

**目标**：整合网络请求和本地匹配

**文件位置**：`PhotoCleaner/SmartSearchService.swift`

**实现内容**：
- `search(query:) async throws -> [PHAsset]`
- 调用 `SmartSearchClient` 获取搜索条件
- 调用 `PhotoSearchIndexStore` 获取本地索引
- 调用匹配算法筛选图片
- 转换 `PhotoSearchIndexEntry` 为 `PHAsset`

---

### 任务 6：实现本地匹配算法

**目标**：在本地图片索引中筛选匹配图片

**文件位置**：`PhotoCleaner/SmartSearchMatcher.swift`

**实现内容**：
- `filterByHardConditions(entries:, condition:) -> [PhotoSearchIndexEntry]`
  - 时间范围过滤
  - 位置边界过滤
  - 媒体类型过滤
  - 资源类型过滤
  - 文件大小过滤
  - 像素尺寸过滤
  - 是否有位置信息过滤

- `scoreByKeywords(entries:, condition:) -> [(entry, score)]`
  - 关键词匹配（visualTags + ocrText）
  - 视觉概念匹配（visualConcepts）
  - OCR 正则匹配（ocrRegexes）

- `matchesKeyword(_:, entry:) -> Bool`
- `matchesVisualTag(_:, entry:) -> Bool`

---

### 任务 7：集成到 UI

**目标**：在现有搜索界面中集成智能搜索

**文件位置**：`PhotoCleaner/ PhotoPreview.swift`（或新建搜索视图）

**实现内容**：
- 识别用户输入是否为自然语言搜索
- 调用 `SmartSearchService.search()`
- 展示搜索结果
- 处理加载状态和错误

## 客户端本地索引结构【已完成】

客户端预先将每张图片的信息存入本地缓存，结构如下：

```json
{
      "assetTypes" : [
        "live"
      ],
      "creationDate" : "2022-10-23T01:39:52Z",
      "filename" : "IMG_6484.HEIC",
      "hasValidIndex" : true,
      "latitude" : 39.977916666666665,
      "localIdentifier" : "6B91FE1B-A39E-4600-B72C-1E4E7E16DDFE\/L0\/001",
      "longitude" : 116.36846166666666,
      "mediaType" : "image",
      "ocrIndexedAt" : "2026-06-25T02:22:08Z",
      "ocrText" : "",
      "pixelHeight" : 4032,
      "pixelWidth" : 3024,
      "signature" : "6B91FE1B-A39E-4600-B72C-1E4E7E16DDFE\/L0\/001:1666489192.228:1775212666.651:3024:4032:1:8",
      "storageBytes" : 6453363,
      "visualIndexedAt" : "2026-06-25T02:22:08Z",
      "visualTags" : [
        "baby",
        "clothing",
        "gray_clothing",
        "human",
        "material",
        "orange",
        "people",
        "person",
        "textile"
      ]
    },
```

### 可用于筛选的字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `creationDate` | `ISO8601` | 图片创建时间，用于时间范围过滤 |
| `latitude` / `longitude` | `Double` | GPS 坐标，用于位置过滤 |
| `mediaType` | `String` | `"image"` 或 `"video"` |
| `assetTypes` | `String[]` | 资源类型：`"screenshot"`、`"live"`、`"screen_recording"` |
| `storageBytes` | `Int64` | 文件大小（字节） |
| `pixelWidth` / `pixelHeight` | `Int` | 图片像素尺寸 |
| `hasLocation` | `Bool` | 是否有位置信息 |
| `ocrText` | `String` | OCR 识别的文字内容，用于文字匹配 |
| `visualTags` | `String[]` | 视觉标签列表，用于关键词匹配 |

## Request Schema

### 请求

```json
{
  "query": "去年在海南拍的海边大头照",
  "locale": "zh-Hans_CN",
  "appVersion": "1.0.0",
  "buildVersion": "100",
  "availableTags": ["person", "beach", "ocean", "sky"],
  "sign": "a1b2c3d4e5f6..."
}
```

### 字段

| Field | Type | Required | Description |
|---|---|---:|---|
| `query` | `string` | 是 | 用户输入的原始搜索文本（客户端已 trim） |
| `locale` | `string` | 是 | 设备语言区域，如 `zh-Hans_CN`、`en_US`、`ja_JP` |
| `appVersion` | `string` | 是 | 客户端 App 版本号，如 `"1.0.0"` |
| `buildVersion` | `string` | 是 | 客户端 Build 号，如 `"100"` |
| `availableTags` | `string[]` | 是 | 本机 visualTags 全量去重列表（最多 1000），供 LLM 选词 |
| `sign` | `string` | 是 | 签名，用于验证请求完整性 |

### 签名算法

客户端计算签名，服务器验证签名，防止请求被篡改。

**签名计算**：

```
sign = MD5(query + serverSecret)
```

- 将 `query` 与服务器共享密钥 `serverSecret` 拼接
- 计算 MD5 哈希值
- 转为 32 位小写十六进制字符串

**客户端示例**（Swift）：

```swift
import CommonCrypto

func calculateSign(query: String) -> String {
    let raw = query + serverSecret
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    raw.withCString { cString in
        CC_MD5(cString, CC_LONG(raw.utf8.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}
```

**服务器验证**：

```python
import hashlib

def verify_sign(query: str, sign: str, secret: str) -> bool:
    raw = query + secret
    expected = hashlib.md5(raw.encode()).hexdigest()
    return sign.lower() == expected
```

### 请求规则

- `query` 是自然语言文本，服务器不应信任其格式
- 服务器应再次 trim 并做空值校验
- `availableTags` 必填，可为空数组 `[]`
- 空查询应返回 400
- `appVersion` 和 `buildVersion` 用于服务器判断客户端能力，便于后续版本兼容
- `sign` 验证失败应返回 `401 Unauthorized`

## Response Schema（SearchPlan v2）

### 响应

```json
{
  "summary": "去年在海南拍的海边人物照片",
  "filters": {
    "dateRange": {
      "start": "2025-01-01",
      "end": "2025-12-31"
    },
    "locationBounds": [
      {
        "name": "海南",
        "minLatitude": 18.0,
        "maxLatitude": 20.0,
        "minLongitude": 108.0,
        "maxLongitude": 111.0
      }
    ],
    "mediaTypes": ["image"],
    "minPixelWidth": 800,
    "minPixelHeight": 800,
    "hasLocation": true
  },
  "must": {
    "visualTagsAll": ["beach", "person"],
    "sensitiveTypes": [],
    "ocrContainsAll": []
  },
  "count": 1000,
  "confidence": 0.85
}
```

### 字段

| Field | Type | Required | Description |
|---|---|---:|---|
| `summary` | `string` | 是 | 搜索条件的简短描述，用于 UI 展示 |
| `filters` | `object` | 否 | 元数据硬条件（查正排档案，不走倒排） |
| `filters.dateRange` | `object` | 否 | 时间范围 |
| `filters.dateRange.start` | `string` | 否 | 起始日期，`YYYY-MM-DD` |
| `filters.dateRange.end` | `string` | 否 | 结束日期，`YYYY-MM-DD` |
| `filters.locationBounds` | `object[]` | 否 | 位置边界（任一边界匹配即可） |
| `filters.mediaTypes` | `string[]` | 否 | `"image"` / `"video"` |
| `filters.assetTypes` | `string[]` | 否 | `"screenshot"` / `"live"` / `"screen_recording"` |
| `filters.minSizeMB` / `maxSizeMB` | `number` | 否 | 文件大小（MB） |
| `filters.minPixelWidth` / `minPixelHeight` | `integer` | 否 | 最小像素尺寸 |
| `filters.hasLocation` | `boolean` | 否 | 是否必须有 GPS |
| `must` | `object` | 是 | 倒排交集条件 |
| `must.visualTagsAll` | `string[]` | 是 | 视觉 tag，**AND** 语义（每组客户端扩展同义词后做交集） |
| `must.sensitiveTypes` | `string[]` | 是 | `id_card` / `bank_card` / `passport` / `document` |
| `must.ocrContainsAll` | `string[]` | 是 | OCR 须同时包含的文字 |
| `count` | `integer` | 是 | 返回数量上限，默认 1000，最大 1000 |
| `confidence` | `number` | 否 | 解析置信度 0~1 |

### 响应规则

- `filters` 中未返回的字段表示**不过滤**
- `must.visualTagsAll` 每项为 `availableTags` 中的原样 tag key；**组间 AND**；优先最少 tag；同义词由客户端组内扩展
- `must.sensitiveTypes` 不进 `availableTags`，由客户端 `sensitivePostings` 检索
- **已废弃**（v2 不再返回）：`keywords`、`visualConcepts`、`should`、`ocrKeywords`、`ocrRegexes`、`requiresOCR` 及顶层扁平 `dateRange` 等
- 服务端对 LLM 旧格式输出做兼容归一化后统一返回 SearchPlan
- `count` 默认 1000，最大 1000

### 响应示例

用户查询：`"去年在海南拍的海边大头照"`

```json
{
  "summary": "Beach person photos in Hainan last year",
  "filters": {
    "dateRange": {"start": "2025-01-01", "end": "2025-12-31"},
    "locationBounds": [{"name": "Hainan", "minLatitude": 18.0, "maxLatitude": 20.0, "minLongitude": 108.0, "maxLongitude": 111.0}],
    "mediaTypes": ["image"]
  },
  "must": {"visualTagsAll": ["beach", "person"], "sensitiveTypes": [], "ocrContainsAll": []},
  "count": 1000,
  "confidence": 0.85
}
```

用户查询：`"找大于5M的视频"`

```json
{
  "summary": "Videos larger than 5MB",
  "filters": {"mediaTypes": ["video"], "minSizeMB": 5},
  "must": {"visualTagsAll": [], "sensitiveTypes": [], "ocrContainsAll": []},
  "count": 1000
}
```

用户查询：`"穿红衣服的人"`

```json
{
  "summary": "Person in red clothing",
  "must": {"visualTagsAll": ["person", "red_clothing"], "sensitiveTypes": [], "ocrContainsAll": []},
  "count": 1000,
  "confidence": 0.95
}
```

用户查询：`"身份证照片"`

```json
{
  "summary": "ID card photos",
  "filters": {"mediaTypes": ["image"]},
  "must": {"visualTagsAll": [], "sensitiveTypes": ["id_card"], "ocrContainsAll": []},
  "count": 1000
}
```

## 客户端匹配逻辑

### 匹配流程

```
所有本地图片索引
    ↓
第一步：硬条件过滤（AND 关系）
  - dateRange: creationDate 在范围内
  - locationBounds: latitude/longitude 在任一位置边界内（OR）
  - mediaTypes: mediaType 在列表中
  - assetTypes: assetType 在列表中
  - minSizeMB/maxSizeMB: storageBytes 在范围内
  - minPixelWidth / minPixelHeight: 尺寸 >= 阈值
  - hasLocation: 是否有位置信息
  - sensitiveTypes: 敏感类型匹配
    ↓
第二步：关键词匹配（计算匹配分数）
  - 遍历剩余图片，统计每个图片匹配了多少个关键词
  - 匹配范围：同时在 `visualTags` 和 `ocrText` 两个字段中匹配
  - 匹配规则：
    a. 服务器返回的关键词列表作为"查询词"
    b. 遍历图片的 visualTags，检查每个 tag 是否在关键词列表中（包含匹配）
    c. 遍历图片的 ocrText，检查是否包含关键词
    d. ocrRegexes 正则匹配 ocrText
  - visualConcepts 概念匹配（概念间 AND，概念内 OR）
    ↓
第三步：按匹配分数降序排序，取 Top N
    ↓
展示搜索结果
```

### 关键词匹配规则

服务器返回的 `keywords` 已拆分为独立词（不带下划线），客户端直接使用：

1. trim 空白
2. 转小写

示例：
- `person` → `person`
- `DOG` → `dog`
- `red` → `red`

#### visualTags 匹配（视觉标签）

**核心逻辑**：遍历图片的 visualTags，检查每个 tag 是否匹配服务器返回的关键词列表。

匹配规则：
1. **包含匹配**：图片的某个 visualTag 在服务器返回的关键词列表中被找到，即计 1 分
2. **子串包含**：tag 与关键词互相包含也算匹配

**示例**：
- 服务器返回 `keywords: ["red", "clothing"]`
- 图片 A 的 visualTags: `["person", "red_clothing"]`
- 匹配过程：
  - 检查 `person` 是否匹配 `["red", "clothing"]` → 不匹配
  - 检查 `red_clothing` 是否匹配 → 包含 `red` 和 `clothing` → **匹配成功，计 1 分**

> **注意**：是图片的 tag 去匹配关键词列表，不是反过来。

#### visualConcepts 匹配（视觉概念）

匹配规则：
1. **概念间 AND**：所有 `visualConcepts` 都必须匹配
2. **概念内 OR**：每个概念的 `matchAny` 数组中，匹配任一词即可
3. 匹配方式：与 `visualTags` 相同（图片的 tag 包含关键词列表中的任一词）

示例：
```json
"visualConcepts": [
  {"name": "海边", "matchAny": ["beach", "shore", "seaside"]},
  {"name": "人物", "matchAny": ["person", "people", "human"]}
]
```
- 图片必须同时匹配"海边"和"人物"概念
- "海边"概念：图片的 visualTags 包含 `beach` 或 `shore` 或 `seaside` 中任一词即可

#### ocrText 匹配（文字内容）

- 将 `ocrText` 转小写后，检查是否包含关键词（忽略大小写）
- 示例：ocrText="Hello Red World" 匹配关键词 `red`（因为包含 `red`）

#### ocrRegexes 匹配（正则表达式）

- 用于银行卡尾号等精确匹配场景
- 示例：`"\\d{0,15}1234\\b"` 匹配包含尾号 1234 的文本
- 注意：正则在 OCR 文本中任意位置匹配，不限于末尾

#### 匹配计数

每个关键词独立计分：
- 如果 `red` 匹配成功（图片的某个 tag 包含 `red`），计 1 次
- 如果 `clothing` 匹配成功，计 1 次
- 最终得分 = 匹配成功的关键词数量

同一关键词在 `visualTags` 和 `ocrText` 中都匹配时，计 2 次（不去重）。

### 匹配分数计算

```
score = matchedKeywordCount
```

- `matchedKeywordCount`：该图片匹配到的关键词数量（在 `visualTags` 或 `ocrText` 中任一匹配即计数）

按 `score` 降序排序，取前 N 张图片展示（N 由 `count` 字段决定，默认 9）。

### 边界情况

- 硬条件过滤后无图片 → 返回空结果，UI 显示"没有找到匹配的图片"
- 有图片但关键词全部不匹配 → 返回空结果（严格匹配模式）
- 关键词为空数组 → 只做硬条件过滤，不做关键词匹配，返回符合条件的所有图片

## 服务器端实现方案

### 技术选型

- **语言**：Go
- **LLM 接入**：DeepSeek API
- **部署**：云服务器 / Nginx 反向代理

### 核心逻辑

#### LLM 提示词模板

使用 DeepSeek API，提示词和返回内容全部使用英文：

```text
You are a photo search intent parser. Return only valid JSON, no Markdown.

User query: {query}
Query language: {locale}
Current date: {current_date}

Schema:
{
  "summary": "short summary",
  "mediaTypes": ["image"|"video"],
  "assetTypes": ["screenshot"|"live"|"screen_recording"],
  "dateRange": {"start":"YYYY-MM-DD","end":"YYYY-MM-DD"},
  "locationBounds": [{"name":"","minLatitude":0,"maxLatitude":0,"minLongitude":0,"maxLongitude":0}],
  "minSizeMB": 0, "maxSizeMB": 0,
  "hasLocation": true,
  "keywords": [],
  "visualConcepts": [{"name":"","matchAny":["","synonym"]}],
  "ocrKeywords": [], "ocrRegexes": [],
  "sensitiveTypes": ["bank_card","id_card","passport","document"],
  "requiresOCR": false,
  "count": 9,
  "confidence": 0
}

Rules:
1. summary: short English description of search condition (required)
2. dateRange: resolve relative dates (last year, past month, past week, this year) from Current date
3. locationBounds: if place mentioned, return latitude/longitude bounds
4. hasLocation: only when user explicitly asks for WITH/WITHOUT location (not for visual scenes)
5. mediaTypes: ["image"] or ["video"] based on query
6. minSizeMB/maxSizeMB: in MB (e.g., "larger than 5M" → 5)
7. count: number of photos requested (default 9 if not specified)
8. keywords (required): split compound words, include synonyms (e.g., "car" → ["car","vehicle","automobile"])
9. visualConcepts: for abstract concepts, matchAny contains synonyms (concepts ANDed, words ORed)
10. ocrKeywords: text keywords to find in images
11. ocrRegexes: regex for card tail numbers (e.g., "\d{0,15}1234\\b")
12. sensitiveTypes: ["bank_card","id_card","passport","document"]
13. requiresOCR: true when text recognition needed
14. confidence: 0-1 float

Omit fields with no information. Return only JSON.
```

#### Go 实现概要

服务器使用 Go 语言实现，核心文件：

```
src/go/
├── main.go       # 入口，路由配置，日志初始化
├── handler.go    # HTTP 处理器，请求解析，签名验证
├── deepseek.go   # DeepSeek API 客户端
├── prompt.go     # LLM 提示词模板
└── logger.go     # 日志记录（按日期分文件）
```

**核心流程**：

1. 接收 POST `/smart-search` 请求
2. 验证 `query`、`locale`、`sign` 必填字段
3. MD5 签名验证：`MD5(query + serverSecret)`
4. 调用 DeepSeek API 解析查询
5. 规范化响应（确保 `keywords` 存在，`count` 在 1-50 范围）
6. 返回 JSON 结果

**日志**：

- 日志目录：`/home/www/websites/cleaner.digsaw.cc/log`
- 按日期分文件：`YYYY-MM-DD.log`
- 自动清理：每天凌晨 2 点清理超过 100 天的日志

### 位置解析

大模型直接返回位置的经纬度范围，无需服务器维护位置映射表。

### 时间解析

大模型根据 `Current date` 和用户查询中的相对时间表达式（去年、今年、最近一周等）自动计算日期范围。

## 客户端实现方案

### 数据结构

```swift
struct SmartSearchCondition: Decodable {
    var summary: String?
    var dateRange: DateRange?
    var locationBounds: [LocationBound]?
    var mediaTypes: [String]?
    var assetTypes: [String]?
    var minSizeMB: Double?
    var maxSizeMB: Double?
    var minPixelWidth: Int?
    var minPixelHeight: Int?
    var hasLocation: Bool?
    var keywords: [String]
    var visualConcepts: [VisualConcept]?
    var ocrKeywords: [String]?
    var ocrRegexes: [String]?
    var sensitiveTypes: [String]?
    var requiresOCR: Bool?
    var count: Int?
    var confidence: Double?
}

struct DateRange: Decodable {
    var start: String?  // YYYY-MM-DD
    var end: String?
}

struct LocationBound: Decodable {
    var name: String?
    var minLatitude: Double?
    var maxLatitude: Double?
    var minLongitude: Double?
    var maxLongitude: Double?
}

struct VisualConcept: Decodable {
    var name: String
    var matchAny: [String]
}
```

### 搜索实现

```swift
func smartSearch(query: String) async throws -> [PHAsset] {
    // 1. 请求服务器
    let condition = try await fetchSearchCondition(query: query)
    
    // 2. 获取所有图片索引
    let allEntries = await PhotoSearchIndexStore.shared.allEntries()
    
    // 3. 硬条件过滤
    var candidates = allEntries
    
    // 3.1 时间范围过滤
    if let dateRange = condition.dateRange {
        candidates = candidates.filter { entry in
            guard let created = parseISO8601(entry.creationDate) else { return false }
            let dateStr = created.formatted(.iso8601.year().month().day())
            if let start = dateRange.start, dateStr < start { return false }
            if let end = dateRange.end, dateStr > end { return false }
            return true
        }
    }
    
    // 3.2 位置边界过滤（任一边界匹配即可）
    if let locationBounds = condition.locationBounds, !locationBounds.isEmpty {
        candidates = candidates.filter { entry in
            guard let lat = entry.latitude, let lon = entry.longitude else { 
                return condition.hasLocation != true  // 如果要求有位置，无位置的排除
            }
            return locationBounds.contains { bound in
                guard let minLat = bound.minLatitude, let maxLat = bound.maxLatitude,
                      let minLon = bound.minLongitude, let maxLon = bound.maxLongitude else { return false }
                return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
            }
        }
    } else if condition.hasLocation == true {
        // 如果没有位置边界但要求有位置
        candidates = candidates.filter { entry in
            entry.latitude != nil && entry.longitude != nil
        }
    }
    
    // 3.3 媒体类型过滤
    if let mediaTypes = condition.mediaTypes, !mediaTypes.isEmpty {
        candidates = candidates.filter { mediaTypes.contains($0.mediaType) }
    }
    
    // 3.4 资源类型过滤
    if let assetTypes = condition.assetTypes, !assetTypes.isEmpty {
        candidates = candidates.filter { entry in
            let types = Set(entry.assetTypes ?? [])
            return assetTypes.contains { types.contains($0) }
        }
    }
    
    // 3.5 文件大小过滤（MB 转 bytes）
    if let minMB = condition.minSizeMB {
        let minBytes = Int64(minMB * 1024 * 1024)
        candidates = candidates.filter { $0.storageBytes >= minBytes }
    }
    
    if let maxMB = condition.maxSizeMB {
        let maxBytes = Int64(maxMB * 1024 * 1024)
        candidates = candidates.filter { $0.storageBytes <= maxBytes }
    }
    
    // 3.6 敏感类型过滤
    if let sensitiveTypes = condition.sensitiveTypes, !sensitiveTypes.isEmpty {
        // 根据敏感类型进行特殊处理
        // 例如：检测图片是否包含银行卡、身份证等敏感信息
        // 这里需要结合 OCR 和图像识别能力
    }
    
    // 4. 关键词匹配打分（同时匹配 visualTags 和 ocrText）
    let normalizedKeywords = condition.keywords.map { keyword in
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }.filter { !$0.isEmpty }
    
    let scored = candidates.map { entry in
        var matchedCount = 0
        
        // 4.1 匹配 keywords
        for keyword in normalizedKeywords {
            if matchesKeyword(keyword, entry: entry) {
                matchedCount += 1
            }
        }
        
        // 4.2 匹配 visualConcepts（概念间 AND，概念内 OR）
        for concept in (condition.visualConcepts ?? []) {
            let matched = concept.matchAny.contains { tag in
                matchesKeyword(tag.lowercased(), entry: entry)
            }
            if matched {
                matchedCount += 1  // 每个概念匹配成功计 1 分
            }
        }
        
        // 4.3 匹配 ocrRegexes
        let ocrText = (entry.ocrText ?? "").lowercased()
        for regexPattern in (condition.ocrRegexes ?? []) {
            if let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive),
               regex.firstMatch(in: ocrText, options: [], range: NSRange(ocrText.startIndex..., in: ocrText)) != nil {
                matchedCount += 1
            }
        }
        
        return (entry: entry, score: Double(matchedCount))
    }
    
    // 辅助函数：关键词是否匹配该图片
    func matchesKeyword(_ keyword: String, entry: PhotoSearchIndexEntry) -> Bool {
        // 1. 检查 visualTags 匹配
        if matchesVisualTag(keyword, entry: entry) {
            return true
        }
        
        // 2. 检查 ocrText 匹配
        let ocrText = (entry.ocrText ?? "").lowercased()
        if ocrText.contains(keyword) {
            return true
        }
        
        return false
    }
    
    // 辅助函数：visualTags 匹配（精确 + 子串）
    func matchesVisualTag(_ keyword: String, entry: PhotoSearchIndexEntry) -> Bool {
        let indexedTags = Set((entry.visualTags ?? []).map { $0.lowercased() })
        guard !indexedTags.isEmpty else { return false }
        
        // 精确匹配
        if indexedTags.contains(keyword) {
            return true
        }
        
        // 子串包含匹配
        return indexedTags.contains { indexedTag in
            indexedTag.contains(keyword) || keyword.contains(indexedTag)
        }
    }
    
    // 5. 排序并取 Top N（默认 9，最大 50）
    let sorted = scored.sorted { $0.score > $1.score }
    let limit = max(1, min(condition.count ?? 9, 50))
    let topN = Array(sorted.prefix(limit)).map { $0.entry }
    
    // 6. 转换为 PHAsset
    return topN.compactMap { entry in
        PHAsset.fetchAssets(withLocalIdentifiers: [entry.localIdentifier], options: nil).firstObject
    }
}
```

## 错误处理

### 服务器端

| 场景 | HTTP 状态码 | 响应 |
|---|---|---|
| 请求体无效 | `400` | `{"error": "invalid_request", "message": "query is required"}` |
| 签名验证失败 | `401` | `{"error": "unauthorized", "message": "invalid signature"}` |
| 解析失败 | `200` | 空 SearchPlan：`must` 全空数组，`count`: 1000，`confidence`: 0 |
| 服务器内部错误 | `500` | `{"error": "internal_error", "message": "..."}` |

### 客户端

- `401` 响应 → 显示"验证失败，请重试"
- 其他非 2xx 响应 → 显示"网络错误"
- 无效 JSON → 显示"解析失败"
- 超时（15s） → 显示"搜索超时"

## 性能要求

| 指标 | 目标 |
|---|---|
| p50 响应时间 | < 1s |
| p95 响应时间 | < 3s |
| 硬上限 | < 10s |

客户端本地筛选应在 100ms 内完成（4000+ 图片）。

## 安全考虑

- 服务端不应暴露 LLM 的 system prompt、model name、API key
- 用户查询文本仅用于解析，不应持久化存储
- 位置信息由客户端本地匹配，不上传到服务器

## 常见视觉标签参考

服务器返回 `keywords` 时，应包含主词及其同义词/近义词，并拆分为独立词（不带下划线）。

以下是完整的视觉标签列表（从 `visual-tags.txt` 提取，下划线词已拆分并去重）：

```
# 人物
adult, baby, child, teen, person, people, human, bride, crowd

# 服装 & 颜色
clothing, textile, material, gown, jacket, jeans, kimono, lab_coat, hoodie, suit, swimsuit, wetsuit, wedding, whiteboard
black, blue, gray, green, orange, purple, red, white, yellow

# 交通 & 车辆
aircraft, automobile, car, vehicle, train, train_real, sportscar, rickshaw, skateboard, bicycle, conveyance, wheelchair

# 动物 & 宠物
animal, pet, doll, stuffed_animals

# 食物 & 饮料
food, drink, meal, soup, spaghetti, frozen, baked_goods, pizza

# 建筑 & 室内
building, skyscraper, house, apartment, classroom, bedroom, bathroom, kitchen, living_room, office, hotel, restaurant, church, school
interior_room, exterior, doorway, door, window, wall, floor, ceiling, roof, stairs, elevator, escalator

# 自然 & 景观
sky, cloud, sun, moon, star, night_sky, daytime, sunset_sunrise, blue_sky, cloudy
land, water, ocean, sea, lake, river, pool, sand, snow, ice, rain, fog
beach, mountain, hill, valley, forest, grass, tree, palm_tree, vineyard, garden, park, playground

# 物品 & 工具
tool, machine, appliance, computer, printer, telephone, tv, radio, camera, clock, calendar
book, bookshelf, newspaper, magazine, document, paper, receipt, invoice, ticket, stamp
pen, pencil, marker, eraser, scissors, knife, fork, spoon, chopsticks, plate, bowl, cup, glass
bag, backpack, purse, wallet, key, watch, jewelry, ring, necklace, bracelet, earring
shirt, shoe, sneaker, boot, hat, cap, helmet, sunglasses, eyeglasses, scarf, glove, tie, belt
coat, jacket, jeans, pants, shorts, skirt, dress, underwear, swimsuit

# 运动 & 活动
sport, game, play, exercise, workout, yoga, dance, swim, skiing, snowboarding, skating, cycling, running, walking
ball, basketball, football, soccer, tennis, golf, hockey, baseball, volleyball, bowling
board_game, card_game, video_game, videogame, chess

# 场所 & 地点
airport, train_station, bus_station, parking_lot, street, road, highway, bridge, tunnel
hospital, school, church, museum, theater, cinema, stadium, gymnasium, swimming_pool
hotel, resort, campground, beach, mountain, hill, forest, park, garden

# 抽象概念
art, music, dance, performance, ceremony, celebration, wedding, birthday, christmas, new_year, halloween
love, romance, couple, family, friend, group, team
work, business, meeting, interview, office, school, classroom, library
travel, vacation, trip, tour, expedition
nature, landscape, seascape, cityscape, nightscape

# 其他常见词
big, large, small, tiny, medium, little, huge, enormous, miniature
beautiful, pretty, cute, adorable, gorgeous, stunning, attractive, charming
happy, sad, angry, surprised, neutral, serious, funny, humorous, serious
new, old, ancient, modern, contemporary, vintage, antique
full, empty, half_full, half_empty
clean, dirty, messy, tidy, organized
bright, dark, light, dim, dull, glowing
clear, blurry, sharp, soft, smooth, rough, hard, soft
dry, wet, damp, moist, humid, arid
hot, cold, warm, cool, mild, freezing
fast, slow, quick, swift, sluggish
high, low, short, tall, wide, narrow, thick, thin, flat
open, closed, locked, unlocked
public, private, personal, common, shared
urban, rural, suburban, countryside
indoor, outdoor, inside, outside
natural, artificial, synthetic, organic, man-made
wild, tame, domestic, domesticated
fresh, stale, rotten, spoiled, raw, cooked
ripe, unripe, mature, immature
sharp, blunt, dull, smooth, rough
```

> **重要**：
> - 同义词展开由服务器完成
> - 复合词需拆分为独立词：`red_clothing` → `["red", "clothing"]`
> - 例如用户搜索"穿红衣服的人"，服务器应返回 `["person", "people", "human", "red", "clothing"]`
> - 完整原始标签列表见 `script/visual-tags.txt`

```swift
private static let systemPrompt = """
    You parse photo search requests for an iOS photo cleaner app.
    Return only valid JSON, no Markdown.
    Schema:
    {
      "summary": "short user-facing summary",
      "mediaTypes": ["image" | "video"],
      "assetTypes": ["screenshot" | "live" | "screen_recording"],
      "dateRange": {"start": "yyyy-MM-dd", "end": "yyyy-MM-dd"},
      "locations": ["place names"],
      "locationBounds": [{"name":"", "minLatitude":0, "maxLatitude":0, "minLongitude":0, "maxLongitude":0}],
      "minSizeMB": 0,
      "maxSizeMB": 0,
      "hasLocation": true,
      "keywords": [],
      "visualTags": ["person", "red_clothing", "blue_clothing", "white_clothing", "black_clothing", "yellow_clothing", "green_clothing", "car", "food", "beach", "dog", "cat", "pet", "building", "sky", "flower", "document"],
      "visualConcepts": [{"name": "concept name in user's language", "matchAny": ["english_vision_label", "synonym"]}],
      "ocrKeywords": [],
      "ocrRegexes": [],
      "sensitiveTypes": ["bank_card", "id_card", "passport", "document"],
      "requiresOCR": false
    }
    Omit unknown fields. Photos never leave the device; use OCR fields for text on images.
    Resolve relative dates like today, yesterday, last year, and last month from the provided Current date.
    If the user says photos, pictures, or images, set mediaTypes to ["image"]. If the user says videos or recordings, set mediaTypes to ["video"].
    Only set hasLocation when the user explicitly asks for photos with location information or without location information. Do not set hasLocation for visual scenes like beach, sea, mountains, or city.
    For visual object searches without an explicit media type, prefer mediaTypes ["image"].
    For open-ended visual requests, return visualConcepts. Each visualConcept represents one required concept; matchAny contains English Vision-style labels and synonyms. Concepts are ANDed together, labels inside matchAny are ORed.
    Example: "catching crabs" should include {"name":"抓螃蟹","matchAny":["crab","shellfish","seafood"]}. Add only concepts that are likely visible in the image.
    For card tail-number queries, set requiresOCR true and use a regex that matches the number inside OCR text, not only at the end of the whole text; for example tail number 124 should use "\\d{0,15}124\\b".
    visualTags must contain only the allowed English enum values from the schema, never Chinese words.
    For people clothing queries, use person plus color_clothing. Do not infer gender as a required tag.
    """
```

相近词参考：
不用大模型返回，自动补充相近词
    private static func visualTagSynonyms(for tag: String) -> Set<String> {
        switch tag {
        case "car", "vehicle", "automobile":
            return ["car", "vehicle", "automobile", "motor_vehicle", "land_vehicle"]
        case "food", "meal", "dish":
            return ["food", "meal", "dish", "cuisine", "plate"]
        case "beach", "sea", "ocean":
            return ["beach", "sea", "ocean", "coast", "shore", "seashore", "water"]
        case "dog":
            return ["dog", "canine"]
        case "cat":
            return ["cat", "feline"]
        case "pet", "animal":
            return ["pet", "animal", "dog", "cat", "canine", "feline"]
        case "person", "people", "human":
            return ["person", "people", "human"]
        case "building", "architecture":
            return ["building", "architecture", "house", "skyscraper"]
        case "flower", "plant":
            return ["flower", "plant", "flora"]
        case "document":
            return ["document", "paper", "receipt", "invoice"]
        default:
            return [tag]
        }
    }
