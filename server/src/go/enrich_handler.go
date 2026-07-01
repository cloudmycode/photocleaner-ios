package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
)

// EnrichItem 单张图片扩 tag 请求项
type EnrichItem struct {
	AssetID     string   `json:"assetId"`
	RawTags     []string `json:"rawTags"`
	OCRSnippet  string   `json:"ocrSnippet"`
	MediaType   string   `json:"mediaType"`
	AssetTypes  []string `json:"assetTypes"`
}

// EnrichRequest 扩 tag 请求
type EnrichRequest struct {
	DeviceID     string       `json:"deviceId"`
	Locale       string       `json:"locale"`
	AppVersion   string       `json:"appVersion"`
	BuildVersion string       `json:"buildVersion"`
	Items        []EnrichItem `json:"items"`
	Sign         string       `json:"sign"`
}

// EnrichResultItem 扩 tag 响应项
type EnrichResultItem struct {
	AssetID           string   `json:"assetId"`
	EnrichedTags      []string `json:"enrichedTags"`
	SensitiveTypes    []string `json:"sensitiveTypes"`
	SearchDescription string   `json:"searchDescription"`
}

// EnrichResponse 扩 tag 响应
type EnrichResponse struct {
	Items []EnrichResultItem `json:"items"`
}

// EnrichTagsHandler 标签扩写处理器
type EnrichTagsHandler struct {
	config *Config
	client *DeepSeekClient
	logger *Logger
}

// NewEnrichTagsHandler 创建处理器
func NewEnrichTagsHandler(config *Config, logger *Logger) *EnrichTagsHandler {
	return &EnrichTagsHandler{
		config: config,
		client: NewDeepSeekClient(config.DeepSeekAPIKey, config.DeepSeekBaseURL, config.DeepSeekModel, config.RequestTimeout),
		logger: logger,
	}
}

// HandleEnrich 处理扩 tag 请求
func (h *EnrichTagsHandler) HandleEnrich(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read request body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	var req EnrichRequest
	if err := json.Unmarshal(body, &req); err != nil {
		h.writeJSON(w, http.StatusBadRequest, map[string]interface{}{
			"error":   "invalid_request",
			"message": "Invalid JSON body",
		})
		return
	}

	deviceID := strings.TrimSpace(req.DeviceID)
	if deviceID == "" || len(req.Items) == 0 || req.Sign == "" {
		h.writeJSON(w, http.StatusBadRequest, map[string]interface{}{
			"error":   "invalid_request",
			"message": "deviceId, items and sign are required",
		})
		return
	}

	expectedSign := calculateMD5(deviceID + h.config.ServerSecret)
	if strings.ToLower(req.Sign) != expectedSign {
		h.writeJSON(w, http.StatusUnauthorized, map[string]interface{}{
			"error":   "unauthorized",
			"message": "invalid signature",
		})
		return
	}

	locale := req.Locale
	if locale == "" {
		locale = "en"
	}

	raw, err := h.client.ParseQuery(renderEnrichPrompt(locale, req.Items))
	if err != nil {
		h.logger.Error("Enrich tags API error", map[string]interface{}{
			"deviceId": deviceID,
			"count":    len(req.Items),
			"error":    err.Error(),
		})
		h.writeJSON(w, http.StatusOK, fallbackEnrichResponse(req.Items))
		return
	}

	response := normalizeEnrichResponse(raw, req.Items)
	h.logger.Info("Enrich tags completed", map[string]interface{}{
		"deviceId": deviceID,
		"count":    len(req.Items),
	})

	h.writeJSON(w, http.StatusOK, response)
}

func (h *EnrichTagsHandler) writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func fallbackEnrichResponse(items []EnrichItem) EnrichResponse {
	results := make([]EnrichResultItem, 0, len(items))
	for _, item := range items {
		results = append(results, EnrichResultItem{
			AssetID:           item.AssetID,
			EnrichedTags:      normalizeTagList(item.RawTags),
			SensitiveTypes:    []string{},
			SearchDescription: buildFallbackSearchDescription(item.RawTags, item.OCRSnippet),
		})
	}
	return EnrichResponse{Items: results}
}

