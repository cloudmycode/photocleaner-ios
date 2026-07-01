package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

// Request 请求结构
type Request struct {
	Query         string   `json:"query"`
	Locale        string   `json:"locale"`
	AppVersion    string   `json:"appVersion"`
	BuildVersion  string   `json:"buildVersion"`
	AvailableTags []string `json:"availableTags"`
	Sign          string   `json:"sign"`
}

// SmartSearchHandler 智能搜索处理器
type SmartSearchHandler struct {
	config *Config
	client *DeepSeekClient
	logger *Logger
}

// NewSmartSearchHandler 创建处理器
func NewSmartSearchHandler(config *Config, logger *Logger) *SmartSearchHandler {
	return &SmartSearchHandler{
		config: config,
		client: NewDeepSeekClient(config.DeepSeekAPIKey, config.DeepSeekBaseURL, config.DeepSeekModel, config.RequestTimeout),
		logger: logger,
	}
}

// HandleSearch 处理搜索请求
func (h *SmartSearchHandler) HandleSearch(w http.ResponseWriter, r *http.Request) {
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

	var req Request
	if err := json.Unmarshal(body, &req); err != nil {
		h.writeJSON(w, http.StatusBadRequest, map[string]interface{}{
			"error":   "invalid_request",
			"message": "Invalid JSON body",
		})
		return
	}

	if req.Query == "" {
		h.writeJSON(w, http.StatusBadRequest, map[string]interface{}{
			"error":   "invalid_request",
			"message": "query is required",
		})
		return
	}

	if req.Locale == "" {
		h.writeJSON(w, http.StatusBadRequest, map[string]interface{}{
			"error":   "invalid_request",
			"message": "locale is required",
		})
		return
	}

	if req.AvailableTags == nil {
		h.writeJSON(w, http.StatusBadRequest, map[string]interface{}{
			"error":   "invalid_request",
			"message": "availableTags is required",
		})
		return
	}

	if req.Sign == "" {
		h.writeJSON(w, http.StatusUnauthorized, map[string]interface{}{
			"error":   "unauthorized",
			"message": "sign is required",
		})
		return
	}

	query := strings.TrimSpace(req.Query)
	if query == "" {
		h.writeJSON(w, http.StatusBadRequest, map[string]interface{}{
			"error":   "invalid_request",
			"message": "query cannot be empty",
		})
		return
	}

	expectedSign := calculateMD5(query + h.config.ServerSecret)
	if strings.ToLower(req.Sign) != expectedSign {
		h.writeJSON(w, http.StatusUnauthorized, map[string]interface{}{
			"error":   "unauthorized",
			"message": "invalid signature",
		})
		return
	}

	currentDate := time.Now().Format("2006-01-02")

	raw, err := h.client.ParseQuery(renderPromptInternal(query, req.Locale, currentDate, req.AvailableTags))
	if err != nil {
		h.logger.Error("DeepSeek API error", map[string]interface{}{
			"query": query,
			"error": err.Error(),
		})
		h.writeJSON(w, http.StatusOK, emptySearchPlan(query, h.config))
		return
	}

	plan := normalizeSearchPlan(raw, query, h.config)
	plan.Must.VisualTagsAll = filterVisualTagsInAvailable(plan.Must.VisualTagsAll, req.AvailableTags)
	plan.Must = ensureMustArrays(plan.Must)

	h.logger.Info("Smart search completed", map[string]interface{}{
		"query":               query,
		"locale":              req.Locale,
		"appVersion":          req.AppVersion,
		"tagCount":            len(req.AvailableTags),
		"searchKeywordGroups": plan.Must.SearchKeywordGroups,
		"visualTagsAll":       plan.Must.VisualTagsAll,
		"sensitive":           plan.Must.SensitiveTypes,
		"count":               plan.Count,
	})

	h.writeJSON(w, http.StatusOK, plan)
}

// writeJSON 写入 JSON 响应
func (h *SmartSearchHandler) writeJSON(w http.ResponseWriter, status int, data interface{}) {
	if plan, ok := data.(SearchPlan); ok {
		plan.Must = ensureMustArrays(plan.Must)
		data = plan
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

// HealthHandler 健康检查处理器
type HealthHandler struct{}

// HandleHealth 处理健康检查
func (h *HealthHandler) HandleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":       "ok",
		"service":      "smart-search",
		"version":      "2.0.0",
		"buildVersion": BuildVersion,
		"buildTime":    BuildTime,
		"timestamp":    time.Now().Format("2006-01-02 15:04:05"),
	})
}
