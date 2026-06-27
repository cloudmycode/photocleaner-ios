# 智能搜索实现方案

> 新 App，不考虑旧版兼容。  
> **隐私**：照片、索引、OCR 全文只在手机上；每次搜索只上传「用户文字 + 本机 visualTags 列表」。

---

## 一、核心结论（先读这段）

1. **索引**：每张照片一条**正排档案** + 内存里两张**倒排表**（visual tag、sensitive type → 照片 ID 集合）。
2. **搜索**：每次调**大模型**得到 SearchPlan；本地用倒排做 **ID 集合交集**，再对交集里的 ID 验 **filters（元数据）**，最后按时间取前 N 张。
3. **不用 should 打分**：符合 = 在交集中且通过 filters；排序默认**拍摄时间**。
4. **倒排增量维护**：新/改图 patch 倒排；删图在 `rebuildMetadata` 时主动清理；冷启动可从 `index.json` **一次性重建内存倒排**（不是重新 Vision 全库）。

---

## 二、三类条件（不要混）

| 类型 | SearchPlan 字段 | 数据从哪来 | 检索方式 |
|------|-----------------|------------|----------|
| **元数据 filters** | `filters` | 正排档案：时间、GPS、大小、截图… | 对候选 **id 查 entry** 判断 |
| **视觉 tag** | `must.visualTagsAll` | L1 Vision；词表随本机相册变化 | **tagPostings** 倒排，组间 **交集** |
| **敏感类型** | `must.sensitiveTypes` | L3 规则；**固定 4 个枚举** | **sensitivePostings** 倒排，再与 tag **交集** |

**不要**把 `id_card` 放进 `filters`——它是内容分类，不是文件属性。  
**不要**把 `sensitiveTypes` 放进 `availableTags`——枚举写死在服务端 prompt 里即可。

固定敏感枚举：`id_card` | `bank_card` | `passport` | `document`

---

## 三、App 启动后：索引（L0～L3）

```
授权相册
    │
    ▼
L0 元数据 ──→ 时间、GPS、大小、mediaType、assetTypes
    │
    ▼
L1 视觉标签 ──→ visualTags（Apple Vision + 人物/颜色）
    │
    ▼
L2 OCR（按需）──→ 像 document 的图做 accurate OCR → ocrText
    │
    ▼
L3 敏感类型 ──→ sensitiveTypes（id_card 等）
    │
    ▼
写入 index.json（正排）
    │
    ▼
增量 patch 倒排表（tagPostings / sensitivePostings）
```

### 正排：一张照片的档案

```json
{
  "id": "相册唯一 ID",
  "creationDate": "2022-10-23",
  "latitude": 39.97,
  "longitude": 116.36,
  "mediaType": "image",
  "assetTypes": ["screenshot"],
  "storageBytes": 6453363,
  "visualTags": ["person", "beach"],
  "ocrText": "某某市居民身份证……",
  "sensitiveTypes": ["id_card"]
}
```

### 倒排：两张表（仅内存，可不落盘）

```
tagPostings:
  person  → { id1, id3, id9, … }
  beach   → { id1, id5, id9, … }

sensitivePostings:
  id_card    → { id2, id15, … }
  bank_card  → { … }
```

### 倒排何时更新（惰性 / 增量）

| 事件 | 操作 |
|------|------|
| 新图索引完成 | 向相关 posting **insert(id)** |
| 图 tags / sensitive 变了 | **remove(id, 旧)** + **insert(id, 新)** |
| 相册删图（`rebuildMetadata`） | 从所有 posting **remove(id)** |
| App 冷启动 | 读 `index.json`；内存倒排为空时 **buildFrom(entries)** 一次 |

- **不需要**每次启动对相册全量重新 Vision。  
- **不需要**为 filters 建倒排表。  
- **不要**只靠「展示时发现图不存在」再删倒排（可作兜底，不能当主路径）。

当前代码：`rebuildMetadata` + `indexSearchImagesIfNeeded` 已对正排做增量；**倒排表与 sensitivePostings 待实现**。

---

## 四、用户搜索时

```
用户输入 / 语音转文字
        │
        ▼
① topVisualTags(1000)  → availableTags（本机全量去重，最多 1000）
        │
        ▼
② POST /smart-search（必联网）
   上传：query + availableTags + sign
   不上传：照片、档案、OCR 全文
        │
        ▼
③ 大模型返回 SearchPlan
        │
        ▼
④ 本地 SearchEngine：倒排交集 → filters → 按时间取前 count 张
        │
        ▼
    展示
```

---

## 五、API

### 5.1 请求（每次搜索）

