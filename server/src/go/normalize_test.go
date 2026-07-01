package main

import (
	"encoding/json"
	"testing"
)

func TestNormalizeSearchPlan_NewFormat(t *testing.T) {
	cfg := DefaultConfig()
	raw := map[string]interface{}{
		"summary": "beach photos with people",
		"filters": map[string]interface{}{
			"mediaTypes": []interface{}{"image"},
			"dateRange": map[string]interface{}{
				"start": "2024-01-01",
				"end":   "2024-12-31",
			},
		},
		"must": map[string]interface{}{
			"visualTagsAll":  []interface{}{"beach", "person"},
			"sensitiveTypes": []interface{}{},
			"ocrContainsAll": []interface{}{},
		},
		"count":      float64(50),
		"confidence": 0.9,
	}

	plan := normalizeSearchPlan(raw, "fallback", cfg)

	if plan.Summary != "beach photos with people" {
		t.Fatalf("summary: got %q", plan.Summary)
	}
	if len(plan.Must.VisualTagsAll) != 2 || plan.Must.VisualTagsAll[0] != "beach" {
		t.Fatalf("visualTagsAll: %v", plan.Must.VisualTagsAll)
	}
	if plan.Count != 50 {
		t.Fatalf("count: got %d", plan.Count)
	}
	if plan.Filters.DateRange == nil || plan.Filters.DateRange.Start != "2024-01-01" {
		t.Fatalf("dateRange: %+v", plan.Filters.DateRange)
	}
}

func TestNormalizeSearchPlan_LegacyKeywords(t *testing.T) {
	cfg := DefaultConfig()
	raw := map[string]interface{}{
		"keywords":       []interface{}{"white car", "beach"},
		"sensitiveTypes": []interface{}{"id_card", "invalid_type"},
		"count":          float64(2000),
	}

	plan := normalizeSearchPlan(raw, "q", cfg)

	wantTags := map[string]bool{"white": true, "car": true, "beach": true}
	for _, tag := range plan.Must.VisualTagsAll {
		if !wantTags[tag] {
			t.Fatalf("unexpected tag %q in %v", tag, plan.Must.VisualTagsAll)
		}
		delete(wantTags, tag)
	}
	if len(wantTags) != 0 {
		t.Fatalf("missing tags: %v", wantTags)
	}
	if len(plan.Must.SensitiveTypes) != 1 || plan.Must.SensitiveTypes[0] != "id_card" {
		t.Fatalf("sensitiveTypes: %v", plan.Must.SensitiveTypes)
	}
	if plan.Count != cfg.MaxCount {
		t.Fatalf("count capped: got %d want %d", plan.Count, cfg.MaxCount)
	}
}

func TestNormalizeSearchPlan_VisualConcepts(t *testing.T) {
	cfg := DefaultConfig()
	raw := map[string]interface{}{
		"visualConcepts": []interface{}{
			map[string]interface{}{
				"name":     "cat",
				"matchAny": []interface{}{"cat", "kitten"},
			},
			map[string]interface{}{
				"name":     "beach",
				"matchAny": []interface{}{"beach", "ocean"},
			},
		},
	}

	plan := normalizeSearchPlan(raw, "q", cfg)
	if len(plan.Must.VisualTagsAll) != 2 {
		t.Fatalf("expected 2 tags, got %v", plan.Must.VisualTagsAll)
	}
	if plan.Must.VisualTagsAll[0] != "cat" || plan.Must.VisualTagsAll[1] != "beach" {
		t.Fatalf("tags: %v", plan.Must.VisualTagsAll)
	}
}

func TestNormalizeSearchPlan_PreservesUnderscoreTags(t *testing.T) {
	cfg := DefaultConfig()
	raw := map[string]interface{}{
		"must": map[string]interface{}{
			"visualTagsAll": []interface{}{"gray_clothing", "person"},
		},
	}

	plan := normalizeSearchPlan(raw, "q", cfg)
	if len(plan.Must.VisualTagsAll) != 2 {
		t.Fatalf("got %v", plan.Must.VisualTagsAll)
	}
	if plan.Must.VisualTagsAll[0] != "gray_clothing" {
		t.Fatalf("underscore tag altered: %v", plan.Must.VisualTagsAll)
	}
}

