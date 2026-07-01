以下是根据前述方案整理的技术文档，可直接保存为 .md 文件。

```markdown
# iPhone 基于 Vision 标签的自然语言照片搜索方案

## 概述
利用 iPhone 本地 Vision 框架已提取的照片标签（如汽车、衣服、人物等），结合时间与地理位置元数据，实现“去年在南海抓螃蟹的照片”这类自然语言查询，从标签中筛选最接近的照片。全部处理在设备端完成，保护用户隐私。

---

## 1. 数据准备（离线阶段）
每张照片预先提取并存储三类信息，构建结构化索引。

### 1.1 Vision 标签
- 使用 `VNClassifyImageRequest` 获取标签与置信度，保留 Top-K（如 10 个）。
- 存储为 `标签:置信度` 字典，同时维护中英文映射表（例如 `crab → 螃蟹`）。
- 支持全文搜索，可导入 SQLite FTS5。

### 1.2 时间元数据
- 使用 `PHAsset.creationDate`，精确到秒，存入数据库支持区间查询。

### 1.3 地理位置
- 通过 `PHAsset.location` 获取经纬度。
- 使用 `CLGeocoder` 反向地理编码，解析出国家、省、市、水域等结构化地址。
- 关键自然实体（如“南海”）单独标记，并存储经纬度用于空间范围过滤。
- 可选：为常见大区域预置地理围栏（边界框）。

### 1.4 索引存储
建议使用 SQLite 表：
```sql
CREATE TABLE photos (
    id TEXT PRIMARY KEY,
    creation_date REAL,
    latitude REAL,
    longitude REAL,
    address_json TEXT,
    tags_json TEXT
);
CREATE INDEX idx_date ON photos(creation_date);
CREATE INDEX idx_location ON photos(latitude, longitude);
-- FTS5 全文索引用于标签和地址搜索
CREATE VIRTUAL TABLE photos_fts USING fts5(tags, address);
```

---

2. 查询理解（在线阶段）

输入：“去年在南海抓螃蟹的照片”

2.1 时间提取

· 利用 NSDataDetector 或 NLTagger 提取时间表达式。
· “去年” → 当前年份减一，时间范围 [2025-01-01, 2025-12-31]（以2026年为例）。
· 支持更精细表达（如“去年夏天”）。

2.2 地点提取

· 使用 NLTagger 识别地名（NSLinguisticTagPlaceName）或自定义词典。
· “南海” → 可能指南中国海，通过预置地理围栏（纬度 3.5~22.5，经度 105~122）或地址关键字“南海”匹配。
· 模糊地点同时启用经纬度范围与地址字符串匹配，加权计分。

2.3 事件/物体提取

· “抓螃蟹”中“抓”是动作（Vision 不识别动作），“螃蟹”是核心名词。
· 将“螃蟹”映射到 Vision 标签：螃蟹 → crab，并关联上位词（如 shellfish）。
· 若无直接映射，后续用语义嵌入模型兜底。

解析结果示例：

```
时间：2025年
地点：南海（地理围栏 + 关键字）
目标概念：螃蟹(crab)，关联场景(seashore, beach)
```

---

3. 候选照片筛选

利用结构化条件快速缩小候选集，避免全量语义计算。

```sql
SELECT * FROM photos
WHERE creation_date BETWEEN '2025-01-01' AND '2025-12-31'
AND (latitude BETWEEN 3.5 AND 22.5 AND longitude BETWEEN 105 AND 122)
   OR address_json LIKE '%南海%';
