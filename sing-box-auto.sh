#!/bin/bash
###############################################################################
# sing-box 全自动一键安装脚本（7 协议版）
#
# 功能：零交互，一次装好以下 7 种协议
#   [1] VLESS + Reality (TCP)
#   [2] VMess + WebSocket (TCP)
#   [3] VMess + Argo 隧道 (Cloudflare 临时隧道，转发到 VMess-WS)
#   [4] Hysteria2 (UDP)
#   [5] TUIC v5 (UDP)
#   [6] AnyTLS (TCP)
#   [7] VLESS + WebSocket + TLS (域名链，与 Argo 共存：域名直连/套 Cloudflare，
#       Argo 走隧道，两条链路互为备份)
#
# 用法：
#   安装：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-coexist/main/sing-box-auto.sh | sudo bash
#   卸载：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-coexist/main/sing-box-auto.sh | sudo bash -s -- uninstall
#   管理菜单：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-coexist/main/sing-box-auto.sh | sudo bash -s -- menu
#   （或下载后 sudo bash sing-box-auto.sh menu）
#   动作参数：menu | change-uuid | change-reality | change-cert | change-argo
#            | change-warp | warp-reroll | change-domain | change-ports
#            | show-links | restart | uninstall
#            | update-script | update-core | version
#   快捷命令：安装时会自动装好 sbox 命令（/usr/local/bin/sbox），之后直接打
#            sbox 就进管理菜单（非 root 会自动 sudo 提权），sbox <动作> 执行对应操作
#
# 特性：
#   - 全程无交互：UUID、密码、Reality 密钥对全部自动生成
#   - 可选提问：有终端时安装会给 60 秒窗口填 TLS 域名与固定隧道 Token，
#     超时或无终端（curl|bash、远程无 tty）自动走默认——TLS 域名默认用
#     服务器 IP 生成的 sslip.io 临时域名，隧道默认临时隧道；事后均可改：
#     sbox change-domain 换域名（可同时申请真证书并套 Cloudflare），
#     sbox change-argo 切换固定/临时隧道
#   - 随机端口：新装时 5 个协议端口在 10000-60000 内随机分配（互不冲突，避开已占用），
#     多台服务器端口各不相同；重跑/升级保留已有端口，菜单 7 可手动改
#   - 防火墙：自动从配置提取监听端口并在 firewalld/ufw/iptables 放行，
#     配置增减协议或换端口时自动跟上
#   - 证书：自动生成 www.bing.com 自签证书（供 Hy2/TUIC/AnyTLS/VMess-WS 使用）
#   - 幂等：重复运行保留已有 UUID/端口/密钥，只重写配置并重启；
#     也能识别互联网上知名同类脚本留下的配置并导入
#   - 安装后打印全部客户端链接，并保存到 /root/singbox-links.txt
#
# 参考互联网上知名的相关 sing-box 一键脚本，交互点已全部自动化，详见本仓库 README.md
###############################################################################
set -euo pipefail

#----------------------------- 0. 参数与常量 ---------------------------------
# 通过 sbox 快捷命令调用且无参数时默认进菜单；其他方式无参数默认执行安装
if [[ "$(basename "$0")" == "sbox" && $# -eq 0 ]]; then
  ACTION="menu"
else
  ACTION="${1:-install}"        # install | uninstall | menu | change-uuid | change-reality | change-cert | change-argo | change-domain | change-ports | show-links | restart | update-script | update-core | version
fi

SCRIPT_VERSION="1.1.0"          # 脚本版本号（与仓库 tag / Release 对应，见 CHANGELOG.md）
INPUT_TIMEOUT=60                # 输入类等待秒数：60 秒无输入自动按默认走下一步
CHOICE_TIMEOUT=20               # 选择类等待秒数：20 秒无选择/回车一律取默认选择

# version 动作只打印版本，不需要 root / 已安装，提前处理
if [[ "$ACTION" == "version" ]]; then
  echo "sing-box-coexist v${SCRIPT_VERSION}（全自动 7 协议版）"
  exit 0
fi

SB_DIR="/etc/s-box"
UNIT="sing-box-auto"           # systemd 服务名：用专属名，避免覆盖机器上已有的其他 sing-box 安装
ARGO_UNIT="${UNIT}-argo"       # Argo 隧道的 systemd 服务名（cloudflared 交 systemd 托管，崩溃自动拉起）
ENV_FILE="$SB_DIR/auto.env"    # 持久化：UUID/端口/密钥，重跑时复用
CF_ENV_FILE="$SB_DIR/cf.env"   # 持久化：Cloudflare API Token（仅换域名申请证书/套 CF 时用，600 权限）
WARP_ENV_FILE="$SB_DIR/warp.env"   # 持久化：WARP 出站模式与 wgcf 一次性注册参数（菜单 change-warp 管理，600 权限）
LINKS_FILE="/root/singbox-links.txt"

# 端口分配：新装时随机（10000-60000），重跑/升级保留已有端口（见 load_or_gen_identity）

SNI_REALITY="apple.com"        # Reality 伪装域名（常见默认值）
SNI_SELF="www.bing.com"        # 自签证书 CN

if [[ "$EUID" -ne 0 ]]; then
  # sbox 快捷命令：非 root 时自动提权，opc 下直接打 sbox 就能进菜单
  if [[ "$(basename "$0")" == "sbox" ]]; then
    exec sudo "$0" "$@"
  fi
  echo "[错误] 请以 root 运行，例如：sudo bash $0"
  exit 1
fi

#----------------------------- 1. 系统识别 -----------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    OS_ID="unknown"
  fi
  if command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG="yum"
  elif command -v apk >/dev/null 2>&1; then PKG="apk"
  else echo "[错误] 不支持的系统：找不到 apt/dnf/yum/apk"; exit 1; fi
  if [[ "$PKG" == "apk" ]]; then
    echo "[警告] Alpine 未充分验证：运行前请确认已 apk add bash，且 dcron 已启用（rc-update add dcron），否则脚本解释器或开机自启会出问题"
  fi
  echo "[信息] 系统：${OS_ID}，包管理器：${PKG}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    *) echo "[错误] 不支持的架构：$(uname -m)"; exit 1 ;;
  esac
  echo "[信息] 架构：${ARCH}"
}

install_deps() {
  # 先检查缺什么：齐了就直接跳过，dnf 在小内存机器上又慢又吃内存
  local need="" pkgs="" c
  command -v curl >/dev/null 2>&1 || need="$need curl"
  command -v jq >/dev/null 2>&1 || need="$need jq"
  command -v openssl >/dev/null 2>&1 || need="$need openssl"
  command -v tar >/dev/null 2>&1 || need="$need tar"
  { command -v ss >/dev/null 2>&1 || command -v ip >/dev/null 2>&1; } || need="$need iproute"
  command -v crontab >/dev/null 2>&1 || need="$need cron"
  if [[ -z "${need// }" ]]; then
    echo "[信息] 依赖已齐全，跳过安装"
    return 0
  fi
  # 包名映射（cron、iproute 在不同发行版名字不一样）
  for c in $need; do
    case "$c" in
      cron)
        case "$PKG" in
          apt) pkgs="$pkgs cron" ;;
          apk) pkgs="$pkgs dcron" ;;
          *) pkgs="$pkgs cronie" ;;
        esac ;;
      iproute)
        case "$PKG" in
          apt|apk) pkgs="$pkgs iproute2" ;;
          *) pkgs="$pkgs iproute" ;;
        esac ;;
      *) pkgs="$pkgs $c" ;;
    esac
  done
  # apt/apk 顺带补 ca-certificates：极简镜像缺它时 curl 拉 https 会证书校验失败（与精简版对齐）
  case "$PKG" in
    apt|apk) pkgs="$pkgs ca-certificates" ;;
  esac
  echo "[信息] 安装缺失依赖：${pkgs} …"
  # 转成数组再传给包管理器，避免未引用展开的分词歧义（SC2086）
  local -a pkgarr
  read -ra pkgarr <<< "$pkgs"
  case "$PKG" in
    apt) apt-get update -y >/dev/null 2>&1 || true
         DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgarr[@]}" >/dev/null 2>&1 || true ;;
    dnf) dnf install -y --setopt=install_weak_deps=False "${pkgarr[@]}" >/dev/null 2>&1 || true ;;
    yum) yum install -y "${pkgarr[@]}" >/dev/null 2>&1 || true ;;
    apk) apk add --no-cache "${pkgarr[@]}" >/dev/null 2>&1 || true ;;
  esac
  command -v curl >/dev/null 2>&1 || { echo "[错误] curl 安装失败"; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "[错误] jq 安装失败"; exit 1; }
}

check_memory() {
  # 小内存机器预警：dnf 单次可占 350M+，无 swap 时易 OOM 卡死整机（实测 498M 机器被顶爆过）
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 1048576 ] && [ "$swap_kb" -eq 0 ]; then
    echo "[警告] 内存较小 ($((mem_kb / 1024))M) 且无 swap，装依赖时 dnf 可能 OOM 导致卡死"
    echo "[警告] 建议先加 swap：fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    echo "[警告] 继续安装…"
  fi
}

disable_dnf_makecache() {
  # 小内存机器（<2G）禁用 dnf-makecache 定时器：后台自动跑 dnf 易致 OOM
  # 只影响软件源缓存的自动更新，手动 dnf 不受影响
  case "$PKG" in
    dnf|yum) ;;
    *) return 0 ;;
  esac
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl list-unit-files 2>/dev/null | grep -q "^dnf-makecache\.timer" || return 0
  local mem_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 2097152 ]; then
    if systemctl is-enabled --quiet dnf-makecache.timer 2>/dev/null; then
      systemctl disable --now dnf-makecache.timer >/dev/null 2>&1 || true
      echo "[信息] 已禁用 dnf-makecache 定时器（小内存机器，后台自动 dnf 易致 OOM）"
    fi
  fi
}

# 容器环境提示：兜底自启依赖 cron 的 @reboot，容器里通常没有真正的 reboot 语义、
# 也不跑 cron 守护——提前说明，避免用户误以为重启后还能自动拉起
check_container() {
  if [[ -f /.dockerenv ]] || { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; }; then
    echo "[提示] 检测到容器环境：开机自启（systemd / cron @reboot）在容器中通常不生效，"
    echo "       本次安装只保证容器运行期间可用；容器重建后请重新运行安装命令"
  fi
}

#----------------------------- 2. 端口分配 -----------------------------------
# 端口是否被占用（TCP/UDP 一起查）
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -tunlp 2>/dev/null | grep -Eo ':[0-9]+' | grep -qw ":$p"; then
      return 0
    fi
  fi
  return 1
}

# 随机分配空闲端口（10000-60000），避开已占用和本次已分配的
rand_port() {
  # 在 10000-60000 内随机取一个空闲端口
  # 参数 $1：已分配端口列表（空格分隔，如 " 12345 23456 "），避免 5 个协议互相冲突
  # 无参调用（如 warp_probe）时 $1 未绑定，set -u 下会直接炸，用 ${1:-} 容错
  local allocated="${1:-}" p tries=0
  while (( tries < 100 )); do
    p=$(( (RANDOM * 32768 + RANDOM) % 50001 + 10000 ))
    if [[ "$allocated" != *" $p "* ]] && ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    tries=$((tries + 1))
  done
  echo "[错误] 无法分配随机空闲端口" >&2
  return 1   # 只 return 不 exit：本函数多在命令替换（子 shell）里调用，失败语义交给调用方明确处理
}

