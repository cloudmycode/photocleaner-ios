#!/bin/bash

# 编译 Linux 二进制并上传到服务器
#
# 用法: ./deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

SERVER_IP="45.79.40.29"
REMOTE_USER="root"
REMOTE_DIR="/home/www/websites/cleaner.digsaw.cc"
REMOTE_BIN="${REMOTE_DIR}/smart-search"

BUILD_VERSION="$(date -u +%Y%m%d-%H%M%S)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LDFLAGS="-X main.BuildVersion=${BUILD_VERSION} -X main.BuildTime=${BUILD_TIME}"

echo "编译 Linux amd64..."
cd src/go
GOOS=linux GOARCH=amd64 go build -ldflags "${LDFLAGS}" -o smart-search .
cd "${SCRIPT_DIR}"

echo "上传到 ${REMOTE_USER}@${SERVER_IP}:${REMOTE_BIN} ..."
ssh "${REMOTE_USER}@${SERVER_IP}" "mkdir -p '${REMOTE_DIR}'"
scp src/go/smart-search "${REMOTE_USER}@${SERVER_IP}:${REMOTE_BIN}"
ssh "${REMOTE_USER}@${SERVER_IP}" "chmod +x '${REMOTE_BIN}'"

echo "完成 buildVersion=${BUILD_VERSION}"
