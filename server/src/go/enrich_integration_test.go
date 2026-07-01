//go:build integration

package main

import (
	"os"
	"strings"
	"testing"
)

func TestEnrichPromptLLM(t *testing.T) {
	cfg := enrichTestConfig(t)
	client := newEnrichTestClient(cfg)

	cases := []struct {
		name   string
		locale string
		item   EnrichItem
		check  func(t *testing.T, got EnrichResultItem, raw rawEnrichLLMItem, input EnrichItem)
	}{
		{
			name:   "chinese_modem_router_label",
			locale: "zh_CN",
			item: EnrichItem{
				AssetID:    "asset-modem-zh",
				RawTags:    []string{"text", "indoor"},
				OCRSnippet: "产品型号 ZXHN G7715V5 XG-PON ONU WiFi 7 无线名称 MyHome-5G 登录密码 admin 管理地址 192.168.1.1",
				MediaType:  "image",
				AssetTypes: []string{"screenshot"},
			},
			check: func(t *testing.T, got EnrichResultItem, raw rawEnrichLLMItem, input EnrichItem) {
				t.Helper()
				assertAssetID(t, got, input.AssetID)
				desc := strings.ToLower(got.SearchDescription)
				assertContainsAny(t, desc, []string{"光猫", "路由器", "modem", "router", "onu"})
				assertContainsAll(t, desc, []string{"zxhn", "g7715v5", "wifi", "192.168.1.1"})
				assertContainsAny(t, desc, []string{"密码", "password", "admin"})
				assertContainsAny(t, desc, []string{"myhome-5g", "无线", "ssid"})
				assertNoUncertainty(t, got.SearchDescription)
				assertRawTagsPreserved(t, raw.enrichedTags, input.RawTags)
				preferNoSensitiveInEnrichedTags(t, raw.enrichedTags, raw.sensitiveTypes)
				assertTagsNormalized(t, normalizeTagList(raw.enrichedTags))
			},
		},
		{
			name:   "english_router_label",
			locale: "en_US",
			item: EnrichItem{
				AssetID:    "asset-router-en",
				RawTags:    []string{"text", "closeup"},
				OCRSnippet: "Model ZXHN G7715V5 XG-PON ONU WiFi 7 SSID MyHome-5G Password admin URL 192.168.1.1",
				MediaType:  "image",
				AssetTypes: []string{},
			},
			check: func(t *testing.T, got EnrichResultItem, raw rawEnrichLLMItem, input EnrichItem) {
				t.Helper()
				assertAssetID(t, got, input.AssetID)
				desc := strings.ToLower(got.SearchDescription)
				assertContainsAny(t, desc, []string{"router", "modem", "onu", "label"})
				assertContainsAll(t, desc, []string{"zxhn", "g7715v5", "wifi", "192.168.1.1", "myhome-5g"})
				assertContainsAny(t, desc, []string{"password", "admin", "url"})
				assertNoUncertainty(t, got.SearchDescription)
				assertRawTagsPreserved(t, raw.enrichedTags, input.RawTags)
			},
		},
		{
			name:   "chinese_id_card",
			locale: "zh_CN",
			item: EnrichItem{
				AssetID:    "asset-idcard-zh",
				RawTags:    []string{"document", "text"},
				OCRSnippet: "姓名 张三 性别 男 民族 汉 出生 1990年1月1日 住址 北京市朝阳区 公民身份号码 110101199001011234",
				MediaType:  "image",
				AssetTypes: []string{},
			},
			check: func(t *testing.T, got EnrichResultItem, raw rawEnrichLLMItem, input EnrichItem) {
				t.Helper()
				assertAssetID(t, got, input.AssetID)
				desc := got.SearchDescription
				assertContainsAny(t, desc, []string{"身份证", "身份證", "居民身份证", "身份证件"})
				assertContainsAll(t, desc, []string{"张三", "110101199001011234"})
				assertSensitiveTypes(t, got.SensitiveTypes, []string{"id_card"})
				preferNoSensitiveInEnrichedTags(t, raw.enrichedTags, raw.sensitiveTypes)
				assertNoUncertainty(t, desc)
			},
		},
		{
			name:   "japanese_passport",
			locale: "ja_JP",
			item: EnrichItem{
				AssetID:    "asset-passport-ja",
				RawTags:    []string{"document"},
				OCRSnippet: "氏名 田中太郎 旅券番号 TR1234567 日本国パスポート",
				MediaType:  "image",
				AssetTypes: []string{},
			},
			check: func(t *testing.T, got EnrichResultItem, raw rawEnrichLLMItem, input EnrichItem) {
				t.Helper()
				assertAssetID(t, got, input.AssetID)
				desc := got.SearchDescription
				assertContainsAny(t, desc, []string{"パスポート", "旅券"})
				assertContainsAll(t, desc, []string{"田中太郎", "TR1234567"})
				assertSensitiveTypes(t, got.SensitiveTypes, []string{"passport"})
				preferNoSensitiveInEnrichedTags(t, raw.enrichedTags, raw.sensitiveTypes)
				assertNoUncertainty(t, desc)
			},
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			prompt := renderEnrichPrompt(tc.locale, []EnrichItem{tc.item})
			raw, err := client.ParseQuery(prompt)
			if err != nil {
				t.Fatalf("ParseQuery: %v", err)
			}

			response := normalizeEnrichResponse(raw, []EnrichItem{tc.item})
			if len(response.Items) != 1 {
				t.Fatalf("expected 1 item, got %d", len(response.Items))
			}

			got := response.Items[0]
			rawItem := firstRawEnrichItem(t, raw, tc.item.AssetID)
			t.Logf("searchDescription: %s", got.SearchDescription)
			t.Logf("enrichedTags (normalized): %v", got.EnrichedTags)
			t.Logf("enrichedTags (raw LLM): %v", rawItem.enrichedTags)
			t.Logf("sensitiveTypes: %v", got.SensitiveTypes)

			if strings.TrimSpace(got.SearchDescription) == "" {
				t.Fatal("searchDescription is empty")
			}
			tc.check(t, got, rawItem, tc.item)
		})
	}
}

