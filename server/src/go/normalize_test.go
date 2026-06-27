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
	if m.VisualTagsAll == nil || m.SensitiveTypes == nil || m.OcrContainsAll == nil {
		t.Fatalf("ensureMustArrays: %+v", m)
	}
}

func TestNormalizeSensitiveTypes(t *testing.T) {
	got := normalizeSensitiveTypes([]string{"ID_CARD", "foo", "passport"})
	if len(got) != 2 {
		t.Fatalf("got %v", got)
	}
}
