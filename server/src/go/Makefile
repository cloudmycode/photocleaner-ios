.PHONY: build run test clean

# 编译
build:
	go build -o smart-search main.go

# 运行
run: build
	./smart-search

# 测试
test: build
	go run test.go

# 清理
clean:
	rm -f smart-search

# 安装依赖
deps:
	go mod tidy

# 构建发布版本
release: clean build
	@echo "Built: smart-search"
	@ls -la smart-search

# 帮助
help:
	@echo "Smart Search Server (Go)"
	@echo ""
	@echo "Targets:"
	@echo "  make build   - Compile the server"
	@echo "  make run     - Compile and run the server"
	@echo "  make test    - Run tests"
	@echo "  make clean   - Remove binary"
	@echo "  make release - Build release version"
	@echo "  make help    - Show this help"