type rawEnrichLLMItem struct {
	enrichedTags      []string
	sensitiveTypes    []string
	searchDescription string
}

func firstRawEnrichItem(t *testing.T, raw map[string]interface{}, assetID string) rawEnrichLLMItem {
	t.Helper()
	itemsRaw, ok := raw["items"].([]interface{})
	if !ok || len(itemsRaw) == 0 {
		t.Fatal("raw response missing items array")
	}
	for _, entry := range itemsRaw {
		obj, ok := entry.(map[string]interface{})
		if !ok {
			continue
		}
		id, _ := obj["assetId"].(string)
		if id != assetID {
			continue
		}
		return rawEnrichLLMItem{
			enrichedTags:      interfaceToStringSlice(obj["enrichedTags"]),
			sensitiveTypes:    interfaceToStringSlice(obj["sensitiveTypes"]),
			searchDescription: stringFromInterface(obj["searchDescription"]),
		}
	}
	t.Fatalf("raw response missing assetId %q", assetID)
	return rawEnrichLLMItem{}
}

func enrichTestConfig(t *testing.T) *Config {
	t.Helper()
	cfg := DefaultConfig()
	if key := strings.TrimSpace(os.Getenv("DEEPSEEK_API_KEY")); key != "" {
		cfg.DeepSeekAPIKey = key
	}
	if base := strings.TrimSpace(os.Getenv("DEEPSEEK_BASE_URL")); base != "" {
		cfg.DeepSeekBaseURL = base
	}
	if model := strings.TrimSpace(os.Getenv("DEEPSEEK_MODEL")); model != "" {
		cfg.DeepSeekModel = model
	}
	if cfg.DeepSeekAPIKey == "" || cfg.DeepSeekAPIKey == "your-deepseek-api-key" {
		t.Skip("set DEEPSEEK_API_KEY to run integration test")
	}
	return cfg
}

func assertAssetID(t *testing.T, got EnrichResultItem, want string) {
	t.Helper()
	if got.AssetID != want {
		t.Fatalf("assetId = %q, want %q", got.AssetID, want)
	}
}

func assertContainsAll(t *testing.T, haystack string, needles []string) {
	t.Helper()
	lower := strings.ToLower(haystack)
	for _, needle := range needles {
		if !strings.Contains(lower, strings.ToLower(needle)) {
			t.Fatalf("searchDescription missing %q\ngot: %s", needle, haystack)
		}
	}
}

func assertContainsAny(t *testing.T, haystack string, needles []string) {
	t.Helper()
	lower := strings.ToLower(haystack)
	for _, needle := range needles {
		if strings.Contains(lower, strings.ToLower(needle)) {
			return
		}
	}
	t.Fatalf("searchDescription missing any of %v\ngot: %s", needles, haystack)
}

func assertNoUncertainty(t *testing.T, text string) {
	t.Helper()
	lower := strings.ToLower(text)
	for _, word := range []string{"可能", "大概", "推测", "maybe", "probably", "perhaps"} {
		if strings.Contains(lower, word) {
			t.Fatalf("searchDescription contains uncertainty word %q: %s", word, text)
		}
	}
}

func assertRawTagsPreserved(t *testing.T, enriched, raw []string) {
	t.Helper()
	set := make(map[string]struct{}, len(enriched))
	for _, tag := range enriched {
		set[strings.ToLower(tag)] = struct{}{}
	}
	for _, tag := range raw {
		normalized := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(strings.TrimSpace(tag), "-", "_"), " ", "_"))
		if _, ok := set[normalized]; !ok {
			t.Fatalf("enrichedTags missing raw tag %q; got %v", tag, enriched)
		}
	}
}

func preferNoSensitiveInEnrichedTags(t *testing.T, tags, sensitiveTypes []string) {
	t.Helper()
	if len(sensitiveTypes) == 0 {
		return
	}
	sensitive := make(map[string]struct{}, len(sensitiveTypes))
	for _, s := range sensitiveTypes {
		sensitive[strings.ToLower(strings.TrimSpace(s))] = struct{}{}
	}
	for _, tag := range tags {
		if _, ok := sensitive[strings.ToLower(strings.TrimSpace(tag))]; ok {
			t.Logf("WARN: LLM put sensitiveTypes value %q in enrichedTags (prompt prefers sensitiveTypes only)", tag)
		}
	}
}

func assertTagsNormalized(t *testing.T, tags []string) {
	t.Helper()
	for _, tag := range tags {
		if tag != strings.ToLower(tag) {
			t.Fatalf("tag not lowercase: %q", tag)
		}
		if strings.Contains(tag, " ") {
			t.Fatalf("tag contains space: %q", tag)
		}
		if strings.Contains(tag, "-") {
			t.Fatalf("tag contains hyphen: %q", tag)
		}
	}
}

func assertSensitiveTypes(t *testing.T, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("sensitiveTypes = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("sensitiveTypes = %v, want %v", got, want)
		}
	}
}
