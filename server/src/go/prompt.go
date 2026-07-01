package main

// LLM 提示词模板（SearchPlan：filters + must）
const PromptTemplate = `Parse photo search intent. Return only JSON, no Markdown.

Query: {query}
Locale: {locale}
Today: {current_date}
Device tags (ONLY for visualTagsAll; max 1000): {available_tags}

Schema:
{
  "summary": "",
  "filters": { ... },
  "must": {
    "searchKeywordGroups": [],
    "visualTagsAll": [],
    "sensitiveTypes": [],
    "ocrContainsAll": []
  },
  "count": 1000,
  "confidence": 0.8
}

Rules:
- summary: required, short, in the user's language.
- filters: metadata only (time, place, mediaTypes, assetTypes, size MB, hasLocation). Omit if unused.
- must: always include all four arrays ([] if unused).

SEARCH MODE (pick ONE primary path):

A) searchKeywordGroups — DEFAULT for objects, devices, text on labels, brands, accounts, passwords, documents, receipts, specific words.
   * Each inner array = one concept; OR inside group, AND across groups.
   * ALWAYS copy the user's exact query words into the first group (verbatim, same characters).
   * Then add true synonyms / translations only (same meaning). Never substitute a different word that merely shares a character.
   * Chinese: 卡车 (truck) ≠ 卡钳 (caliper). Do NOT confuse similar-looking or same-first-character words.
   * Client matches against per-photo searchDescription (substring match).
   * Examples:
     - 路由器账号 → [["路由器","router","无线路由","wifi"],["账号","账户","account","用户名","登录"]]
     - 汽车 → [["汽车","轿车","车辆","car","automobile","vehicle"]]
     - 卡车 → [["卡车","货车","重型卡车","lorry","truck","pickup"]]
     - 身份证 → sensitiveTypes ["id_card"] + searchKeywordGroups [["身份证","id card","证件"]]
   * If user mentions quoted text or numbers, also add ocrContainsAll.
   * When using searchKeywordGroups, set visualTagsAll: [] unless user ALSO needs a pure visual constraint (e.g. 海边 + 路由器文案).

B) visualTagsAll — ONLY for pure scene/appearance WITHOUT specific text/objects (海边, 红衣服, 猫, 狗).
   * Copy EXACT strings from Device tags only. One tag per concept. Never invent.
   * If no Device tag fits, return visualTagsAll: [] — do NOT fallback to person/clothing.

C) sensitiveTypes — id_card|bank_card|passport|document for证件/票据.

STRICT:
- NEVER drop or replace the user's query wording with a different Chinese word.
- NEVER use person/people/human/clothing as fallback for object/text queries.
- If nothing matches, return searchKeywordGroups: [] AND visualTagsAll: [] (empty results).
- Do not use both searchKeywordGroups and visualTagsAll unless user clearly combines scene + object.

Omit empty fields.`
