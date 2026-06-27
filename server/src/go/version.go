package main

// 由 deploy.sh 通过 -ldflags 注入，本地 go build 默认为 dev
var (
	BuildVersion = "dev"
	BuildTime    = "unknown"
)