#----------------------------- 3. 防火墙放行 ---------------------------------
# 自适应放行：从已生成的 sing-box 配置里提取所有 inbound 监听端口，
# TCP+UDP 双开。以后脚本增减协议、换端口，这里自动跟上，无需维护端口列表。
# 必须在 write_config 之后调用。云厂商安全组/安全列表需在控制台另行放行。
open_firewall() {
  local ports=""
  if [[ -f "$SB_DIR/sb.json" ]] && command -v jq >/dev/null 2>&1; then
    ports=$(jq -r '.inbounds[].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null | sort -un | tr '\n' ' ' || true)
  fi
  # 回退：配置文件不存在或 jq 不可用时，用 PORT_* 变量
  if [[ -z "${ports// }" ]]; then
    ports="${PORT_VLESS:-} ${PORT_VMESS:-} ${PORT_HY2:-} ${PORT_TUIC:-} ${PORT_ANYTLS:-} ${PORT_VTLS:-}"
  fi
  # 直连真证书（direct 模式）签发/续期要走 HTTP-01，额外放行 80
  if [[ "${TLS_ACME:-0}" == "1" && "${TLS_ACME_MODE:-cf}" == "direct" ]]; then
    ports="${ports} 80"
  fi
  if [[ -z "${ports// }" ]]; then
    echo "[警告] 未找到需要放行的端口，跳过防火墙设置"
    return 0
  fi
  echo "[信息] 放行防火墙端口：${ports}（TCP+UDP）…"
  local p
  # firewalld：仅当正在运行时加规则，不擅自启停它
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    for p in $ports; do
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
      firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  # ufw：仅当已启用时加规则
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in $ports; do
      ufw allow "${p}/tcp" >/dev/null 2>&1
      ufw allow "${p}/udp" >/dev/null 2>&1
    done
  fi
  # iptables：显式加 ACCEPT 规则（已存在则跳过，不动其他规则）
  if command -v iptables >/dev/null 2>&1; then
    for p in $ports; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    # 持久化（尽力而为）
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    service iptables save >/dev/null 2>&1 || true
  fi
  # ip6tables：纯 IPv6 机器上 iptables 管不到 v6，需单独放行
  if command -v ip6tables >/dev/null 2>&1; then
    for p in $ports; do
      ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    service ip6tables save >/dev/null 2>&1 || true
  fi
  # 回读校验：至少确认一条路径真的放行成功。纯 nftables 等未覆盖的防火墙下，
  # 上面的命令可能全部静默失败——那种情况必须明确警告，不能笼统报"已放行"
  local first_port="${ports%% *}" fw_ok=0
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null \
     && firewall-cmd --list-ports 2>/dev/null | grep -qw "${first_port}/tcp"; then
    fw_ok=1
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" \
     && ufw status 2>/dev/null | grep -qw "$first_port"; then
    fw_ok=1
  elif command -v iptables >/dev/null 2>&1 \
     && iptables -C INPUT -p tcp --dport "$first_port" -j ACCEPT 2>/dev/null; then
    fw_ok=1
  elif command -v ip6tables >/dev/null 2>&1 \
     && ip6tables -C INPUT -p tcp --dport "$first_port" -j ACCEPT 2>/dev/null; then
    fw_ok=1
  fi
  if (( fw_ok == 1 )); then
    echo "[信息] 防火墙已放行"
  else
    echo "[警告] 未能确认防火墙放行成功（本机可能使用纯 nftables 等未覆盖的防火墙）"
    echo "[警告] 请手动放行端口：${ports}（TCP+UDP），云厂商安全组同样需要放行"
  fi
}

#----------------------------- 4. 安装 sing-box ------------------------------
# GitHub 可达性预检（装机时在主流程开头先跑，fetch_latest_version 里也会兜底调用）：
# api.github.com / github.com 至今只有 IPv4 地址，纯 IPv6 机器、或 IPv4 出站损坏
# （形同纯 v6）的机器会死在查版本/下内核这一步。判断看行为不看配置：
#   - GitHub 已可达（v4 正常，或线路自带 NAT64）→ 什么都不动，直接装
#   - 不可达但有 IPv6 出站 → 先跑一段引导：把 resolv.conf 换成公共 DNS64
#     （nat64.net，改前备份、换后复探、仍不通自动还原），通了再继续装
# 本段所有提示走 stderr：fetch_latest_version 的 stdout 是版本号，不能污染。
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
DNS64_SERVERS=("2a01:4f8:c2c:123f::1" "2a01:4ff:f0:9876::1" "2a01:4f9:c010:3f02::1")
_GH_OK=""

gh_probe() {  # 拿到任意 HTTP 状态码即算可达（403 是 GitHub 限流，不是连不上）
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 https://api.github.com 2>/dev/null) || true
  [[ -n "$code" && "$code" != "000" ]]
}

ensure_github() {
  [[ "$_GH_OK" == "1" ]] && return 0
  if gh_probe; then _GH_OK=1; return 0; fi
  echo "[信息] GitHub 直连不通，检测是否为纯 IPv6 / IPv4 出站异常环境…" >&2
  if ! curl -6 -fsS --connect-timeout 5 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    echo "[警告] 本机也没有 IPv6 出站，无法自动绕行到 GitHub。" >&2
    echo "[警告] 可手动把 sing-box 二进制预置到 $SB_DIR/sing-box、cloudflared 预置到 $SB_DIR/cloudflared 后重跑安装（脚本会跳过下载）。" >&2
    return 1
  fi
  local s
  for s in "${DNS64_SERVERS[@]}"; do
    if grep -qF "$s" "$RESOLV_CONF" 2>/dev/null; then
      echo "[警告] 已在使用公共 DNS64 但 GitHub 仍不可达，本次不重复修改 DNS。" >&2
      return 1
    fi
  done
  if [[ -L "$RESOLV_CONF" ]] && readlink "$RESOLV_CONF" 2>/dev/null | grep -q "systemd/resolve"; then
    echo "[警告] resolv.conf 由 systemd-resolved 托管，无法自动切换 DNS64；请手动把上行 DNS 改为 DNS64 后重试。" >&2
    return 1
  fi
  [[ -w "$RESOLV_CONF" ]] || { echo "[警告] $RESOLV_CONF 不可写，无法自动切换 DNS64。" >&2; return 1; }
  local bak="${RESOLV_CONF}.sbox-bak"
  [[ -f "$bak" ]] || cp -L "$RESOLV_CONF" "$bak" 2>/dev/null || true
  echo "[信息] 引导：切换 DNS 到公共 DNS64（nat64.net），经 NAT64 绕行访问 GitHub…" >&2
  { for s in "${DNS64_SERVERS[@]}"; do echo "nameserver $s"; done; } > "$RESOLV_CONF"
  # NAT64 冷启动慢（真机实测：换完 DNS 立刻探活常超时，稍等就通）：复探给 3 次
  # 机会、间隔递增，别一次判死刑就还原——真机上就是靠第二次调用救回来的
  local try
  for try in 1 2 3; do
    if gh_probe; then
      _GH_OK=1
      echo "[信息] DNS64 已生效，GitHub 可达，继续安装。原 DNS 配置备份在 $bak（不再需要绕行时可还原）。" >&2
      return 0
    fi
    [[ "$try" -lt 3 ]] && sleep $((try * 3))
  done
  [[ -f "$bak" ]] && cp "$bak" "$RESOLV_CONF" 2>/dev/null || true
  echo "[警告] DNS64 绕行未生效，已还原 DNS 配置；请预置二进制（见上）或检查 IPv6 线路后重试。" >&2
  return 1
}

# 取 sing-box 最新正式版版本号（不含 v 前缀）；失败时输出空字符串
fetch_latest_version() {
  local ver=""
  ensure_github || true
  # 优先 GitHub API，失败回退到 releases 页面解析
  ver=$(curl -fsSL --max-time 15 --retry 2 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//' || true)
  if [[ -z "$ver" ]]; then
    ver=$(curl -fsSL --max-time 15 --retry 2 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -n 1 || true)
  fi
  echo "$ver"
}

# 下载并解压指定版本到 $SB_DIR；失败返回非 0（不直接退出，由调用方决定回滚或报错）
download_singbox() {
  local ver="$1"
  local name="sing-box-${ver}-linux-${ARCH}"
  curl -fSL --retry 2 --max-time 120 -o "$SB_DIR/sing-box.tar.gz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${name}.tar.gz" || return 1
  tar xzf "$SB_DIR/sing-box.tar.gz" -C "$SB_DIR" || return 1
  mv -f "$SB_DIR/$name/sing-box" "$SB_DIR/sing-box" || return 1
  rm -rf "$SB_DIR/sing-box.tar.gz" "$SB_DIR/${name:?}"
  chmod +x "$SB_DIR/sing-box"
}

install_singbox() {
  mkdir -p "$SB_DIR"
  if [[ -x "$SB_DIR/sing-box" ]]; then
    echo "[信息] sing-box 已安装：$("$SB_DIR/sing-box" version 2>/dev/null | awk '/version/{print $NF}')"
    return 0
  fi
  echo "[信息] 获取 sing-box 最新版本…"
  local ver=""
  ver=$(fetch_latest_version)
  [[ -z "$ver" ]] && { echo "[错误] 获取 sing-box 版本失败，请检查网络"; exit 1; }
  echo "[信息] 最新版本：v$ver，开始下载…"
  download_singbox "$ver" || { echo "[错误] sing-box 下载失败"; exit 1; }
  echo "[信息] sing-box 安装成功：$("$SB_DIR/sing-box" version | awk '/version/{print $NF}')"
}

# 更新 sing-box 内核到最新正式版：先备份旧版；新版过不了现有配置校验时自动回滚
do_update_core() {
  if [[ ! -x "$SB_DIR/sing-box" ]]; then
    echo "[错误] sing-box 尚未安装，无法更新内核"
    return 1
  fi
  local cur="" latest=""
  cur=$("$SB_DIR/sing-box" version 2>/dev/null | awk '/version/{print $NF}')
  echo "[信息] 当前 sing-box 版本：v$cur，获取最新版本…"
  latest=$(fetch_latest_version)
  [[ -z "$latest" ]] && { echo "[错误] 获取 sing-box 最新版本失败，请检查网络"; return 1; }
  if [[ "$cur" == "$latest" ]]; then
    echo "[信息] 已是最新版本 v$cur，无需更新"
    return 0
  fi
  echo "[信息] 发现新版本：v$cur → v$latest，开始更新…"
  cp -f "$SB_DIR/sing-box" "$SB_DIR/sing-box.bak"
  if ! download_singbox "$latest"; then
    mv -f "$SB_DIR/sing-box.bak" "$SB_DIR/sing-box"
    echo "[错误] 新版下载失败，已恢复旧版 v$cur"
    return 1
  fi
  if [[ -f "$SB_DIR/sb.json" ]] && ! "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1; then
    mv -f "$SB_DIR/sing-box.bak" "$SB_DIR/sing-box"
    setup_service
    echo "[错误] 新版 sing-box 与现有配置不兼容，已回滚到 v$cur 并重启服务"
    return 1
  fi
  setup_service
  echo "[完成] sing-box 内核已更新：v$cur → v$latest（旧版备份在 $SB_DIR/sing-box.bak，如需可手动恢复）"
}

#----------------------------- 4.1 快捷命令 ----------------------------------
# 把本脚本安装为 sbox 系统命令：sudo sbox 进菜单，sudo sbox <动作> 直达操作
# 从 GitHub 拉取最新脚本（带防缓存 + 备用源），成功返回 0
fetch_latest_script() {
  local dest="$1"
  local ts url
  ts=$(date +%s)
  # 优先跟随最新 Release（tag），避免 main 上未发布的改动直接打到已安装机器；取不到 tag 再回退 main
  local tag=""
  tag=$(curl -fsSL --max-time 15 https://api.github.com/repos/lnant/sing-box-coexist/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
  local urls=()
  if [[ -n "$tag" ]]; then
    urls+=(
      "https://raw.githubusercontent.com/lnant/sing-box-coexist/${tag}/sing-box-auto.sh?t=${ts}"
      "https://cdn.jsdelivr.net/gh/lnant/sing-box-coexist@${tag}/sing-box-auto.sh"
    )
  fi
  urls+=(
    "https://raw.githubusercontent.com/lnant/sing-box-coexist/main/sing-box-auto.sh?t=${ts}"
    "https://cdn.jsdelivr.net/gh/lnant/sing-box-coexist@main/sing-box-auto.sh"
  )
  for url in "${urls[@]}"; do
    if curl -fsSL --max-time 60 --retry 2 "$url" -o "$dest" \
       && grep -q "sing-box 全自动一键安装脚本" "$dest" \
       && bash -n "$dest"; then
      return 0
    fi
    echo "[警告] 从 ${url%%\?*} 获取失败，尝试备用源…"
  done
  return 1
}

setup_shortcut() {
  echo "[信息] 安装 sbox 快捷命令…"
  # 优先把"正在运行的这份脚本自身"装为 sbox：用户跑的是哪个版本，sbox 就是哪个版本，不串版；
  # 管道运行（curl | bash）时拿不到自身文件，再回退到拉取最新正式版（update-script 的职责）
  local self="${BASH_SOURCE[0]:-}"
  if [[ -n "$self" && -f "$self" && "$self" != "/usr/local/bin/sbox" ]] \
     && grep -q "sing-box 全自动一键安装脚本" "$self" 2>/dev/null \
     && cp "$self" /usr/local/bin/sbox 2>/dev/null; then
    chmod 755 /usr/local/bin/sbox
    ln -sf /usr/local/bin/sbox /usr/bin/sbox 2>/dev/null || true
    echo "[信息] 快捷命令已安装：直接打 sbox 进管理菜单（自动提权）"
    return 0
  fi
  # 先下到临时文件、校验通过再覆盖（与 do_update_script 同一模式）：直接以 sbox 为下载目标时，
  # 网络中断会把已有的好文件截断成残件；走临时文件则失败时原文件原封不动
  local tmp_sbox
  tmp_sbox=$(mktemp)
  if fetch_latest_script "$tmp_sbox"; then
    cp -f "$tmp_sbox" /usr/local/bin/sbox
    chmod 755 /usr/local/bin/sbox
    # 部分系统 root 的 PATH（sudo secure_path）不含 /usr/local/bin，加个软链接兜底
    ln -sf /usr/local/bin/sbox /usr/bin/sbox 2>/dev/null || true
    echo "[信息] 快捷命令已安装：直接打 sbox 进管理菜单（自动提权）"
  else
    echo "[警告] sbox 快捷命令安装失败，可手动下载脚本使用"
  fi
  rm -f "$tmp_sbox"
}

#----------------------------- 5. 自签证书 -----------------------------------
# 对应同类脚本的证书选项：默认不申请 Acme，直接用自签证书
gen_certs() {
  if [[ -f "$SB_DIR/cert.pem" && -f "$SB_DIR/private.key" ]]; then
    echo "[信息] 自签证书已存在，跳过生成"
    return 0
  fi
  # SAN 带上自签伪装域名；有 TLS 域名时一并带上，域名链用同一张证书
  local _san="DNS:$SNI_SELF"
  if [[ -n "${TLS_DOMAIN:-}" && "$TLS_DOMAIN" != "$SNI_SELF" ]]; then
    _san="DNS:$SNI_SELF,DNS:$TLS_DOMAIN"
  fi
  # 再带上本机公网 IP（IP SAN）：纯 IP 型机器（无域名）按 IP 直连时，
  # 不允许 insecure 的客户端靠它完成 TLS 校验；拿不到的地址跳过该项
  local _lip
  for _lip in $(local_ip_set); do
    if [[ "$_lip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$_lip" == *:* ]]; then
      _san="$_san,IP:$_lip"
    fi
  done
  echo "[信息] 生成自签证书（CN=$SNI_SELF，SAN=$_san）…"
  openssl ecparam -genkey -name prime256v1 -out "$SB_DIR/private.key" 2>/dev/null
  # 必须带 SAN：现代 TLS 会拒绝只有 CN 的证书
  # （x509: certificate relies on legacy Common Name field）
  if ! openssl req -new -x509 -days 36500 -key "$SB_DIR/private.key" \
      -out "$SB_DIR/cert.pem" -subj "/CN=$SNI_SELF" \
      -addext "subjectAltName=$_san" 2>/dev/null; then
    # 老版本 OpenSSL 不支持 -addext，回退到配置文件方式
    local _cnf
    _cnf=$(mktemp)
    cat > "$_cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SNI_SELF
[ext]
subjectAltName = $_san
EOF
    openssl req -new -x509 -days 36500 -key "$SB_DIR/private.key" \
      -out "$SB_DIR/cert.pem" -config "$_cnf" 2>/dev/null
    rm -f "$_cnf"
  fi
  [[ -f "$SB_DIR/cert.pem" ]] || { echo "[错误] 证书生成失败"; exit 1; }
  echo "[信息] 自签证书生成成功"
}

#----------------------------- 6. 身份与端口 ----------------------------------
save_env() {
  cat > "$ENV_FILE" <<EOF
UUID="$UUID"
PRIVKEY="$PRIVKEY"
PUBKEY="$PUBKEY"
SHORTID="$SHORTID"
PORT_VLESS="$PORT_VLESS"
PORT_VMESS="$PORT_VMESS"
PORT_HY2="$PORT_HY2"
PORT_TUIC="$PORT_TUIC"
PORT_ANYTLS="$PORT_ANYTLS"
PORT_VTLS="${PORT_VTLS:-}"
TLS_DOMAIN="${TLS_DOMAIN:-}"
TLS_DOMAIN_AUTO="${TLS_DOMAIN_AUTO:-1}"
TLS_ACME="${TLS_ACME:-0}"
TLS_ACME_MODE="${TLS_ACME_MODE:-cf}"
EOF
  chmod 600 "$ENV_FILE"
}

# 为域名 TLS 入站挑端口：优选 Cloudflare 中转支持的 HTTPS 端口（将来套 CF 不用再换），
# 全被占才回退随机端口（回退后该链直连可用，但不能套 Cloudflare 橙色云）
pick_vtls_port() {
  local allocated="$1" p
  # 自动挑的顺序：443 优先（客户端网络兼容性最好），其次同为 Cloudflare
  # 支持的 HTTPS 端口；首次安装时用户可在提问环节改选其它端口
  for p in 443 8443 2053 2083 2087 2096; do
    if [[ "$allocated" != *" $p "* ]] && ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  rand_port "$allocated"
}

#----------------------------- 5.5 Cloudflare API -----------------------------
# 仅在换域名/自动域名需要时用：Token 来源（优先级）环境变量 SBOX_CF_TOKEN >
# $CF_ENV_FILE。普通安装没有 Token 时这些函数根本不会被调到。
load_cf_token() {
  CF_API_TOKEN=""
  if [[ -n "${SBOX_CF_TOKEN:-}" ]]; then
    CF_API_TOKEN="$SBOX_CF_TOKEN"
  elif [[ -f "$CF_ENV_FILE" ]]; then
    CF_API_TOKEN=$(grep '^CF_API_TOKEN=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  fi
  # 字符集校验：Token 只应含字母/数字/下划线/连字符，含其他字符一律视为
  # 无效并忽略（cf.env 只用 grep 解析、从不 source，这一步是双保险）
  if [[ -n "$CF_API_TOKEN" && ! "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "[警告] Cloudflare API Token 含非法字符，已忽略" >&2
    CF_API_TOKEN=""
  fi
  [[ -n "$CF_API_TOKEN" ]]
}

save_cf_token() {
  printf 'CF_API_TOKEN="%s"\n' "$CF_API_TOKEN" > "$CF_ENV_FILE"
  chmod 600 "$CF_ENV_FILE"
}

# $1=方法 $2=路径 $3=JSON 体（可选）；成功输出响应体，失败返回非 0
cf_api() {
  local _m="$1" _p="$2" _b="${3:-}"
  if [[ -n "$_b" ]]; then
    curl -fsSL --max-time 25 -X "$_m" "https://api.cloudflare.com/client/v4$_p" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      --data "$_b" 2>/dev/null
  else
    curl -fsSL --max-time 25 -X "$_m" "https://api.cloudflare.com/client/v4$_p" \
      -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null
  fi
}

# 逐级剥掉最左标签，找到 $1 所属的已激活 zone；输出 "zone_id<TAB>zone_name"
cf_zone_for_domain() {
  local cand="$1" _resp _zid
  while [[ "$cand" == *.* ]]; do
    if _resp=$(cf_api GET "/zones?name=$cand&status=active"); then
      _zid=$(printf '%s' "$_resp" | jq -r --arg n "$cand" '[.result[] | select(.name==$n) | .id][0] // empty' 2>/dev/null || true)
      if [[ -n "$_zid" ]]; then
        printf '%s\t%s\n' "$_zid" "$cand"
        return 0
      fi
    fi
    cand="${cand#*.}"
  done
  return 1
}

# 检查 zone 的 NS 是否已真正委托到 Cloudflare：返回 0=已委托，1=未委托，2=没查成
cf_zone_ns_check() {
  local _zid="$1" _zname="$2" _resp _assigned _public _ns
  _resp=$(cf_api GET "/zones/$_zid") || return 2
  _assigned=$(printf '%s' "$_resp" | jq -r '.result.name_servers[]? // empty' 2>/dev/null | sed 's/\.$//' || true)
  [[ -n "$_assigned" ]] || return 2
  _public=$(curl -fsSL --max-time 10 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$_zname&type=NS" 2>/dev/null | jq -r '.Answer[]?.data // empty' 2>/dev/null | sed 's/\.$//' || true)
  if [[ -z "$_public" ]]; then
    _public=$(curl -fsSL --max-time 10 "https://dns.google/resolve?name=$_zname&type=NS" 2>/dev/null | jq -r '.Answer[]?.data // empty' 2>/dev/null | sed 's/\.$//' || true)
  fi
  [[ -n "$_public" ]] || return 2
  while IFS= read -r _ns; do
    [[ -n "$_ns" ]] || continue
    if printf '%s\n' "$_public" | grep -qix "$_ns"; then
      return 0
    fi
  done <<< "$_assigned"
  return 1
}

# 冲突判定谓词（jq 片段，cf_domain_conflicts 与 cf_delete_conflicting_records
# 共用，改判定规则只改这一处，防两处分叉）：CNAME 独占域名、与 A/AAAA 不可
# 共存，恒算冲突；A/AAAA 只与本机同族记录比（A 与 AAAA 可共存、互不妨碍），
# 内容大小写归一后与本机地址不等的才算冲突。
# 调用方须以 --arg ip（裸地址）与 --arg want（A 或 AAAA）传入
cf_conflict_pred() {
  printf '%s' '(.type=="CNAME") or (.type==$want and ((.content|ascii_downcase) != ($ip|ascii_downcase)))'
}

# 列出 $2 上与本机冲突的记录摘要（空=无冲突）：同名 CNAME，或同族记录指向别处
cf_domain_conflicts() {
  local _zid="$1" _fqdn="$2" _ip="$3" _resp _want="A" _pred _jq
  _ip="${_ip#[}"; _ip="${_ip%]}"   # 归一化：get_ip 的 v6 带方括号，记录 content 是裸地址
  [[ "$_ip" == *:* ]] && _want="AAAA"
  _resp=$(cf_api GET "/zones/$_zid/dns_records?name=$_fqdn&per_page=100") || { printf ''; return 0; }
  _pred=$(cf_conflict_pred)
  _jq='[.result[] | select('"$_pred"') | "\(.type)→\(.content)"] | join("；")'
  printf '%s' "$_resp" | jq -r --arg ip "$_ip" --arg want "$_want" "$_jq" 2>/dev/null || true
}

# 删除 $2 上与本机冲突的记录（用户在冲突提示里确认覆盖后调用；判定与上共用谓词）
cf_delete_conflicting_records() {
  local _zid="$1" _fqdn="$2" _ip="$3" _resp _rid _want="A" _pred _jq
  _ip="${_ip#[}"; _ip="${_ip%]}"   # 归一化：同 cf_domain_conflicts
  [[ "$_ip" == *:* ]] && _want="AAAA"
  _resp=$(cf_api GET "/zones/$_zid/dns_records?name=$_fqdn&per_page=100") || return 0
  _pred=$(cf_conflict_pred)
  _jq='.result[] | select('"$_pred"') | .id'
  while IFS= read -r _rid; do
    [[ -n "$_rid" ]] || continue
    cf_api DELETE "/zones/$_zid/dns_records/$_rid" >/dev/null 2>&1 || true
  done < <(printf '%s' "$_resp" | jq -r --arg ip "$_ip" --arg want "$_want" "$_jq" 2>/dev/null || true)
}

# DNS-01 预检：在 _acme-challenge.$2 写一条随机 TXT，从公网 DNS 确认可见后删除；
# 可见返回 0（签发链大概率能走通），超时未见返回 1
cf_dns01_precheck() {
  local _zid="$1" _fqdn="$2" _name="_acme-challenge.$_fqdn" _val _resp _rid _i _seen=""
  _val="sbox-precheck-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  _resp=$(cf_api POST "/zones/$_zid/dns_records" "{\"type\":\"TXT\",\"name\":\"$_name\",\"content\":\"$_val\",\"ttl\":60}") || return 1
  _rid=$(printf '%s' "$_resp" | jq -r '.result.id // empty' 2>/dev/null || true)
  [[ -n "$_rid" ]] || return 1
  for _i in $(seq 1 12); do
    sleep 5
    _seen=$(curl -fsSL --max-time 8 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$_name&type=TXT" 2>/dev/null | jq -r '.Answer[]?.data // empty' 2>/dev/null | tr -d '"' || true)
    if [[ "$_seen" == *"$_val"* ]]; then
      break
    fi
    _seen=""
  done
  cf_api DELETE "/zones/$_zid/dns_records/$_rid" >/dev/null 2>&1 || true
  [[ -n "$_seen" ]]
}

# 换域名前的深度验证（有 CF Token 时）：zone 归属、NS 委托、现有解析冲突、
# DNS-01 预检；全部通过返回 0，任何一项不过打印原因返回 1（调用方重新让用户输入）
validate_cf_domain() {
  local _fqdn="$1" _z _zid _zname _nsrc _conf _ans _ip
  _z=$(cf_zone_for_domain "$_fqdn") || { echo "[错误] 在 Cloudflare 账号里找不到 $_fqdn 所属的已激活域名（确认域名已托管到该账号），请重新输入"; return 1; }
  _zid="${_z%%$'\t'*}"
  _zname="${_z##*$'\t'}"
  cf_zone_ns_check "$_zid" "$_zname"; _nsrc=$?
  if [[ "$_nsrc" == "1" ]]; then
    echo "[错误] $_zname 的 NS 还没有指到 Cloudflare（先在域名注册商处改成 Cloudflare 分配的 NS），请重新输入"
    return 1
  elif [[ "$_nsrc" == "2" ]]; then
    echo "[警告] NS 委托状态没查成（公共 DNS 查询失败），继续往下验证"
  fi
  _ip="$(get_ip)"
  _conf=$(cf_domain_conflicts "$_zid" "$_fqdn" "$_ip")
  if [[ -n "$_conf" ]]; then
    echo "[警告] $_fqdn 已有解析记录：$_conf"
    read -t "$CHOICE_TIMEOUT" -rp "输入 y 覆盖这些记录并继续（回车/输错/20 秒无输入 = 默认选择：重新输入域名）: " _ans || _ans=""
    if [[ "$_ans" != "y" && "$_ans" != "Y" ]]; then
      return 1
    fi
    cf_delete_conflicting_records "$_zid" "$_fqdn" "$_ip"
  fi
  echo "[信息] 正在做 DNS-01 预检（写入测试 TXT 记录并从公网确认）…"
  if ! cf_dns01_precheck "$_zid" "$_fqdn"; then
    echo "[错误] DNS-01 预检未通过：测试 TXT 记录写入后公网查不到（多半是 NS 委托或传播问题），证书大概率签不下来，请重新输入"
    return 1
  fi
  echo "[信息] 域名验证通过：$_fqdn（归属、NS、DNS-01 预检均正常）"
  return 0
}

# 把 $2 的 A 记录指向 $3 并开橙色云代理；输出 record_id
cf_upsert_a_record() {
  local _zid="$1" _fqdn="$2" _ip="$3" _resp _rid _body
  _resp=$(cf_api GET "/zones/$_zid/dns_records?type=A&name=$_fqdn") || return 1
  _rid=$(printf '%s' "$_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)
  _body=$(printf '{"type":"A","name":"%s","content":"%s","proxied":true,"ttl":1}' "$_fqdn" "$_ip")
  if [[ -n "$_rid" ]]; then
    cf_api PUT "/zones/$_zid/dns_records/$_rid" "$_body" >/dev/null || return 1
  else
    _resp=$(cf_api POST "/zones/$_zid/dns_records" "$_body") || return 1
    _rid=$(printf '%s' "$_resp" | jq -r '.result.id // empty' 2>/dev/null || true)
  fi
  printf '%s' "$_rid"
}

# 把 $2 的 AAAA 记录指向 $3（裸 IPv6，不带方括号）并开橙色云代理；输出 record_id
# 与 cf_upsert_a_record 对称，纯 IPv6 机器走这条路径
cf_upsert_aaaa_record() {
  local _zid="$1" _fqdn="$2" _ip="$3" _resp _rid _body
  _resp=$(cf_api GET "/zones/$_zid/dns_records?type=AAAA&name=$_fqdn") || return 1
  _rid=$(printf '%s' "$_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)
  _body=$(printf '{"type":"AAAA","name":"%s","content":"%s","proxied":true,"ttl":1}' "$_fqdn" "$_ip")
  if [[ -n "$_rid" ]]; then
    cf_api PUT "/zones/$_zid/dns_records/$_rid" "$_body" >/dev/null || return 1
  else
    _resp=$(cf_api POST "/zones/$_zid/dns_records" "$_body") || return 1
    _rid=$(printf '%s' "$_resp" | jq -r '.result.id // empty' 2>/dev/null || true)
  fi
  printf '%s' "$_rid"
}

# 给域名套上 Cloudflare：解析指向本机（橙色云）+ SSL 模式改完全（严格），
# 并把 zone/record 记进 cf.env，供换域名/卸载时清理本脚本建的记录
cf_setup_domain() {
  local _fqdn="$1" _z _zid _ip _bare _rtype _rid
  _z=$(cf_zone_for_domain "$_fqdn") || { echo "[错误] 在 Cloudflare 找不到 $_fqdn 所属的已激活域名（确认域名已托管到该账号）"; return 1; }
  _zid="${_z%%$'\t'*}"
  _ip="$(get_ip)"
  _bare="${_ip#[}"; _bare="${_bare%]}"   # 归一化：裸地址（CF API 的 content 不接受方括号写法）
  if [[ "$_bare" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    _rid=$(cf_upsert_a_record "$_zid" "$_fqdn" "$_bare") || { echo "[错误] Cloudflare 解析记录写入失败"; return 1; }
    _rtype="A"
  elif [[ "$_bare" == *:* ]]; then
    _rid=$(cf_upsert_aaaa_record "$_zid" "$_fqdn" "$_bare") || { echo "[错误] Cloudflare 解析记录写入失败"; return 1; }
    _rtype="AAAA"
  else
    echo "[错误] 未取得公网 IP（v4/v6 均无），无法设置解析"; return 1
  fi
  cf_api PATCH "/zones/$_zid/settings/ssl" '{"value":"strict"}' >/dev/null 2>&1 \
    || echo "[警告] SSL 模式自动设置失败，请在 Cloudflare 手动改为「完全（严格）」"
  {
    printf 'CF_API_TOKEN="%s"\n' "$CF_API_TOKEN"
    printf 'CF_ZONE_ID="%s"\n' "$_zid"
    printf 'CF_RECORD_ID="%s"\n' "$_rid"
    printf 'CF_RECORD_TYPE="%s"\n' "$_rtype"
    printf 'CF_HOST="%s"\n' "$_fqdn"
  } > "$CF_ENV_FILE"
  chmod 600 "$CF_ENV_FILE"
  TLS_ACME_MODE="cf"
  echo "[信息] 已套 Cloudflare：$_fqdn → $_bare（$_rtype，橙色云代理），SSL 模式=完全（严格）"
}

# 删除本脚本在 Cloudflare 建的解析记录（换域名/卸载时调用；没有记录则静默跳过）
cf_delete_managed_record() {
  [[ -f "$CF_ENV_FILE" ]] || return 0
  local _zid _rid
  _zid=$(grep '^CF_ZONE_ID=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  _rid=$(grep '^CF_RECORD_ID=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  [[ -n "$_zid" && -n "$_rid" ]] || return 0
  load_cf_token || return 0
  # 删之前先回查：记录还在、且名字确实是本脚本记下的 CF_HOST 才删，
  # 防止本地状态过期时误删别人的记录
  local _host _rname _chk
  _host=$(grep '^CF_HOST=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  if [[ -n "$_host" ]]; then
    _chk=$(cf_api GET "/zones/$_zid/dns_records/$_rid" 2>/dev/null || true)
    _rname=$(printf '%s' "${_chk:-}" | jq -r '.result.name // empty' 2>/dev/null || true)
    [[ "$_rname" == "$_host" ]] || return 0
  fi
  cf_api DELETE "/zones/$_zid/dns_records/$_rid" >/dev/null 2>&1 || true
}

# 有 CF Token 时的自动域名：在账号域名下开一个随机子域名套上 CF，
# 配合 ACME 真证书使用——不暴露源站 IP，也不依赖任何第三方临时域名服务
ensure_cf_auto_domain() {
  local _resp _zid _zname _label _fqdn _r
  if [[ -n "${SBOX_CF_ZONE:-}" ]]; then
    _resp=$(cf_api GET "/zones?name=$SBOX_CF_ZONE&status=active") || return 1
    _zid=$(printf '%s' "$_resp" | jq -r --arg n "$SBOX_CF_ZONE" '[.result[] | select(.name==$n) | .id][0] // empty' 2>/dev/null || true)
    _zname=$(printf '%s' "$_resp" | jq -r --arg n "$SBOX_CF_ZONE" '[.result[] | select(.name==$n) | .name][0] // empty' 2>/dev/null || true)
  else
    _resp=$(cf_api GET "/zones?status=active&per_page=50") || return 1
    _zid=$(printf '%s' "$_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)
    _zname=$(printf '%s' "$_resp" | jq -r '.result[0].name // empty' 2>/dev/null || true)
    # 账号里有多个域名时不许默默选错：明确播报建在哪个域名下，并给出指定办法
    local _nz
    _nz=$(printf '%s' "$_resp" | jq -r '.result | length' 2>/dev/null || echo 1)
    if [[ "${_nz:-1}" -gt 1 && -n "$_zname" ]]; then
      echo "[信息] Cloudflare 账号共有 ${_nz} 个域名，自动域名将建在 ${_zname} 下（指定其他域名：SBOX_CF_ZONE=域名）"
    fi
  fi
  [[ -n "$_zid" && -n "$_zname" ]] || return 1
  _r=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  _label="sbox-${_r:-a1b2c3}"
  _fqdn="$_label.$_zname"
  TLS_DOMAIN="$_fqdn"
  if ! cf_setup_domain "$_fqdn"; then
    TLS_DOMAIN=""
    return 1
  fi
  TLS_DOMAIN_AUTO=1
  TLS_ACME=1
  echo "[信息] TLS 域名自动生成（Cloudflare）：$TLS_DOMAIN（真证书 + 橙色云代理）"
}

# TLS 域名兜底：已设置则保留；未设置时优先用 Cloudflare 自动子域名（需已有
# Token），否则用公网 IP 生成 sslip.io 临时域名（解析直达本机、立即可用；
# IPv4 点换横杠、IPv6 冒号换横杠，两种写法均可解析出对应记录）。
# 两种临时域名事后都可用 sbox change-domain 换成自己的真域名。
ensure_tls_domain() {
  if [[ -n "${TLS_DOMAIN:-}" ]]; then
    TLS_DOMAIN_AUTO="${TLS_DOMAIN_AUTO:-0}"
    TLS_ACME="${TLS_ACME:-0}"
    return 0
  fi
  if load_cf_token && ensure_cf_auto_domain; then
    return 0
  fi
  local _ip _bare
  _ip="$(get_ip)"
  _bare="${_ip#[}"; _bare="${_bare%]}"   # 归一化：裸地址
  TLS_ACME=0
  if [[ "$_bare" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    TLS_DOMAIN="${_bare//./-}.sslip.io"
    TLS_DOMAIN_AUTO=1
    echo "[信息] TLS 域名自动生成（临时）：$TLS_DOMAIN"
  elif [[ "$_bare" == *:* ]]; then
    # sslip.io 的 IPv6 写法：冒号换横杠（:: 自然变成 --），可解析出 AAAA
    TLS_DOMAIN="${_bare//:/-}.sslip.io"
    TLS_DOMAIN_AUTO=1
    echo "[信息] TLS 域名自动生成（临时，IPv6）：$TLS_DOMAIN"
  else
    TLS_DOMAIN="$SNI_SELF"
    TLS_DOMAIN_AUTO=1
    echo "[警告] 未能获取公网 IP（v4/v6 均无），TLS 域名暂用 $SNI_SELF（链接以 IP 直连），稍后可运行 sbox change-domain 更换"
  fi
}

# 三级取值：①本脚本上次运行的 env → ②同类脚本残留配置 → ③全新生成
load_or_gen_identity() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    # 兼容精简版写下的 env：缺失的协议端口随机分配
    local used=" ${PORT_VLESS:-} ${PORT_VMESS:-} ${PORT_HY2:-} ${PORT_TUIC:-} ${PORT_ANYTLS:-} ${PORT_VTLS:-} "
    # 缺哪个补哪个：逐个显式分配并校验结果，不用链式 &&——链式写法在 rand_port 失败时会
    # 留下空端口继续往下跑，直到写配置时才以误导性报错失败
    local _pv _p
    for _pv in PORT_VLESS PORT_VMESS PORT_HY2 PORT_TUIC PORT_ANYTLS; do
      if [[ -z "${!_pv:-}" ]]; then
        _p=$(rand_port "$used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
        printf -v "$_pv" '%s' "$_p"
        used+=" $_p "
      fi
    done
    if [[ -z "${PORT_VTLS:-}" ]]; then
      PORT_VTLS=$(pick_vtls_port "$used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
      VTLS_PORT_FRESH=1
    fi
    ensure_tls_domain
    if [[ -n "${UUID:-}" && -n "${PRIVKEY:-}" && -n "${PUBKEY:-}" && -n "${SHORTID:-}" ]]; then
      echo "[信息] 检测到已有配置，UUID/端口/密钥保持不变（幂等重跑）"
      save_env
      return 0
    fi
    echo "[警告] 已有配置不完整，将重新生成身份信息"
  fi
  if [[ -f "$SB_DIR/sb.json" ]]; then
    local old_uuid=""
    old_uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
    if [[ -n "$old_uuid" ]]; then
      UUID="$old_uuid"
      PORT_VLESS=$(jq -r '.inbounds[0].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_VMESS=$(jq -r '.inbounds[1].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_HY2=$(jq -r '.inbounds[2].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_TUIC=$(jq -r '.inbounds[3].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_ANYTLS=$(jq -r '.inbounds[4].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      # 导入值逐个校验：残缺配置（inbound 不足 5 个）会读出空/null/非数字，坏端口直接随机补齐，
      # 避免把坏值写进新配置、最后在 sing-box check 处以误导性报错失败
      local _used=" " _pv _v _p
      for _pv in PORT_VLESS PORT_VMESS PORT_HY2 PORT_TUIC PORT_ANYTLS; do
        _v="${!_pv:-}"
        if [[ "$_v" =~ ^[0-9]+$ ]] && (( _v >= 1 && _v <= 65535 )) && [[ "$_used" != *" $_v "* ]]; then
          _used+=" $_v "
        else
          _p=$(rand_port "$_used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
          printf -v "$_pv" '%s' "$_p"
          _used+=" $_p "
        fi
      done
      if [[ -z "${PORT_VTLS:-}" ]]; then
        PORT_VTLS=$(pick_vtls_port "$_used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
        VTLS_PORT_FRESH=1
      fi
      ensure_tls_domain
      PRIVKEY=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      SHORTID=$(jq -r '.inbounds[0].tls.reality.short_id[0] // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PUBKEY="$(cat "$SB_DIR/public.key" 2>/dev/null || true)"
      if [[ -n "$PRIVKEY" && -n "$PUBKEY" && -n "$SHORTID" ]]; then
        echo "[信息] 从同类脚本残留配置导入 UUID/端口/密钥，客户端链接保持不变"
        save_env
        return 0
      fi
    fi
  fi
  echo "[信息] 生成 UUID 与 Reality 密钥对…"
  # uuid 生成：优先用 sing-box generate uuid，失败则用系统 uuid
  if "$SB_DIR/sing-box" generate uuid >/dev/null 2>&1; then
    UUID=$("$SB_DIR/sing-box" generate uuid)
  else
    UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  local kp
  kp=$("$SB_DIR/sing-box" generate reality-keypair)
  PRIVKEY=$(echo "$kp" | awk '/PrivateKey/{print $2}' | tr -d '"')
  PUBKEY=$(echo "$kp" | awk '/PublicKey/{print $2}' | tr -d '"')
  echo "$PUBKEY" > "$SB_DIR/public.key"
  SHORTID=$("$SB_DIR/sing-box" generate rand --hex 4)
  if [[ -z "$PRIVKEY" || -z "$PUBKEY" || -z "$SHORTID" ]]; then
    echo "[错误] Reality 密钥生成失败"; exit 1
  fi
  local used=" "
  PORT_VLESS=$(rand_port "$used"); used+=" $PORT_VLESS "
  PORT_VMESS=$(rand_port "$used"); used+=" $PORT_VMESS "
  PORT_HY2=$(rand_port "$used"); used+=" $PORT_HY2 "
  PORT_TUIC=$(rand_port "$used"); used+=" $PORT_TUIC "
  PORT_ANYTLS=$(rand_port "$used"); used+=" $PORT_ANYTLS "
  PORT_VTLS=$(pick_vtls_port "$used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
  VTLS_PORT_FRESH=1
  ensure_tls_domain
  echo "[信息] 端口分配：VLESS=$PORT_VLESS VMess-WS=$PORT_VMESS Hy2=$PORT_HY2 TUIC=$PORT_TUIC AnyTLS=$PORT_ANYTLS VLESS-WS-TLS=$PORT_VTLS"
  save_env
}

#----------------------------- 6.5 安装时可选提问 ------------------------------
# 只在有控制终端时出现：输入类等 60 秒、选择类等 20 秒，回车/超时一律取默认；无终端（curl|bash、远程无 tty、定时任务）
# 或超时未输入，一律走已生成的默认——TLS 域名默认临时域名、隧道默认临时隧道，
# 全程静默不受影响；填了的值事后都能改（change-domain / change-argo）。
# 清理用户输入的域名：去空白、协议头、路径与尾点，并转小写（粘贴时常带这些）
clean_domain() {
  printf '%s' "$1" | tr -d '[:space:]' | sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#/.*$##' -e 's/\.$//' | tr 'A-Z' 'a-z'
}

# 域名格式校验：至少两段，每段字母数字开头结尾、中间可含连字符，总长 ≤253
valid_domain_format() {
  local d="$1"
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# 公共 DNS 查 $1 的 A 记录，输出逗号分隔的 IP 列表（无记录/查询失败输出空）
domain_a_records() {
  local _out
  _out=$(curl -fsSL --max-time 8 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null | jq -r '[.Answer[]? | select(.type==1) | .data] | join(",")' 2>/dev/null || true)
  if [[ -z "$_out" ]]; then
    _out=$(curl -fsSL --max-time 8 "https://dns.google/resolve?name=$1&type=A" 2>/dev/null | jq -r '[.Answer[]? | select(.type==1) | .data] | join(",")' 2>/dev/null || true)
  fi
  printf '%s' "$_out"
}

domain_aaaa_records() {
  local _out
  _out=$(curl -fsSL --max-time 8 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$1&type=AAAA" 2>/dev/null | jq -r '[.Answer[]? | select(.type==28) | .data] | join(",")' 2>/dev/null || true)
  if [[ -z "$_out" ]]; then
    _out=$(curl -fsSL --max-time 8 "https://dns.google/resolve?name=$1&type=AAAA" 2>/dev/null | jq -r '[.Answer[]? | select(.type==28) | .data] | join(",")' 2>/dev/null || true)
  fi
  printf '%s' "$_out"
}

# 本机全部可达地址（前后带空格、空格分隔，一次运行内缓存）：公网查询到的
# IP（v4 或 v6）+ 网卡上的全部 global 地址。域名解析命中其中任意一个，
# 才算「解析到本机」。旧实现只认单个公网 IPv4：查不到 v4（如纯 IPv6
# 机器、查询源抖动）就把「没法验证」当成验证通过，乱填的域名也被采用。
_LOCAL_IP_SET=""
local_ip_set() {
  if [[ -n "$_LOCAL_IP_SET" ]]; then printf '%s' "$_LOCAL_IP_SET"; return 0; fi
  local _set="" _ip _a
  _ip=$(get_ip | tr -d '[]')
  [[ -n "$_ip" ]] && _set="$_ip"
  if command -v ip >/dev/null 2>&1; then
    for _a in $(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
      [[ " $_set " == *" $_a "* ]] || _set="$_set $_a"
    done
  fi
  _LOCAL_IP_SET=" $_set "
  printf '%s' "$_LOCAL_IP_SET"
}

# 带倒计时的限时输入：$1=总秒数 $2=提示语 $3=输入来源（/dev/tty 或空=stdin）
# 读到的整行写入全局 REPLY_LINE；读到非空行返回 0，无输入/直接回车/读完返回 1。
# 真实终端必须走 raw 逐字读：普通 read 是整行交付，没法在用户敲键期间逐秒
# 刷新倒计时（回显会被倒计时帧反复覆盖，光标错位、输入看着像乱码），逐字
# 读则要自己处理回显、退格、回车（\r/\n 都算）、方向键转义序列与 Ctrl-C。
# 倒计时只在用户尚未输入时刷新本行；一开始输入就擦掉倒计时、不再干扰。
# 管道/文件输入没有行编辑问题，沿用整行分片累积（超时片读的部分输入也算）。
prompt_line_countdown() {
  local _secs="$1" _prompt="$2" _src="${3:-}" _buf="" _ch="" _junk="" _chunk=""
  local _i _rc _is_tty=0 _old_stty="" _left="$_secs"
  REPLY_LINE=""
  if [[ -n "$_src" ]]; then
    [[ -e "$_src" ]] && _is_tty=1
  else
    [[ -t 0 ]] && _is_tty=1
  fi
  if [[ "$_is_tty" == "1" ]]; then
    # stty 一律走重定向作用于目标终端（不用 GNU 专属的 -F，精简工具集也兼容）
    if [[ -n "$_src" ]]; then
      _old_stty=$(stty -g < "$_src" 2>/dev/null) || _is_tty=0
    else
      _old_stty=$(stty -g 2>/dev/null) || _is_tty=0
    fi
  fi
  if [[ "$_is_tty" == "1" ]]; then
    if [[ -n "$_src" ]]; then stty -icanon -echo -isig -icrnl < "$_src" 2>/dev/null; else stty -icanon -echo -isig -icrnl 2>/dev/null; fi
    # 逐字节读只用 bash 自带 read，不再借 dd/timeout：timeout 的进程组处理
    # 与部分精简系统（BusyBox 等）的工具差异都曾让 /dev/tty 一个字节都读
    # 不到。read -n 首次调用会冲掉输入队列，先在打印提示前空读一次吸收掉
    if [[ -n "$_src" ]]; then IFS= read -r -n 1 -t 0.3 _ch < "$_src" || true; else IFS= read -r -n 1 -t 0.3 _ch || true; fi
    printf '\r%s（还剩 %d 秒）\033[K' "$_prompt" "$_left" >&2
    while [[ "$_left" -gt 0 ]]; do
      if [[ -n "$_src" ]]; then IFS= read -r -n 1 -t 1 _ch < "$_src"; else IFS= read -r -n 1 -t 1 _ch; fi
      _rc=$?
      if [[ $_rc -eq 0 ]]; then
        # read -n 读到换行时可能把它当分隔符吞掉、返回空字符：空字符即回车
        [[ -z "$_ch" ]] && break
        case "$_ch" in
          $'\n'|$'\r') break ;;
          $'\003')   # Ctrl-C：先恢复终端再自发中断信号，保持原有行为
            if [[ -n "$_src" ]]; then stty "$_old_stty" < "$_src" 2>/dev/null; else stty "$_old_stty" 2>/dev/null; fi
            kill -INT $$ ;;
          $'\032')   # Ctrl-Z：同理恢复后挂起
            if [[ -n "$_src" ]]; then stty "$_old_stty" < "$_src" 2>/dev/null; else stty "$_old_stty" 2>/dev/null; fi
            kill -TSTP $$ ;;
          $'\033')   # 方向键等转义序列：吞掉后续字节，不进输入
            if [[ -n "$_src" ]]; then IFS= read -r -n 2 -t 0.3 _junk < "$_src" || true; else IFS= read -r -n 2 -t 0.3 _junk || true; fi ;;
          $'\177'|$'\b')
            if [[ -n "$_buf" ]]; then _buf="${_buf%?}"; printf '\b \b' >&2; fi ;;
          $'\004')   # Ctrl-D：空输入按结束处理，有内容则忽略
            [[ -z "$_buf" ]] && break ;;
          [[:print:]])
            if [[ -z "$_buf" ]]; then printf '\r%s\033[K' "$_prompt" >&2; fi
            _buf+="$_ch"; printf '%s' "$_ch" >&2 ;;
          *) ;;      # 其他控制字符忽略
        esac
      elif [[ $_rc -ge 128 ]]; then
        _left=$((_left-1))
        if [[ -z "$_buf" && "$_left" -gt 0 ]]; then
          printf '\r%s（还剩 %d 秒）\033[K' "$_prompt" "$_left" >&2
        fi
      else
        break        # EOF
      fi
    done
    if [[ -n "$_src" ]]; then stty "$_old_stty" < "$_src" 2>/dev/null; else stty "$_old_stty" 2>/dev/null; fi
    printf '\n' >&2
    REPLY_LINE="$_buf"
    [[ -n "$REPLY_LINE" ]] && return 0
    return 1
  fi
  # 管道/文件：整行分片累积
  for (( _i=_secs; _i>0; _i-- )); do
    if [[ -z "$REPLY_LINE" && -z "$_chunk" ]]; then
      printf '\r%s（还剩 %d 秒）' "$_prompt" "$_i" >&2
    fi
    if [[ -n "$_src" ]]; then
      read -t 1 -r _chunk < "$_src"
    else
      read -t 1 -r _chunk
    fi
    _rc=$?
    REPLY_LINE+="${_chunk}"
    if [[ $_rc -eq 0 ]]; then
      printf '\n' >&2
      [[ -n "$REPLY_LINE" ]] && return 0
      return 1   # 直接回车（空行）
    fi
    if [[ $_rc -lt 128 ]]; then
      printf '\n' >&2
      return 1
    fi
  done
  printf '\n' >&2
  [[ -n "$REPLY_LINE" ]] && return 0
  return 1
}

# 域名校验失败后的统一处理：$1=累计失败次数 $2=启用临时域名后的提示后缀 $3=输入来源
# 返回 0=重新输入；返回 1=用默认。只有明确输 2 才用默认：输 1、直接回车、
# 输错其他字符、20 秒不选，都按默认选择（重新输入）。错误累计满 3 次直接启用临时域名。
domain_fail_next() {
  local _fails="$1" _suffix="$2" _src="${3:-}" _c=""
  if [[ "$_fails" -ge 3 ]]; then
    echo "[提示] 域名未正确解析（连续 3 次未通过校验），已启用临时域名。$_suffix"
    echo "[提示] 域名校验不只看格式：直连时还查是否已解析到本机 IP（$(get_ip)），未生效是最常见原因；用 Cloudflare Token 时另查归属、NS 与 DNS-01。"
    return 1
  fi
  echo "[选择] 1) 重新输入域名  2) 使用默认域名（默认选择 = 1：回车、输错、20 秒不选都算默认；只有输 2 才用默认域名）"
  if [[ -n "$_src" ]]; then
    read -t "$CHOICE_TIMEOUT" -r -p "请选择 [1/2]: " _c < "$_src" || _c=""
  else
    read -t "$CHOICE_TIMEOUT" -r -p "请选择 [1/2]: " _c || _c=""
  fi
  [[ "$_c" == "2" ]] && return 1
  return 0
}

# 直连模式（脚本不管理 DNS）下的域名解析验证：$1 必须解析到本机公网 IP。
# 返回 0=解析正确，或查询源不可用（警告后放行）；1=没解析到本机（报错，由调用方重输）
validate_domain_points_here() {
  local _fqdn="$1" _set _a _aaaa _hit="" _r
  _set=$(local_ip_set)
  if [[ -z "${_set// }" ]]; then
    echo "[警告] 未取得本机任何地址，无法验证域名解析，跳过验证"
    return 0
  fi
  _a=$(domain_a_records "$_fqdn")
  _aaaa=$(domain_aaaa_records "$_fqdn")
  if [[ -z "$_a" && -z "$_aaaa" ]]; then
    if [[ -z "$(domain_a_records cloudflare.com)" ]]; then
      echo "[警告] 公共 DNS 查询不可用，跳过域名解析验证"
      return 0
    fi
    echo "[错误] $_fqdn 目前没有任何解析记录（A/AAAA 均为空），请先把域名解析到本机，或重新输入"
    return 1
  fi
  for _r in ${_a//,/ } ${_aaaa//,/ }; do
    if [[ "$_set" == *" $_r "* ]]; then _hit="$_r"; break; fi
  done
  if [[ -n "$_hit" ]]; then
    echo "[信息] 域名解析验证通过：$_fqdn → $_hit"
    return 0
  fi
  echo "[错误] $_fqdn 当前解析（A：${_a:-无}，AAAA：${_aaaa:-无}）均不是本机地址，请先改解析或重新输入"
  return 1
}

# 首次安装时选 TLS 链端口（仅在本轮刚自动分配过端口时问）：选项均为
# Cloudflare 支持的 HTTPS 端口；回车/输错/超时一律默认 443；所选被占用
# 或与其它链冲突时提示并回退 443，443 也不可用再走自动挑端口；选定播报。
prompt_vtls_port() {
  [[ "${VTLS_PORT_FRESH:-0}" == "1" ]] || return 0
  local _c="" _want=""
  local _others=" ${PORT_VLESS:-} ${PORT_VMESS:-} ${PORT_HY2:-} ${PORT_TUIC:-} ${PORT_ANYTLS:-} "
  echo "[提示] TLS 端口选择（域名链使用，以下均为 Cloudflare 支持的 HTTPS 端口）："
  echo "  1) 443（默认，大多数网络都支持）"
  echo "  2) 8443（可避开建站等常用服务；注意：部分网络可能不支持）"
  echo "  3) 2053（注意：部分网络可能不支持）"
  echo "  4) 2083（注意：部分网络可能不支持）"
  echo "  5) 2087（注意：部分网络可能不支持）"
  echo "  6) 2096（注意：部分网络可能不支持）"
  read -t "$CHOICE_TIMEOUT" -r -p "请选择 [1-6]（回车/输错/20 秒不选，默认 443）: " _c </dev/tty || _c=""
  case "$_c" in
    2) _want=8443 ;;
    3) _want=2053 ;;
    4) _want=2083 ;;
    5) _want=2087 ;;
    6) _want=2096 ;;
    *) _want=443 ;;
  esac
  if [[ "$_want" != "443" ]] && { port_in_use "$_want" || [[ "$_others" == *" $_want "* ]]; }; then
    echo "[提示] 端口 $_want 已被占用，改用 443"
    _want=443
  fi
  if port_in_use "$_want" || [[ "$_others" == *" $_want "* ]]; then
    _want=$(pick_vtls_port "$_others") || _want=""
    echo "[提示] 默认端口也不可用，已自动挑选端口：$_want"
  fi
  PORT_VTLS="$_want"
  save_env
  echo "[信息] TLS 端口已选定：$PORT_VTLS（装后可用 sbox 菜单「更换端口」随时更改）"
}

prompt_install_choices() {
  [[ -r /dev/tty ]] || return 0
  # 0) TLS 端口：首次安装时让用户选（回车/输错默认 443）
  prompt_vtls_port
  # 1) TLS 域名：当前是脚本自动的临时域名时，给一次手填机会
  if [[ "${TLS_DOMAIN_AUTO:-1}" == "1" ]]; then
    local _d="" _tok_asked=0 _fails=0
    echo "[提示] 手填域名请先解析到本机 IP：$(get_ip | tr -d '[]')（IPv6 请建 AAAA 记录、IPv4 建 A 记录；填 Cloudflare Token 时脚本可自动设置解析）"
    while true; do
      if prompt_line_countdown "$INPUT_TIMEOUT" "TLS 域名（无输入自动用临时域名 ${TLS_DOMAIN}）: " /dev/tty; then
        _d=$(clean_domain "$REPLY_LINE")
        if ! valid_domain_format "$_d"; then
          echo "[错误] 域名格式不对（示例：node.example.com）"
          _fails=$((_fails+1))
          if domain_fail_next "$_fails" "安装完成后随时可以更改（运行 sbox change-domain）。" /dev/tty; then
            continue
          fi
          break
        fi
        # Token 只问一次：已保存的直接用；没有就给一次 60 秒填入机会，
        # 有 Token 时与 change-domain 走同一套深度验证 + 装时直接申请真证书
        if [[ "$_tok_asked" == "0" ]]; then
          _tok_asked=1
          load_cf_token || true
          if [[ -z "${CF_API_TOKEN:-}" ]]; then
            read -t "$INPUT_TIMEOUT" -r -p "Cloudflare API Token（申请真证书并套 CF；直接回车跳过（域名已解析到本机时自动直连申请真证书））: " CF_API_TOKEN </dev/tty || CF_API_TOKEN=""
          fi
          if [[ -n "${CF_API_TOKEN:-}" && ! "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
            echo "[警告] Token 含非法字符（Cloudflare API Token 只应含字母、数字、_ 与 -），已忽略，按自签直连处理"
            CF_API_TOKEN=""
          fi
          [[ -n "${CF_API_TOKEN:-}" ]] && save_cf_token
        fi
        if [[ -n "${CF_API_TOKEN:-}" ]]; then
          if ! validate_cf_domain "$_d"; then
            _fails=$((_fails+1))
            if domain_fail_next "$_fails" "安装完成后随时可以更改（运行 sbox change-domain）。" /dev/tty; then
              continue
            fi
            break
          fi
          cf_delete_managed_record   # 若临时域名是脚本在 CF 建的记录，先清掉再换
          TLS_DOMAIN="$_d"
          TLS_DOMAIN_AUTO=0
          TLS_ACME=0
          save_env
          if cf_setup_domain "$TLS_DOMAIN"; then
            TLS_ACME=1
            save_env
            echo "[信息] 已采用域名：$TLS_DOMAIN（真证书，安装完成后自动签发并验证）"
          else
            echo "[警告] Cloudflare 设置未完成，已回退自签证书直连"
            echo "[信息] 已采用域名：$TLS_DOMAIN（自签证书；装后运行 sbox change-domain 可申请真证书并套 Cloudflare）"
          fi
          break
        fi
        # 无 Token 直连：域名必须已解析到本机；解析正确直接走真证书申请
        if ! validate_domain_points_here "$_d"; then
          _fails=$((_fails+1))
          if domain_fail_next "$_fails" "安装完成后随时可以更改（运行 sbox change-domain）。" /dev/tty; then
            continue
          fi
          break
        fi
        cf_delete_managed_record   # 若临时域名是脚本在 CF 建的记录，先清掉再换
        TLS_DOMAIN="$_d"
        TLS_DOMAIN_AUTO=0
        TLS_ACME=1
        TLS_ACME_MODE="direct"
        save_env
        echo "[信息] 已采用域名：$TLS_DOMAIN（真证书，安装完成后自动签发并验证）"
        break
      fi
      break   # 无输入/直接回车：按默认用临时域名，不再问
    done
  fi
  # 2) Argo 固定隧道：还没配置过时给一次填 Token 的机会，默认临时隧道
  if [[ ! -f "$SB_DIR/argo.env" ]]; then
    local _tok="" _dom=""
    echo "[可选] 60 秒内输入 Cloudflare 固定隧道 Token，超时/直接回车用临时隧道"
    if read -t "$INPUT_TIMEOUT" -r -p "Argo Token: " _tok </dev/tty && [[ -n "$_tok" ]]; then
      read -t "$INPUT_TIMEOUT" -r -p "固定隧道域名: " _dom </dev/tty || _dom=""
      if [[ "$_tok" =~ ^[A-Za-z0-9+/=_-]+$ && "$_dom" =~ ^[A-Za-z0-9.-]+$ && "$_dom" == *.* && "$_dom" != .* && "$_dom" != *. ]]; then
        cat > "$SB_DIR/argo.env" <<EOF
ARGO_MODE="fixed"
ARGO_TOKEN="$_tok"
ARGO_DOMAIN="$_dom"
EOF
        chmod 600 "$SB_DIR/argo.env"
        ARGO_TOKEN="$_tok"
        ARGO_DOMAIN="$_dom"
        echo "[信息] 已配置固定隧道：$_dom"
        echo "[提示] Token 方式的固定隧道，转发目标在 Cloudflare 侧管理：请确认隧道 ingress 指向 http://localhost:${PORT_VMESS}（本机 VMess 端口），不一致时 Argo 链会返回 502；可在 CF 面板修改，或用菜单「Argo 隧道管理」的 API 方式自动写入"
      else
        echo "[警告] Token/域名不完整或格式不对，继续用临时隧道"
      fi
    fi
  fi
}

#----------------------------- 7. 写 sing-box 配置 ---------------------------
# 受限网络环境自适应（OpenVZ/venet 容器）：
# 背景（2026-11-06 于 OpenVZ 免费机实测）：这类容器默认路由无网关、网卡是 venet，
# sing-box 内置 DNS 要靠枚举网卡/路由选默认接口，而容器禁止枚举（日志原文
# "list routes: address family not supported by protocol"），于是出站解析全灭、
# 全部直连链与 ACME 一起死；同机的系统解析（/etc/resolv.conf）却一切正常。
# 对策：三项指纹同时成立才判「受限」，write_config 给配置顶层加两段——
# dns 走普通 UDP 指向系统解析（注意：sing-box 的 dns type "local" 仍走其自家
# 拨号层、实测无效，必须普通 udp）；route 关闭接口自动探测并写死默认网卡。
# 判假时不写这两段，生成的配置与改前逐字节一致（正常机器零影响）。
# 检测宁可漏报不可误报：用到的命令缺失（systemd-detect-virt / ip）一律判假。

# 默认路由的 dev 名（如 venet0 / eth0）；取不到输出空
restricted_net_dev() {
  command -v ip >/dev/null 2>&1 || return 0
  ip route show default 2>/dev/null | head -n 1 \
    | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

# 系统解析地址：/etc/resolv.conf 第一个 nameserver；读不到回退回环 stub 口
restricted_net_nameserver() {
  local _ns=""
  if [[ -r /etc/resolv.conf ]]; then
    _ns=$(awk '$1=="nameserver" {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
  fi
  [[ -n "$_ns" ]] || _ns="127.0.0.53"
  printf '%s\n' "$_ns"
}

# 三项指纹同时成立才返回 0：①OpenVZ ②默认路由 dev 以 venet 开头 ③默认路由无网关
restricted_net_env() {
  # ① OpenVZ：systemd-detect-virt 最直接；它缺失或判不出时退查
  #    /proc/user_beancounters——OpenVZ/Virtuozzo 容器有此文件、普通机器没有
  local _ovz=0
  if command -v systemd-detect-virt >/dev/null 2>&1 \
     && [[ "$(systemd-detect-virt 2>/dev/null || true)" == "openvz" ]]; then
    _ovz=1
  fi
  if [[ -e /proc/user_beancounters ]]; then _ovz=1; fi
  (( _ovz == 1 )) || return 1
  command -v ip >/dev/null 2>&1 || return 1
  # ② 网卡：默认路由 dev 名以 venet 开头（venet0 等）
  local _dev
  _dev=$(restricted_net_dev)
  [[ "$_dev" == venet* ]] || return 1
  # ③ 无网关：受限环境的默认路由形如 "default dev venet0 scope link"（无 via 段）；
  #    IPv6 默认路由同机同形，可作旁证，这里以 IPv4 行为准即可（venet 机器必有此行）
  local _def
  _def=$(ip route show default 2>/dev/null | head -n 1)
  [[ -n "$_def" && "$_def" != *" via "* ]] || return 1
  return 0
}

# 受限时 write_config 追加的 JSON 尾段（顶层 dns + route）；非受限输出空。
# $1 可选：调用方既有的 route 内字段（如 WARP 的 rules/final），非空时并入
# 同一个 route 对象，避免顶层出现两个 "route" 键；default_interface 取不到时
# 只写 auto_detect_interface。
restricted_net_tail() {
  restricted_net_env || return 0
  local _ns _dev _route="\"auto_detect_interface\": false"
  _ns=$(restricted_net_nameserver)
  _dev=$(restricted_net_dev)
  if [[ -n "$_dev" ]]; then _route="$_route, \"default_interface\": \"$_dev\""; fi
  if [[ -n "${1:-}" ]]; then _route="$_route, $1"; fi
  printf ',\n  "dns": {"servers": [{"type": "udp", "server": "%s", "tag": "sys"}], "final": "sys"},\n  "route": {%s}' "$_ns" "$_route"
}

write_config() {
  echo "[信息] 写入 sing-box 配置…"
  # 域名 TLS 入站的 tls 段两种形态：默认自签证书；换真域名并提供 CF Token 后走
  # sing-box 内置 ACME（DNS-01 走 Cloudflare，自动续期，不占 80/443、不装额外软件）
  local _tls_sni="${TLS_DOMAIN:-$SNI_SELF}" vtls_tls
  local _self_tls="\"enabled\": true, \"server_name\": \"$_tls_sni\", \"certificate_path\": \"$SB_DIR/cert.pem\", \"key_path\": \"$SB_DIR/private.key\""
  if [[ "${TLS_ACME:-0}" == "1" && "${TLS_ACME_MODE:-cf}" == "direct" ]]; then
    # 直连真证书：域名已解析到本机时走 ACME 通用验证（HTTP-01 / TLS-ALPN-01），
    # 不依赖任何 DNS 服务商的 API；两个挑战都不禁，哪个通走哪个
    vtls_tls="\"enabled\": true, \"server_name\": \"$_tls_sni\", \"certificate_provider\": {\"type\": \"acme\", \"domain\": [\"$_tls_sni\"], \"data_directory\": \"$SB_DIR/acme\", \"email\": \"admin@$_tls_sni\", \"provider\": \"letsencrypt\"}"
  elif [[ "${TLS_ACME:-0}" == "1" ]]; then
    local _tok=""
    if [[ -f "$CF_ENV_FILE" ]]; then
      _tok=$(grep '^CF_API_TOKEN=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    fi
    if [[ -n "$_tok" ]]; then
      vtls_tls="\"enabled\": true, \"server_name\": \"$_tls_sni\", \"certificate_provider\": {\"type\": \"acme\", \"domain\": [\"$_tls_sni\"], \"data_directory\": \"$SB_DIR/acme\", \"email\": \"admin@$_tls_sni\", \"provider\": \"letsencrypt\", \"disable_http_challenge\": true, \"disable_tls_alpn_challenge\": true, \"dns01_challenge\": {\"provider\": \"cloudflare\", \"api_token\": \"$_tok\"}}"
    else
      # 状态不一致兜底（ACME 开着但 Token 丢失）：宁可降级自签，也不能生成坏配置
      echo "[警告] ACME 已启用但读不到 Cloudflare Token，域名 TLS 链暂用自签证书"
      vtls_tls="$_self_tls"
    fi
  else
    vtls_tls="$_self_tls"
  fi
  # WARP 出站：状态在 warp.env（菜单 change-warp 管理）；关闭或注册参数不全时
  # 不生成任何 WARP 配置（零成本），换端口/UUID/域名等重写配置时原样保留
  load_warp_env
  local _warp_tail="" _ep_tail="" _warp_route=""
  if [[ "$WARP_MODE" != "off" ]]; then
    if warp_profile_complete; then
      local _ep
      _ep=$(warp_endpoint_json)
      _ep_tail=",
  \"endpoints\": [$_ep]"
      if [[ "$WARP_MODE" == "all" ]]; then
        _warp_route="\"final\": \"warp\""
      else
        _warp_route="\"rules\": [{\"ip_cidr\": [\"0.0.0.0/0\"], \"outbound\": \"warp\"}], \"final\": \"direct\""
      fi
    else
      echo "[警告] WARP 模式为 $WARP_MODE 但注册参数不齐全，本次配置不启用 WARP（运行 sbox change-warp 重新注册）"
    fi
  fi
  # 尾段组装：受限网络自适应（restricted_net_tail）判假时返回空；判真时其 route
  # 对象需与 WARP 的 route 字段合并（把 _warp_route 作为 $1 传入并入同一对象）。
  # 非受限时走原路径：endpoints + route 逐字拼接，产物与改前逐字节一致。
  local _net_tail
  _net_tail=$(restricted_net_tail "$_warp_route")
  if [[ -n "$_warp_route" && -z "$_net_tail" ]]; then
    _warp_tail="$_ep_tail,
  \"route\": {$_warp_route}"
  else
    _warp_tail="$_ep_tail$_net_tail"
  fi
  cat > "$SB_DIR/sb.json" <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality",
      "listen": "::", "listen_port": $PORT_VLESS,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "$SNI_REALITY",
        "reality": {
          "enabled": true,
          "handshake": {"server": "$SNI_REALITY", "server_port": 443},
          "private_key": "$PRIVKEY",
          "short_id": ["$SHORTID"]
        }
      }
    },
    {
      "type": "vmess", "tag": "vmess-ws",
      "listen": "::", "listen_port": $PORT_VMESS,
      "users": [{"uuid": "$UUID", "alterId": 0}],
      "transport": {
        "type": "ws", "path": "${UUID}-vm",
        "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {"enabled": false}
    },
    {
      "type": "hysteria2", "tag": "hysteria2",
      "listen": "::", "listen_port": $PORT_HY2,
      "users": [{"password": "$UUID"}],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true, "alpn": ["h3"],
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "tuic", "tag": "tuic",
      "listen": "::", "listen_port": $PORT_TUIC,
      "users": [{"uuid": "$UUID", "password": "$UUID"}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true, "alpn": ["h3"],
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "anytls", "tag": "anytls",
      "listen": "::", "listen_port": $PORT_ANYTLS,
      "users": [{"password": "$UUID"}],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "vless", "tag": "vless-ws-tls",
      "listen": "::", "listen_port": ${PORT_VTLS:-443},
      "users": [{"uuid": "$UUID"}],
      "transport": {
        "type": "ws", "path": "${UUID}-vt",
        "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": { $vtls_tls }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]${_warp_tail}
}
EOF
  chmod 600 "$SB_DIR/sb.json"   # 内含 Reality 私钥与（ACME 模式下）CF Token，按密钥文件对待
  "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1 \
    || { echo "[错误] 配置校验失败"; exit 1; }
  echo "[信息] 配置校验通过"
}

#----------------------------- 7.5 cron 守护 -----------------------------------
# Argo 隧道与无 systemd 时的 sing-box 自启都依赖 crontab 的 @reboot 条目，
# 但装好 crontab 命令不等于 cron 守护在运行（RHEL 系装完 cronie 默认不启用），这里统一保证
ensure_cron_running() {
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    local unit=""
    if systemctl cat cron >/dev/null 2>&1; then unit="cron";
    elif systemctl cat crond >/dev/null 2>&1; then unit="crond"; fi
    if [[ -n "$unit" ]]; then
      systemctl enable --now "$unit" >/dev/null 2>&1 || true
      if systemctl is-active --quiet "$unit"; then
        echo "[信息] cron 服务运行中（$unit），@reboot 自启可用"
        return 0
      fi
    fi
    echo "[警告] 未能启用 cron 服务：重启后 Argo 隧道（及无 systemd 时的 sing-box）无法自动拉起，请手动启用 cron/crond 服务"
  fi
}

#----------------------------- 时间同步 ---------------------------------------
# Reality 握手对时钟偏移敏感，机器时钟慢慢漂移会让节点莫名其妙连不上；长期运行必须保证 NTP 开着
ensure_time_sync() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
    echo "[信息] 已确保 NTP 时间同步开启"
  fi
}

#----------------------------- 8. 系统服务 ------------------------------------
# SELinux：Enforcing 会拦截 sing-box 的出站连接（avc denied name_connect），切为 permissive
fix_selinux() {
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    echo "[信息] 检测到 SELinux 为 Enforcing，切换为 Permissive（否则代理出站会被拦截）…"
    setenforce 0 2>/dev/null || true
    [[ -f /etc/selinux/config ]] && sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    echo "[信息] SELinux 已切换为 Permissive（重启后依然有效）"
  fi
}

setup_service() {
  echo "[信息] 配置并启动 sing-box 服务…"
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    # 服务名处理：旧版用通名 sing-box.service。若是本脚本装的（ExecStart 指向 $SB_DIR）则迁移到专属名 $UNIT；
    # 若是别人装的 sing-box 则不碰它，只警告，本脚本用专属名与其共存
    local legacy_unit="/etc/systemd/system/sing-box.service"
    if [[ -f "$legacy_unit" ]]; then
      if grep -q "$SB_DIR/sing-box" "$legacy_unit"; then
        systemctl disable --now sing-box >/dev/null 2>&1 || true
        rm -f "$legacy_unit"
        echo "[信息] 已把服务名从 sing-box 迁移为 $UNIT"
      else
        echo "[警告] 检测到已存在的 sing-box 服务（非本脚本安装）：本脚本改用 $UNIT 与其共存，请注意端口不要冲突"
      fi
    fi
    cat > "/etc/systemd/system/${UNIT}.service" <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_DIR/sing-box run -c $SB_DIR/sb.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null 2>&1 || true
    systemctl restart "$UNIT" || true   # 失败先不退出：走到下方 is-active 检查并打印日志诊断
    sleep 2
    if systemctl is-active --quiet "$UNIT"; then
      echo "[信息] sing-box 运行中"
    else
      echo "[错误] sing-box 启动失败，日志如下："
      journalctl -u "$UNIT" --no-pager -n 20 2>/dev/null || true
      exit 1
    fi
  else
    echo "[警告] 未检测到 systemd，改用后台方式启动"
    pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
    nohup "$SB_DIR/sing-box" run -c "$SB_DIR/sb.json" >/var/log/sing-box.log 2>&1 &
    sleep 2
    pgrep -f "$SB_DIR/sing-box run" >/dev/null || { echo "[错误] sing-box 启动失败"; exit 1; }
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "$SB_DIR/sing-box run"; echo "@reboot sleep 10 && $SB_DIR/sing-box run -c $SB_DIR/sb.json >/var/log/sing-box.log 2>&1") | crontab - >/dev/null 2>&1 || true
    fi
    # 后台方式的日志直接写文件、无人轮转会随年月涨满磁盘，给它配上 logrotate
    if [[ -d /etc/logrotate.d ]]; then
      cat > /etc/logrotate.d/sing-box-fallback <<'ROT'
/var/log/sing-box.log {
    weekly
    rotate 4
    size 5M
    copytruncate
    missingok
    notifempty
}
ROT
    fi
    echo "[信息] sing-box 已在后台启动"
  fi
}

#----------------------------- 9. Argo 临时隧道 -------------------------------
# cloudflared 临时隧道无需 Cloudflare 账号授权；
# 固定隧道需要手动在 CF 官网创建并填 token，无法自动化，本脚本只做临时隧道。
# 隧道失败不阻塞：拿不到域名就跳过，只是不输出第 3 条链接。
# 有 systemd 时把 cloudflared 交给 systemd 托管（崩溃自动拉起 + 开机自启），成功返回 0；
# 无 systemd 时返回 1，调用方回退到 nohup + crontab 老路径（进程死了只能等重启，是临时方案）

# 从 cloudflared 日志里提取当前临时隧道域名。取第二个匹配：第一个是日志里
# api.trycloudflare.com 的提示链接，第二个才是本隧道的域名。解析逻辑集中在一处，
# cloudflared 改日志版式时只修这里（此前同一段 grep 在 5 处各复制一份）
current_argo_domain() {
  grep -a -o 'https://[^ "]*trycloudflare.com' "$SB_DIR/argo.log" 2>/dev/null | head -n 2 | tail -n 1 | sed 's|https://||' || true
}

start_argo_systemd() {
  local exec_cmd="$1"
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    cat > "/etc/systemd/system/${ARGO_UNIT}.service" <<EOF
[Unit]
Description=cloudflared Argo tunnel (sing-box-auto)
After=network.target

[Service]
ExecStart=$exec_cmd
Restart=always
RestartSec=10
StandardOutput=append:$SB_DIR/argo.log
StandardError=append:$SB_DIR/argo.log

[Install]
WantedBy=multi-user.target
EOF
    # 清掉老的 crontab @reboot 自启，避免与 systemd 托管双开
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "$SB_DIR/cloudflared") | crontab - >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$ARGO_UNIT" >/dev/null 2>&1 || true
    systemctl restart "$ARGO_UNIT" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

# 确保 cloudflared 已下载：缺失时按架构拉取官方版。成功输出路径，失败返回 1
ensure_cloudflared() {
  local cf="$SB_DIR/cloudflared"
  if [[ ! -x "$cf" ]]; then
    echo "[信息] 下载 cloudflared…" >&2
    # cloudflared 的资产命名与 sing-box 不同：官方没有 armv7 资产，arm 版即给 armv7 用；
    # 且菜单路径下 ARCH 可能未设置，这里按 uname 现算，不依赖 detect_arch
    local cf_arch
    case "$(uname -m)" in
      x86_64) cf_arch="amd64" ;;
      aarch64) cf_arch="arm64" ;;
      armv7l) cf_arch="arm" ;;
      *) cf_arch="${ARCH:-amd64}" ;;
    esac
    if ! curl -fSL --retry 2 --max-time 120 -o "$cf" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"; then
      echo "[警告] cloudflared 下载失败" >&2
      return 1
    fi
    chmod +x "$cf"
  fi
  printf '%s' "$cf"
}

start_argo() {
  # 如果配置了固定隧道，优先使用固定隧道
  if [[ -f "$SB_DIR/argo.env" ]]; then
    local _am
    _am=$(grep '^ARGO_MODE=' "$SB_DIR/argo.env" 2>/dev/null | cut -d'"' -f2 || true)
    if [[ "$_am" == "fixed" ]]; then
      # shellcheck disable=SC1090
      . "$SB_DIR/argo.env"
      start_argo_fixed
      return 0
    fi
  fi
  echo "[信息] 启动 Argo 临时隧道…"
  local cf
  cf=$(ensure_cloudflared) || { echo "[警告] cloudflared 下载失败，跳过 Argo（不影响其他 5 种协议）"; ARGO_DOMAIN=""; return 0; }
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true   # 若之前由 systemd 托管，先停掉避免双开
  pkill -f "$SB_DIR/cloudflared.*tunnel.*--url" >/dev/null 2>&1 || true
  sleep 1
  : > "$SB_DIR/argo.log"   # 清空旧日志，避免抓到上一次隧道的域名
  local argo_managed=0
  if start_argo_systemd "$cf tunnel --url http://localhost:${PORT_VMESS} --edge-ip-version auto --no-autoupdate --protocol http2"; then
    argo_managed=1
    echo "[信息] Argo 临时隧道已由 systemd 托管（崩溃自动拉起）"
  else
    nohup "$cf" tunnel --url "http://localhost:${PORT_VMESS}" \
      --edge-ip-version auto --no-autoupdate --protocol http2 \
      > "$SB_DIR/argo.log" 2>&1 &
  fi
  echo "[信息] 等待 Cloudflare 分配临时域名（最多约 60 秒）…"
  ARGO_DOMAIN=""
  local _i
  for _i in $(seq 1 20); do
    sleep 3
    ARGO_DOMAIN="$(current_argo_domain)"
    [[ -n "$ARGO_DOMAIN" ]] && break
  done
  if [[ -n "${ARGO_DOMAIN:-}" ]]; then
    echo "[信息] Argo 临时域名：$ARGO_DOMAIN（重启后会变化）"
    if [[ "$argo_managed" -eq 0 ]] && command -v crontab >/dev/null 2>&1; then
      # 宽匹配：切回临时隧道时，把固定隧道的开机自启也清掉，避免重启后双隧道齐跑
      (crontab -l 2>/dev/null | grep -v "$SB_DIR/cloudflared"
       echo "@reboot sleep 15 && $cf tunnel --url http://localhost:${PORT_VMESS} --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo.log 2>&1 &") | crontab - >/dev/null 2>&1 || true
    fi
  else
    echo "[警告] 未能获取 Argo 域名，跳过 VMess+Argo（不影响其他 5 种协议）"
    echo "[提示] 隧道日志最后几行："
    tail -n 5 "$SB_DIR/argo.log" 2>/dev/null || true
    ARGO_DOMAIN=""
  fi
}

#----------------------------- 10. 输出客户端链接 ----------------------------
get_ip() {
  # 多个公网 IP 查询源依次尝试，返回内容必须是合法 IP 才采用；v4 优先，其次 v6
  # 全部失败时输出空字符串，由 print_links 给出明确警告（不再静默生成坏链接）
  local src ip=""
  for src in "https://icanhazip.com" "https://ip.sb" "https://ifconfig.me/ip" "https://api.ipify.org"; do
    ip=$(curl -fsSL --max-time 8 -4 "$src" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
  done
  for src in "https://icanhazip.com" "https://ip.sb" "https://ifconfig.me/ip"; do
    ip=$(curl -fsSL --max-time 8 -6 "$src" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then echo "[$ip]"; return 0; fi   # IPv6 加方括号
  done
  echo ""
}

# base64 不换行（兼容 busybox）
b64() { base64 -w 0 2>/dev/null || base64 | tr -d '\n'; }

print_links() {
  local ip host ip_bare
  ip="$(get_ip)"
  ip_bare="${ip#[}"; ip_bare="${ip_bare%]}"   # 裸地址：仅 VMess 的 add 字段用（base64-JSON 不是 URI，不带方括号）
  host="$(hostname)"

  local vl_link vm_link hy2_link tuic_link an_link vt_link
  local _vt_host="${TLS_DOMAIN:-$SNI_SELF}" _vt_addr="${TLS_DOMAIN:-$ip}" _vt_ins="&allowInsecure=1"
  [[ "${TLS_ACME:-0}" == "1" ]] && _vt_ins=""
  vt_link="vless://${UUID}@${_vt_addr}:${PORT_VTLS:-443}?encryption=none&security=tls&sni=${_vt_host}&fp=chrome&type=ws&host=${_vt_host}&path=${UUID}-vt${_vt_ins}#vl-ws-tls-${host}"
  vl_link="vless://${UUID}@${ip}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_REALITY}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&headerType=none#vl-reality-${host}"

  vm_link="vmess://$(printf '{"add":"%s","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"%s","ps":"vm-ws-%s","tls":"","type":"none","v":"2"}' \
    "$ip_bare" "$SNI_SELF" "$UUID" "$UUID" "$PORT_VMESS" "$host" | b64)"

  hy2_link="hysteria2://${UUID}@${ip}:${PORT_HY2}?security=tls&alpn=h3&insecure=1&allowInsecure=1&sni=${SNI_SELF}#hy2-${host}"

  tuic_link="tuic://${UUID}:${UUID}@${ip}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI_SELF}&insecure=1&allowInsecure=1&allow_insecure=1#tu5-${host}"

  an_link="anytls://${UUID}@${ip}:${PORT_ANYTLS}?&sni=${SNI_SELF}&allowInsecure=1&insecure=1#anytls-${host}"

  {
    echo "================ sing-box 节点链接 ================"
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo
    if [[ -z "$ip" ]]; then
      echo "[警告] 未能获取公网 IP（多个查询源均失败）：下方直连链接的服务器地址为空，"
      echo "       使用前请把链接中的 @: 替换为 @服务器IP:（VMess 的 add 字段同理），或稍后重跑 show-links"
      echo
    fi
    echo "[1] VLESS + Reality (TCP/${PORT_VLESS})"
    echo "$vl_link"
    echo
    echo "[2] VMess + WS (TCP/${PORT_VMESS})"
    echo "$vm_link"
    echo
    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
      local argo_link _argo_note="重启后会变"
      # 固定隧道重启不变，标注要与 argo.env 的实际模式一致，别误导用户
      if [[ -f "$SB_DIR/argo.env" ]] && grep -q '^ARGO_MODE="fixed"' "$SB_DIR/argo.env" 2>/dev/null; then
        _argo_note="固定隧道"
      fi
      argo_link="vmess://$(printf '{"add":"cloudflare-ech.com","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"443","ps":"vm-argo-%s","tls":"tls","sni":"%s","fp":"chrome","type":"none","v":"2"}' \
        "$ARGO_DOMAIN" "$UUID" "$UUID" "$host" "$ARGO_DOMAIN" | b64)"
      echo "[3] VMess + Argo 隧道（${ARGO_DOMAIN}，${_argo_note}）"
      echo "$argo_link"
    else
      echo "[3] VMess + Argo：本次未能建立隧道，已跳过"
    fi
    echo
    echo "[4] Hysteria2 (UDP/${PORT_HY2})"
    echo "$hy2_link"
    echo
    echo "[5] TUIC v5 (UDP/${PORT_TUIC})"
    echo "$tuic_link"
    echo
    echo "[6] AnyTLS (TCP/${PORT_ANYTLS})"
    echo "$an_link"
    echo
    echo "[7] VLESS + WS + TLS（域名：${TLS_DOMAIN:-未设置}，TCP/${PORT_VTLS:-443}）"
    if [[ "${TLS_ACME:-0}" == "1" ]]; then
      echo "（真证书 + Cloudflare 代理，与 Argo 隧道链共存互备）"
    elif [[ "${TLS_DOMAIN_AUTO:-1}" == "1" ]]; then
      echo "（临时域名 + 自签证书，运行 sbox change-domain 可换真域名、申请真证书并套 Cloudflare）"
    else
      echo "（自签证书，运行 sbox change-domain 可申请真证书并套 Cloudflare）"
    fi
    echo "$vt_link"
    echo
    echo "==================================================="
    echo "提示：链接已保存到 $LINKS_FILE"
  } | tee "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

#----------------------------- 11. 卸载 --------------------------------------
do_uninstall() {
  echo "[信息] 卸载 sing-box…"
  cf_delete_managed_record   # 若脚本在 Cloudflare 建过解析记录（自动域名/套 CF），一并删掉不留残留
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  systemctl disable "$UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${UNIT}.service"
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$ARGO_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${ARGO_UNIT}.service"
  # 旧版通名服务：确认是本脚本装的（指向 $SB_DIR）才一并清理，别人的 sing-box 不碰
  if [[ -f /etc/systemd/system/sing-box.service ]] && grep -q "$SB_DIR/sing-box" /etc/systemd/system/sing-box.service; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sing-box.service
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    # 注意：固定/临时隧道的 crontab 格式不同，但都带本脚本的安装路径，按路径一起清掉
    (crontab -l 2>/dev/null | grep -v "$SB_DIR/sing-box run" | grep -v "$SB_DIR/cloudflared") | crontab - >/dev/null 2>&1 || true
  fi
  rm -rf "$SB_DIR" "$LINKS_FILE"
  rm -f /etc/logrotate.d/sing-box-fallback
  # sbox 快捷命令：确认是本脚本装的才删（本体带脚本标记、/usr/bin 那份是指向它的软链），
  # 别的工具的同名文件不碰
  if grep -q "sing-box 全自动一键安装脚本" /usr/local/bin/sbox 2>/dev/null; then
    rm -f /usr/local/bin/sbox
  fi
  if [[ -L /usr/bin/sbox && "$(readlink /usr/bin/sbox 2>/dev/null || true)" == "/usr/local/bin/sbox" ]]; then
    rm -f /usr/bin/sbox
  fi
  echo "[信息] 卸载完成"
}

#----------------------------- 12. 管理菜单 ------------------------------------
# 加载已保存的配置，不存在则报错退出
load_env_or_exit() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "[错误] 未找到配置文件 $ENV_FILE，请先运行安装"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  if [[ -f "$SB_DIR/argo.env" ]]; then
    # shellcheck disable=SC1090
    . "$SB_DIR/argo.env"
  fi
  if [[ -z "${ARGO_DOMAIN:-}" && "${ARGO_MODE:-}" != "fixed" ]]; then
    ARGO_DOMAIN="$(current_argo_domain)"
  fi
}

# 3. 更换 UUID（全协议）
do_change_uuid() {
  load_env_or_exit
  echo "[信息] 正在生成新 UUID…"
  if "$SB_DIR/sing-box" generate uuid >/dev/null 2>&1; then
    UUID=$("$SB_DIR/sing-box" generate uuid)
  else
    UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  echo "[信息] 新 UUID：$UUID"
  save_env
  write_config
  setup_service
  start_argo
  print_links
  echo
  echo "[完成] UUID 已更换，全协议链接已更新"
}

# 5. 更新 Reality 密钥对
do_change_reality() {
  load_env_or_exit
  echo "[信息] 正在生成新 Reality 密钥对…"
  local kp
  kp=$("$SB_DIR/sing-box" generate reality-keypair)
  PRIVKEY=$(echo "$kp" | awk '/PrivateKey/{print $2}' | tr -d '"')
  PUBKEY=$(echo "$kp" | awk '/PublicKey/{print $2}' | tr -d '"')
  echo "$PUBKEY" > "$SB_DIR/public.key"
  SHORTID=$("$SB_DIR/sing-box" generate rand --hex 4)
  if [[ -z "$PRIVKEY" || -z "$PUBKEY" || -z "$SHORTID" ]]; then
    echo "[错误] Reality 密钥生成失败"; exit 1
  fi
  save_env
  write_config
  setup_service
  print_links
  echo
  echo "[完成] Reality 密钥对已更新"
}

# 6. 更新自签证书
do_change_cert() {
  load_env_or_exit
  echo "[信息] 正在重新生成自签证书…"
  rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key"
  gen_certs
  write_config
  setup_service
  print_links
  echo
  echo "[完成] 自签证书已更新（Hy2/TUIC/AnyTLS/VMess-WS 已切换新证书）"
}

# ACME 模式下等待签发并验证域名链握手（调用前需已 setup_service）；
# 失败自动回退自签，绝不留一条死链。change-domain 与安装流程共用
acme_verify_or_fallback() {
  [[ "${TLS_ACME:-0}" == "1" ]] || return 0
  # ACME 首次签发要等 DNS-01 验证，最长约 2 分钟；验证域名链真的能握手
  echo "[信息] 等待 Let's Encrypt 签发证书（DNS-01 验证，最长约 2 分钟）…"
  local _ok=0 _i _code
  for _i in $(seq 1 40); do
    sleep 3
    # 注意：WS 握手成功（101）后连接保持开启，curl 会以超时退出（28）——
    # 不能把 curl 放进受 pipefail 影响的管道里判断，必须先捕获状态码再比较
    _code=$(curl -s --max-time 5 --resolve "${TLS_DOMAIN}:${PORT_VTLS}:127.0.0.1" \
         "https://${TLS_DOMAIN}:${PORT_VTLS}/${UUID}-vt" \
         -H "Connection: Upgrade" -H "Upgrade: websocket" \
         -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
         -o /dev/null -w '%{http_code}' 2>/dev/null || true)
    if [[ "$_code" == "101" ]]; then
      _ok=1
      break
    fi
  done
  if [[ "$_ok" == "1" ]]; then
    echo "[完成] 真证书已签发，域名 TLS 链已通过 WebSocket 握手验证"
    return 0
  fi
  echo "[警告] 证书签发或握手验证未通过（sing-box 日志：journalctl -u $UNIT -n 20），自动回退自签证书"
  TLS_ACME=0
  save_env
  # 回退自签后 Cloudflare 若仍是「完全（严格）」会因源站证书不受信报 526，同步降为「完全」
  # （direct 直连模式不经 Cloudflare，跳过这步）
  if [[ "${TLS_ACME_MODE:-cf}" != "direct" && -f "$CF_ENV_FILE" ]] && load_cf_token; then
    local _zid_fb
    _zid_fb=$(grep '^CF_ZONE_ID=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    if [[ -n "$_zid_fb" ]]; then
      cf_api PATCH "/zones/$_zid_fb/settings/ssl" '{"value":"full"}' >/dev/null 2>&1 || true
      echo "[信息] 已同步把 Cloudflare SSL 模式降为「完全」，与自签证书匹配"
    fi
  fi
  rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key"
  gen_certs
  write_config
  setup_service
}

# 更换 TLS 域名：可换回自动临时域名，或换成自己的真域名并（可选）申请
# Let's Encrypt 真证书（sing-box 内置 ACME + Cloudflare DNS-01）+ 套 Cloudflare
do_change_domain() {
  load_env_or_exit
  local _cert_desc="自签"
  [[ "${TLS_ACME:-0}" == "1" ]] && _cert_desc="Let's Encrypt 真证书（ACME 自动续期）"
  local _auto_desc="手动设置"
  [[ "${TLS_DOMAIN_AUTO:-1}" == "1" ]] && _auto_desc="自动生成的临时域名"
  echo "当前 TLS 域名：${TLS_DOMAIN:-（未设置）}（$_auto_desc，证书：$_cert_desc，端口：${PORT_VTLS:-}）"
  echo "[提示] 手填域名请先解析到本机 IP：$(get_ip | tr -d '[]')（IPv6 请建 AAAA 记录、IPv4 建 A 记录；填 Cloudflare Token 时脚本可自动设置解析）"
  local _d="" _tok_asked=0 _fails=0 _use_default=0 _direct_acme=0
  while true; do
    # 60 秒无输入（含直接回车）= 按默认：重新自动生成临时域名，不再追问
    if ! prompt_line_countdown "$INPUT_TIMEOUT" "输入新域名（无输入 = 重新自动生成临时域名）: "; then
      _use_default=1
      break
    fi
    _d=$(clean_domain "$REPLY_LINE")
    if ! valid_domain_format "$_d"; then
      echo "[错误] 域名格式不对（示例：node.example.com）"
      _fails=$((_fails+1))
      if domain_fail_next "$_fails" "可随时再次运行 sbox change-domain 更改。"; then
        continue
      fi
      _use_default=1
      break
    fi
    # Token 只问一次：验证不过、重新输入域名时不重复问
    if [[ "$_tok_asked" == "0" ]]; then
      _tok_asked=1
      load_cf_token || true
    if [[ -z "${CF_API_TOKEN:-}" ]]; then
      read -rp "Cloudflare API Token（申请真证书并套 CF；直接回车跳过（域名已解析到本机时自动直连申请真证书））: " CF_API_TOKEN || CF_API_TOKEN=""
    fi
    if [[ -n "${CF_API_TOKEN:-}" && ! "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "[警告] Token 含非法字符（Cloudflare API Token 只应含字母、数字、_ 与 -），已忽略，按自签直连处理"
      CF_API_TOKEN=""
    fi
    fi
    if [[ -n "${CF_API_TOKEN:-}" ]]; then
      save_cf_token
      # 深度验证（归属/NS/冲突/DNS-01 预检）：不过就报错并重新输入域名，不动现有配置
      if ! validate_cf_domain "$_d"; then
        _fails=$((_fails+1))
        if domain_fail_next "$_fails" "可随时再次运行 sbox change-domain 更改。"; then
          continue
        fi
        _use_default=1
        break
      fi
    else
      # 无 Token 直连：域名必须自己解析到本机；解析正确就直接走真证书申请
      # （HTTP-01 / TLS-ALPN-01 通用验证，不依赖任何 DNS 服务商 API）
      if ! validate_domain_points_here "$_d"; then
        _fails=$((_fails+1))
        if domain_fail_next "$_fails" "可随时再次运行 sbox change-domain 更改。"; then
          continue
        fi
        _use_default=1
        break
      fi
      _direct_acme=1
      echo "[信息] 域名已解析到本机，直接申请 Let's Encrypt 真证书（通用验证，无需 Cloudflare）"
    fi
    TLS_DOMAIN="$_d"
    TLS_DOMAIN_AUTO=0
    TLS_ACME=0
    if [[ "$_direct_acme" == "1" ]]; then
      TLS_ACME=1
      TLS_ACME_MODE="direct"
    fi
    cf_delete_managed_record   # 验证通过后才清理旧域名的脚本记录
    if [[ -n "${CF_API_TOKEN:-}" ]]; then
      if cf_setup_domain "$TLS_DOMAIN"; then
        TLS_ACME=1
      else
        echo "[警告] Cloudflare 设置未完成，已回退自签证书直连"
      fi
    fi
    break
  done
  if [[ "$_use_default" == "1" ]]; then
    cf_delete_managed_record   # 旧域名若是脚本在 CF 建的记录，先删再换，避免残留
    TLS_DOMAIN=""
    TLS_ACME=0
    TLS_DOMAIN_AUTO=1
    ensure_tls_domain
  fi
  save_env
  if [[ "${TLS_ACME:-0}" != "1" ]]; then
    # 自签模式下新域名要进证书 SAN，重签一次（ACME 模式下域名链不使用这张证书）
    rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key"
    gen_certs
  fi
  write_config
  open_firewall
  setup_service
  acme_verify_or_fallback
  print_links
  echo
  echo "[完成] TLS 域名已更新：$TLS_DOMAIN"
}

# 启动 Argo 固定隧道
start_argo_fixed() {
  local cf
  cf=$(ensure_cloudflared) || { echo "[警告] cloudflared 不可用，固定隧道未启动（不影响其他协议；网络恢复后运行 sbox restart 可重试）"; return 0; }
  if [[ -z "${ARGO_TOKEN:-}" ]]; then
    echo "[错误] 未配置 Argo Token"
    return 1
  fi
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true   # 先停掉可能在跑的旧托管实例，避免双开
  pkill -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1 || true
  sleep 1
  echo "[信息] 固定隧道启动中…"
  if start_argo_systemd "$cf tunnel --no-autoupdate run --token $ARGO_TOKEN"; then
    echo "[信息] 固定隧道已由 systemd 托管（崩溃自动拉起）"
  else
    nohup "$cf" tunnel --no-autoupdate run --token "$ARGO_TOKEN" > "$SB_DIR/argo.log" 2>&1 &
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "$SB_DIR/cloudflared"
       echo "@reboot sleep 15 && $cf tunnel --no-autoupdate run --token $ARGO_TOKEN > $SB_DIR/argo.log 2>&1 &") | crontab - >/dev/null 2>&1 || true
    fi
  fi
  sleep 5
  echo "[信息] 固定隧道域名：${ARGO_DOMAIN:-（未知）}"
}

# Argo 期望状态对齐检查：argo.env 声明的模式/令牌（或临时隧道的 VMess 端口）
# 与现行 Argo 单元 ExecStart（无 systemd 时为 crontab @reboot 行）不一致、
# 或单元/自启行缺失时返回 0（需要重建），一致返回 1。此前 restart 根本不碰
# Argo，外部手改 argo.env 后跑多少次 restart 都不会生效，靠它在重启时发现。
argo_unit_diverged() {
  local _want _cur=""
  if [[ -f "$SB_DIR/argo.env" ]] && grep -q '^ARGO_MODE="fixed"' "$SB_DIR/argo.env"; then
    local _tok
    _tok=$(grep '^ARGO_TOKEN=' "$SB_DIR/argo.env" 2>/dev/null | cut -d'"' -f2 || true)
    _want="tunnel --no-autoupdate run --token $_tok"
  else
    _want="tunnel --url http://localhost:${PORT_VMESS}"
  fi
  if [[ -f "/etc/systemd/system/${ARGO_UNIT}.service" ]]; then
    _cur=$(grep '^ExecStart=' "/etc/systemd/system/${ARGO_UNIT}.service" 2>/dev/null | sed 's/^ExecStart=//' || true)
  elif command -v crontab >/dev/null 2>&1; then
    _cur=$(crontab -l 2>/dev/null | grep '@reboot' | grep "$SB_DIR/cloudflared" || true)
  fi
  [[ -n "$_cur" && "$_cur" == *"$_want"* ]] && return 1
  return 0
}

# 重启（菜单项 2 与 restart 动作共用）：本体重启后对齐 Argo 期望状态。
# 配置无分歧时不扰动在跑的隧道——临时隧道一旦重连就会换域名、已分享的
# 链接随之作废；仅当隧道没在运行时才按现行配置把它拉起来。
do_restart() {
  load_env_or_exit
  setup_service
  if argo_unit_diverged; then
    echo "[信息] 检测到 Argo 配置与运行状态不一致，按 argo.env 重新生成"
    start_argo
  elif [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    systemctl is-active --quiet "$ARGO_UNIT" 2>/dev/null || start_argo
  else
    pgrep -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1 || start_argo
  fi
  echo "[完成] 服务已重启"
}

# 7. Argo 隧道管理子菜单
do_argo_menu() {
  load_env_or_exit
  # 载入 Argo 状态用于显示：固定隧道读 argo.env，临时隧道从日志恢复当前域名
  if [[ -f "$SB_DIR/argo.env" ]]; then
    # shellcheck disable=SC1090
    . "$SB_DIR/argo.env" 2>/dev/null || true
  elif [[ -z "${ARGO_DOMAIN:-}" ]]; then
    ARGO_DOMAIN="$(current_argo_domain)"
  fi
  while true; do
    echo
    echo "---------- Argo 隧道管理 ----------"
    if [[ "${ARGO_MODE:-}" == "fixed" ]]; then
      echo "当前模式：固定隧道（${ARGO_DOMAIN:-未知域名}）"
    else
      echo "当前模式：临时隧道（${ARGO_DOMAIN:-未建立}）"
    fi
    echo "1. 重新抓取隧道域名（隧道在跑但没显示域名时用）"
    echo "2. 重启临时隧道（获取新域名）"
    echo "3. 设置固定隧道（需 Cloudflare Token）"
    echo "4. 切换回临时隧道"
    echo "0. 返回上级"
    read -rp "请选择 [0-4]: " c
    case "$c" in
      1)
        ARGO_DOMAIN="$(current_argo_domain)"
        if [[ -n "$ARGO_DOMAIN" ]]; then
          echo "[信息] 抓到域名：$ARGO_DOMAIN"
          print_links
        else
          echo "[警告] 日志里还没有域名，隧道可能仍在启动中，稍后再试"
          tail -n 5 "$SB_DIR/argo.log" 2>/dev/null || true
        fi
        ;;
      2)
        rm -f "$SB_DIR/argo.env"
        unset ARGO_MODE ARGO_TOKEN ARGO_DOMAIN
        start_argo
        print_links
        ;;
      3)
        local token domain
        read -rp "输入 Argo Tunnel Token: " token
        read -rp "输入固定隧道域名: " domain
        if [[ -z "$token" || -z "$domain" ]]; then
          echo "[错误] Token 和域名不能为空"
          continue
        fi
        # 格式白名单校验：argo.env 之后会被 source 加载，含引号/$()/反引号的输入会破坏文件结构甚至被执行
        if [[ ! "$token" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
          echo "[错误] Token 格式不对（应为 Cloudflare 签发的长字符串，只含字母、数字与 +/=_- 等符号）"
          continue
        fi
        if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ || "$domain" != *.* || "$domain" == .* || "$domain" == *. ]]; then
          echo "[错误] 域名格式不对（示例：tun.example.com）"
          continue
        fi
        cat > "$SB_DIR/argo.env" <<EOF
ARGO_MODE="fixed"
ARGO_TOKEN="$token"
ARGO_DOMAIN="$domain"
EOF
        chmod 600 "$SB_DIR/argo.env"
        echo "[提示] Token 方式的固定隧道，转发目标在 Cloudflare 侧管理：请确认隧道 ingress 指向 http://localhost:${PORT_VMESS}（本机 VMess 端口），不一致时 Argo 链会返回 502；可在 CF 面板修改，或用本菜单的 API 方式自动写入"
        # shellcheck disable=SC1090
        . "$SB_DIR/argo.env"
        start_argo_fixed
        print_links
        echo
        echo "[完成] 已切换到固定隧道：$domain"
        ;;
      4)
        rm -f "$SB_DIR/argo.env"
        unset ARGO_MODE ARGO_TOKEN ARGO_DOMAIN
        start_argo
        print_links
        ;;
      0) break ;;
      *) echo "[错误] 无效选择" ;;
    esac
  done
}

#----------------------------- WARP 出站 -------------------------------------
# sing-box 内置 WireGuard 出口：不开 TUN、不加常驻进程，关闭时配置里不生成
# 任何 WARP 内容（零成本）。注册参数由 wgcf 一次性生成（下载→注册→删除，
# 绝不常驻），全部落在 warp.env（600 权限，只用 grep 解析、从不 source），
# 之后可经菜单 change-warp 开关、切换模式或重新注册。
# 模式：off=关闭；ipv4=仅 IPv4 目的地经 WARP（给纯 IPv6 机器补 IPv4 出口，
# 其余直连）；all=全部流量经 WARP。

# 读取 warp.env 到全局变量；文件不存在或字段被污染时按关闭处理
load_warp_env() {
  WARP_MODE="off"; WARP_PRIVATE_KEY=""; WARP_V4=""; WARP_V6=""
  WARP_RESERVED=""; WARP_PEER_KEY=""; WARP_ENDPOINT_HOST=""; WARP_ENDPOINT_PORT=""
  WARP_MTU=""
  [[ -f "$WARP_ENV_FILE" ]] || return 0
  local _v
  _v=$(grep '^WARP_MODE=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  case "$_v" in off|ipv4|all) WARP_MODE="$_v" ;; esac
  WARP_PRIVATE_KEY=$(grep '^WARP_PRIVATE_KEY=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  WARP_V4=$(grep '^WARP_V4=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  WARP_V6=$(grep '^WARP_V6=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  WARP_RESERVED=$(grep '^WARP_RESERVED=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  WARP_PEER_KEY=$(grep '^WARP_PEER_KEY=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  WARP_ENDPOINT_HOST=$(grep '^WARP_ENDPOINT_HOST=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  WARP_ENDPOINT_PORT=$(grep '^WARP_ENDPOINT_PORT=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  WARP_MTU=$(grep '^WARP_MTU=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  # 字符集校验：私钥字段异常说明状态文件被污染，整份状态视为不可用，
  # 宁可日后重新注册，也不拿坏参数生成配置
  if [[ -n "$WARP_PRIVATE_KEY" && ! "$WARP_PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{42,44}={0,2}$ ]]; then
    echo "[警告] warp.env 中的 WARP 私钥格式异常，已忽略现有 WARP 状态" >&2
    WARP_MODE="off"; WARP_PRIVATE_KEY=""; WARP_V4=""; WARP_V6=""; WARP_RESERVED=""
    WARP_PEER_KEY=""; WARP_ENDPOINT_HOST=""; WARP_ENDPOINT_PORT=""; WARP_MTU=""
  fi
  return 0
}

# 注册参数是否齐全（生成 endpoint 配置的最低要求）
warp_profile_complete() {
  [[ -n "$WARP_PRIVATE_KEY" && -n "$WARP_V4" && -n "$WARP_PEER_KEY" \
     && -n "$WARP_ENDPOINT_HOST" && -n "$WARP_ENDPOINT_PORT" ]]
}

# 原子落盘：先写临时文件再改名，避免中途断电/中断留下半份 warp.env
save_warp_env() {
  local _tmp="$WARP_ENV_FILE.tmp"
  {
    printf 'WARP_MODE="%s"\n' "${WARP_MODE:-off}"
    printf 'WARP_PRIVATE_KEY="%s"\n' "$WARP_PRIVATE_KEY"
    printf 'WARP_V4="%s"\n' "$WARP_V4"
    printf 'WARP_V6="%s"\n' "$WARP_V6"
    printf 'WARP_RESERVED="%s"\n' "$WARP_RESERVED"
    printf 'WARP_PEER_KEY="%s"\n' "$WARP_PEER_KEY"
    printf 'WARP_ENDPOINT_HOST="%s"\n' "$WARP_ENDPOINT_HOST"
    printf 'WARP_ENDPOINT_PORT="%s"\n' "$WARP_ENDPOINT_PORT"
    printf 'WARP_MTU="%s"\n' "$WARP_MTU"
  } > "$_tmp" && mv -f "$_tmp" "$WARP_ENV_FILE"
  chmod 600 "$WARP_ENV_FILE"
}

warp_mode_desc() {
  case "${WARP_MODE:-off}" in
    ipv4) echo "IPv4 经 WARP（其余直连）" ;;
    all) echo "全部流量经 WARP" ;;
    *) echo "关闭" ;;
  esac
}

# 生成 sing-box 的 WireGuard endpoint JSON（调用前须 load_warp_env 且参数齐全）
warp_endpoint_json() {
  local _addr="\"$WARP_V4/32\""
  [[ -n "$WARP_V6" ]] && _addr="$_addr, \"$WARP_V6/128\""
  local _res=""
  [[ -n "$WARP_RESERVED" ]] && _res=", \"reserved\": [${WARP_RESERVED//,/, }]"
  printf '%s' "{\"type\": \"wireguard\", \"tag\": \"warp\", \"address\": [$_addr], \"private_key\": \"$WARP_PRIVATE_KEY\", \"mtu\": ${WARP_MTU:-1280}, \"peers\": [{\"address\": \"$WARP_ENDPOINT_HOST\", \"port\": $WARP_ENDPOINT_PORT, \"public_key\": \"$WARP_PEER_KEY\", \"allowed_ips\": [\"0.0.0.0/0\", \"::/0\"]$_res}]}"
}

# 下载 wgcf 到 $1：先走 ensure_github 的可达性引导（纯 IPv6 机经 DNS64/NAT64
# 绕行 GitHub），再按 GitHub API 找最新版的本架构资产
warp_fetch_wgcf() {
  local _dst="$1" _arch _resp _url
  case "$(uname -m)" in
    x86_64) _arch="amd64" ;;
    aarch64) _arch="arm64" ;;
    armv7l) _arch="armv7" ;;
    armv6l) _arch="armv6" ;;
    i386|i686) _arch="386" ;;
    *) echo "[错误] 当前架构 $(uname -m) 没有 wgcf 官方构建" >&2; return 1 ;;
  esac
  ensure_github || true
  _resp=$(curl -fsSL --max-time 20 --retry 2 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" 2>/dev/null || true)
  _url=$(printf '%s' "$_resp" | grep -o "\"browser_download_url\": *\"[^\"]*_linux_${_arch}\"" | head -n 1 | cut -d'"' -f4 || true)
  [[ -n "$_url" ]] || { echo "[错误] 未能获取 wgcf 下载地址（GitHub 不可达或无此架构资产）" >&2; return 1; }
  curl -fSL --retry 2 --max-time 120 -o "$_dst" "$_url" 2>/dev/null || { echo "[错误] wgcf 下载失败" >&2; return 1; }
  chmod +x "$_dst"
}

# 用 wgcf 一次性注册并把参数解析进全局变量（不落盘，由调用方决定何时保存）。
# wgcf 只在临时目录里存在，结束即删；注册有界重试 3 次、单次 60 秒超时。
warp_register() {
  echo "[信息] 正在用 wgcf 一次性注册 WARP 设备（用完即删，不常驻）…"
  local _dir _try _ok=0
  _dir=$(mktemp -d)
  if ! warp_fetch_wgcf "$_dir/wgcf"; then
    rm -rf "$_dir"
    return 1
  fi
  for _try in 1 2 3; do
    if ( cd "$_dir" && timeout 60 ./wgcf register --accept-tos >/dev/null 2>&1 \
         && timeout 60 ./wgcf generate >/dev/null 2>&1 ) \
       && [[ -f "$_dir/wgcf-profile.conf" ]]; then
      _ok=1; break
    fi
    echo "[警告] WARP 注册第 ${_try} 次尝试失败（共 3 次）"
    [[ "$_try" -lt 3 ]] && sleep $((_try * 3))
  done
  if [[ "$_ok" != "1" ]]; then
    echo "[错误] WARP 注册失败：wgcf 三次尝试均未完成（多为 Cloudflare 注册接口不可达）"
    rm -rf "$_dir"
    return 1
  fi
  # 解析 wgcf-profile.conf：[Interface] PrivateKey/Address/MTU、[Peer] PublicKey/Endpoint
  local _conf="$_dir/wgcf-profile.conf" _addr _ep _cid _hex
  WARP_PRIVATE_KEY=$(grep -E '^PrivateKey[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
  _addr=$(grep -E '^Address[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
  WARP_V4=$(printf '%s' "$_addr" | tr ',' '\n' | grep -E '^[0-9.]+/' | head -n 1 | cut -d/ -f1 || true)
  WARP_V6=$(printf '%s' "$_addr" | tr ',' '\n' | grep ':' | head -n 1 | cut -d/ -f1 || true)
  WARP_PEER_KEY=$(grep -E '^PublicKey[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
  WARP_MTU=$(grep -E '^MTU[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
  _ep=$(grep -E '^Endpoint[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
  WARP_ENDPOINT_HOST="${_ep%:*}"
  WARP_ENDPOINT_PORT="${_ep##*:}"
  # reserved（client_id 三字节）：wgcf 的输出文件里带 client_id 就解出来存下；
  # 没有就留空（endpoint 不写 reserved 字段），是否可用以启用后出口实测为准
  WARP_RESERVED=""
  _cid=$(grep -hoE 'client_id"?[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9+/=]+' \
           "$_dir/wgcf-account.toml" "$_conf" 2>/dev/null | grep -oE '[A-Za-z0-9+/=]+$' | head -n 1 || true)
  if [[ -n "$_cid" ]]; then
    _hex=$(printf '%s' "$_cid" | base64 -d 2>/dev/null | od -An -tu1 | tr -s ' ' || true)
    WARP_RESERVED=$(printf '%s' "$_hex" | awk '{if (NF>=3) printf "%s,%s,%s", $1, $2, $3}')
  fi
  rm -rf "$_dir"
  [[ -n "$WARP_MTU" ]] || WARP_MTU="1280"
  if ! warp_profile_complete; then
    echo "[错误] WARP 注册结果不完整（wgcf 输出缺少必要参数）"
    return 1
  fi
  echo "[信息] WARP 注册完成"
  return 0
}

# 生成探针配置到 $1/probe.json（本地入口端口 $2）：仅本地 mixed 入口 + WARP
# 出口、route final=warp。探针进程与主配置同病同治：受限网络环境下探针的
# 内置解析同样枚举不到默认接口（www.cloudflare.com 还没轮到走 WARP 就先死
# 在解析上），故探针配置并入同一份自适应 dns/route（route 的 final 仍为
# warp）；非受限环境保持原字面量，行为与此前一致。
# warp_probe（出口自检）与 warp_trace_info（出口信息展示）共用此生成方式
warp_write_probe_config() {
  local _dir="$1" _port="$2" _probe_tail
  if restricted_net_env; then
    _probe_tail=$(restricted_net_tail '"final": "warp"')
  else
    _probe_tail=',
  "route": {"final": "warp"}'
  fi
  cat > "$_dir/probe.json" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{"type": "mixed", "tag": "probe-in", "listen": "127.0.0.1", "listen_port": $_port}],
  "endpoints": [$(warp_endpoint_json)],
  "outbounds": [{"type": "direct", "tag": "direct"}]${_probe_tail}
}
EOF
}

# 出口自检：用与正式配置相同的 WARP 参数起一个临时 sing-box（仅本地 mixed
# 入口 + WARP 出口），经它取 Cloudflare trace，确认 warp=on/plus 才算通。
# 临时进程与文件用完即删，不碰正在运行的服务。成功返回 0
warp_probe() {
  local _dir _port _pid _out _try
  _dir=$(mktemp -d)
  _port=$(rand_port)
  warp_write_probe_config "$_dir" "$_port"
  if ! "$SB_DIR/sing-box" check -c "$_dir/probe.json" >/dev/null 2>&1; then
    echo "[错误] WARP 自检配置未通过 sing-box 校验"
    rm -rf "$_dir"
    return 1
  fi
  "$SB_DIR/sing-box" run -c "$_dir/probe.json" > "$_dir/probe.log" 2>&1 &
  _pid=$!
  _out=""
  for _try in 1 2 3 4 5; do
    sleep 3
    _out=$(curl -s --max-time 10 -x "socks5h://127.0.0.1:$_port" \
             "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null \
           | grep -E '^warp=' | cut -d= -f2 || true)
    [[ "$_out" == "on" || "$_out" == "plus" ]] && break
    _out=""
  done
  kill "$_pid" >/dev/null 2>&1 || true
  wait "$_pid" 2>/dev/null || true
  if [[ -n "$_out" ]]; then
    echo "[信息] WARP 出口自检通过（Cloudflare trace 显示 warp=$_out）"
    rm -rf "$_dir"
    return 0
  fi
  echo "[错误] WARP 出口自检未通过：经 WARP 访问 Cloudflare trace 未得到 warp=on，自检日志最后几行："
  tail -n 5 "$_dir/probe.log" 2>/dev/null || true
  rm -rf "$_dir"
  return 1
}

# 解析 Cloudflare trace 全文（$1）：仅 warp=on/plus 时提取 ip= 与 loc=，
# 成功输出一行「WARP 出口：<ip>（<loc>）」（缺 loc 时只输出 IP），
# 否则返回 1 且无输出。
# 【铁律】trace 里的出口 IP 是 Cloudflare 的共享出口地址，只许展示给人看，
# 绝不写入任何节点链接、env 或配置当服务器地址用——ygkkk 旧脚本曾把经
# WARP 探测到的出口 IP 写进直链与域名校验，造成链接拨不通、解析对不上；
# 本项目结构上禁止重蹈：本函数与 warp_trace_info 的输出无任何落盘路径
warp_trace_parse() {
  local _txt="$1" _w _ip _loc
  _w=$(printf '%s\n' "$_txt" | grep -E '^warp=' | head -n 1 | cut -d= -f2 || true)
  [[ "$_w" == "on" || "$_w" == "plus" ]] || return 1
  _ip=$(printf '%s\n' "$_txt" | grep -E '^ip=' | head -n 1 | cut -d= -f2 || true)
  [[ -n "$_ip" ]] || return 1
  _loc=$(printf '%s\n' "$_txt" | grep -E '^loc=' | head -n 1 | cut -d= -f2 || true)
  if [[ -n "$_loc" ]]; then
    printf 'WARP 出口：%s（%s）\n' "$_ip" "$_loc"
  else
    printf 'WARP 出口：%s\n' "$_ip"
  fi
}

# 展示当前 WARP 出口 IP 与落地国家：WARP 未启用（模式 off 或参数不齐）时
# 直接返回 1、不输出、也不起探针；启用时起一个临时 sing-box 经 WARP 拉
# trace 再解析（探针配置与 warp_probe 共用 warp_write_probe_config，临时
# 进程与目录用完即清理，同 warp_probe 规矩）。取不到就返回 1 不输出，
# 调用方一律以 || true 承接，绝不阻塞菜单与安装流程
warp_trace_info() {
  load_warp_env
  [[ "$WARP_MODE" != "off" ]] || return 1
  warp_profile_complete || return 1
  local _dir _port _pid _txt="" _try
  _dir=$(mktemp -d)
  _port=$(rand_port)
  warp_write_probe_config "$_dir" "$_port"
  if ! "$SB_DIR/sing-box" check -c "$_dir/probe.json" >/dev/null 2>&1; then
    rm -rf "$_dir"
    return 1
  fi
  "$SB_DIR/sing-box" run -c "$_dir/probe.json" > "$_dir/probe.log" 2>&1 &
  _pid=$!
  for _try in 1 2 3 4 5; do
    sleep 3
    _txt=$(curl -s --max-time 10 -x "socks5h://127.0.0.1:$_port" \
             "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || true)
    if printf '%s' "$_txt" | grep -qE '^warp='; then break; fi
    _txt=""
  done
  kill "$_pid" >/dev/null 2>&1 || true
  wait "$_pid" 2>/dev/null || true
  rm -rf "$_dir"
  [[ -n "$_txt" ]] || return 1
  warp_trace_parse "$_txt"
}

# 回滚 WARP 变更：恢复 auto.env / sb.json / warp.env 三件套备份并重启服务
# （备份不存在的 warp.env 按「原本没有」处理：回滚时删除）
warp_rollback() {
  [[ -f "$ENV_FILE.bak" ]] && cp -f "$ENV_FILE.bak" "$ENV_FILE" || true
  [[ -f "$SB_DIR/sb.json.bak" ]] && cp -f "$SB_DIR/sb.json.bak" "$SB_DIR/sb.json" || true
  if [[ -f "$WARP_ENV_FILE.bak" ]]; then
    cp -f "$WARP_ENV_FILE.bak" "$WARP_ENV_FILE"
  else
    rm -f "$WARP_ENV_FILE"
  fi
  rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak" "$WARP_ENV_FILE.bak"
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  setup_service
}

# 切换 WARP 模式（原子生效，与换端口同规矩）：先备份、需要时才注册（已有
# 参数直接复用，幂等）、落盘新状态、生成配置（子进程跑 write_config，挡住
# 它校验失败时的 exit）、重启、出口自检；任一步失败自动回滚并说明原因。
# $1=目标模式 off|ipv4|all  $2=1 时强制重新注册（换一套设备参数）
warp_apply() {
  local _mode="$1" _force="${2:-0}"
  load_env_or_exit
  load_warp_env
  cp -f "$ENV_FILE" "$ENV_FILE.bak" 2>/dev/null || true
  [[ -f "$SB_DIR/sb.json" ]] && cp -f "$SB_DIR/sb.json" "$SB_DIR/sb.json.bak" || true
  [[ -f "$WARP_ENV_FILE" ]] && cp -f "$WARP_ENV_FILE" "$WARP_ENV_FILE.bak" || true
  if [[ "$_mode" != "off" || "$_force" == "1" ]]; then
    if [[ "$_force" == "1" ]]; then
      WARP_PRIVATE_KEY=""; WARP_V4=""; WARP_V6=""; WARP_RESERVED=""
      WARP_PEER_KEY=""; WARP_ENDPOINT_HOST=""; WARP_ENDPOINT_PORT=""; WARP_MTU=""
    fi
    if ! warp_profile_complete; then
      if ! warp_register; then
        echo "[错误] WARP 注册未完成，未做任何修改"
        rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak" "$WARP_ENV_FILE.bak"
        return 1
      fi
    fi
  fi
  WARP_MODE="$_mode"
  save_warp_env
  if ! ( write_config ); then
    echo "[错误] 新配置生成/校验失败，已自动回滚，WARP 模式未改变"
    warp_rollback
    return 1
  fi
  setup_service
  if [[ "$_mode" != "off" ]] && ! warp_probe; then
    echo "[错误] WARP 已写入配置但出口自检未通过，已自动回滚到之前的状态"
    warp_rollback
    return 1
  fi
  rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak" "$WARP_ENV_FILE.bak"
  echo "[完成] WARP 出站模式已更新：$(warp_mode_desc)"
  # 启用成功顺手展示一次出口 IP 与落地国家（仅展示，取不到不算失败）
  if [[ "$_mode" != "off" ]]; then
    warp_trace_info || true
  fi
  return 0
}

# 本机是否有可用的 IPv4 出口（与 ensure_github 的 IPv6 检测同一探法）
has_ipv4_egress() {
  curl -4 -fsS --connect-timeout 5 --max-time 8 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1
}

# 安装时的 WARP 决策（静默安装哲学）：已有状态直接保留、不重复决策；
# 否则按环境定默认——无 IPv4 出口默认开启 IPv4 经 WARP、有 IPv4 出口默认
# 关闭；有终端时给一次 20 秒选择（回车/输错/超时取默认），无终端直接用默认。
# 注册/自检失败一律降级为关闭并留一句总结（WARP_NOTE），绝不中断安装、
# 不留半成品（失败时不保存注册参数，日后可从菜单重新注册）。
warp_install_setup() {
  load_warp_env
  if [[ "$WARP_MODE" != "off" ]] || warp_profile_complete; then
    return 0
  fi
  local _def="off" _def_desc="关闭"
  if ! has_ipv4_egress; then
    _def="ipv4"; _def_desc="开启（IPv4 经 WARP）"
  fi
  local _choice="$_def" _ans=""
  if [[ -r /dev/tty ]]; then
    read -t "$CHOICE_TIMEOUT" -r -p "WARP 出站：1=开启（IPv4 经 WARP） 2=全部经 WARP 3=关闭（回车/输错/20 秒无输入 = 默认选择：$_def_desc）: " _ans </dev/tty || _ans=""
    case "$_ans" in
      1) _choice="ipv4" ;;
      2) _choice="all" ;;
      3) _choice="off" ;;
      *) _choice="$_def" ;;
    esac
  fi
  if [[ "$_choice" == "off" ]]; then
    WARP_NOTE="WARP 出站：未开启（可日后运行 sbox change-warp 开启）"
    echo "[信息] $WARP_NOTE"
    return 0
  fi
  if warp_register && warp_probe; then
    WARP_MODE="$_choice"
    save_warp_env
    WARP_NOTE="WARP 出站：已开启（$(warp_mode_desc)）"
    # 总结里带上出口 IP 与落地国家（仅展示，取不到就跳过、不算失败）
    local _ti=""
    _ti=$(warp_trace_info || true)
    [[ -n "$_ti" ]] && WARP_NOTE="$WARP_NOTE；$_ti"
    echo "[信息] $WARP_NOTE"
  else
    WARP_PRIVATE_KEY=""; WARP_V4=""; WARP_V6=""; WARP_RESERVED=""
    WARP_PEER_KEY=""; WARP_ENDPOINT_HOST=""; WARP_ENDPOINT_PORT=""; WARP_MTU=""
    WARP_MODE="off"
    rm -f "$WARP_ENV_FILE"
    WARP_NOTE="WARP 出站：未开启（注册或出口自检未通过，已自动跳过；可日后运行 sbox change-warp 重试）"
    echo "[警告] $WARP_NOTE"
  fi
  return 0
}

# 更换 WARP IP：强制重新注册一套设备参数（出口 IP 随新账号变更），保持当前
# 模式不变。一次调用只换一次——频繁注册会招 Cloudflare 注册限流（429），
# 想再换请隔段时间。底层走 warp_apply 的强制注册路径：先备份、生成新配置、
# 重启、出口自检，任一步失败自动回滚到旧参数与旧配置（原出口 IP 保住）；
# 普通 change-warp 的「参数齐全直接复用」幂等路径不经过这里、不受影响
warp_reroll() {
  load_warp_env
  if [[ "$WARP_MODE" == "off" ]]; then
    echo "[提示] WARP 当前为关闭状态，没有可更换的出口 IP；请先在菜单选 1 或 2 启用 WARP"
    return 0
  fi
  echo "[信息] 正在更换 WARP IP（重新注册一套设备参数，模式保持：$(warp_mode_desc)）…"
  if warp_apply "$WARP_MODE" 1; then
    return 0
  fi
  echo "[提示] 更换 WARP IP 未成功，已恢复原有参数与配置（原出口 IP 保持不变）"
  return 0
}

# WARP 出站管理子菜单
do_warp_menu() {
  load_env_or_exit
  while true; do
    load_warp_env
    echo
    echo "---------- WARP 出站管理 ----------"
    echo "当前模式：$(warp_mode_desc)"
    if warp_profile_complete; then
      echo "注册状态：已注册（参数在 $WARP_ENV_FILE，重复开启直接复用、不重新注册）"
    else
      echo "注册状态：未注册（首次开启时用 wgcf 一次性注册，用完即删）"
    fi
    # 已启用时在状态区展示出口 IP 与落地国家（仅展示；取不到不显示、不阻塞）
    if [[ "$WARP_MODE" != "off" ]] && warp_profile_complete; then
      warp_trace_info || true
    fi
    echo "1. IPv4 经 WARP（推荐：给纯 IPv6 机器补 IPv4 出口，其余流量直连）"
    echo "2. 全部流量经 WARP"
    echo "3. 关闭 WARP 出站（配置里不留任何 WARP 内容，零成本）"
    echo "4. 更换 WARP IP（重新注册换一套参数，出口随之变更；频繁更换可能触发 Cloudflare 注册限流）"
    echo "0. 返回上级"
    local _c=""
    read -t "$CHOICE_TIMEOUT" -rp "请选择 [0-4]（回车/输错/20 秒无输入 = 默认选择：0 返回）: " _c || _c="0"
    case "$_c" in
      1) warp_apply ipv4 || true ;;
      2) warp_apply all || true ;;
      3) warp_apply off || true ;;
      4) warp_reroll || true ;;
      0) break ;;
      *) echo "[错误] 无效选择" ;;
    esac
  done
}

# 4. 更换端口
do_change_ports() {
  load_env_or_exit
  echo "当前端口：VLESS=$PORT_VLESS VMess-WS=$PORT_VMESS Hy2=$PORT_HY2 TUIC=$PORT_TUIC AnyTLS=$PORT_ANYTLS VLESS-WS-TLS=${PORT_VTLS:-}"
  echo "输入新端口（直接回车保持不变；VLESS-WS-TLS 要套 Cloudflare 须用 443/8443/2053/2083/2087/2096 之一）："
  local p
  local n_vless="$PORT_VLESS" n_vmess="$PORT_VMESS" n_hy2="$PORT_HY2" n_tuic="$PORT_TUIC" n_anytls="$PORT_ANYTLS" n_vtls="${PORT_VTLS:-}"
  read -rp "VLESS [$PORT_VLESS]: " p; [[ -n "$p" ]] && n_vless="$p"
  read -rp "VMess-WS [$PORT_VMESS]: " p; [[ -n "$p" ]] && n_vmess="$p"
  read -rp "Hysteria2 [$PORT_HY2]: " p; [[ -n "$p" ]] && n_hy2="$p"
  read -rp "TUIC [$PORT_TUIC]: " p; [[ -n "$p" ]] && n_tuic="$p"
  read -rp "AnyTLS [$PORT_ANYTLS]: " p; [[ -n "$p" ]] && n_anytls="$p"
  read -rp "VLESS-WS-TLS [${PORT_VTLS:-}]: " p; [[ -n "$p" ]] && n_vtls="$p"
  # ---- 写入前校验：全部通过才动 env/配置，坏输入不留半成品 ----
  local names=("VLESS" "VMess-WS" "Hysteria2" "TUIC" "AnyTLS" "VLESS-WS-TLS")
  local news=("$n_vless" "$n_vmess" "$n_hy2" "$n_tuic" "$n_anytls" "$n_vtls")
  local olds=" $PORT_VLESS $PORT_VMESS $PORT_HY2 $PORT_TUIC $PORT_ANYTLS ${PORT_VTLS:-} "
  local i j v
  for i in 0 1 2 3 4 5; do
    v="${news[$i]}"
    if ! [[ "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 || 10#$v > 65535 )); then
      echo "[错误] ${names[$i]} 端口不合法：'$v'（须为 1-65535 的数字），未做任何修改"
      return 0
    fi
    news[$i]=$((10#$v))
  done
  for i in 0 1 2 3 4 5; do
    for j in 0 1 2 3 4 5; do
      if (( i < j )) && [[ "${news[$i]}" == "${news[$j]}" ]]; then
        echo "[错误] ${names[$i]} 与 ${names[$j]} 端口重复：${news[$i]}，未做任何修改"
        return 0
      fi
    done
  done
  for i in 0 1 2 3 4 5; do
    v="${news[$i]}"
    # 本服务现有的端口在重启时会被释放，不算占用；其余端口被占则拒绝
    if [[ "$olds" != *" $v "* ]] && port_in_use "$v"; then
      echo "[错误] ${names[$i]} 端口 $v 已被其他程序占用，未做任何修改"
      return 0
    fi
  done
  # ---- 备份现状；写完配置用 sing-box 自检，不过则回滚 ----
  cp -f "$ENV_FILE" "$ENV_FILE.bak" 2>/dev/null || true
  [[ -f "$SB_DIR/sb.json" ]] && cp -f "$SB_DIR/sb.json" "$SB_DIR/sb.json.bak" || true
  PORT_VLESS="${news[0]}"; PORT_VMESS="${news[1]}"; PORT_HY2="${news[2]}"; PORT_TUIC="${news[3]}"; PORT_ANYTLS="${news[4]}"; PORT_VTLS="${news[5]}"
  save_env
  write_config
  if [[ -x "$SB_DIR/sing-box" ]] && ! "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1; then
    echo "[错误] 新配置未通过 sing-box 自检，已回滚到原端口配置"
    cp -f "$ENV_FILE.bak" "$ENV_FILE" 2>/dev/null || true
    [[ -f "$SB_DIR/sb.json.bak" ]] && cp -f "$SB_DIR/sb.json.bak" "$SB_DIR/sb.json" || true
    rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    return 0
  fi
  rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak"
  open_firewall
  setup_service
  start_argo
  print_links
  echo
  echo "[完成] 端口已更新"
}

# 9. 更新脚本到最新版（从 GitHub 拉取）
do_update_script() {
  echo "[信息] 正在从 GitHub 拉取最新脚本…"
  local tmpfile
  tmpfile=$(mktemp)
  if fetch_latest_script "$tmpfile"; then
    local newver=""
    newver=$(grep -m1 '^SCRIPT_VERSION=' "$tmpfile" | cut -d'"' -f2 || true)
    cp -f "$tmpfile" /usr/local/bin/sbox
    chmod 755 /usr/local/bin/sbox
    rm -f "$tmpfile"
    if [[ -n "$newver" ]]; then
      echo "[完成] 脚本已更新到 v$newver"
    else
      echo "[完成] 脚本已更新到最新版"
    fi
    return 0
  fi
  rm -f "$tmpfile"
  echo "[错误] 下载失败，请检查网络后重试"
  return 1
}

# 主管理菜单
# 检查端口是否在监听：$1=tcp|udp  $2=端口
port_listening() {
  case "$1" in
    tcp) command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE "[:.]$2[[:space:]]" ;;
    udp) command -v ss >/dev/null 2>&1 && ss -uln 2>/dev/null | grep -qE "[:.]$2[[:space:]]" ;;
    *) return 1 ;;
  esac
}

# 菜单端口状态
show_port_status() {
  local _d argo_st="未开启"
  if [[ -f "$SB_DIR/argo.env" ]] && grep -q '^ARGO_MODE="fixed"' "$SB_DIR/argo.env" 2>/dev/null; then
    argo_st="固定隧道：$(grep '^ARGO_DOMAIN=' "$SB_DIR/argo.env" 2>/dev/null | cut -d'"' -f2)"
  else
    _d="$(current_argo_domain)"
    [[ -n "$_d" ]] && argo_st="临时隧道：$_d"
  fi
  echo "Sing-box节点端口状态如下："
  local item name proto port st
  for item in \
    "Vless-reality|tcp|$PORT_VLESS" \
    "Vmess-ws|tcp|$PORT_VMESS" \
    "Hysteria-2|udp|$PORT_HY2" \
    "Tuic-v5|udp|$PORT_TUIC" \
    "Anytls|tcp|$PORT_ANYTLS" \
    "Vless-ws-tls|tcp|${PORT_VTLS:-0}"; do
    name="${item%%|*}"; proto="${item#*|}"; proto="${proto%%|*}"; port="${item##*|}"
    if port_listening "$proto" "$port"; then st="监听中"; else st="未监听"; fi
    if [[ "$name" == "Vmess-ws" ]]; then
      printf '🚀【 %-13s 】端口:%-5s  状态:%s  Argo:%s\n' "$name" "$port" "$st" "$argo_st"
    else
      printf '🚀【 %-13s 】端口:%-5s  状态:%s\n' "$name" "$port" "$st"
    fi
  done
  if command -v systemctl >/dev/null 2>&1; then
    echo "Sing-box状态：$(systemctl is-active "$UNIT" 2>/dev/null || echo '未知')"
  fi
  local _dom_desc="手动域名"
  [[ "${TLS_DOMAIN_AUTO:-1}" == "1" ]] && _dom_desc="自动临时域名"
  [[ "${TLS_ACME:-0}" == "1" ]] && _dom_desc="$_dom_desc + 真证书/Cloudflare"
  echo "TLS 域名：${TLS_DOMAIN:-未设置}（$_dom_desc）"
  local _warp_desc="关闭"
  if [[ -f "$WARP_ENV_FILE" ]]; then
    case "$(grep '^WARP_MODE=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)" in
      ipv4) _warp_desc="IPv4 经 WARP" ;;
      all) _warp_desc="全部经 WARP" ;;
    esac
  fi
  echo "WARP 出站：$_warp_desc"
}

show_menu() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "[错误] 请以 root 运行，例如：sudo bash $0 menu"
    exit 1
  fi
  load_env_or_exit
  while true; do
    echo
    echo "================ sing-box 管理菜单（v${SCRIPT_VERSION}）================"
    show_port_status
    echo
    echo "1. 查看节点链接"
    echo
    echo "2. 重启 sing-box 服务"
    echo "3. 更换 TLS 域名（可申请真证书/套 Cloudflare）"
    echo "4. Argo 隧道管理"
    echo "5. WARP 出站管理"
    echo
    echo "6. 更换 UUID（全协议）"
    echo "7. 更换端口"
    echo "8. 更新 Reality 密钥对"
    echo "9. 更新自签证书"
    echo
    echo "10. 更新 sing-box 内核到最新版"
    echo "11. 更新脚本到最新版"
    echo
    echo "12. 卸载"
    echo "0. 退出"
    echo "==================================================="
    read -rp "请选择 [0-12]: " choice
    case "$choice" in
      1) load_env_or_exit; print_links ;;
      2) do_restart ;;
      3) do_change_domain ;;
      4) do_argo_menu ;;
      5) do_warp_menu ;;
      6) do_change_uuid ;;
      7) do_change_ports ;;
      8) do_change_reality ;;
      9) do_change_cert ;;
      10) detect_arch; if ! do_update_core; then echo "[提示] 内核更新未完成，见上方信息"; fi ;;
      11) if do_update_script; then exec /usr/local/bin/sbox menu; fi ;;
      12) do_uninstall; break ;;
      0) echo "退出"; break ;;
      *) echo "[错误] 无效选择" ;;
    esac
  done
}


