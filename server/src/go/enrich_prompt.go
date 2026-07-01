package main

import (
	"encoding/json"
	"strings"
)

const EnrichPromptTemplate = `Enrich photo index from Vision tags and OCR snippet. Return only JSON, no Markdown code fences.

Device locale (fallback only when OCR language is unclear): {locale_fallback_language} ({locale})

Return exactly one item per input asset. Copy assetId verbatim from input.

Schema:
{
  "items": [
    {
      "assetId": "same as input",
      "enrichedTags": ["tag1"],
      "sensitiveTypes": [],
      "searchDescription": "one sentence"
    }
  ]
}

Rules:

1) enrichedTags
- lowercase snake_case English only
- keep ALL input rawTags unchanged
- add 3–15 inferred semantic tags from OCR/object type (e.g. router, modem, onu, wifi, ticket, invoice, packaging, label)
- do NOT put sensitiveTypes values here (no id_card in enrichedTags)

2) sensitiveTypes
- only: id_card | bank_card | passport | document
- set when OCR shows ID numbers, passport numbers, bank card numbers, or formal personal/document content
- leave [] if none apply

3) searchDescription — language (per item)
- Detect the primary language from ocrSnippet script and vocabulary for EACH item independently.
- Write the whole sentence in that detected language.
- Supported languages (detect and write natively): English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, Italian, Portuguese, Russian, Arabic, Hindi, Thai, Vietnamese, Indonesian, Turkish, Polish, Dutch, Malay.
- Mixed OCR: use the dominant language for sentence grammar; keep brand names, SSIDs, URLs, codes, and proper nouns in their original script inside the sentence.
- If ocrSnippet is empty or only numbers/symbols: fall back to device locale language above.
- purpose: client substring search — pack many concrete keywords, not marketing prose
- must include: object/document type + purpose/use + key field labels from OCR
- preserve important OCR literals as readable phrases: brand, model, SSID, IP, URL, account/password labels, names, numbers, flight codes
- do NOT summarize away searchable words; do NOT use "..." or omit router/account/password info present in ocrSnippet
- do NOT invent facts absent from rawTags/ocrSnippet
- no uncertainty words: 可能, 大概, 推测, maybe, probably

searchDescription examples (keyword-dense; language follows OCR):

Input ocrSnippet: 产品型号 ZXHN G7715V5 XG-PON ONU WiFi 7 无线名称 MyHome-5G 登录密码 管理地址 192.168.1.1
Output: 中兴 ZXHN G7715V5 XG-PON 光猫路由器标签照片，包含产品型号、WiFi 7 无线网络、无线名称 MyHome-5G、登录密码和管理地址 192.168.1.1 等宽带账号信息。

Input ocrSnippet: Model ZXHN G7715V5 XG-PON ONU WiFi 7 SSID MyHome-5G Password Admin URL 192.168.1.1
Output: ZTE ZXHN G7715V5 XG-PON modem router label photo with model, WiFi 7 wireless network, SSID MyHome-5G, admin password and management URL 192.168.1.1.

Input ocrSnippet: 氏名 田中太郎 旅券番号 TR1234567 日本国パスポート
Output: 日本国パスポートの写真で、氏名田中太郎、旅券番号 TR1234567 などの旅券情報が含まれます。

Input ocrSnippet: Nombre Juan Pérez DNI 12345678A Pasaporte español
Output: Foto de pasaporte español con nombre Juan Pérez, DNI 12345678A y datos del documento de viaje.

Input JSON:
{items_json}`

func renderEnrichPrompt(locale string, items []EnrichItem) string {
	payload, _ := json.Marshal(map[string]interface{}{"items": items})
	t := EnrichPromptTemplate
	t = replaceAll(t, "{locale}", locale)
	t = replaceAll(t, "{locale_fallback_language}", localeFallbackLanguage(locale))
	t = replaceAll(t, "{items_json}", string(payload))
	return t
}

// localeFallbackLanguage maps device locale to a natural language name when OCR is ambiguous.
func localeFallbackLanguage(locale string) string {
	lower := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(locale), "-", "_"))
	prefix := lower
	if idx := strings.IndexAny(lower, "_"); idx > 0 {
		prefix = lower[:idx]
	}

	switch {
	case strings.HasPrefix(lower, "zh_hant"), strings.HasPrefix(lower, "zh_tw"), strings.HasPrefix(lower, "zh_hk"), strings.HasPrefix(lower, "zh_mo"):
		return "Traditional Chinese"
	case strings.HasPrefix(lower, "zh"):
		return "Simplified Chinese"
	case strings.HasPrefix(prefix, "ja"):
		return "Japanese"
	case strings.HasPrefix(prefix, "ko"):
		return "Korean"
	case strings.HasPrefix(prefix, "en"):
		return "English"
	case strings.HasPrefix(prefix, "es"):
		return "Spanish"
	case strings.HasPrefix(prefix, "fr"):
		return "French"
	case strings.HasPrefix(prefix, "de"):
		return "German"
	case strings.HasPrefix(prefix, "it"):
		return "Italian"
	case strings.HasPrefix(prefix, "pt"):
		return "Portuguese"
	case strings.HasPrefix(prefix, "ru"):
		return "Russian"
	case strings.HasPrefix(prefix, "ar"):
		return "Arabic"
	case strings.HasPrefix(prefix, "hi"):
		return "Hindi"
	case strings.HasPrefix(prefix, "th"):
		return "Thai"
	case strings.HasPrefix(prefix, "vi"):
		return "Vietnamese"
	case strings.HasPrefix(prefix, "id"), strings.HasPrefix(prefix, "in"):
		return "Indonesian"
	case strings.HasPrefix(prefix, "tr"):
		return "Turkish"
	case strings.HasPrefix(prefix, "pl"):
		return "Polish"
	case strings.HasPrefix(prefix, "nl"):
		return "Dutch"
	case strings.HasPrefix(prefix, "ms"):
		return "Malay"
	case strings.HasPrefix(prefix, "sv"):
		return "Swedish"
	case strings.HasPrefix(prefix, "nb"), strings.HasPrefix(prefix, "no"):
		return "Norwegian"
	case strings.HasPrefix(prefix, "da"):
		return "Danish"
	case strings.HasPrefix(prefix, "fi"):
		return "Finnish"
	case strings.HasPrefix(prefix, "cs"):
		return "Czech"
	case strings.HasPrefix(prefix, "hu"):
		return "Hungarian"
	case strings.HasPrefix(prefix, "ro"):
		return "Romanian"
	case strings.HasPrefix(prefix, "uk"):
		return "Ukrainian"
	case strings.HasPrefix(prefix, "he"), strings.HasPrefix(prefix, "iw"):
		return "Hebrew"
	case strings.HasPrefix(prefix, "el"):
		return "Greek"
	default:
		if locale == "" {
			return "English"
		}
		return "the device locale language"
	}
}
