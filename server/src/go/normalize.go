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
	plan.Must.SearchKeywordGroups = repairSearchKeywordGroups(summary, plan.Must.SearchKeywordGroups)

	stripEmptyFilters(&plan.Filters)
	plan.Must = ensureMustArrays(plan.Must)
	return plan
}

func ensureMustArrays(must MustMatch) MustMatch {
	if must.SearchKeywordGroups == nil {
		must.SearchKeywordGroups = [][]string{}
	}
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
			SearchKeywordGroups: [][]string{},
			VisualTagsAll:       []string{},
			SensitiveTypes:      []string{},
			OcrContainsAll:      []string{},
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
		SearchKeywordGroups: [][]string{},
		VisualTagsAll:       []string{},
		SensitiveTypes:      []string{},
		OcrContainsAll:      []string{},
	}

	if nested, ok := raw["must"].(map[string]interface{}); ok {
		must.SearchKeywordGroups = append(must.SearchKeywordGroups, stringMatrixField(nested, "searchKeywordGroups")...)
		must.VisualTagsAll = append(must.VisualTagsAll, normalizeVisualTags(stringSliceField(nested, "visualTagsAll"))...)
		must.SensitiveTypes = append(must.SensitiveTypes, normalizeSensitiveTypes(stringSliceField(nested, "sensitiveTypes"))...)
		must.OcrContainsAll = append(must.OcrContainsAll, stringSliceField(nested, "ocrContainsAll")...)
	}

	must.SearchKeywordGroups = append(must.SearchKeywordGroups, stringMatrixField(raw, "searchKeywordGroups")...)
	must.VisualTagsAll = append(must.VisualTagsAll, normalizeVisualTags(stringSliceField(raw, "visualTagsAll"))...)
	must.VisualTagsAll = append(must.VisualTagsAll, normalizeLegacyKeywords(stringSliceField(raw, "keywords"))...)
	must.VisualTagsAll = append(must.VisualTagsAll, visualTagsFromConcepts(raw)...)
	must.SensitiveTypes = append(must.SensitiveTypes, normalizeSensitiveTypes(stringSliceField(raw, "sensitiveTypes"))...)
	must.OcrContainsAll = append(must.OcrContainsAll, stringSliceField(raw, "ocrKeywords")...)
	must.OcrContainsAll = append(must.OcrContainsAll, stringSliceField(raw, "ocrContainsAll")...)

	must.SearchKeywordGroups = normalizeKeywordGroups(must.SearchKeywordGroups)
	must.VisualTagsAll = uniqueStrings(must.VisualTagsAll)
	must.SensitiveTypes = uniqueStrings(must.SensitiveTypes)
	must.OcrContainsAll = uniqueStrings(must.OcrContainsAll)

	return must
}

func stringMatrixField(m map[string]interface{}, key string) [][]string {
	raw, ok := m[key].([]interface{})
	if !ok {
		return nil
	}
	var groups [][]string
	for _, item := range raw {
		group, ok := item.([]interface{})
		if !ok {
			continue
		}
		words := stringSliceFromInterface(group)
		if len(words) > 0 {
			groups = append(groups, words)
		}
	}
	return groups
}

func stringSliceFromInterface(items []interface{}) []string {
	var out []string
	for _, item := range items {
		if s, ok := item.(string); ok {
			s = strings.TrimSpace(s)
			if s != "" {
				out = append(out, s)
			}
		}
	}
	return out
}

func normalizeKeywordGroups(groups [][]string) [][]string {
	var out [][]string
	for _, group := range groups {
		words := uniqueStrings(group)
		if len(words) > 0 {
			out = append(out, words)
		}
	}
	return out
}

func repairSearchKeywordGroups(query string, groups [][]string) [][]string {
	terms := extractSearchQueryTerms(query)
	if len(terms) == 0 {
		return groups
	}

	filtered := make([][]string, 0, len(groups))
	for _, group := range groups {
		words := filterMisreadChineseKeywords(terms, group)
		if len(words) > 0 {
			filtered = append(filtered, words)
		}
	}
	groups = filtered

	if !groupsContainAnyTerm(groups, terms) {
		return [][]string{uniqueStrings(terms)}
	}

	for _, term := range terms {
		if !queryTermCoveredByGroups(term, groups) {
			if len(groups) == 0 {
				groups = [][]string{{term}}
			} else {
				groups[0] = prependUnique([]string{term}, groups[0])
			}
		}
	}

	return normalizeKeywordGroups(groups)
}

func queryTermCoveredByGroups(term string, groups [][]string) bool {
	term = strings.TrimSpace(term)
	if term == "" {
		return true
	}
	if groupsContainKeyword(groups, term) {
		return true
	}

	substringHits := 0
	for _, group := range groups {
		for _, word := range group {
			word = strings.TrimSpace(word)
			if len([]rune(word)) >= 2 && strings.Contains(term, word) {
				substringHits++
				break
			}
		}
	}
	if len(groups) >= 2 && substringHits >= 2 {
		return true
	}
	return substringHits > 0
}

func extractSearchQueryTerms(query string) []string {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil
	}
	parts := strings.Fields(query)
	if len(parts) > 1 {
		return uniqueStrings(parts)
	}
	return []string{query}
}

func filterMisreadChineseKeywords(terms, keywords []string) []string {
	if len(keywords) == 0 {
		return nil
	}
	out := make([]string, 0, len(keywords))
	for _, keyword := range keywords {
		if isLikelyChineseHomographConfusion(terms, keyword) {
			continue
		}
		out = append(out, keyword)
	}
	return out
}

func isLikelyChineseHomographConfusion(terms []string, keyword string) bool {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" {
		return false
	}
	for _, term := range terms {
		term = strings.TrimSpace(term)
		if term == "" || term == keyword {
			continue
		}
		if strings.Contains(term, keyword) || strings.Contains(keyword, term) {
			continue
		}
		termRunes := []rune(term)
		keywordRunes := []rune(keyword)
		if len(termRunes) >= 2 && len(keywordRunes) >= 2 && len(termRunes) == len(keywordRunes) {
			if termRunes[0] == keywordRunes[0] && termRunes[1] != keywordRunes[1] {
				return true
			}
		}
	}
	return false
}

func groupsContainAnyTerm(groups [][]string, terms []string) bool {
	for _, term := range terms {
		term = strings.TrimSpace(term)
		if term == "" {
			continue
		}
		if groupsContainKeyword(groups, term) {
			return true
		}
		for _, group := range groups {
			for _, word := range group {
				word = strings.TrimSpace(word)
				if word == "" {
					continue
				}
				if word == term {
					return true
				}
				if len([]rune(word)) >= 2 && (strings.Contains(term, word) || strings.Contains(word, term)) {
					return true
				}
			}
		}
	}
	return false
}

func groupsContainKeyword(groups [][]string, keyword string) bool {
	for _, group := range groups {
		for _, word := range group {
			if word == keyword {
				return true
			}
		}
	}
	return false
}

func prependUnique(prefix, items []string) []string {
	seen := make(map[string]struct{}, len(prefix)+len(items))
	out := make([]string, 0, len(prefix)+len(items))
	for _, word := range prefix {
		word = strings.TrimSpace(word)
		if word == "" {
			continue
		}
		if _, ok := seen[word]; ok {
			continue
		}
		seen[word] = struct{}{}
		out = append(out, word)
	}
	for _, word := range items {
		word = strings.TrimSpace(word)
		if word == "" {
			continue
		}
		if _, ok := seen[word]; ok {
			continue
		}
		seen[word] = struct{}{}
		out = append(out, word)
	}
	return out
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
