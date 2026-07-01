package main

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"time"
)

func main() {
	// 加载配置
	config := DefaultConfig()

	// 从环境变量覆盖配置（可选）
	if secret := os.Getenv("SERVER_SECRET"); secret != "" {
		config.ServerSecret = secret
	}
	if apiKey := os.Getenv("DEEPSEEK_API_KEY"); apiKey != "" {
		config.DeepSeekAPIKey = apiKey
	}

	// 初始化日志
	logDir := os.Getenv("LOG_DIR")
	if logDir == "" {
		logDir = "/home/www/websites/cleaner.digsaw.cc/log"
	}
	logger := GetLogger(logDir)

	// 定时清理日志（每天凌晨2点执行一次）
	go func() {
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for range ticker.C {
			if time.Now().Hour() == 2 {
				logger.CleanOldLogs(100)
			}
		}
	}()

	// 创建处理器
	searchHandler := NewSmartSearchHandler(config, logger)
	enrichHandler := NewEnrichTagsHandler(config, logger)
	healthHandler := &HealthHandler{}

	// 设置路由
	mux := http.NewServeMux()
	mux.HandleFunc("/smart-search", searchHandler.HandleSearch)
	mux.HandleFunc("/enrich-tags", enrichHandler.HandleEnrich)
	mux.HandleFunc("/health", healthHandler.HandleHealth)

	// 创建服务器（默认端口 8081，避免与 Nginx 8080 冲突）
	addr := ":8081"
	if port := os.Getenv("PORT"); port != "" {
		addr = ":" + port
	}

	server := &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	// 启动服务器
	logger.Info("Starting Smart Search server", map[string]interface{}{
		"addr": addr,
	})

	if err := server.ListenAndServe(); err != nil {
		logger.Error("Server failed", err)
	}
}

// calculateMD5 计算 MD5
func calculateMD5(s string) string {
	h := md5.New()
	h.Write([]byte(s))
	return hex.EncodeToString(h.Sum(nil))
}

// replaceAll 替换所有匹配项
func replaceAll(s, old, new string) string {
	result := ""
	for i := 0; i < len(s); {
		// 查找 old
		found := true
		if i+len(old) > len(s) {
			found = false
		} else {
			for j := 0; j < len(old); j++ {
				if s[i+j] != old[j] {
					found = false
					break
				}
			}
		}
		if found {
			result += new
			i += len(old)
		} else {
			result += string(s[i])
			i++
		}
	}
	return result
}

// renderPromptInternal 内部实现
func renderPromptInternal(query, locale, currentDate string, availableTags []string) string {
	tagsJSON, _ := json.Marshal(availableTags)
	t := PromptTemplate
	t = replaceAll(t, "{query}", query)
	t = replaceAll(t, "{locale}", locale)
	t = replaceAll(t, "{current_date}", currentDate)
	t = replaceAll(t, "{available_tags}", string(tagsJSON))
	return t
}
