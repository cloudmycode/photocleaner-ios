//go:build integration

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

const defaultIndexExportJSON = "smart-search-index-2026-06-29_14-32-24.json"

type indexExportFile struct {
	Entries []indexExportEntry `json:"entries"`
}

type indexExportEntry struct {
	Filename        string   `json:"filename"`
	LocalIdentifier string   `json:"localIdentifier"`
	MediaType       string   `json:"mediaType"`
	AssetTypes      []string `json:"assetTypes"`
	VisualTags      []string `json:"visualTags"`
	SensitiveTypes  []string `json:"sensitiveTypes"`
	OCRText         string   `json:"ocrText"`
}

type indexOCRFixture struct {
	name       string
	filename   string
	locale     string
	assetID    string
	rawTags    []string
	ocrSnippet string
	mediaType  string
	assetTypes []string
	indexSens  []string
}

func TestEnrichPromptLLM_FromIndexJSON(t *testing.T) {
	cfg := enrichTestConfig(t)
	client := newEnrichTestClient(cfg)
	fixtures := loadIndexOCRFixtures(t)

	t.Logf("loaded %d unique OCR fixtures from index export", len(fixtures))

	for _, fx := range fixtures {
		fx := fx
		t.Run(fx.name, func(t *testing.T) {
			item := EnrichItem{
				AssetID:    fx.assetID,
				RawTags:    fx.rawTags,
				OCRSnippet: fx.ocrSnippet,
				MediaType:  fx.mediaType,
				AssetTypes: fx.assetTypes,
			}

			t.Logf("filename: %s", fx.filename)
			t.Logf("index sensitiveTypes: %v", fx.indexSens)
			t.Logf("rawTags: %v", fx.rawTags)
			t.Logf("ocrSnippet (%d chars): %s", len(fx.ocrSnippet), fx.ocrSnippet)

			prompt := renderEnrichPrompt(fx.locale, []EnrichItem{item})
			raw, err := client.ParseQuery(prompt)
			if err != nil {
				t.Fatalf("ParseQuery: %v", err)
			}

			response := normalizeEnrichResponse(raw, []EnrichItem{item})
			if len(response.Items) != 1 {
				t.Fatalf("expected 1 item, got %d", len(response.Items))
			}

			got := response.Items[0]
			rawItem := firstRawEnrichItem(t, raw, item.AssetID)

			t.Logf("=== searchDescription ===\n%s", got.SearchDescription)
			t.Logf("sensitiveTypes: %v", got.SensitiveTypes)
			t.Logf("enrichedTags (normalized): %v", got.EnrichedTags)
			t.Logf("enrichedTags (raw LLM): %v", rawItem.enrichedTags)

			if strings.TrimSpace(got.SearchDescription) == "" {
				t.Fatal("searchDescription is empty")
			}
			assertNoUncertainty(t, got.SearchDescription)
			preferNoSensitiveInEnrichedTags(t, rawItem.enrichedTags, rawItem.sensitiveTypes)
		})
	}
}

func loadIndexOCRFixtures(t *testing.T) []indexOCRFixture {
	t.Helper()

	path := indexExportJSONPath()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read index export %s: %v", path, err)
	}

	var export indexExportFile
	if err := json.Unmarshal(data, &export); err != nil {
		t.Fatalf("parse index export: %v", err)
	}

	seenOCR := map[string]struct{}{}
	fixtures := make([]indexOCRFixture, 0, 32)

	for _, entry := range export.Entries {
		ocr := strings.TrimSpace(entry.OCRText)
		if ocr == "" {
			continue
		}
		snippet := ocr
		if len(snippet) > TagEnrichmentClientOCRSnippetLimit {
			snippet = snippet[:TagEnrichmentClientOCRSnippetLimit]
		}
		dedupeKey := strings.ToLower(snippet)
		if _, ok := seenOCR[dedupeKey]; ok {
			continue
		}
		seenOCR[dedupeKey] = struct{}{}

		filename := entry.Filename
		if filename == "" {
			filename = "unknown"
		}

		mediaType := entry.MediaType
		if mediaType == "" {
			mediaType = "image"
		}

		fixtures = append(fixtures, indexOCRFixture{
			name:       "index_" + sanitizeTestName(filename),
			filename:   filename,
			locale:     guessLocaleFromOCR(ocr),
			assetID:    "index-" + sanitizeTestName(filename),
			rawTags:    entry.VisualTags,
			ocrSnippet: snippet,
			mediaType:  mediaType,
			assetTypes: entry.AssetTypes,
			indexSens:  entry.SensitiveTypes,
		})
	}

	if len(fixtures) == 0 {
		t.Fatal("no OCR entries found in index export")
	}
	return fixtures
}

func indexExportJSONPath() string {
	if path := strings.TrimSpace(os.Getenv("INDEX_EXPORT_JSON")); path != "" {
		return path
	}
	candidates := []string{
		filepath.Join("..", "..", "..", "script", "data", defaultIndexExportJSON),
		filepath.Join("script", "data", defaultIndexExportJSON),
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return candidates[0]
}

func sanitizeTestName(name string) string {
	re := regexp.MustCompile(`[^a-zA-Z0-9._-]+`)
	cleaned := re.ReplaceAllString(name, "_")
	cleaned = strings.Trim(cleaned, "_")
	if cleaned == "" {
		return "item"
	}
	return cleaned
}

func guessLocaleFromOCR(ocr string) string {
	var han, kana, hangul, latin int
	for _, r := range ocr {
		switch {
		case r >= 0x4E00 && r <= 0x9FFF:
			han++
		case (r >= 0x3040 && r <= 0x30FF) || (r >= 0x31F0 && r <= 0x31FF):
			kana++
		case r >= 0xAC00 && r <= 0xD7AF:
			hangul++
		case (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'):
			latin++
		}
	}
	switch {
	case han >= kana && han >= hangul && han > latin:
		return "zh_CN"
	case kana > han && kana >= hangul:
		return "ja_JP"
	case hangul > han && hangul > kana:
		return "ko_KR"
	case latin > 0:
		return "en_US"
	default:
		return "zh_CN"
	}
}

// TagEnrichmentClientOCRSnippetLimit mirrors iOS client truncation.
const TagEnrichmentClientOCRSnippetLimit = 400

func newEnrichTestClient(cfg *Config) *DeepSeekClient {
	return NewDeepSeekClient(
		cfg.DeepSeekAPIKey,
		cfg.DeepSeekBaseURL,
		cfg.DeepSeekModel,
		90*time.Second,
	)
}
