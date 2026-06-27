package main

import (
	"strings"
	"unicode"
)

func normalizeSearchPlan(raw map[string]interface{}, summary string, cfg *Config) SearchPlan {
	plan := SearchPlan{
		Summary: summary,
		Must: MustMatch{
			VisualTagsAll:  []string{},
			SensitiveTypes: []string{},
			OcrContainsAll: []string{},
		},
		Count: cfg.DefaultCount,
	}

	if s, ok := raw["summary"].(string); ok && strings.TrimSpace(s) != "" {
		plan.Summary = strings.TrimSpace(s)
	}

	plan.Filters = extractFilters(raw)
	plan.Must = extractMust(raw)
	plan.Count = normalizeCount(raw, cfg)
	plan.Confidence = normalizeConfidence(raw)

	stripEmptyFilters(&plan.Filters)
	plan.Must = ensureMustArrays(plan.Must)
	return plan
}

func ensureMustArrays(must MustMatch) MustMatch {
	if must.VisualTagsAll == nil {
		must.VisualTagsAll = []string{}
	}
	if must.SensitiveTypes == nil {
		must.SensitiveTypes = []string{}
	}
	if must.OcrContainsAll == nil {
		must.OcrContainsAll = []string{}
	}
	return must
}

func emptySearchPlan(query string, cfg *Config) SearchPlan {
	return SearchPlan{
		Summary: query,
		Must: MustMatch{
			VisualTagsAll:  []string{},
			SensitiveTypes: []string{},
			OcrContainsAll: []string{},
		},
		Count:      cfg.DefaultCount,
		Confidence: 0,
	}
}

func extractFilters(raw map[string]interface{}) Filters {
	filters := Filters{}

	if nested, ok := raw["filters"].(map[string]interface{}); ok {
		mergeFiltersFromMap(&filters, nested)
	}
	mergeFiltersFromMap(&filters, raw)

	return filters
}

func mergeFiltersFromMap(filters *Filters, m map[string]interface{}) {
	if v := objectField(m, "dateRange"); v != nil {
		filters.DateRange = parseDateRange(v)
	}
	if bounds := sliceField(m, "locationBounds"); len(bounds) > 0 {
		filters.LocationBounds = parseLocationBounds(bounds)
	}
	if types := stringSliceField(m, "mediaTypes"); len(types) > 0 {
		filters.MediaTypes = types
	}
	if types := stringSliceField(m, "assetTypes"); len(types) > 0 {
		filters.AssetTypes = types
	}
	if v, ok := floatField(m, "minSizeMB"); ok {
		filters.MinSizeMB = &v
	}
	if v, ok := floatField(m, "maxSizeMB"); ok {
		filters.MaxSizeMB = &v
	}
	if v, ok := intField(m, "minPixelWidth"); ok {
		filters.MinPixelWidth = &v
	}
	if v, ok := intField(m, "minPixelHeight"); ok {
		filters.MinPixelHeight = &v
	}
	if v, ok := boolField(m, "hasLocation"); ok {
		filters.HasLocation = &v
	}
}

func extractMust(raw map[string]interface{}) MustMatch {
	must := MustMatch{
		VisualTagsAll:  []string{},
		SensitiveTypes: []string{},
		OcrContainsAll: []string{},
	}

	if nested, ok := raw["must"].(map[string]interface{}); ok {
		must.VisualTagsAll = append(must.VisualTagsAll, normalizeVisualTags(stringSliceField(nested, "visualTagsAll"))...)
		must.SensitiveTypes = append(must.SensitiveTypes, normalizeSensitiveTypes(stringSliceField(nested, "sensitiveTypes"))...)
		must.OcrContainsAll = append(must.OcrContainsAll, stringSliceField(nested, "ocrContainsAll")...)
	}

	// 新格式：must.visualTagsAll
	must.VisualTagsAll = append(must.VisualTagsAll, normalizeVisualTags(stringSliceField(raw, "visualTagsAll"))...)

	// 兼容旧格式：keywords → visualTagsAll（旧 prompt 会拆词，保留拆词逻辑）
	must.VisualTagsAll = append(must.VisualTagsAll, normalizeLegacyKeywords(stringSliceField(raw, "keywords"))...)

	// 兼容旧格式：visualConcepts → 每个概念取 matchAny 第一个词
	must.VisualTagsAll = append(must.VisualTagsAll, visualTagsFromConcepts(raw)...)

	must.SensitiveTypes = append(must.SensitiveTypes, normalizeSensitiveTypes(stringSliceField(raw, "sensitiveTypes"))...)

	// 兼容旧格式：ocrKeywords
	must.OcrContainsAll = append(must.OcrContainsAll, stringSliceField(raw, "ocrKeywords")...)
	must.OcrContainsAll = append(must.OcrContainsAll, stringSliceField(raw, "ocrContainsAll")...)

	must.VisualTagsAll = uniqueStrings(must.VisualTagsAll)
	must.SensitiveTypes = uniqueStrings(must.SensitiveTypes)
	must.OcrContainsAll = uniqueStrings(must.OcrContainsAll)

	return must
}

func visualTagsFromConcepts(raw map[string]interface{}) []string {
	concepts, ok := raw["visualConcepts"].([]interface{})
	if !ok {
		return nil
	}
	var tags []string
	for _, item := range concepts {
		concept, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		matchAny := normalizeVisualTags(stringSliceField(concept, "matchAny"))
		if len(matchAny) > 0 {
			tags = append(tags, matchAny[0])
		}
	}
	return tags
}

