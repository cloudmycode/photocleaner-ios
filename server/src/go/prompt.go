package main

// LLM 提示词模板（SearchPlan：filters + must）
const PromptTemplate = `Parse photo search intent. Return only JSON, no Markdown.

Query: {query}
Locale: {locale}
Today: {current_date}
Device tags (use only these keys, max 1000): {available_tags}

Schema:
{
  "summary": "",
  "filters": {
    "dateRange": {"start": "YYYY-MM-DD", "end": "YYYY-MM-DD"},
    "locationBounds": [{
      "name": "",
      "minLatitude": 0, "maxLatitude": 0,
      "minLongitude": 0, "maxLongitude": 0
    }],
    "mediaTypes": ["image"],
    "assetTypes": ["screenshot"],
    "minSizeMB": 0,
    "maxSizeMB": 0,
    "hasLocation": true
  },
  "must": {
    "visualTagsAll": [],
    "sensitiveTypes": [],
    "ocrContainsAll": []
  },
  "count": 1000,
  "confidence": 0.8
}

Rules:
- summary: required, in user's language
- filters: metadata only (time, place bounds, mediaTypes, assetTypes screenshot|live|screen_recording, size MB, hasLocation). Omit if unused. Relative dates from Today. hasLocation only for explicit with/without GPS, not scene words.
- must: always include all three arrays ([] if unused)
- visualTagsAll: copy exact strings from Device tags only; as few as possible (often 1). Items are ANDed; device handles synonyms per item — do not list synonyms or split query into words. Example: 猫猫→["cat"]; 海边人物→["beach","person"]; 红衣服的人→["person","red_clothing"] if both exist. Never invent tags.
- sensitiveTypes: id_card|bank_card|passport|document only (not in visualTagsAll). 身份证→id_card. Combine with filters when needed.
- ocrContainsAll: quoted text / card tail digits (AND). e.g. 尾号1234→["1234"] with bank_card.
- count: default 1000; lower only if user asks for N photos.
- No keywords, visualConcepts, should, ocrKeywords, ocrRegexes.

Omit empty fields.`