```

候选集通常可缩减至数百到数千张，适合实时处理。

---

4. 语义匹配与排序

在候选集上计算多维度相似度，加权排序。

4.1 标签精确匹配

· 检查标签中是否包含目标词映射后的英文标签（如 crab）。
· 精确命中得满分，关联词命中得部分分。
· 可结合置信度加权。

4.2 文本嵌入语义匹配

· 将照片的标签拼接为文档："crab seashore person net outdoor"
· 查询文本："抓螃蟹 beach seashore"
· 使用多语言 Sentence Transformer 模型（如 paraphrase-multilingual-MiniLM-L12-v2）转为 Core ML 模型（≈50MB），计算余弦相似度。
· 跨语言嵌入使“螃蟹”和“crab”向量相近，泛化能力强。

4.3 时间与地点衰减

· 时间得分：照片时间在查询时间区间内得满分，偏离则高斯衰减。
· 地点得分：根据照片坐标与查询地点中心的球面距离，高斯衰减或线性衰减。

4.4 最终排序公式

```
score = w1 × tag_hit + w2 × semantic_sim + w3 × time_score + w4 × location_score
```

推荐权重：w1=0.4, w2=0.3, w3=0.15, w4=0.15，可调整。

取 Top-20 结果返回。

---

5. 完整处理流程

```
用户输入: "去年在南海抓螃蟹的照片"
        │
        ▼
┌──────────────────┐
│   查询解析       │
│ - 时间: 2025年   │
│ - 地点: 南海     │
│ - 概念: 螃蟹     │
└────────┬─────────┘
        ▼
┌──────────────────┐
│ 结构化过滤 (SQL) │ → 时间、地理围栏、地址关键字
│ 候选集约1500张   │
└────────┬─────────┘
        ▼
┌──────────────────┐
│ 语义匹配 + 排序  │
│ - 标签精确命中   │
│ - 跨语言文本嵌入 │
│ - 时空衰减       │
│ → 加权得分排序   │
└────────┬─────────┘
        ▼
    返回最匹配照片
```

---

6. 工程实现建议

· 标签映射：维护一个数百常用词的中英文映射表（可社区贡献），未覆盖词由嵌入模型兜底。
· 地理围栏：对常见大范围地名预存边界框或多边形；动态地名使用 MapKit 地理编码获取坐标范围。
· 模型部署：多语言嵌入模型转为 Core ML，控制在 50MB 以下，首次加载后常驻内存。
· 性能优化：利用 BackgroundTasks 后台更新新照片的标签和索引；候选集控制在 5000 以内，A12+ 芯片上语义匹配耗时<100ms。
· 隐私：所有数据与计算均在设备端，不上传云端。

---

7. 核心代码思路 (Swift 伪代码)

```swift
// 1. 解析查询
let query = "去年在南海抓螃蟹的照片"
let timeRange = parseTime(from: query)          // DateInterval
let locationFilter = parseLocation(from: query) // (region, keyword)
let concept = "螃蟹" // 核心名词

// 2. 数据库过滤
let candidates = database.photos
    .filter { timeRange.contains($0.creationDate) }
    .filter { locationFilter.contains($0.coordinate) }

// 3. 计算嵌入向量
let queryEmbedding = embeddingModel.vector(for: "抓螃蟹 beach seashore")
let photoVectors = candidates.map { asset in
    let tagsText = asset.tags.joined(separator: " ")
    return embeddingModel.vector(for: tagsText)
}

// 4. 加权评分
let scored = zip(candidates, photoVectors).map { asset, vec in
    let semanticSim = cosineSimilarity(queryEmbedding, vec)
    let tagHit = asset.tags.contains("crab") ? 1.0 : 0.0
    let timeScore = gaussianDecay(asset.date, center: timeRange.middle, ...)
    let locationScore = distanceDecay(asset.coordinate, center: locationFilter.center)
    let total = 0.4*tagHit + 0.3*semanticSim + 0.15*timeScore + 0.15*locationScore
    return (asset, total)
}

// 5. 排序并返回 Top-20
let results = scored.sorted(by: { $0.1 > $1.1 }).prefix(20)
```

---

8. 总结

通过 结构化元数据快速过滤 + 同义词映射 + 跨语言语义嵌入 的组合，可以低成本地将 Vision 生成的离散标签转化为支持自然语言查询的搜索引擎。即使 Vision 不识别动作，也能通过物体、场景和时空上下文准确匹配出“去年在南海抓螃蟹”的回忆。

```
```