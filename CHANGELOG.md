# 更新日志

本项目的版本号写在脚本的 `SCRIPT_VERSION` 里，并与 GitHub 的 tag / Release 对应。
一键安装默认拉最新版（main 分支）；把安装命令里的 `main` 换成某个 tag（如 `v1.0.0`）即可固定版本安装。

## v1.0.0（首个发布）

参考 lnant/sing-box-auto（六合一版）改造的新项目，独立发布。主要内容：

- 7 种协议：VLESS+Reality、VMess+WS、VMess+Argo、Hysteria2、TUIC、AnyTLS，
  以及新增的 VLESS+WebSocket+TLS 域名链——与 Argo 隧道链共存互备
- TLS 域名全自动：安装时 10 秒无输入自动生成临时域名（有 Cloudflare API Token
  时自动开子域名 + 真证书；否则 sslip.io 临时域名 + 自签证书）
- `change-domain` 换真域名：自动申请 Let's Encrypt 真证书（DNS-01）并套
  Cloudflare（橙色云 + SSL 完全严格）；证书失败自动回退自签，不锁死链路
- ACME 配置按 sing-box 1.14 实际字段生成（`data_directory` / `dns01_challenge`，
  已在 1.14.4 上实测签发成功；注：内联 ACME 在 1.14 已标记弃用、1.16 将移除）
- Argo 隧道：安装时 10 秒内可填固定隧道 Token/域名，默认临时隧道
- 域名链端口优先选 Cloudflare 支持的端口集（443/8443/2053/2083/2087/2096）
- Cloudflare 操作防误伤：删解析记录前先回查核对、多域名账号下明确播报
  选用的域名、Token 字符集校验；进程与定时任务清理按本脚本安装路径精确匹配
- 发布前经两家外部 AI 模型（Gemini、GitHub Copilot）交叉审核并按意见修订，
  并在真实服务器完成全自动安装 + 双链握手实测