#----------------------------- 主流程 ----------------------------------------
case "$ACTION" in
  install)
    detect_os
    detect_arch
    ensure_github || true
    check_memory
    check_container
    install_deps
    ensure_cron_running
    ensure_time_sync
    disable_dnf_makecache
    install_singbox
    setup_shortcut
    load_or_gen_identity
    prompt_install_choices
    warp_install_setup
    gen_certs
    write_config
    open_firewall
    fix_selinux
    setup_service
    acme_verify_or_fallback
    start_argo
    print_links
    echo
    echo "[完成] 7 种协议已就绪，链接见上 / $LINKS_FILE"
    [[ -n "${WARP_NOTE:-}" ]] && echo "$WARP_NOTE"
    ;;
  uninstall)
    do_uninstall
    ;;
  menu)
    show_menu
    ;;
  change-uuid)
    do_change_uuid
    ;;
  change-reality)
    do_change_reality
    ;;
  change-cert)
    do_change_cert
    ;;
  change-argo)
    do_argo_menu
    ;;
  change-warp)
    do_warp_menu
    ;;
  warp-reroll)
    load_env_or_exit; warp_reroll
    ;;
  change-domain)
    do_change_domain
    ;;
  change-ports)
    do_change_ports
    ;;
  show-links)
    load_env_or_exit; print_links
    ;;
  restart)
    do_restart
    ;;
  update-script)
    do_update_script
    ;;
  update-core)
    load_env_or_exit; detect_arch; do_update_core
    ;;
  *)
    echo "用法：$0 [install|uninstall|menu|change-uuid|change-reality|change-cert|change-argo|change-warp|warp-reroll|change-domain|change-ports|show-links|restart|update-script|update-core|version]"
    exit 1
    ;;
esac