```json
{
  "query": "去年在海南拍的海边人物照",
  "locale": "zh-Hans_CN",
  "appVersion": "1.0.0",
  "buildVersion": "26",
  "availableTags": ["person", "beach", "document", "car"],
  "sign": "md5(query + 密钥)"
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `query` | 是 | 用户原文 |
| `availableTags` | **是** | 本机 visualTags 全量去重，按频次排序，**最多 1000**（不足则全传） |
| `sign` | 是 | `MD5(query + serverSecret)` |

`availableTags` 搜索时从倒排/正排当场统计，不单独存文件。

### 5.2 响应 SearchPlan

```json
{
  "summary": "去年海南海边人物照",
  "filters": {
    "dateRange": { "start": "2025-01-01", "end": "2025-12-31" },
    "locationBounds": [{
      "name": "海南",
      "minLatitude": 18.0, "maxLatitude": 20.0,
      "minLongitude": 108.0, "maxLongitude": 111.0
    }],
    "mediaTypes": ["image"]
  },
  "must": {
    "visualTagsAll": ["beach", "person"],
    "sensitiveTypes": [],
    "ocrContainsAll": []
  },
  "count": 1000
}
```

| 字段 | 含义 |
|------|------|
| `filters` | **仅元数据**：时间、地点、媒体类型、大小、像素… |
| `must.visualTagsAll` | 每个 tag 一组倒排，**组内同义词并集，组间交集** |
| `must.sensitiveTypes` | 敏感倒排组，与 visual 组同样 **交集** |
| `must.ocrContainsAll` | 候选很少时，逐张查 `ocrText` 是否包含 |
| `count` | 最多返回张数，默认 1000 |

**不使用 `should`**：不做「满足越多分越高」；交集 + filters 即最终结果，按 `creationDate` 降序截断。

大模型 prompt 要点：

- `must.visualTagsAll` 每项必须是 `availableTags` 里的**原样字符串**（倒排 key）；优先**最少 tag**（常只需 1 个）；仅当用户明确要两个独立条件且词表里有两个对应 tag 时才 AND 两项；同义词由客户端组内扩展，模型禁止拆词、禁止列近义词
- 证件类 → `must.sensitiveTypes`（枚举见第三节），不进 `visualTagsAll` / `filters`
- 相对时间 → `filters.dateRange`

---

## 六、本地检索算法（核心）

### 6.1 集合定义

```
T = visual tag 组交集（见 6.2）
S = sensitiveTypes 组交集（若有）
O = ocrContainsAll 过滤后的 ID（若有，候选少时扫描）

TagCandidates = T ∩ S ∩ O   （无 tag/sensitive 时 TagCandidates = 全已索引 ID）

F = { id | entry(id) 满足 filters }   （扫正排或只对 TagCandidates 逐张验）

结果 IDs = TagCandidates ∩ F
```

**tag 先还是 filters 先？** 结果相同，都是 **TagCandidates ∩ F**：

| 路径 | 做法 |
|------|------|
| tag 先 | 倒排求交 → 对每个候选 id 验 filters |
| filters 先 | 扫正排得 F → 与倒排交集 `T ∩ F` |

**filters 先不需要重建倒排表**——filters 查的是正排 `entry`，不是第二张倒排。

### 6.2 visualTagsAll：组内 OR，组间 AND

```
must.visualTagsAll: ["beach", "person"]

beach 组 = tagPostings[beach] ∪ tagPostings[shore] ∪ …   // VisualSynonyms 扩展
person 组 = tagPostings[person] ∪ tagPostings[people] ∪ …

T = beach组 ∩ person组
```

例：`beach → {id1,id5,id9}`，`person → {id1,id3,id9}` → **T = {id1}**

### 6.3 sensitiveTypes

```
must.sensitiveTypes: ["id_card"]
  → S = sensitivePostings["id_card"]
```

与 visual 组一起做 **T ∩ S**。仅搜证件时 often 只有 S 一组。

### 6.4 filters（元数据）

对**交集中的每个 id** 查正排档案（不是全有或全无）：

- `id1` 在 T 里但不符合去年 → 丢弃  
- `id9` 在 T 里且符合 → 保留  

### 6.5 排序与截断

```
结果按 creationDate 降序
取前 count 张（默认 1000）
```

### 6.6 流程图

```
SearchPlan
    │
    ├─ must.visualTagsAll? → 同义词扩展 → 组内∪ → 组间∩ ─┐
    ├─ must.sensitiveTypes? → sensitivePostings ∩ ─────┤→ TagCandidates
    ├─ must.ocrContainsAll? → 候选上逐张 OCR 包含 ─────┘
    │
    ├─ filters? → 对 TagCandidates 逐张验元数据 → ∩ F
    │
    └─ 按时间排序 → 取前 count → PHAsset 展示
