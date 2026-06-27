package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// DeepSeekRequest DeepSeek API 请求结构
type DeepSeekRequest struct {
	Model       string        `json:"model"`
	Messages    []ChatMessage `json:"messages"`
	Temperature float64       `json:"temperature"`
}

// ChatMessage 聊天消息
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// DeepSeekResponse DeepSeek API 响应结构
type DeepSeekResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

// DeepSeekClient DeepSeek API 客户端
type DeepSeekClient struct {
	apiKey  string
	baseURL string
	model   string
	timeout time.Duration
	client  *http.Client
}

// NewDeepSeekClient 创建 DeepSeek 客户端
func NewDeepSeekClient(apiKey, baseURL, model string, timeout time.Duration) *DeepSeekClient {
	return &DeepSeekClient{
		apiKey:  apiKey,
		baseURL: baseURL,
		model:   model,
		timeout: timeout,
		client: &http.Client{
			Timeout: timeout,
		},
	}
}

// ParseQuery 调用 DeepSeek API 解析查询
func (c *DeepSeekClient) ParseQuery(prompt string) (map[string]interface{}, error) {
	url := c.baseURL + "/v1/chat/completions"

	// 构建请求体
	reqBody, err := json.Marshal(DeepSeekRequest{
		Model: c.model,
		Messages: []ChatMessage{
			{Role: "user", Content: prompt},
		},
		Temperature: 0.3,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	// 创建 HTTP 请求
	httpReq, err := http.NewRequest("POST", url, bytes.NewBuffer(reqBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("DeepSeek API request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("DeepSeek API error: HTTP %d, body: %s", resp.StatusCode, string(body))
	}

	var dsResp DeepSeekResponse
	if err := json.Unmarshal(body, &dsResp); err != nil {
		return nil, fmt.Errorf("invalid JSON response: %w", err)
	}

	if len(dsResp.Choices) == 0 || dsResp.Choices[0].Message.Content == "" {
		return nil, fmt.Errorf("empty response from DeepSeek")
	}

	content := dsResp.Choices[0].Message.Content

	// 解析 JSON 响应
	return c.parseJSONResponse(content)
}

// parseJSONResponse 解析 JSON 响应
func (c *DeepSeekClient) parseJSONResponse(content string) (map[string]interface{}, error) {
	// 移除可能的 markdown 代码块
	content = strings.TrimSpace(content)
	
	// 移除开头的 ```json 或 ```
	if strings.HasPrefix(content, "```json") {
		content = content[7:]
	} else if strings.HasPrefix(content, "```") {
		content = content[3:]
	}
	
	// 移除结尾的 ```
	if strings.HasSuffix(content, "```") {
		content = content[:len(content)-3]
	}
	
	content = strings.TrimSpace(content)

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(content), &result); err != nil {
		return nil, fmt.Errorf("failed to parse JSON: %w", err)
	}

	return result, nil
}