func normalizeLegacyKeywords(tags []string) []string {
	var out []string
	for _, tag := range tags {
		out = append(out, splitVisualTagInput(tag)...)
	}
	return uniqueStrings(out)
}

func normalizeVisualTags(tags []string) []string {
	var out []string
	for _, tag := range tags {
		tag = strings.TrimSpace(tag)
		if tag != "" {
			out = append(out, tag)
		}
	}
	return uniqueStrings(out)
}

// filterVisualTagsInAvailable 只保留客户端词表中存在的 tag（防模型幻觉）
func filterVisualTagsInAvailable(tags, available []string) []string {
	if len(tags) == 0 {
		return []string{}
	}
	allowed := make(map[string]struct{}, len(available))
	for _, t := range available {
		t = strings.TrimSpace(t)
		if t != "" {
			allowed[t] = struct{}{}
		}
	}
	out := make([]string, 0, len(tags))
	for _, tag := range tags {
		if _, ok := allowed[tag]; ok {
			out = append(out, tag)
		}
	}
	return out
}

func normalizeSensitiveTypes(types []string) []string {
	var out []string
	for _, t := range types {
		t = strings.TrimSpace(strings.ToLower(t))
		if _, ok := validSensitiveTypes[t]; ok {
			out = append(out, t)
		}
	}
	return uniqueStrings(out)
}

func normalizeCount(raw map[string]interface{}, cfg *Config) int {
	count := cfg.DefaultCount
	if v, ok := floatField(raw, "count"); ok {
		count = int(v)
	}
	if count <= 0 {
		count = cfg.DefaultCount
	}
	if count > cfg.MaxCount {
		count = cfg.MaxCount
	}
	return count
}

func normalizeConfidence(raw map[string]interface{}) float64 {
	v, ok := floatField(raw, "confidence")
	if !ok {
		return 0
	}
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func stripEmptyFilters(filters *Filters) {
	if filters.DateRange != nil && filters.DateRange.Start == "" && filters.DateRange.End == "" {
		filters.DateRange = nil
	}
	if len(filters.LocationBounds) == 0 {
		filters.LocationBounds = nil
	}
	if len(filters.MediaTypes) == 0 {
		filters.MediaTypes = nil
	}
	if len(filters.AssetTypes) == 0 {
		filters.AssetTypes = nil
	}
}

func parseDateRange(v interface{}) *DateRange {
	m, ok := v.(map[string]interface{})
	if !ok {
		return nil
	}
	dr := &DateRange{}
	if s, ok := m["start"].(string); ok {
		dr.Start = strings.TrimSpace(s)
	}
	if s, ok := m["end"].(string); ok {
		dr.End = strings.TrimSpace(s)
	}
	if dr.Start == "" && dr.End == "" {
		return nil
	}
	return dr
}

func parseLocationBounds(items []interface{}) []LocationBound {
	var bounds []LocationBound
	for _, item := range items {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		b := LocationBound{}
		if s, ok := m["name"].(string); ok {
			b.Name = s
		}
		if v, ok := floatField(m, "minLatitude"); ok {
			b.MinLatitude = v
		}
		if v, ok := floatField(m, "maxLatitude"); ok {
			b.MaxLatitude = v
		}
		if v, ok := floatField(m, "minLongitude"); ok {
			b.MinLongitude = v
		}
		if v, ok := floatField(m, "maxLongitude"); ok {
			b.MaxLongitude = v
		}
		bounds = append(bounds, b)
	}
	return bounds
}

func objectField(m map[string]interface{}, key string) map[string]interface{} {
	v, ok := m[key].(map[string]interface{})
	if !ok {
		return nil
	}
	return v
}

func sliceField(m map[string]interface{}, key string) []interface{} {
	v, ok := m[key].([]interface{})
	if !ok {
		return nil
	}
	return v
}

func stringSliceField(m map[string]interface{}, key string) []string {
	raw, ok := m[key].([]interface{})
	if !ok {
		return nil
	}
	var out []string
	for _, item := range raw {
		if s, ok := item.(string); ok {
			s = strings.TrimSpace(s)
			if s != "" {
				out = append(out, s)
			}
		}
	}
	return out
}

func floatField(m map[string]interface{}, key string) (float64, bool) {
	v, ok := m[key]
	if !ok {
		return 0, false
	}
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	default:
		return 0, false
	}
}

func intField(m map[string]interface{}, key string) (int, bool) {
	v, ok := floatField(m, key)
	if !ok {
		return 0, false
	}
	return int(v), true
}

func boolField(m map[string]interface{}, key string) (bool, bool) {
	v, ok := m[key].(bool)
	return v, ok
}

func uniqueStrings(items []string) []string {
	if len(items) == 0 {
		return []string{}
	}
	seen := make(map[string]struct{}, len(items))
	out := make([]string, 0, len(items))
	for _, item := range items {
		if item == "" {
			continue
		}
		if _, ok := seen[item]; ok {
			continue
		}
		seen[item] = struct{}{}
		out = append(out, item)
	}
	return out
}

// splitVisualTagInput 将可能含空格的关键词拆成多个单词
func splitVisualTagInput(tag string) []string {
	tag = strings.TrimSpace(strings.ToLower(tag))
	tag = strings.ReplaceAll(tag, "-", " ")
	tag = strings.ReplaceAll(tag, "_", " ")
	var parts []string
	for _, p := range strings.Fields(tag) {
		p = strings.Map(func(r rune) rune {
			if unicode.IsLetter(r) || unicode.IsDigit(r) {
				return r
			}
			return -1
		}, p)
		if p != "" {
			parts = append(parts, p)
		}
	}
	return parts
}
