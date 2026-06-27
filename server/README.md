# Smart Search Server

PhotoCleaner 智能搜索服务端实现（Go 语言）

## 目录结构

```
server/
├── src/
│   ├── go/                    # Go 源代码
│   │   ├── main.go            # 主程序入口
│   │   ├── config.go          # 配置文件
│   │   ├── config.example.go  # 配置示例
│   │   ├── prompt.go          # LLM 提示词模板
│   │   ├── deepseek.go        # DeepSeek API 客户端
│   │   ├── handler.go         # HTTP 请求处理器
│   │   └── README.md          # Go 详细文档
│   └── test/                  # 测试代码
│       └── test_api.py        # Python 测试脚本
├── cleaner.digsaw.cc.conf     # Nginx 配置
├── deploy.sh                  # 部署脚本
├── smart-search-api.md        # API 文档
└── README.md                  # 本文件
```

## 配置

编辑 `src/go/config.go`，设置以下配置：

```go
ServerSecret:  "your-secret-key",     // 服务器密钥（用于签名验证）
DeepSeekAPIKey: "your-api-key",       // DeepSeek API Key
DeepSeekBaseURL: "https://api.deepseek.com",
DeepSeekModel:  "deepseek-chat",
```

**重要**：`ServerSecret` 必须与客户端代码中的 `serverSecret` 保持一致。

## 部署

### 使用部署脚本

```bash
cd server
./deploy.sh
```

脚本只做两件事：
1. 交叉编译 Linux amd64（注入 `buildVersion` / `buildTime`）
2. 上传到服务器 `/home/www/websites/cleaner.digsaw.cc/smart-search`

上传后需**手动**在服务器停旧进程并启动新二进制：

```bash
ssh root@45.79.40.29
fuser -k 8081/tcp 2>/dev/null || true
cd /home/www/websites/cleaner.digsaw.cc
nohup ./smart-search &
curl -s http://127.0.0.1:8081/health
```

### 配置 Nginx

参考 `cleaner.digsaw.cc.conf` 配置 Nginx。

## 测试

### 使用 Python 测试脚本

```bash
cd server/src/test
python3 test_api.py
```

### 使用 curl 测试

```bash
# 计算签名
QUERY="去年在海南拍的海边大头照"
SECRET="4154b54de82723ca38aec922b3f6a7dfc104fde9"
SIGN=$(echo -n "$QUERY$SECRET" | md5sum | cut -d' ' -f1)

# 健康检查
curl -s https://cleaner.digsaw.cc/health

# 智能搜索
curl -X POST https://cleaner.digsaw.cc/smart-search \
  -H "Content-Type: application/json" \
  -d '{
    "query": "'$QUERY'",
    "locale": "zh-Hans_CN",
    "appVersion": "1.0.0",
    "buildVersion": "100",
    "sign": "'$SIGN'"
  }'
```

## API 端点

| 端点 | 方法 | 说明 |
|------|------|------|
| `/smart-search` | POST | 智能搜索解析 |
| `/health` | GET | 健康检查 |

## 错误码

| HTTP 状态码 | 说明 |
|-------------|------|
| 200 | 成功 |
| 400 | 请求无效（缺少必填字段或 JSON 格式错误） |
| 401 | 签名验证失败 |
| 405 | 请求方法不允许 |
| 500 | 服务器内部错误 |

## 依赖

- Go 1.21+
- Nginx（可选，用于反向代理和 HTTPS）