func normalizeEnrichResponse(raw map[string]interface{}, requested []EnrichItem) EnrichResponse {
	byID := map[string]EnrichItem{}
	for _, item := range requested {
		byID[item.AssetID] = item
	}

	results := make([]EnrichResultItem, 0, len(requested))
	itemsRaw, ok := raw["items"].([]interface{})
	if !ok {
		return fallbackEnrichResponse(requested)
	}

	seen := map[string]struct{}{}
	for _, entry := range itemsRaw {
		obj, ok := entry.(map[string]interface{})
		if !ok {
			continue
		}
		assetID, _ := obj["assetId"].(string)
		if assetID == "" {
			continue
		}
		seen[assetID] = struct{}{}
		input := byID[assetID]
		enriched := mergeTagLists(input.RawTags, interfaceToStringSlice(obj["enrichedTags"]))
		sensitive := filterSensitiveTypes(interfaceToStringSlice(obj["sensitiveTypes"]))
		for _, s := range sensitive {
			enriched = mergeTagLists(enriched, []string{s})
		}
		description := strings.TrimSpace(stringFromInterface(obj["searchDescription"]))
		if description == "" {
			description = buildFallbackSearchDescription(input.RawTags, input.OCRSnippet)
		}
		results = append(results, EnrichResultItem{
			AssetID:           assetID,
			EnrichedTags:      enriched,
			SensitiveTypes:    sensitive,
			SearchDescription: description,
		})
	}

	for _, item := range requested {
		if _, ok := seen[item.AssetID]; ok {
			continue
		}
		results = append(results, EnrichResultItem{
			AssetID:           item.AssetID,
			EnrichedTags:      normalizeTagList(item.RawTags),
			SensitiveTypes:    []string{},
			SearchDescription: buildFallbackSearchDescription(item.RawTags, item.OCRSnippet),
		})
	}

	return EnrichResponse{Items: results}
}

func mergeTagLists(lists ...[]string) []string {
	merged := []string{}
	for _, list := range lists {
		merged = append(merged, list...)
	}
	return normalizeTagList(merged)
}

func stringFromInterface(value interface{}) string {
	if s, ok := value.(string); ok {
		return s
	}
	return ""
}

func buildFallbackSearchDescription(rawTags []string, ocrSnippet string) string {
	parts := make([]string, 0, len(rawTags)+1)
	parts = append(parts, rawTags...)
	ocr := strings.TrimSpace(ocrSnippet)
	if ocr != "" {
		parts = append(parts, ocr)
	}
	return strings.Join(parts, " ")
}

func interfaceToStringSlice(value interface{}) []string {
	switch v := value.(type) {
	case []interface{}:
		out := make([]string, 0, len(v))
		for _, item := range v {
			if s, ok := item.(string); ok {
				out = append(out, s)
			}
		}
		return out
	case []string:
		return v
	default:
		return nil
	}
}

func normalizeTagList(tags []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(tags))
	for _, tag := range tags {
		normalized := strings.TrimSpace(strings.ToLower(tag))
		normalized = strings.ReplaceAll(normalized, "-", "_")
		normalized = strings.ReplaceAll(normalized, " ", "_")
		if normalized == "" {
			continue
		}
		if _, ok := seen[normalized]; ok {
			continue
		}
		seen[normalized] = struct{}{}
		out = append(out, normalized)
	}
	return out
}

func filterSensitiveTypes(types []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(types))
	for _, t := range types {
		normalized := strings.TrimSpace(strings.ToLower(t))
		if _, ok := validSensitiveTypes[normalized]; !ok {
			continue
		}
		if _, ok := seen[normalized]; ok {
			continue
		}
		seen[normalized] = struct{}{}
		out = append(out, normalized)
	}
	return out
}
