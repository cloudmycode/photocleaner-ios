package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Logger 日志记录器
type Logger struct {
	mu     sync.Mutex
	logDir string
}

var (
	logger     *Logger
	loggerOnce sync.Once
)

// GetLogger 获取全局日志记录器
func GetLogger(logDir string) *Logger {
	loggerOnce.Do(func() {
		if logDir == "" {
			logDir = "/tmp"
		}
		logger = &Logger{
			logDir: logDir,
		}
		// 确保日志目录存在
		os.MkdirAll(logDir, 0755)
	})
	return logger
}

// CleanOldLogs 清理超过指定天数的日志文件
func (l *Logger) CleanOldLogs(maxAgeDays int) {
	if maxAgeDays <= 0 {
		maxAgeDays = 100
	}
	
	cutoff := time.Now().AddDate(0, 0, -maxAgeDays)
	
	entries, err := os.ReadDir(l.logDir)
	if err != nil {
		return
	}
	
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		
		// 只处理 .log 文件
		if filepath.Ext(entry.Name()) != ".log" {
			continue
		}
		
		// 解析日期格式 YYYY-MM-DD.log
		dateStr := entry.Name()[:10]
		t, err := time.Parse("2006-01-02", dateStr)
		if err != nil {
			continue
		}
		
		if t.Before(cutoff) {
			os.Remove(filepath.Join(l.logDir, entry.Name()))
		}
	}
}

// getLogFileName 获取当日日志文件名
func (l *Logger) getLogFileName() string {
	return filepath.Join(l.logDir, time.Now().Format("2006-01-02")+".log")
}

// getLogFile 获取或创建日志文件
func (l *Logger) getLogFile() (*os.File, error) {
	logFileName := l.getLogFileName()
	
	l.mu.Lock()
	defer l.mu.Unlock()
	
	// 检查文件是否已存在且是今天的
	file, err := os.OpenFile(logFileName, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open log file: %w", err)
	}
	return file, nil
}

// Log 记录日志
func (l *Logger) Log(level, msg string, data interface{}) {
	now := time.Now().Format("2006-01-02 15:04:05.000")
	logLine := fmt.Sprintf("[%s] [%s] %s\n%s\n", now, level, msg, formatData(data))
	
	// 输出到标准输出
	fmt.Print(logLine)
	
	// 写入文件
	file, err := l.getLogFile()
	if err != nil {
		return
	}
	defer file.Close()
	
	file.WriteString(logLine)
}

// Info 记录信息日志
func (l *Logger) Info(msg string, data interface{}) {
	l.Log("INFO", msg, data)
}

// Error 记录错误日志
func (l *Logger) Error(msg string, data interface{}) {
	l.Log("ERROR", msg, data)
}

// formatData 格式化数据为 JSON
func formatData(data interface{}) string {
	if data == nil {
		return ""
	}
	
	// 如果是字符串，直接返回
	if s, ok := data.(string); ok {
		return s
	}
	
	// 尝试 JSON 编码
	logBytes, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return fmt.Sprintf("%v", data)
	}
	return string(logBytes)
}
