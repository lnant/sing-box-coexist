# sing-box-coexist

sing-box 一键安装脚本，**全程零交互**，复制一条命令即可装好 7 种协议。

本项目参考 [lnant/sing-box-auto](https://github.com/lnant/sing-box-auto)（六合一版）改造：
在原有 6 种协议之外，新增一条 **VLESS + WebSocket + TLS 域名链**，与 **Argo 隧道链共存**——
域名链可直连或套 Cloudflare，Argo 走隧道，两条链路互为备份，一条被干扰另一条还能用。

## 协议一览

| # | 协议 | 说明 |
|---|---|---|
| 1 | VLESS + Reality (TCP) | 直连 |
| 2 | VMess + WebSocket (TCP) | 直连 |
| 3 | VMess + Argo 隧道 | Cloudflare 隧道（临时/固定），不暴露源站 IP、无需公网入站 |
| 4 | Hysteria2 (UDP) | 直连 |
| 5 | TUIC v5 (UDP) | 直连 |
| 6 | AnyTLS (TCP) | 直连 |
| 7 | VLESS + WebSocket + TLS (TCP) | **新增**：域名链，可套 Cloudflare，与 Argo 共存互备 |

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-coexist/main/sing-box-auto.sh | sudo bash
```

要求：Linux 服务器（Debian / Ubuntu / CentOS / Oracle Linux 等），**root 权限**，
x86_64 / arm64 / armv7 架构，内存建议 ≥1 GB。

## 全自动逻辑（零交互）

安装全程不需要回答任何问题。少数可选点会限时等待（输入类 60 秒、选择类 20 秒），无输入自动走默认：

- **TLS 域名**：60 秒内可手填自己的域名；不填则自动生成临时域名
  （有 Cloudflare API Token 时在账号域名下自动开随机子域名并申请真证书；
  没有时用基于公网 IP 的 sslip.io 临时域名 + 自签证书，立即可用）。
  装后随时可运行 `sbox change-domain` 换成真域名：换域名时自动申请
  Let's Encrypt 真证书（DNS-01 验证）并套 Cloudflare（橙色云 + SSL 完全严格）。
- **Argo 隧道**：60 秒内可填固定隧道 Token + 域名；不填默认用临时隧道。
- **WARP 出站**：安装时以 20 秒选择题出现——纯 IPv6 / 无 IPv4 出口的机器默认开启「仅 IPv4 经 WARP」，其余默认关闭；注册与参数全自动生成，失败自动降级关闭、不阻塞安装。部分机器 IP 纯净度较低、无法解锁部分流媒体服务，或纯 IPv6 无法访问 IPv4 网站时，WARP 可提供相对干净的双栈出口。装后在「WARP 出站管理」里可查看当前出口 IP 与落地国家、更换 WARP IP、切换模式或关闭（关闭后配置里不留任何 WARP 内容、零成本）。
- **端口**：随机分配（互不冲突）；域名链端口优先选 Cloudflare 支持的
  443 / 8443 / 2053 / 2083 / 2087 / 2096，将来套 CF 不用再换端口。
- **防火墙**：自动放行所需端口（仅在 firewalld / ufw 已启用时操作它们，
  iptables 只加本脚本自己端口的规则）。

## 资源占用

实测（1 OCPU / 6 GB 机器）：sing-box 约 15 MB + cloudflared 约 23 MB 内存，
合计不到 40 MB，不影响同机其他服务；服务与隧道由 systemd 托管（崩溃自动拉起），
无 systemd 时以 cron `@reboot` 兜底。

## 管理

装好后直接运行 `sbox` 进管理菜单，或用动作参数：

```bash
sbox                    # 管理菜单
sbox show-links         # 重新打印全部链接
sbox change-domain      # 更换 TLS 域名（可申请真证书 / 套 Cloudflare）
sbox change-argo        # Argo 隧道管理（临时/固定切换）
sbox change-warp        # WARP 出站管理（开关/模式/更换出口 IP）
sbox change-ports       # 更换端口
sbox restart            # 重启服务
sbox uninstall          # 卸载（会一并删掉脚本在 Cloudflare 建的解析记录）
sbox update-core        # 更新 sing-box 内核
sbox update-script      # 更新脚本自身
sbox version            # 查看版本
```

链接保存在 `/root/singbox-links.txt`。

## 版本

当前版本：**v1.1.0**（变更记录见 [CHANGELOG.md](CHANGELOG.md)，发布包见 GitHub Releases）。
一键安装默认拉取最新版（main 分支）；把命令里的 `main` 换成版本号 tag（如 `v1.0.0`）
即可固定版本安装。