```

仅 `filters`、无 must：TagCandidates = 全部已索引 ID → 只验 filters → 按时间取前 N。

---

## 七、完整例子

### 例子 A：搜「身份证」

**索引**：L2 OCR + L3 → `sensitiveTypes: ["id_card"]` → `sensitivePostings["id_card"].insert(id2)`

**搜索**：

1. `availableTags` + `query:"身份证"` → 大模型  
2. `must.sensitiveTypes: ["id_card"]`  
3. `TagCandidates = sensitivePostings["id_card"]`  
4. 无 filters → 按时间展示  

### 例子 B：搜「去年海南海边人物」

1. 大模型返回 `filters`（去年、海南）+ `must.visualTagsAll: ["beach","person"]`  
2. `T = beach组 ∩ person组`，例如 `{id1, id9}`  
3. 对 id1、id9 验 filters → 假设只剩 `{id9}`  
4. 按时间展示  

### 例子 C：只有 filters「大于 5M 的视频」

1. 无 must → TagCandidates = 全部已索引 ID  
2. filters 筛 `mediaType=video` 且 `storageBytes`  
3. 按时间取前 count  

---

## 八、数据结构（PhotoSearchIndexStore）

| 结构 | 说明 |
|------|------|
| `entries: [String: PhotoSearchIndexEntry]` | 正排，持久化 `index.json` |
| `tagPostings: [String: Set<String>]` | visual 倒排，内存，可冷启动重建 |
| `sensitivePostings: [String: Set<String>]` | 敏感倒排，固定少量 key |

```text
// 索引更新时（增量）
func patchPostings(photoId: String, oldEntry: Entry?, newEntry: Entry) {
  从 oldEntry 的 visualTags / sensitiveTypes 对应 posting 中 remove(photoId)
  向 newEntry 的 tags / sensitiveTypes 对应 posting 中 insert(photoId)
}

func removeFromAllPostings(photoId: String) { … }

func buildPostingsFromEntries() { 遍历 entries 重建两张倒排 }
```

`topVisualTags(limit: 1000)`：按 `tagPostings` 集合大小（文档频次）排序取 key；**已实现**（当前从 entries 统计，待改为读倒排计数）。

---

## 九、代码模块

| 模块 | 文件 | 状态 | 职责 |
|------|------|------|------|
| 正排 + 倒排 | `SimilarAnalysisCache.swift` | 部分 | 档案、`topVisualTags`；**待加 postings** |
| 扫图 L0～L3 | `PhotoLibraryService.swift` | 部分 | 索引流水线 |
| 敏感检测 | `SensitiveTypeDetector.swift` | 待建 | L3 |
| 同义词 | `VisualSynonyms.swift` | 待建 | 倒排查询前扩展 |
| API | `SmartSearchClient.swift` | 已有 | 必带 `availableTags` |
| 检索 | `SearchEngine.swift` | 待建 | 交集 + filters + 时间排序 |
| 串联 | `SmartSearchService.swift` | 部分 | tags → API → engine |
| UI | `PhotoPreview.swift` | 已有 | 搜索界面 |
| Prompt | `server/src/go/prompt.go` | 已有 | 注入 `availableTags`、敏感枚举 |

无 `QueryRouter`；无 `should` 打分逻辑。

---

## 十、开发步骤

| 步骤 | 任务 | 验收 |
|------|------|------|
| **1** | 正排 L0+L1：`index.json`、增量 `rebuildMetadata`、`indexSearchImagesIfNeeded` | 档案含 visualTags |
| **2** | 内存倒排：`tagPostings` 增量 patch + 冷启动 `buildFrom(entries)` | 倒排与档案一致 |
| **3** | `topVisualTags(1000)` + `SmartSearchClient` 必传 `availableTags` | 请求体正确 |
| **4** | 服务端 prompt：SearchPlan 结构、敏感枚举、`availableTags` 约束 | 返回可解析 JSON |
| **5** | L2 accurate OCR + L3 `SensitiveTypeDetector` + `sensitivePostings` | 身份证写入敏感倒排 |
| **6** | `SearchEngine`：组内∪组间∩ → filters 验正排 → 时间排序 | 交集检索正确 |
| **7** | `VisualSynonyms` 接入倒排查询 | 海边/人等同义词 |
| **8** | 索引进度 UI、Debug 日志（SearchPlan + 交集 ID 数） | 可排错 |

建议顺序：**1 → 2 → 3 → 4 → 6**（先打通视觉 tag 交集搜索）→ **5 → 7** → **8**。

---

## 十一、一张图总结

```
┌──────────── App 启动 / 后台索引 ────────────┐
│  正排 index.json（增量，不每次全量 Vision）    │
│  倒排 tagPostings / sensitivePostings（增量） │
└────────────────────────────────────────────┘
                      │
                      ▼
┌──────────── 用户搜索 ────────────────────────┐
│  availableTags(≤1000) + query → 大模型       │
│  SearchPlan                                   │
│  倒排多组 ID → 组间交集 → 验 filters(正排)     │
│  按时间取前 N → 展示（照片不出手机）            │
└────────────────────────────────────────────┘
```

**记住**：

- **云**：听懂话，返回 filters + must（tags / sensitiveTypes）。  
- **机**：倒排求 **ID 交集** 是真检索；filters 查正排；**不算 should 分**。

---

## 附录：与调试导出

- `smart-search-index-*.json`：正排全量导出，调试用。  
- `visual-tags.txt`：从导出 JSON 排重 visualTags，**非运行时配置**。  
- 其他用户相册不同 → 各自 `availableTags` 与倒排内容不同，无需用户维护词表。