func TestFilterVisualTagsInAvailable(t *testing.T) {
	available := []string{"person", "beach", "gray_clothing", "car"}
	got := filterVisualTagsInAvailable(
		[]string{"person", "white", "shore", "gray_clothing"},
		available,
	)
	want := []string{"person", "gray_clothing"}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
}

func TestUniqueStringsJSONEmptyArray(t *testing.T) {
	got := uniqueStrings(nil)
	if got == nil {
		t.Fatal("uniqueStrings(nil) should return non-nil empty slice")
	}
	data, err := json.Marshal(map[string][]string{"items": got})
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"items":[]}` {
		t.Fatalf("json: %s", data)
	}
}

func TestEnsureMustArrays(t *testing.T) {
	m := ensureMustArrays(MustMatch{})
	if m.SearchKeywordGroups == nil || m.VisualTagsAll == nil || m.SensitiveTypes == nil || m.OcrContainsAll == nil {
		t.Fatalf("ensureMustArrays: %+v", m)
	}
}

func TestNormalizeSearchPlan_KeywordGroups(t *testing.T) {
	cfg := DefaultConfig()
	raw := map[string]interface{}{
		"must": map[string]interface{}{
			"searchKeywordGroups": []interface{}{
				[]interface{}{"路由器", "router", "wifi"},
				[]interface{}{"账号", "account"},
			},
			"visualTagsAll": []interface{}{},
		},
	}

	plan := normalizeSearchPlan(raw, "路由器账号", cfg)
	if len(plan.Must.SearchKeywordGroups) != 2 {
		t.Fatalf("groups: %v", plan.Must.SearchKeywordGroups)
	}
	if len(plan.Must.SearchKeywordGroups[0]) != 3 {
		t.Fatalf("group0: %v", plan.Must.SearchKeywordGroups[0])
	}
	if len(plan.Must.VisualTagsAll) != 0 {
		t.Fatalf("visualTagsAll should be empty: %v", plan.Must.VisualTagsAll)
	}
}

func TestNormalizeSensitiveTypes(t *testing.T) {
	got := normalizeSensitiveTypes([]string{"ID_CARD", "foo", "passport"})
	if len(got) != 2 {
		t.Fatalf("got %v", got)
	}
}

func TestRepairSearchKeywordGroups_TruckNotCaliper(t *testing.T) {
	cfg := DefaultConfig()
	raw := map[string]interface{}{
		"must": map[string]interface{}{
			"searchKeywordGroups": []interface{}{
				[]interface{}{"卡钳", "caliper", "卡钳工具", "卡钳测量"},
			},
		},
	}

	plan := normalizeSearchPlan(raw, "卡车", cfg)
	if len(plan.Must.SearchKeywordGroups) != 1 {
		t.Fatalf("groups: %v", plan.Must.SearchKeywordGroups)
	}
	group := plan.Must.SearchKeywordGroups[0]
	if len(group) != 1 || group[0] != "卡车" {
		t.Fatalf("expected only user term 卡车, got %v", group)
	}
}

func TestRepairSearchKeywordGroups_KeepsValidSynonyms(t *testing.T) {
	got := repairSearchKeywordGroups("卡车", [][]string{
		{"卡车", "卡钳", "货车", "truck"},
	})
	if len(got) != 1 {
		t.Fatalf("groups: %v", got)
	}
	want := map[string]bool{"卡车": true, "货车": true, "truck": true}
	for _, word := range got[0] {
		if !want[word] {
			t.Fatalf("unexpected keyword %q in %v", word, got[0])
		}
		delete(want, word)
	}
	if len(want) != 0 {
		t.Fatalf("missing keywords: %v in %v", want, got[0])
	}
}

func TestIsLikelyChineseHomographConfusion(t *testing.T) {
	if !isLikelyChineseHomographConfusion([]string{"卡车"}, "卡钳") {
		t.Fatal("卡车 vs 卡钳 should be flagged")
	}
	if isLikelyChineseHomographConfusion([]string{"卡车"}, "货车") {
		t.Fatal("卡车 vs 货车 should not be flagged")
	}
	if isLikelyChineseHomographConfusion([]string{"卡车"}, "truck") {
		t.Fatal("卡车 vs truck should not be flagged")
	}
}
