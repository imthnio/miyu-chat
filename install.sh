#!/bin/sh
# shellcheck disable=SC1111
# =====================================================================
#  密语 miyu-chat 一键安装脚本
#  支持系统：Debian / Ubuntu（systemd）、Alpine（OpenRC）
#  支持机器：独立服务器（母鸡）、VPS（小鸡）、NAT 小鸡
#  两种接入方式（安装时让你选）：
#    1) 直连模式：程序监听 0.0.0.0:端口，靠公网 IP / 端口映射访问（原来的方式）
#    2) Cloudflare Tunnel 模式：程序只听本机 127.0.0.1:端口，由 cloudflared 主动连到 Cloudflare，
#       不用公网 IP、不用开防火墙端口、不用端口映射（NAT 小鸡推荐）
#
#  用法：
#    安装：  sh install.sh            （或 sh install.sh install；已经装过时会让你选“修改设置 / 更新 / 退出”）
#    改设置：sh install.sh config     （切换直连/Tunnel 模式、换 Tunnel 令牌、改邀请码和上限，聊天数据保留）
#    卸载：  sh install.sh uninstall  （删除程序、服务、数据、防火墙规则、本脚本装的 cloudflared，删得干干净净）
#    更新：  sh install.sh update     （只换程序，聊天数据和设置都保留；Tunnel 模式可顺便更新 cloudflared）
#    状态：  sh install.sh status
#
#  免交互安装（给会写脚本的人用，可选）：
#    MIYU_PORT=8080 MIYU_EXT_PORT=8080 sh install.sh     直接指定端口，不再提问
#    MIYU_MODE=direct 或 MIYU_MODE=tunnel                直接指定模式（直连 / Cloudflare Tunnel），不再提问
#    MIYU_TUNNEL_TOKEN_FILE=/root/token.txt             Tunnel 令牌从这个文件读（令牌不用写在命令行里）
#    MIYU_HOST=chat.example.com                         聊天域名（多个用逗号分隔；直连模式会自动再加上“公网IP:外部端口”）
#    MIYU_INVITE_CODE=random 或 none 或 你自己的邀请码     random=随机生成，none=不设置（默认不设置）
#    MIYU_MAX_USERS=50 MIYU_MAX_DB_MB=2000              最多多少用户、数据库最大多少 MB（0 = 不限制）
#    MIYU_CF_UPDATE=1 或 0                               更新时要不要顺便更新 cloudflared
#    MIYU_YES=1 sh install.sh uninstall                 卸载时不再二次确认
#    MIYU_BIN=/root/miyu-chat-linux-amd64 sh install.sh 用你自己下载好的程序文件
#    MIYU_SHA256=<64位校验值>                            配合 MIYU_BIN，校验你自己下载的文件
#    MIYU_DOWNLOAD_BASE=http://内网镜像/目录 sh install.sh  从你自己的镜像下载（目录里要有程序和 SHA256SUMS）
#
# ---------------------------------------------------------------------
#  名词小词典（看不懂的词先看这里）：
#    母鸡：独立服务器，整台物理机都是你的。
#    小鸡：从母鸡上切出来的一台 VPS（虚拟服务器）。
#    NAT 小鸡：多个人共用一个公网 IP，商家只把几个端口转给你。
#              别人访问“公网IP:外部端口”，商家再转到你机器里的“内部端口”。
#    端口映射：就是上面说的“外部端口 -> 内部端口”的转发关系，在商家后台能看到。
#    端口：一台机器上可以同时跑很多服务，用端口号（1-65535）区分。
#    WebSocket：聊天用的长连接，Cloudflare 默认支持，不用特别设置。
#    端到端加密：消息在浏览器里加密，服务器只存密文，看不到内容。
#    systemd / OpenRC：系统的“服务管家”，负责开机自启、崩溃自动重启。
#              Debian/Ubuntu 用 systemd，Alpine 用 OpenRC，脚本会自动判断。
#    数据目录：聊天数据都存在 /var/lib/miyu-chat/miyu.db 这一个文件里。
#    SHA256 校验值：文件的“指纹”。发布时会把官方程序的指纹写进 SHA256SUMS，
#              脚本下载完先对指纹，一个字节不对都不会安装，防止下到损坏或被篡改的程序。
#    jsDelivr：一个免费的 CDN 镜像站。国内机器连不上 GitHub 时，脚本自动改从这里下载。
#    Cloudflare 小黄云：在 Cloudflare 里把域名的云朵点成橙色，访问会先经过 Cloudflare 再转到你的机器，
#              能隐藏真实 IP、免费加 HTTPS。
#    Cloudflare Tunnel：Cloudflare 的免费“内网穿透”。你的机器主动连到 Cloudflare，
#              别人访问你的域名时，Cloudflare 顺着这条连接把请求送进来。
#              不用公网 IP、不用开端口、不用端口映射，NAT 小鸡也能用，还自带 HTTPS。
#    cloudflared：Cloudflare 官方的小程序，负责在你机器上建立并一直保持上面那条连接。
#              脚本从 Cloudflare 在 GitHub 的官方发布页下载，并核对官方公布的 SHA256 校验值。
#    Tunnel 令牌（token）：一长串 eyJ 开头的字符，是这条隧道的“钥匙”，等于密码。
#              谁拿到它，谁就能冒充你的机器接管这个域名的访问。千万不要发给别人、不要截图、不要贴到群里！
#              脚本输入时不显示，只存在 /etc/miyu-chat/tunnel.token（权限 0600），不会出现在日志和进程列表里。
#    127.0.0.1：只有本机自己能访问的地址。Tunnel 模式下聊天程序只听这个地址，
#              外面直接连不上，只能经过 Cloudflare Tunnel 进来，更安全。
#    邀请码：设置后，新用户第一次登录要先输入它，陌生人就没法在你的服务器上注册。
#    登录网址（MIYU_HOST）：新版程序登录时会核对浏览器地址栏里的网址（域名[:端口]），只认这里列出的，
#              防止别的网站转发登录。填错了大家都会登录失败（提示“密钥校验失败”），可以用 sh install.sh config 改。
#    环境变量文件：/etc/miyu-chat/miyu.env，放登录网址、邀请码、上限这些设置，权限 0600，只有 root 能看；
#              服务管家启动程序时把它交给程序，所以这些设置不会出现在命令行参数里（别人用 ps 看不到）。
#    0600 权限：文件只有它的主人（root 或指定的服务用户）能读写，其他用户连看都看不到。
# =====================================================================

# 出错就停，避免装到一半留下烂摊子
set -e

# ---------- 基本配置（一般不用改） ----------
REPO="imthnio/miyu-chat"                 # GitHub 仓库，程序从这里的 Release 下载
APP="miyu-chat"
BIN="/usr/local/bin/miyu-chat"           # 程序装在这里
DATA_DIR="/var/lib/miyu-chat"            # 聊天数据放这里
CONF="/etc/miyu-chat.conf"               # 记录你选的模式和端口，卸载/更新时要用
RUN_USER="miyu"                          # 用一个没有登录权限的普通用户运行，更安全
LOG_FILE="/var/log/miyu-chat.log"        # Alpine 下的运行日志
SECRET_DIR="/etc/miyu-chat"              # 放“不能给别人看”的设置（邀请码、Tunnel 令牌）
ENV_FILE="$SECRET_DIR/miyu.env"          # 邀请码、人数上限、数据库上限；权限 0600，只有 root 能读
TOKEN_FILE="$SECRET_DIR/tunnel.token"    # Tunnel 令牌；权限 0600，只有 cloudflared 的运行用户能读
CF_BIN="/usr/local/bin/cloudflared"      # 脚本下载的 cloudflared 装在这里
CF_SVC="miyu-cloudflared"                # cloudflared 的服务名（不会和你自己装的 cloudflared 服务冲突）
CF_USER="miyu-cf"                        # cloudflared 也用一个不能登录的普通用户运行
CF_LOG="/var/log/miyu-cloudflared.log"   # Alpine 下 cloudflared 的运行日志
CF_MARK_BIN="$SECRET_DIR/cloudflared-installed-by-script"  # 有这个文件 = cloudflared 是本脚本装的，卸载时才删程序
CF_MARK_USER="$SECRET_DIR/cf-user-created-by-script"       # 有这个文件 = miyu-cf 用户是本脚本建的，卸载时才删

# ---------- 输出带颜色的提示 ----------
# 绿色是正常信息，黄色是提醒，红色是错误
info() { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[提醒]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# 用 curl | sh 方式运行时，标准输入被占用了，所以提问优先从终端 /dev/tty 读；
# 没有终端（比如被别的脚本调用）时才退回到标准输入
ask() {
	if (exec < /dev/tty) 2>/dev/null; then
		printf '%s' "$1" > /dev/tty
		read -r REPLY < /dev/tty || REPLY=""
	else
		printf '%s' "$1"
		read -r REPLY || REPLY=""
		echo
	fi
}

# ---------- 输入时不显示的提问（输令牌、邀请码用） ----------
# 用 stty -echo 临时关掉终端回显，输完马上恢复；中途按 Ctrl+C 也会先恢复回显再退出，
# 不会把你的终端弄成“打字看不见”。结果放在 SECRET 变量里，不会写进任何日志。
ask_secret() {
	SECRET=""
	if (exec < /dev/tty) 2>/dev/null; then
		printf '%s' "$1" > /dev/tty
		_stty="$(stty -g < /dev/tty 2>/dev/null || true)"
		trap 'stty echo < /dev/tty 2>/dev/null; printf "\n" > /dev/tty; exit 130' INT TERM HUP
		stty -echo < /dev/tty 2>/dev/null || true
		IFS= read -r SECRET < /dev/tty || SECRET=""
		if [ -n "$_stty" ]; then
			stty "$_stty" < /dev/tty 2>/dev/null || stty echo < /dev/tty 2>/dev/null || true
		else
			stty echo < /dev/tty 2>/dev/null || true
		fi
		trap - INT TERM HUP
		printf '\n' > /dev/tty
	else
		printf '%s' "$1"
		IFS= read -r SECRET || SECRET=""
		echo
	fi
}
# ---------- 必须用 root 运行 ----------
# 安装服务、写 /usr/local/bin 都需要管理员权限
need_root() {
	[ "$(id -u)" = "0" ] || die "请用 root 用户运行（先执行 sudo -i 或 su - 切到 root，再重新运行脚本）。"
}

# ---------- 识别系统 ----------
# 看 /etc/os-release 判断是 Alpine 还是 Debian/Ubuntu，决定用 apk 还是 apt、OpenRC 还是 systemd
detect_os() {
	[ -f /etc/os-release ] || die "认不出你的系统（没有 /etc/os-release）。本脚本只支持 Debian、Ubuntu、Alpine。"
	# shellcheck source=/dev/null
	. /etc/os-release
	case "$ID" in
		alpine) OS="alpine"; INIT="openrc" ;;
		debian|ubuntu) OS="$ID"; INIT="systemd" ;;
		*)
			case "$ID_LIKE" in
				*debian*) OS="debian"; INIT="systemd" ;;
				*) die "暂不支持你的系统：$PRETTY_NAME。请换成 Debian、Ubuntu 或 Alpine。" ;;
			esac ;;
	esac
	# 有些精简镜像（比如 Docker 容器）没有服务管家，提前说明
	if [ "$INIT" = "systemd" ] && ! command -v systemctl >/dev/null 2>&1; then
		die "这台机器没有 systemd（可能是容器环境），没法设置开机自启。请换一台正常的 VPS。"
	fi
	if [ "$INIT" = "openrc" ] && [ ! -x /sbin/openrc-run ]; then
		info "Alpine 没装 OpenRC，正在安装…"
		apk add --no-cache openrc >/dev/null || die "OpenRC 安装失败，请检查网络后重试。"
	fi
	info "系统：${PRETTY_NAME:-$ID}（服务管家：$INIT）"
}

# ---------- 识别 CPU 架构 ----------
# 程序分 amd64（常见的 Intel/AMD）和 arm64（ARM 机器）两个版本
detect_arch() {
	case "$(uname -m)" in
		x86_64|amd64) ARCH="amd64" ;;
		aarch64|arm64) ARCH="arm64" ;;
		*) die "暂不支持这个 CPU 架构：$(uname -m)。目前只有 amd64 和 arm64 版本。" ;;
	esac
}

# ---------- 安装 curl 等基础工具 ----------
# 下载程序要用 curl；精简系统可能没有，缺了就自动装
install_deps() {
	if [ "$OS" = "alpine" ]; then
		need=""
		command -v curl >/dev/null 2>&1 || need="$need curl"
		[ -f /etc/ssl/certs/ca-certificates.crt ] || need="$need ca-certificates"
		if [ -n "$need" ]; then
			info "正在安装缺少的工具：$need"
			# shellcheck disable=SC2086 # $need 里可能有多个包名，故意不加引号让它拆开
			apk add --no-cache $need >/dev/null || die "安装 $need 失败，请检查网络或软件源后重试。"
		fi
	else
		if ! command -v curl >/dev/null 2>&1 || [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
			info "正在安装 curl 和证书…"
			apt-get update -y >/dev/null 2>&1 || true
			DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates >/dev/null 2>&1 \
				|| die "安装 curl 失败，请先手动执行：apt-get update && apt-get install -y curl ca-certificates"
		fi
	fi
}

# ---------- 判断是母鸡、小鸡还是 NAT 小鸡 ----------
# 母鸡/小鸡：看虚拟化类型；NAT：本机网卡是内网地址，但能查到另一个公网 IP
is_private_ip() {
	case "$1" in
		10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
		100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
		*) return 1 ;;
	esac
}

detect_machine() {
	VIRT="none"
	if command -v systemd-detect-virt >/dev/null 2>&1; then
		VIRT="$(systemd-detect-virt 2>/dev/null || true)"
		[ -n "$VIRT" ] || VIRT="none"
	elif [ -f /proc/user_beancounters ]; then
		VIRT="openvz"
	elif grep -qa 'container=' /proc/1/environ 2>/dev/null || [ -f /.dockerenv ]; then
		VIRT="container"
	elif grep -q '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then
		VIRT="vm"
	fi
	if [ "$VIRT" = "none" ]; then MACHINE="母鸡（独立服务器）"; else MACHINE="小鸡（VPS，虚拟化：$VIRT）"; fi

	# 本机出网用的网卡地址
	LOCAL_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
	[ -n "$LOCAL_IP" ] || LOCAL_IP="$(hostname -i 2>/dev/null | awk '{print $1}')"

	# 从外面看到的公网 IP，三个查询地址轮流试，防止某一个打不开
	PUBLIC_IP=""
	for u in https://api.ipify.org https://ipv4.icanhazip.com https://1.1.1.1/cdn-cgi/trace; do
		r="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null || true)"
		case "$u" in *trace) r="$(printf '%s\n' "$r" | sed -n 's/^ip=//p')" ;; esac
		r="$(printf '%s' "$r" | tr -d ' \r\n')"
		if printf '%s' "$r" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then PUBLIC_IP="$r"; break; fi
	done

	IS_NAT=0
	if [ -n "$LOCAL_IP" ] && is_private_ip "$LOCAL_IP" && [ -n "$PUBLIC_IP" ] && [ "$LOCAL_IP" != "$PUBLIC_IP" ]; then
		IS_NAT=1
		MACHINE="NAT 小鸡（虚拟化：$VIRT）"
	fi
	info "机器类型：$MACHINE"
	info "本机网卡 IP：${LOCAL_IP:-查不到}    公网 IP：${PUBLIC_IP:-查不到}"
	[ -n "$PUBLIC_IP" ] || warn "查不到公网 IP（可能只有 IPv6 或者网络受限），不影响安装，最后需要你自己去商家后台看 IP。"
}

# ---------- 检查端口有没有被占用 ----------
port_in_use() {
	# 直接读内核的 /proc/net/tcp（任何 Linux 都有，不依赖 ss/netstat）：
	# 状态 0A 表示“正在监听”，端口号是十六进制
	hexp="$(printf '%04X' "$1")"
	if cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p=":$hexp" '$4=="0A" && substr($2, length($2)-4)==p {f=1} END{exit !f}'; then
		return 0
	fi
	if command -v ss >/dev/null 2>&1; then
		ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
	elif command -v netstat >/dev/null 2>&1; then
		netstat -ltn 2>/dev/null | awk 'NR>2{print $4}' | grep -Eq "[:.]$1\$"
	else
		return 1
	fi
}

# ---------- 选择接入方式：直连 还是 Cloudflare Tunnel ----------
# NAT 小鸡没有自己的公网 IP 和 80/443 端口，用 Tunnel 最省事，所以检测到 NAT 时默认推荐 Tunnel；
# 但最后还是由你自己选。结果放在 MODE 变量里：direct（直连）或 tunnel。
# 重新运行（改设置）时，默认值是你现在用的模式。
ask_mode() {
	case "$MIYU_MODE" in
		direct|1) MODE="direct"; info "接入方式：直连模式（来自 MIYU_MODE）"; return ;;
		tunnel|2) MODE="tunnel"; info "接入方式：Cloudflare Tunnel 模式（来自 MIYU_MODE）"; return ;;
		'') ;;
		*) die "MIYU_MODE 只能是 direct 或 tunnel。" ;;
	esac
	def=1
	if [ "$IS_NAT" = "1" ]; then def=2; fi
	if [ "$CUR_MODE" = "tunnel" ]; then def=2; elif [ "$CUR_MODE" = "direct" ]; then def=1; fi
	echo
	echo "  请选择别人怎么访问你的聊天服务："
	echo "    1) 直连模式：别人直接访问“公网IP:端口”。需要公网 IP 或商家的端口映射，脚本会帮你放行防火墙端口。"
	echo "    2) Cloudflare Tunnel 模式（NAT 小鸡 / 想藏起真实 IP 推荐）：不用公网 IP、不用开端口、不用端口映射，"
	echo "       需要一个托管在 Cloudflare 的域名，并在 Cloudflare 后台建好 Tunnel、复制它的令牌。"
	if [ "$IS_NAT" = "1" ] && [ -z "$CUR_MODE" ]; then
		warn "检测到你是 NAT 小鸡，推荐选 2（Cloudflare Tunnel 模式）。"
	fi
	tries=0
	MODE=""
	while [ $tries -lt 3 ]; do
		tries=$((tries + 1))
		ask "请输入 1 或 2（直接回车 = $def）："
		c="$(printf '%s' "$REPLY" | tr -d ' ')"
		[ -n "$c" ] || c="$def"
		case "$c" in
			1) MODE="direct"; break ;;
			2) MODE="tunnel"; break ;;
			*) err "只能输入 1 或 2，请重新输入。" ;;
		esac
	done
	[ -n "$MODE" ] || die "连续 3 次没有选对，已退出。想好用哪种方式后重新运行脚本即可。"
	if [ "$MODE" = "tunnel" ]; then info "你选了：Cloudflare Tunnel 模式"; else info "你选了：直连模式"; fi
}

# ---------- 让用户自己选端口 ----------
# 直连模式：NAT 小鸡只能用商家分配的端口，所以必须问；最多问 3 次，免得卡死。
# Tunnel 模式：端口只在本机内部用（cloudflared 从本机连过来），外面访问不到，选个没被占用的就行。
ask_port() {
	if [ "$MODE" = "tunnel" ]; then
		info "Tunnel 模式下这个端口只在本机内部使用，外面访问不到，不用开防火墙，也不用找商家映射。"
	elif [ "$IS_NAT" = "1" ]; then
		warn "你是 NAT 小鸡：请去商家后台的“端口映射/端口转发”页面，看商家分给你的端口。"
		warn "这里要填的是“内部端口”（映射到你这台机器里的那个端口）。"
	fi
	tries=0
	PORT=""
	while [ $tries -lt 3 ]; do
		tries=$((tries + 1))
		# 设置了 MIYU_PORT 就不问了（只用一次，不对就退出）
		if [ -n "$MIYU_PORT" ]; then REPLY="$MIYU_PORT"; tries=3
		else ask "请输入聊天服务要用的端口（1-65535，例如 8080）："; fi
		p="$(printf '%s' "$REPLY" | tr -d ' ')"
		case "$p" in ''|*[!0-9]*) err "端口只能是数字，请重新输入。"; continue ;; esac
		if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then err "端口要在 1 到 65535 之间，请重新输入。"; continue; fi
		if port_in_use "$p"; then err "端口 $p 已经被别的程序占用了，请换一个。"; continue; fi
		PORT="$p"; break
	done
	[ -n "$PORT" ] || die "连续 3 次没有输入可用端口，已退出。确认好端口后重新运行脚本即可。"
	EXT_PORT="$PORT"
	if [ "$MODE" = "direct" ]; then ask_ext_port; fi
}

# ---------- 问外部端口（只有直连模式 + NAT 小鸡才需要） ----------
ask_ext_port() {
	EXT_PORT="$PORT"
	if [ -n "$MIYU_EXT_PORT" ]; then
		EXT_PORT="$MIYU_EXT_PORT"
	elif [ "$IS_NAT" = "1" ]; then
		ask "商家后台里，内部端口 $PORT 对应的“外部端口”是多少？（一样就直接回车）："
		e="$(printf '%s' "$REPLY" | tr -d ' ')"
		case "$e" in
			'') ;;
			*[!0-9]*) warn "输入的不是数字，先按和内部端口相同处理。" ;;
			*) EXT_PORT="$e" ;;
		esac
	fi
	case "$EXT_PORT" in ''|*[!0-9]*) EXT_PORT="$PORT" ;; esac
	if [ "$EXT_PORT" -lt 1 ] || [ "$EXT_PORT" -gt 65535 ]; then
		warn "外部端口 $EXT_PORT 不在 1-65535 之间，先按和内部端口相同处理。"; EXT_PORT="$PORT"
	fi
}

# ---------- 检查 Tunnel 令牌的样子 ----------
# 只做粗略检查：长度 50~4096，只含 base64 字符（字母、数字、+ / = _ -）。
# 全程只在 shell 内部判断，令牌不会出现在任何命令的参数里（别的用户用 ps 也看不到）。
token_looks_ok() {
	[ ${#1} -ge 50 ] && [ ${#1} -le 4096 ] || return 1
	case "$1" in *[!A-Za-z0-9+/=_-]*) return 1 ;; esac
	return 0
}

# 很多人会把 Cloudflare 后台给的整条命令（例如 cloudflared service install eyJ...）一起粘贴进来，
# 这里自动挑出 eyJ 开头的那一段；去掉 Windows 复制带的回车和引号。结果放在 TOKEN 里。
normalize_token() {
	_t="$(printf '%s' "$1" | tr -d '\r"'"'")"
	TOKEN=""
	set -f
	for _w in $_t; do
		case "$_w" in eyJ*) TOKEN="$_w" ;; esac
	done
	set +f
	[ -n "$TOKEN" ] || TOKEN="$(printf '%s' "$_t" | tr -d ' \t')"
	_t=""; _w=""
}

# ---------- 输入 Cloudflare Tunnel 令牌 ----------
# 输入时屏幕上不显示（防止被旁边的人或录屏看到）。令牌在 Cloudflare 后台
# Networking（网络）→ Tunnels → 你的 Tunnel 里，就是安装命令里 eyJ 开头的那一长串。
# 改设置时如果已经有令牌，直接回车就继续用原来的。结果放在 TOKEN 里（空 = 沿用旧令牌）。
ask_token() {
	TOKEN=""
	if [ -n "$MIYU_TUNNEL_TOKEN_FILE" ]; then
		[ -f "$MIYU_TUNNEL_TOKEN_FILE" ] || die "MIYU_TUNNEL_TOKEN_FILE 指定的文件不存在：$MIYU_TUNNEL_TOKEN_FILE"
		IFS= read -r SECRET < "$MIYU_TUNNEL_TOKEN_FILE" || true
		normalize_token "$SECRET"; SECRET=""
		token_looks_ok "$TOKEN" || die "MIYU_TUNNEL_TOKEN_FILE 里的内容不像 Tunnel 令牌（应该是一长串 eyJ 开头的字符）。"
		info "已从 $MIYU_TUNNEL_TOKEN_FILE 读取 Tunnel 令牌（不显示内容）。"
		return
	fi
	echo
	echo "  接下来需要 Cloudflare Tunnel 的令牌（token）："
	echo "    Cloudflare 后台 → Networking（网络）→ Tunnels → Create Tunnel（创建隧道）→ 起个名字 →"
	echo "    在“安装并运行”那一步，复制命令里 eyJ 开头的那一长串（整条命令粘贴进来也行，脚本会自动挑出令牌）。"
	warn "令牌等于这条隧道的密码，千万不要发给别人、不要截图！下面输入时屏幕上不会显示，粘贴后直接回车即可。"
	keep=0
	if [ -s "$TOKEN_FILE" ]; then keep=1; fi
	tries=0
	while [ $tries -lt 3 ]; do
		tries=$((tries + 1))
		if [ $keep = 1 ]; then ask_secret "请粘贴新的 Tunnel 令牌（直接回车 = 继续用原来的令牌）："
		else ask_secret "请粘贴 Tunnel 令牌（输入时不显示）："; fi
		if [ -z "$SECRET" ] && [ $keep = 1 ]; then info "继续使用原来的令牌。"; return; fi
		normalize_token "$SECRET"; SECRET=""
		if token_looks_ok "$TOKEN"; then
			case "$TOKEN" in eyJ*) ;; *) warn "令牌一般是 eyJ 开头的，你的不是。先按你输入的保存，连不上的话请回 Cloudflare 后台重新复制。" ;; esac
			info "已收到令牌（长度 ${#TOKEN} 个字符，内容不显示）。"
			return
		fi
		TOKEN=""
		err "这看起来不像 Tunnel 令牌：应该是 eyJ 开头、几百个字母数字组成的一长串，中间没有空格。请重新复制粘贴。"
	done
	die "连续 3 次没有输入有效的令牌，已退出。去 Cloudflare 后台复制好令牌后重新运行脚本即可。"
}

# ---------- 读环境变量文件里的某一项 ----------
# 只认固定格式（名字=字母数字），不执行文件内容。用法：env_get MIYU_MAX_USERS
env_get() {
	[ -f "$ENV_FILE" ] || return 0
	sed -n "s/^$1=\([A-Za-z0-9_.:,-]*\)\$/\1/p" "$ENV_FILE" | head -n1
}

# 生成一个随机邀请码：从系统随机数里取 8 个字节，变成 XXXX-XXXX-XXXX-XXXX 的样子
gen_invite() {
	head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F' | sed 's/\(....\)/\1-/g; s/-$//'
}

# 邀请码只允许 4~64 个字母、数字、点、下划线、减号，避免写进配置文件后出问题
invite_ok() {
	[ ${#1} -ge 4 ] && [ ${#1} -le 64 ] || return 1
	case "$1" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
	return 0
}

# ---------- 问要不要设置邀请码 ----------
# 设置了邀请码，新用户第一次登录必须输入它，陌生人就没法在你的服务器上注册。
# 结果放在 INVITE 里（空 = 不设置）；INVITE_SHOW=1 表示是这次随机生成的，装完显示一次。
ask_invite() {
	INVITE_SHOW=0
	CUR_INVITE="$(env_get MIYU_INVITE_CODE)"
	if [ -n "${MIYU_INVITE_CODE+x}" ]; then
		case "$MIYU_INVITE_CODE" in
			none|'') INVITE="" ;;
			random) INVITE="$(gen_invite)"; INVITE_SHOW=1 ;;
			*) invite_ok "$MIYU_INVITE_CODE" || die "MIYU_INVITE_CODE 只能是 4~64 个字母、数字、点、下划线、减号。"; INVITE="$MIYU_INVITE_CODE" ;;
		esac
		return
	fi
	echo
	echo "  要不要设置邀请码？设置后，新用户第一次登录要先输入邀请码，陌生人没法注册。"
	echo "    1) 自动生成一个随机邀请码（装完会显示一次，记下来发给朋友）"
	echo "    2) 自己输入邀请码（输入时不显示）"
	echo "    3) 不要邀请码（任何能打开网页的人都能注册）"
	def=3
	if [ -n "$CUR_INVITE" ]; then echo "    4) 保持现在的邀请码不变"; def=4; fi
	tries=0
	while [ $tries -lt 3 ]; do
		tries=$((tries + 1))
		ask "请选择（直接回车 = $def）："
		c="$(printf '%s' "$REPLY" | tr -d ' ')"
		[ -n "$c" ] || c="$def"
		case "$c" in
			1) INVITE="$(gen_invite)"; INVITE_SHOW=1; return ;;
			2)
				ask_secret "请输入邀请码（4~64 个字母、数字、点、下划线、减号，输入时不显示）："
				a="$SECRET"
				ask_secret "请再输入一遍确认："
				if [ "$a" != "$SECRET" ]; then a=""; SECRET=""; err "两次输入不一样，请重新选择。"; continue; fi
				SECRET=""
				if invite_ok "$a"; then INVITE="$a"; a=""; info "邀请码已设置（不显示）。"; return; fi
				a=""; err "邀请码只能是 4~64 个字母、数字、点、下划线、减号，请重新选择。" ;;
			3) INVITE=""; return ;;
			4) if [ -n "$CUR_INVITE" ]; then INVITE="$CUR_INVITE"; return; fi; err "请输入 1、2 或 3。" ;;
			*) err "请输入列表里的数字。" ;;
		esac
	done
	die "连续 3 次没有选好，已退出。重新运行脚本即可。"
}

# ---------- 问一个“上限”数字 ----------
# 用法：ask_limit 环境变量名 提问文字 第一次安装的默认值 最大值 "${变量+x}" "$变量"。结果放在 LIMIT 里（0 = 不限制）。
# 第 5、6 个参数是免交互用的：运行脚本时设置了这个环境变量，就直接用它，不再提问。
# 直接回车：第一次安装 = 用默认值；改设置时 = 保持现在的值。输入 0 = 不限制。
# 程序遇到不是数字的上限会拒绝启动，所以这里只收纯数字，输错了重新问（最多 3 次）。
ask_limit() {
	cur="$(env_get "$1")"
	if [ -f "$CONF" ] && [ -f "$ENV_FILE" ]; then def="${cur:-0}"; else def="$3"; fi
	if [ "$def" = "0" ]; then def_txt="不限制"; else def_txt="$def"; fi
	tries=0
	while [ $tries -lt 3 ]; do
		tries=$((tries + 1))
		if [ -n "$5" ]; then REPLY="$6"; tries=3
		else ask "$2（直接回车 = $def_txt，输入 0 = 不限制）："; fi
		v="$(printf '%s' "$REPLY" | tr -d ' ')"
		[ -n "$v" ] || v="$def"
		case "$v" in
			*[!0-9]*)
				if [ -n "$5" ]; then die "$1=$6 不是数字。只能写数字，0 表示不限制。"; fi
				err "只能输入数字（0 表示不限制），请重新输入。"; continue ;;
		esac
		if [ ${#v} -gt 9 ]; then err "$v 太大了（最大 $4），请重新输入。"; continue; fi
		# 去掉前面多余的 0（例如 050 → 50；shell 会把 0 开头的数当成八进制，所以用 sed 去）
		v="$(printf '%s' "$v" | sed 's/^0*//')"; [ -n "$v" ] || v=0
		if [ "$v" -gt "$4" ]; then err "$v 太大了（最大 $4），请重新输入。"; continue; fi
		LIMIT="$v"
		return
	done
	die "连续 3 次没有输入有效的数字，已退出。重新运行脚本即可。"
}

ask_limits() {
	echo
	echo "  可以给服务器加两个上限（防止被陌生人塞满硬盘），0 表示不限制："
	ask_limit MIYU_MAX_USERS "最多允许多少个用户（身份）？例如 50" 0 10000000 "${MIYU_MAX_USERS+x}" "$MIYU_MAX_USERS"
	MAX_USERS="$LIMIT"
	ask_limit MIYU_MAX_DB_MB "聊天数据库最多占多少 MB？小鸡硬盘小建议 2000" 2000 10000000 "${MIYU_MAX_DB_MB+x}" "$MIYU_MAX_DB_MB"
	MAX_DB_MB="$LIMIT"
}

# ---------- 整理网址列表 ----------
# 把用户输入（可能带 http://、https://、路径、空格、大写）整理成“域名[:端口]”用逗号连起来，结果放在 HOSTS 里。
# 只允许字母、数字、点、减号、冒号，有别的字符就返回 1（让用户重新输入）。
clean_hosts() {
	HOSTS=""
	set -f
	for _h in $(printf '%s' "$1" | tr ',' ' '); do
		_h="$(printf '%s' "$_h" | tr '[:upper:]' '[:lower:]' | sed 's#^[a-z]*://##; s#/.*$##')"
		[ -n "$_h" ] || continue
		case "$_h" in *[!a-z0-9.:-]*|.*|-*) set +f; HOSTS=""; return 1 ;; esac
		case ",$HOSTS," in *",$_h,"*) ;; *) HOSTS="${HOSTS:+$HOSTS,}$_h" ;; esac
	done
	set +f
	[ ${#HOSTS} -le 1000 ] || { HOSTS=""; return 1; }
	return 0
}

# 从网址列表里挑出“域名”（去掉纯 IP[:端口] 那几项），结果放在 DOMAINS 里
pick_domains() {
	DOMAINS=""; IPS=""
	set -f
	for _h in $(printf '%s' "$1" | tr ',' ' '); do
		case "$_h" in
			*[!0-9.:]*) DOMAINS="${DOMAINS:+$DOMAINS,}$_h" ;;
			*) IPS="${IPS:+$IPS,}$_h" ;;
		esac
	done
	set +f
}

# ---------- 问聊天域名（写进 MIYU_HOST） ----------
# 新版程序登录时会核对浏览器地址栏里的网址，只认 MIYU_HOST 里列出的，防止别的网站转发登录。
#   Tunnel 模式：填你在 Cloudflare 给这个 Tunnel 配的域名，例如 chat.example.com
#   直连模式：有域名（比如接了 Cloudflare）就填域名；脚本会自动再加上“公网IP:外部端口”，方便直接用 IP 打开
# 什么都不填：程序就以浏览器访问时的网址为准，也能正常用，只是少一层防护。
# 结果放在 HOST_LIST 里（逗号分隔，可以为空）。
ask_hosts() {
	pick_domains "$(env_get MIYU_HOST)"
	cur_dom="$DOMAINS"; cur_ips="$IPS"
	if [ -n "${MIYU_HOST+x}" ]; then
		clean_hosts "$MIYU_HOST" || die "MIYU_HOST 格式不对：只能是 域名[:端口]，多个用逗号分隔，例如 chat.example.com"
		pick_domains "$HOSTS"; dom="$DOMAINS"
	else
		echo
		echo "  设置聊天网址（登录时会核对浏览器地址栏里的网址，填错了会登录失败、提示“密钥校验失败”）："
		if [ "$MODE" = "tunnel" ]; then
			echo "    请填你在 Cloudflare 给这个 Tunnel 配的域名（只填域名，不要 https://），例如 chat.example.com"
		else
			echo "    有域名（例如接了 Cloudflare）就填域名，例如 chat.example.com；只用 IP 访问就直接回车。"
			echo "    脚本会自动再加上“公网IP:外部端口”，用 http://IP:端口 直接打开也能登录。"
		fi
		echo "    多个网址用英文逗号分隔。${cur_dom:+现在是：$cur_dom（直接回车 = 不改，输入 - 清空）}"
		tries=0
		while :; do
			tries=$((tries + 1))
			[ $tries -le 3 ] || die "连续 3 次网址格式不对，已退出。重新运行脚本即可。"
			ask "请输入聊天域名："
			r="$(printf '%s' "$REPLY" | tr -d ' ')"
			if [ -z "$r" ]; then r="$cur_dom"; elif [ "$r" = "-" ]; then r=""; fi
			if clean_hosts "$r"; then pick_domains "$HOSTS"; dom="$DOMAINS"; break; fi
			err "格式不对：只能是 域名[:端口]（字母、数字、点、减号），例如 chat.example.com。请重新输入。"
		done
	fi
	ipp=""
	if [ "$MODE" = "direct" ]; then
		if [ -n "$PUBLIC_IP" ]; then
			# 浏览器访问 80 端口时地址栏里不显示端口，所以 80 端口只写 IP
			if [ "$EXT_PORT" = "80" ]; then ipp="$PUBLIC_IP"; else ipp="$PUBLIC_IP:$EXT_PORT"; fi
		else
			ipp="$cur_ips"
		fi
	fi
	clean_hosts "$dom,$ipp" || HOSTS=""
	HOST_LIST="$HOSTS"
	if [ -z "$HOST_LIST" ]; then
		warn "没有设置聊天网址：程序会以浏览器访问时的网址为准，能正常登录，只是少一层防护。以后可以用 sh install.sh config 补上。"
	elif [ "$MODE" = "tunnel" ] && [ -z "$dom" ]; then
		warn "Tunnel 模式建议填上你的聊天域名。"
	fi
}

# ---------- 保存登录网址、邀请码和上限 ----------
# 写到 /etc/miyu-chat/miyu.env，权限 0600（只有 root 能读）。
# 服务管家（systemd / OpenRC）以 root 身份读这个文件，再把里面的设置交给聊天程序；
# 旧版程序不认识这些设置，会直接忽略，不影响运行。
write_env() {
	mkdir -p "$SECRET_DIR"
	chmod 711 "$SECRET_DIR"
	(
		umask 077
		{
			echo "# miyu-chat 的设置（由安装脚本生成，改设置请运行 sh install.sh config）"
			echo "# 登录时只认这些网址（逗号分隔，空 = 以浏览器访问的网址为准）"
			echo "MIYU_HOST=$HOST_LIST"
			echo "# 邀请码（空 = 不需要邀请码）"
			echo "MIYU_INVITE_CODE=$INVITE"
			echo "# 最多多少个用户、数据库最多多少 MB（0 = 不限制）"
			echo "MIYU_MAX_USERS=${MAX_USERS:-0}"
			echo "MIYU_MAX_DB_MB=${MAX_DB_MB:-0}"
		} > "$ENV_FILE.new"
	)
	chown root:root "$ENV_FILE.new" 2>/dev/null || true
	chmod 600 "$ENV_FILE.new"
	mv -f "$ENV_FILE.new" "$ENV_FILE"
}

# ---------- 获取最新版本号 ----------
# 先问 GitHub 接口；被限流（每小时 60 次）时，改看 releases/latest 网页跳转到哪个版本；
# 还不行就读 jsDelivr 上 dist 分支里的 VERSION 文件
get_version() {
	VER="$(curl -fsS --max-time 10 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
		| sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1 || true)"
	if [ -z "$VER" ]; then
		VER="$(curl -fsSI --max-time 10 "https://github.com/$REPO/releases/latest" 2>/dev/null \
			| tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/\(.*\)$#\1#p' | head -n1 || true)"
	fi
	if [ -z "$VER" ]; then
		VER="$(curl -fsS --max-time 10 "https://cdn.jsdelivr.net/gh/$REPO@dist/VERSION" 2>/dev/null | tr -d ' \r\n' || true)"
	fi
	# 只接受 v1.2.3 这种样子，防止奇怪的内容拼进下载地址
	case "$VER" in v[0-9]*) ;; *) VER="" ;; esac
	case "$VER" in *[!0-9A-Za-z.+-]*) VER="" ;; esac
}

# ---------- 校验下载的文件 ----------
# 对照 SHA256SUMS 里记录的校验值（发布时自动生成），一个字节不对都不会安装。
# 用法：check_sum 程序文件 SHA256SUMS文件
check_sum() {
	command -v sha256sum >/dev/null 2>&1 || die "系统缺少 sha256sum 命令，无法校验程序。Debian/Ubuntu 请装 coreutils，Alpine 请装 busybox。"
	want="$(awk -v f="$file" '$2==f || $2==("*" f) {print $1; exit}' "$2" 2>/dev/null)"
	got="$(sha256sum "$1" | awk '{print $1}')"
	[ -n "$want" ] && [ "$want" = "$got" ]
}

# 从一个下载地址（目录）拿程序和 SHA256SUMS，并校验；成功返回 0
fetch_from() {
	curl -fL --retry 2 --connect-timeout 15 --max-time 180 -o "$tmpd/bin" "$1/$file" 2>/dev/null || return 1
	curl -fL --retry 2 --connect-timeout 15 --max-time 30 -o "$tmpd/SHA256SUMS" "$1/SHA256SUMS" 2>/dev/null \
		|| { warn "没下载到校验文件 SHA256SUMS（$1）。"; return 1; }
	if ! check_sum "$tmpd/bin" "$tmpd/SHA256SUMS"; then
		warn "校验没通过：下载的程序和官方记录的不一致（可能下载损坏、镜像缓存还没更新或被篡改），这个地址不用了。"
		return 1
	fi
	info "校验通过（SHA256：$got）"
}

# ---------- 下载程序 ----------
# 优先用你手动放的文件（MIYU_BIN=路径），其次 GitHub Release，最后 jsDelivr 备用地址。
# 不管从哪下载，都先核对 SHA256 校验值，通过了才会运行它。
download_bin() {
	tmpd="$(mktemp -d)"
	file="$APP-linux-$ARCH"
	ok=0
	if [ -n "$MIYU_BIN" ]; then
		[ -f "$MIYU_BIN" ] || { rm -rf "$tmpd"; die "MIYU_BIN 指定的文件不存在：$MIYU_BIN"; }
		cp "$MIYU_BIN" "$tmpd/bin"
		if [ -n "$MIYU_SHA256" ]; then
			printf '%s  %s\n' "$MIYU_SHA256" "$file" > "$tmpd/SHA256SUMS"
			check_sum "$tmpd/bin" "$tmpd/SHA256SUMS" || { rm -rf "$tmpd"; die "MIYU_BIN 文件的校验值和 MIYU_SHA256 不一致，请重新下载。"; }
		else
			warn "使用本地文件且没给 MIYU_SHA256，跳过校验，请自己确认文件来源可靠。"
		fi
		ok=1; info "使用本地程序文件：$MIYU_BIN"
	elif [ -n "$MIYU_DOWNLOAD_BASE" ]; then
		info "从指定地址下载：$MIYU_DOWNLOAD_BASE"
		fetch_from "${MIYU_DOWNLOAD_BASE%/}" && ok=1
	else
		get_version
		if [ -n "$VER" ]; then
			info "最新版本：$VER，正在从 GitHub 下载…"
			fetch_from "https://github.com/$REPO/releases/download/$VER" && ok=1
		fi
		if [ $ok = 0 ]; then
			warn "GitHub 下载失败，改用 jsDelivr 备用地址…"
			fetch_from "https://cdn.jsdelivr.net/gh/$REPO@dist" && ok=1
		fi
	fi
	[ $ok = 1 ] || { rm -rf "$tmpd"; die "程序下载失败。请检查这台机器能不能访问 github.com 或 cdn.jsdelivr.net，稍后再试。"; }

	# 检查下载的确实是能运行的程序，而不是一个报错网页
	if [ "$(head -c 4 "$tmpd/bin" | od -An -c | tr -d ' ')" != "177ELF" ]; then
		rm -rf "$tmpd"; die "下载到的文件不是程序（可能被网络劫持或地址失效），请稍后重试。"
	fi
	chmod 755 "$tmpd/bin"
	"$tmpd/bin" -version >/dev/null 2>&1 || { rm -rf "$tmpd"; die "程序无法在这台机器上运行，可能是 CPU 架构不匹配。"; }
	mv -f "$tmpd/bin" "$BIN"
	rm -rf "$tmpd"
	info "程序已安装到 $BIN（$("$BIN" -version 2>&1)）"
}

# ---------- 创建运行用户和数据目录 ----------
# 程序不用 root 跑，而是用一个专门的、不能登录的 miyu 用户，就算程序有漏洞也碰不到系统其它文件。
# 数据目录权限设成 700：只有 miyu 用户自己能进。
setup_user() {
	if ! id "$RUN_USER" >/dev/null 2>&1; then
		if [ "$OS" = "alpine" ]; then
			addgroup -S "$RUN_USER" 2>/dev/null || true
			adduser -S -D -H -h "$DATA_DIR" -s /sbin/nologin -G "$RUN_USER" "$RUN_USER"
		else
			useradd --system --no-create-home --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$RUN_USER"
		fi
	fi
	mkdir -p "$DATA_DIR"
	chown "$RUN_USER:$RUN_USER" "$DATA_DIR"
	chmod 700 "$DATA_DIR"
}

# ---------- 查 cloudflared 最新版本和官方校验值 ----------
# Cloudflare 把每个文件的 SHA256 校验值写在 GitHub 发布说明里（形如 cloudflared-linux-amd64: 一串64位字符）。
# 先问 GitHub 接口；被限流时，改看 releases/latest 网页跳转到哪个版本，再从发布页网页里找校验值。
# 结果：CF_VER（版本号，例如 2026.9.3）、CF_SUM（这台机器对应文件的校验值）
cf_latest() {
	cf_file="cloudflared-linux-$ARCH"
	CF_VER=""; CF_SUM=""
	rel="$(curl -fsS --max-time 15 "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null || true)"
	CF_VER="$(printf '%s\n' "$rel" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
	CF_SUM="$(printf '%s\n' "$rel" | grep -o "$cf_file: [0-9a-f]\{64\}" | head -n1 | awk '{print $2}')"
	rel=""
	if [ -z "$CF_VER" ]; then
		CF_VER="$(curl -fsSI --max-time 15 "https://github.com/cloudflare/cloudflared/releases/latest" 2>/dev/null \
			| tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/\(.*\)$#\1#p' | head -n1 || true)"
	fi
	# 版本号只接受数字和点（例如 2026.9.3），防止奇怪的内容拼进下载地址
	case "$CF_VER" in ''|*[!0-9.]*) CF_VER="" ;; esac
	if [ -n "$CF_VER" ] && [ -z "$CF_SUM" ]; then
		CF_SUM="$(curl -fsSL --max-time 30 "https://github.com/cloudflare/cloudflared/releases/tag/$CF_VER" 2>/dev/null \
			| grep -o "$cf_file: [0-9a-f]\{64\}" | head -n1 | awk '{print $2}' || true)"
	fi
}

# ---------- 下载并安装 cloudflared ----------
# 只从 Cloudflare 在 GitHub 的官方发布页下载，核对官方校验值，一个字节不对都不装。
download_cloudflared() {
	cf_latest
	[ -n "$CF_VER" ] || die "查不到 cloudflared 的最新版本（连不上 github.com）。可以自己把 cloudflared 放到 $CF_BIN 后重新运行脚本。"
	[ -n "$CF_SUM" ] || die "没拿到 cloudflared $CF_VER 的官方校验值，为了安全不安装。请稍后重试。"
	info "正在下载 cloudflared $CF_VER（Cloudflare 官方发布）…"
	cfd="$(mktemp -d)"
	if ! curl -fL --retry 2 --connect-timeout 15 --max-time 300 -o "$cfd/cloudflared" \
		"https://github.com/cloudflare/cloudflared/releases/download/$CF_VER/$cf_file" 2>/dev/null; then
		rm -rf "$cfd"; die "cloudflared 下载失败，请检查这台机器能不能访问 github.com，稍后重试。"
	fi
	got="$(sha256sum "$cfd/cloudflared" | awk '{print $1}')"
	if [ "$got" != "$CF_SUM" ]; then
		rm -rf "$cfd"; die "cloudflared 校验没通过（下载损坏或被篡改），已停止安装。请稍后重试。"
	fi
	info "cloudflared 校验通过（SHA256：$got）"
	if [ "$(head -c 4 "$cfd/cloudflared" | od -An -c | tr -d ' ')" != "177ELF" ]; then
		rm -rf "$cfd"; die "下载到的 cloudflared 不是程序文件，请稍后重试。"
	fi
	chmod 755 "$cfd/cloudflared"
	"$cfd/cloudflared" --version >/dev/null 2>&1 || { rm -rf "$cfd"; die "cloudflared 无法在这台机器上运行，可能是 CPU 架构不匹配。"; }
	mv -f "$cfd/cloudflared" "$CF_BIN"
	rm -rf "$cfd"
	mkdir -p "$SECRET_DIR"; chmod 711 "$SECRET_DIR"
	: > "$CF_MARK_BIN"
	info "cloudflared 已安装到 $CF_BIN（$("$CF_BIN" --version 2>&1 | head -n1)）"
}

# ---------- 准备 cloudflared 程序 ----------
# 机器上本来就有 cloudflared（不是本脚本装的）：直接用它，卸载时也不删它；
# 但它必须支持 --token-file（从文件读令牌，2025 年以后的版本都支持），否则令牌只能写在命令行里，不安全。
# 没有就下载官方版本装到 /usr/local/bin/cloudflared，并记一个“是我装的”标记。
# 结果：CF_EXE = 服务要用的 cloudflared 路径
setup_cloudflared_bin() {
	CF_EXE=""
	if [ -x "$CF_BIN" ]; then CF_EXE="$CF_BIN"
	elif command -v cloudflared >/dev/null 2>&1; then CF_EXE="$(command -v cloudflared)"; fi
	if [ -z "$CF_EXE" ]; then
		download_cloudflared; CF_EXE="$CF_BIN"
	elif [ -f "$CF_MARK_BIN" ] && [ "$CF_EXE" = "$CF_BIN" ]; then
		info "cloudflared 已经装好了（$("$CF_EXE" --version 2>&1 | head -n1)）。"
	else
		info "检测到这台机器上已经有 cloudflared（$CF_EXE），直接用它；卸载时不会删它。"
	fi
	if ! "$CF_EXE" tunnel run --help 2>&1 | grep -q -- '--token-file'; then
		die "$CF_EXE 版本太旧，不支持 --token-file（从文件读令牌）。请先把它升级到新版，或者删掉它让脚本自动安装新版，然后重新运行。"
	fi
}

# ---------- 创建 cloudflared 的运行用户 ----------
# 和聊天程序一样，cloudflared 也不用 root 跑，用一个不能登录的 miyu-cf 用户。
setup_cf_user() {
	if id "$CF_USER" >/dev/null 2>&1; then return; fi
	if [ "$OS" = "alpine" ]; then
		addgroup -S "$CF_USER" 2>/dev/null || true
		adduser -S -D -H -h /var/empty -s /sbin/nologin -G "$CF_USER" "$CF_USER"
	else
		useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --user-group "$CF_USER"
	fi
	mkdir -p "$SECRET_DIR"; chmod 711 "$SECRET_DIR"
	: > "$CF_MARK_USER"
}

# ---------- 保存 Tunnel 令牌 ----------
# 存到 /etc/miyu-chat/tunnel.token，权限 0600，主人是 miyu-cf（只有它和 root 能读）。
# cloudflared 用 --token-file 读这个文件，所以令牌不会出现在命令行参数里，别的用户用 ps 也看不到。
# printf 是 shell 内置命令，写文件时令牌同样不会出现在任何进程参数里。
write_token() {
	[ -n "$TOKEN" ] || return 0
	mkdir -p "$SECRET_DIR"; chmod 711 "$SECRET_DIR"
	( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE.new" )
	chown "$CF_USER:$CF_USER" "$TOKEN_FILE.new"
	chmod 600 "$TOKEN_FILE.new"
	mv -f "$TOKEN_FILE.new" "$TOKEN_FILE"
	TOKEN=""
	info "Tunnel 令牌已保存到 $TOKEN_FILE（权限 0600）。"
}

# ---------- 注册 cloudflared 服务（开机自启、断了自动重启） ----------
# 服务名叫 miyu-cloudflared，运行：cloudflared tunnel --no-autoupdate run --token-file 令牌文件
#   --no-autoupdate：不让 cloudflared 自己偷偷升级（升级用 sh install.sh update，会核对校验值）
#   Tunnel 的转发规则（哪个域名转到 http://127.0.0.1:端口）在 Cloudflare 后台配置，这里只负责连上。
setup_cf_service() {
	if [ "$INIT" = "systemd" ]; then
		cat > /etc/systemd/system/$CF_SVC.service <<UNIT
[Unit]
Description=Cloudflare Tunnel（给 miyu-chat 用）
After=network-online.target $APP.service
Wants=network-online.target

[Service]
User=$CF_USER
Group=$CF_USER
ExecStart=$CF_EXE tunnel --no-autoupdate run --token-file $TOKEN_FILE
Restart=on-failure
RestartSec=5
# 下面几行是安全加固：cloudflared 不能提权、看不到家目录、不能改系统文件
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
		systemctl daemon-reload
		systemctl enable $CF_SVC >/dev/null 2>&1
		systemctl restart $CF_SVC
	else
		touch "$CF_LOG"; chown "$CF_USER:$CF_USER" "$CF_LOG"; chmod 640 "$CF_LOG"
		cat > /etc/init.d/$CF_SVC <<RC
#!/sbin/openrc-run
# Cloudflare Tunnel（给 miyu-chat 用，OpenRC 服务）
name="$CF_SVC"
command="$CF_EXE"
command_args="tunnel --no-autoupdate run --token-file $TOKEN_FILE"
command_user="$CF_USER:$CF_USER"
command_background=true
pidfile="/run/$CF_SVC.pid"
output_log="$CF_LOG"
error_log="$CF_LOG"
# 断了自动拉起（不限次数）
supervisor=supervise-daemon
respawn_delay=5
respawn_max=0

depend() {
	need net
	after $APP
}
RC
		chmod 755 /etc/init.d/$CF_SVC
		rc-update add $CF_SVC default >/dev/null 2>&1
		rc-service $CF_SVC restart >/dev/null 2>&1 || rc-service $CF_SVC start
	fi
}

# ---------- 看 Tunnel 连上 Cloudflare 没有 ----------
# cloudflared 会在本机 127.0.0.1 的 20241~20245 端口开一个状态页，/ready 返回 200 就是连上了。
# 只是检查，连不上不算安装失败（多半是令牌复制错了），会告诉你去哪看日志。
cf_ready() {
	for cp in 20241 20242 20243 20244 20245; do
		if curl -fsS --max-time 2 "http://127.0.0.1:$cp/ready" >/dev/null 2>&1; then return 0; fi
	done
	return 1
}

cf_log_hint() {
	if [ "$INIT" = "systemd" ]; then echo "    journalctl -u $CF_SVC -n 50 --no-pager"; else echo "    tail -n 50 $CF_LOG"; fi
}

cf_wait_ready() {
	info "等待 Tunnel 连上 Cloudflare（最多 20 秒）…"
	i=0
	while [ $i -lt 20 ]; do
		if cf_ready; then CF_OK=1; info "Tunnel 已经连上 Cloudflare。"; return 0; fi
		i=$((i + 1)); sleep 1
	done
	CF_OK=0
	warn "Tunnel 暂时还没连上 Cloudflare。最常见的原因是令牌复制错了或不完整，也可能是这台机器连不上 Cloudflare。"
	warn "cloudflared 会自动一直重试。看日志找原因："
	cf_log_hint
	warn "换令牌：重新运行 sh install.sh config，选 Tunnel 模式后粘贴新令牌。"
}

# ---------- 删除 cloudflared 服务和令牌 ----------
# 只删本脚本装的东西：服务、令牌文件、日志；cloudflared 程序和 miyu-cf 用户只有“是脚本装的”才删。
# 你自己原来装的 cloudflared 程序和它自己的服务一律不碰。
remove_cloudflared() {
	had_cf=0
	if [ -f /etc/systemd/system/$CF_SVC.service ] || [ -f /etc/init.d/$CF_SVC ] || [ -f "$TOKEN_FILE" ]; then had_cf=1; fi
	if [ "$INIT" = "systemd" ]; then
		if [ -f /etc/systemd/system/$CF_SVC.service ]; then
			systemctl disable --now $CF_SVC >/dev/null 2>&1 || true
			rm -f /etc/systemd/system/$CF_SVC.service
			systemctl daemon-reload
		fi
	else
		if [ -f /etc/init.d/$CF_SVC ]; then
			rc-service $CF_SVC stop >/dev/null 2>&1 || true
			rc-update del $CF_SVC default >/dev/null 2>&1 || true
			rm -f /etc/init.d/$CF_SVC
		fi
		rm -f "$CF_LOG"
	fi
	rm -f "$TOKEN_FILE" "$TOKEN_FILE.new"
	if [ -f "$CF_MARK_BIN" ]; then
		rm -f "$CF_BIN" "$CF_MARK_BIN"; info "已删除本脚本安装的 cloudflared 程序。"
	elif [ $had_cf = 1 ] && { [ -x "$CF_BIN" ] || command -v cloudflared >/dev/null 2>&1; }; then
		info "cloudflared 程序不是本脚本装的，保留不动。"
	fi
	if [ -f "$CF_MARK_USER" ]; then
		if id "$CF_USER" >/dev/null 2>&1; then
			if [ "$OS" = "alpine" ]; then deluser "$CF_USER" 2>/dev/null || true; delgroup "$CF_USER" 2>/dev/null || true
			else userdel "$CF_USER" 2>/dev/null || true; groupdel "$CF_USER" 2>/dev/null || true; fi
		fi
		rm -f "$CF_MARK_USER"
	fi
}

# ---------- 更新 cloudflared（只更新本脚本装的那个） ----------
update_cloudflared() {
	cf_latest
	if [ -n "$CF_VER" ] && "$CF_BIN" --version 2>&1 | grep -q "version $CF_VER "; then
		info "cloudflared 已经是最新版 $CF_VER，不用更新。"
		return
	fi
	download_cloudflared
}
# ---------- 注册成系统服务（开机自启、崩溃自动重启） ----------
# 直连模式听 0.0.0.0:端口（所有网卡，外面能访问）；Tunnel 模式只听 127.0.0.1:端口（只有本机能访问）。
# 邀请码、上限这些设置从 /etc/miyu-chat/miyu.env 读（服务管家以 root 身份读，再交给程序），
# 所以不会出现在命令行参数里。
setup_service() {
	if [ "$MODE" = "tunnel" ]; then LISTEN="127.0.0.1:$PORT"; else LISTEN="0.0.0.0:$PORT"; fi
	if [ "$INIT" = "systemd" ]; then
		cat > /etc/systemd/system/$APP.service <<UNIT
[Unit]
Description=miyu-chat 密语加密聊天
After=network-online.target
Wants=network-online.target

[Service]
User=$RUN_USER
Group=$RUN_USER
# 登录网址、邀请码、人数上限、数据库上限（文件不存在也没关系）
EnvironmentFile=-$ENV_FILE
ExecStart=$BIN -listen $LISTEN -db $DATA_DIR/miyu.db
Restart=always
RestartSec=3
# 下面几行是安全加固：程序只能写自己的数据目录
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA_DIR
MemoryMax=128M

[Install]
WantedBy=multi-user.target
UNIT
		systemctl daemon-reload
		systemctl enable $APP >/dev/null 2>&1
		systemctl restart $APP
	else
		mkdir -p /etc/init.d
		touch "$LOG_FILE"; chown "$RUN_USER:$RUN_USER" "$LOG_FILE"
		cat > /etc/init.d/$APP <<RC
#!/sbin/openrc-run
# miyu-chat 密语加密聊天（OpenRC 服务）
name="$APP"
command="$BIN"
command_args="-listen $LISTEN -db $DATA_DIR/miyu.db"
command_user="$RUN_USER:$RUN_USER"
command_background=true
pidfile="/run/$APP.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"
# 崩溃后自动拉起
supervisor=supervise-daemon
respawn_delay=3

depend() {
	need net
}

# 启动前读登录网址、邀请码、上限设置（$ENV_FILE）。只认这四个名字，不执行文件内容。
start_pre() {
	if [ -f "$ENV_FILE" ]; then
		while IFS='=' read -r k v; do
			case "\$k" in
				MIYU_HOST|MIYU_INVITE_CODE|MIYU_MAX_USERS|MIYU_MAX_DB_MB) export "\$k=\$v" ;;
			esac
		done < "$ENV_FILE"
	fi
	return 0
}
RC
		chmod 755 /etc/init.d/$APP
		rc-update add $APP default >/dev/null 2>&1
		rc-service $APP restart >/dev/null 2>&1 || rc-service $APP start
	fi
}

# ---------- 防火墙放行（只有直连模式需要） ----------
# 只给自己的端口加规则，不会关掉或卸载你的防火墙。
# 只有“本来没有、是脚本新加的”规则才记到配置文件里，卸载时也只删这一条，不碰你原有的规则。
# Tunnel 模式是 cloudflared 主动往外连，不需要开任何入站端口。
open_firewall() {
	FW=""
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
		if ufw status 2>/dev/null | grep -Eq "^$PORT/tcp[[:space:]]+ALLOW"; then
			info "ufw 里本来就放行了 $PORT 端口，不重复添加（卸载时也不会删它）。"
		elif ufw allow "$PORT"/tcp comment "$APP" >/dev/null 2>&1; then
			FW="ufw"; info "已在 ufw 防火墙放行 $PORT 端口。"
		else
			warn "ufw 放行失败，请自己执行：ufw allow $PORT/tcp"
		fi
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		if firewall-cmd --query-port="$PORT"/tcp >/dev/null 2>&1; then
			info "firewalld 里本来就放行了 $PORT 端口，不重复添加（卸载时也不会删它）。"
		elif firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
			FW="firewalld"; info "已在 firewalld 防火墙放行 $PORT 端口。"
		else
			warn "firewalld 放行失败，请自己执行：firewall-cmd --permanent --add-port=$PORT/tcp && firewall-cmd --reload"
		fi
	elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "policy drop"; then
		warn "检测到 nftables 默认拦截入站。为了不弄乱你的规则，脚本不自动改，请自己复制执行（表名/链名按你的实际配置改）："
		echo "    nft add rule inet filter input tcp dport $PORT accept"
	elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -q -- "-P INPUT DROP"; then
		warn "检测到 iptables 默认拦截入站。请自己复制执行放行命令："
		echo "    iptables -I INPUT -p tcp --dport $PORT -j ACCEPT"
	fi
}

# ---------- 删掉安装时脚本自己加的那条防火墙规则 ----------
close_firewall() {
	if [ -n "$PORT" ] && [ "$FW" = "ufw" ]; then ufw delete allow "$PORT"/tcp >/dev/null 2>&1 || true; fi
	if [ -n "$PORT" ] && [ "$FW" = "firewalld" ]; then
		if firewall-cmd --permanent --remove-port="$PORT"/tcp >/dev/null 2>&1; then firewall-cmd --reload >/dev/null 2>&1 || true; fi
	fi
	FW=""
}

# ---------- 保存 / 读取安装时记下的配置 ----------
# 配置文件 /etc/miyu-chat.conf 里只有模式、端口和防火墙记录，没有任何密码类的东西。
# 读的时候只按固定格式把数字和名字读出来，不直接执行配置文件，就算文件被改坏也不会乱执行命令。
save_conf() {
	printf 'MODE=%s\nPORT=%s\nEXT_PORT=%s\nFW=%s\n' "$MODE" "$PORT" "$EXT_PORT" "$FW" > "$CONF"
}

load_conf() {
	PORT="$(sed -n 's/^PORT=\([0-9]\{1,5\}\)$/\1/p' "$CONF" | head -n1)"
	EXT_PORT="$(sed -n 's/^EXT_PORT=\([0-9]\{1,5\}\)$/\1/p' "$CONF" | head -n1)"
	FW="$(sed -n 's/^FW=\([a-z]*\)$/\1/p' "$CONF" | head -n1)"
	MODE="$(sed -n 's/^MODE=\([a-z]*\)$/\1/p' "$CONF" | head -n1)"
	[ -n "$EXT_PORT" ] || EXT_PORT="$PORT"
	# 1.0 版脚本装的没有记录模式，那时只有直连模式
	[ "$MODE" = "tunnel" ] || MODE="direct"
}

# 改设置、更新、看状态都需要端口；读不到说明配置文件坏了
need_port() {
	[ -n "$PORT" ] || die "配置文件 $CONF 里读不到端口，可能被改坏了。请先卸载（sh install.sh uninstall）再重新安装。"
}

# 把上限显示成中文：空 = 不限制
show_limit() {
	if [ -n "$1" ] && [ "$1" != "0" ]; then printf '%s%s' "$1" "$2"; else printf '不限制'; fi
}

# ---------- 检查服务是否真的跑起来了 ----------
# 最多等 10 秒，访问本机的 /healthz 地址，能返回 ok 才算启动成功；失败就告诉你去哪看日志
health_check() {
	i=0
	while [ $i -lt 10 ]; do
		if [ "$INIT" = "systemd" ] && ! systemctl is-active --quiet $APP; then i=$((i + 1)); sleep 1; continue; fi
		if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then return 0; fi
		i=$((i + 1)); sleep 1
	done
	err "服务没有正常启动。看日志找原因："
	if [ "$INIT" = "systemd" ]; then echo "    journalctl -u $APP -n 50 --no-pager"; else echo "    tail -n 50 $LOG_FILE"; fi
	exit 1
}

# 程序里要是找不到 MIYU_INVITE_CODE 这几个字，说明是还不支持邀请码/上限的旧版程序
bin_supports_limits() {
	grep -q MIYU_INVITE_CODE "$BIN" 2>/dev/null
}

# ---------- 装完/改完后显示的说明 ----------
print_summary() {
	echo
	echo "  ------------------------------------------------------------"
	if [ "$MODE" = "tunnel" ]; then
		echo "  模式：Cloudflare Tunnel（聊天程序只听本机 127.0.0.1:$PORT，外面不能直接访问）"
		pick_domains "$HOST_LIST"
		if [ -n "$DOMAINS" ]; then echo "  配好 Tunnel 后用浏览器打开：https://${DOMAINS%%,*}"; fi
		echo
		echo "  Tunnel 转发目标请设为 http://127.0.0.1:$PORT"
		echo
		echo "  在 Cloudflare 后台：Networking（网络）→ Tunnels → 选中你的 Tunnel → Routes（路由）→"
		echo "  Add route（添加路由）→ Published application（发布应用）→ 填你的域名（例如 chat.example.com），"
		echo "  Service URL（服务地址）填上面这个 http://127.0.0.1:$PORT。Tunnel 由别人配置的话，把上面那行发给他就行。"
		echo "  不需要开防火墙端口，也不需要端口映射；HTTPS 由 Cloudflare 自动提供。"
		if [ "$CF_OK" = "1" ]; then echo "  Tunnel 状态：已连上 Cloudflare"
		else echo "  Tunnel 状态：还没连上（cloudflared 会一直自动重试），看日志："; cf_log_hint; fi
		echo "  Tunnel 令牌保存在 $TOKEN_FILE（权限 0600），不要发给任何人。"
	else
		echo "  模式：直连（聊天程序听 0.0.0.0:$PORT）"
		echo "  本机测试地址：http://${PUBLIC_IP:-你的公网IP}:$EXT_PORT"
		echo "  接 Cloudflare 时需要的信息："
		echo "    公网 IP：${PUBLIC_IP:-请到商家后台查看}"
		echo "    外部端口：$EXT_PORT"
		if [ "$IS_NAT" = "1" ]; then
			echo "  NAT 提醒：请确认商家后台已把外部端口 $EXT_PORT 映射到内部端口 $PORT，"
			echo "           并且安全组/防火墙放行了这个端口。"
		fi
		echo "  建议通过 Cloudflare 加上 HTTPS 再给朋友用，浏览器的复制等功能需要 HTTPS。"
	fi
	echo
	if [ -n "$HOST_LIST" ]; then
		echo "  聊天网址（MIYU_HOST）：$HOST_LIST"
		echo "    浏览器地址栏里的网址必须是其中之一，否则登录会提示“密钥校验失败”。要改：sh install.sh config"
	else
		echo "  聊天网址（MIYU_HOST）：没有设置（以浏览器访问的网址为准）"
	fi
	if [ "$INVITE_SHOW" = "1" ] && [ -n "$INVITE" ]; then
		echo "  邀请码：$INVITE"
		echo "    （只在这里显示这一次，请现在记下来，发给要注册的朋友。"
		echo "      忘了可以用 root 运行：grep INVITE $ENV_FILE 查看）"
	elif [ -n "$INVITE" ]; then
		echo "  邀请码：已设置（不在这里显示）"
	else
		echo "  邀请码：没有设置，任何能打开网页的人都能注册"
	fi
	echo "  最多用户数：$(show_limit "$MAX_USERS" " 人")    数据库上限：$(show_limit "$MAX_DB_MB" " MB")"
	if ! bin_supports_limits; then
		echo "  注意：现在这个版本的程序还不支持登录网址/邀请码/上限，设置已经保存好，程序更新（sh install.sh update）后自动生效。"
	fi
	echo "  改模式、换令牌、改网址、邀请码和上限：sh install.sh config"
	echo "  ------------------------------------------------------------"
	INVITE=""
}

# ---------- 按选好的模式把服务装好 ----------
# 安装和改设置都走这里。顺序：建用户 → 写设置文件 → 聊天程序服务 → 防火墙/Tunnel → 检查
apply_mode() {
	setup_user
	write_env
	if [ "$MODE" = "tunnel" ]; then
		setup_cloudflared_bin
		setup_cf_user
		write_token
		[ -s "$TOKEN_FILE" ] || die "还没有 Tunnel 令牌，请重新运行 sh install.sh config 输入令牌。"
		# 从直连切过来：删掉以前为直连加的防火墙规则（Tunnel 不需要开端口）
		close_firewall
		EXT_PORT="$PORT"
		setup_service
		save_conf
		health_check
		setup_cf_service
		cf_wait_ready
	else
		# 从 Tunnel 切回直连：删掉 cloudflared 服务和令牌
		remove_cloudflared
		setup_service
		if [ "$CUR_MODE" != "direct" ]; then open_firewall; fi
		save_conf
		health_check
	fi
}

# ---------- 安装（默认动作） ----------
# 顺序：检查 root → 认系统和架构 → 装 curl → 看是不是已经装过 → 认机器类型 → 选模式 → 问端口
#       → （Tunnel）问令牌 → 邀请码和上限 → 下载并校验程序 → 建用户 → 注册服务 → 防火墙/Tunnel → 检查
do_install() {
	need_root; detect_os; detect_arch; install_deps
	if [ -f "$CONF" ]; then installed_menu; return; fi
	CUR_MODE=""
	detect_machine; ask_mode; ask_port
	if [ "$MODE" = "tunnel" ]; then ask_token; fi
	ask_hosts; ask_invite; ask_limits
	# 后面任何一步出错，都提示怎么清理装了一半的东西
	trap 'if [ $? -ne 0 ]; then err "安装没有完成。可以运行 sh install.sh uninstall 清理掉装了一半的文件，再重新安装。"; fi' EXIT
	download_bin
	apply_mode
	echo
	if [ "$MODE" = "tunnel" ]; then
		info "安装完成！聊天服务已在本机 127.0.0.1:$PORT 运行，cloudflared 负责把 Cloudflare 的访问转进来，都设置了开机自启。"
	else
		info "安装完成！服务已在 $PORT 端口运行，并设置了开机自启。"
	fi
	print_summary
	trap - EXIT
}

# ---------- 已经装过时再运行安装命令 ----------
installed_menu() {
	load_conf; need_port
	if [ "$MODE" = "tunnel" ]; then m="Cloudflare Tunnel 模式"; else m="直连模式"; fi
	warn "检测到已经安装过了（$m，端口 $PORT）。"
	echo "    1) 修改设置：切换直连/Tunnel 模式、换 Tunnel 令牌、改聊天网址、邀请码和上限（聊天数据保留）"
	echo "    2) 只更新程序（聊天数据和设置都保留）"
	echo "    3) 什么都不做，退出"
	echo "  想换端口：先备份数据，再卸载（sh install.sh uninstall）后重新安装。"
	ask "请选择（直接回车 = 3）："
	case "$(printf '%s' "$REPLY" | tr -d ' ')" in
		1) do_config_main ;;
		2) do_update_main ;;
		*) info "什么都没改，已退出。" ;;
	esac
}

# ---------- 修改设置（sh install.sh config） ----------
# 不重新下载程序、不动聊天数据，端口也不变；可以切换模式、换令牌、改邀请码和上限。
do_config() {
	need_root; detect_os; detect_arch; install_deps
	[ -f "$CONF" ] || die "还没有安装过，请先运行：sh install.sh"
	do_config_main
}

do_config_main() {
	load_conf; need_port
	CUR_MODE="$MODE"
	[ -x "$BIN" ] || die "找不到程序 $BIN，请先运行 sh install.sh update 把程序装回来。"
	detect_machine; ask_mode
	if [ "$MODE" = "tunnel" ]; then
		# 从直连切到 Tunnel 时必须输入令牌（以前的令牌文件不算数）
		if [ "$CUR_MODE" != "tunnel" ]; then rm -f "$TOKEN_FILE"; fi
		ask_token
	elif [ "$CUR_MODE" = "tunnel" ]; then
		# 从 Tunnel 切回直连：NAT 小鸡要问一下外部端口
		ask_ext_port
	fi
	ask_hosts; ask_invite; ask_limits
	apply_mode
	echo
	info "设置已更新，聊天数据没有动。"
	print_summary
}

# ---------- 更新 ----------
# 换程序文件，并按原来的模式重新生成服务配置后重启；端口、邀请码、上限、令牌、聊天数据都不动。
# Tunnel 模式下，如果 cloudflared 是本脚本装的，可以顺便更新到最新官方版本。
do_update() {
	need_root; detect_os; detect_arch; install_deps
	[ -f "$CONF" ] || die "还没有安装过，请先运行：sh install.sh"
	do_update_main
}

do_update_main() {
	load_conf; need_port
	OLD_VER="$("$BIN" -version 2>/dev/null || true)"
	download_bin
	setup_service
	health_check
	info "miyu-chat 更新完成，聊天数据和设置都没有动。"
	if [ "$MODE" = "tunnel" ]; then
		if [ -f "$CF_MARK_BIN" ] && [ -x "$CF_BIN" ]; then
			if [ -n "$MIYU_CF_UPDATE" ]; then REPLY="$MIYU_CF_UPDATE"
			else ask "要不要顺便把 cloudflared 也更新到最新官方版本？[Y/n]（直接回车 = 更新）："; fi
			case "$REPLY" in n|N|no|NO|0) info "cloudflared 保持不变。" ;; *) update_cloudflared ;; esac
		else
			info "cloudflared 不是本脚本装的，不帮你更新它（请用你原来的方式更新）。"
		fi
		setup_cloudflared_bin
		setup_cf_service
		cf_wait_ready || true
	fi
	if [ -z "$(env_get MIYU_HOST)" ]; then
		warn "还没有设置聊天网址（MIYU_HOST）。建议运行 sh install.sh config 填上你的聊天域名，多一层防护。"
	fi
	NEW_VER="$("$BIN" -version 2>/dev/null || true)"
	if [ "$OLD_VER" != "$NEW_VER" ]; then
		warn "程序版本变了（${OLD_VER:-旧版} → $NEW_VER）：请让大家刷新一下聊天网页，旧页面可能登录不上（会提示刷新）。"
	fi
	info "想切换直连/Tunnel 模式、改网址、邀请码或上限：sh install.sh config"
}

# ---------- 查看状态 ----------
# 显示模式、端口、两个服务的运行状态，再实际访问一下 /healthz 确认能用
do_status() {
	detect_os
	if [ -f "$CONF" ]; then load_conf; need_port; else warn "还没有安装。"; return; fi
	if [ "$MODE" = "tunnel" ]; then
		info "已安装：Cloudflare Tunnel 模式，聊天程序只听本机 127.0.0.1:$PORT"
	else
		info "已安装：直连模式，内部端口 $PORT，外部端口 $EXT_PORT"
	fi
	echo "  ---- 聊天程序（$APP） ----"
	if [ "$INIT" = "systemd" ]; then systemctl --no-pager status $APP | head -n 5 || true; else rc-service $APP status || true; fi
	if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then info "聊天服务运行正常。"; else err "聊天服务没响应，试试 sh install.sh update 或看日志。"; fi
	h="$(env_get MIYU_HOST)"
	info "聊天网址（MIYU_HOST）：${h:-没有设置（以浏览器访问的网址为准）}"
	if [ -n "$(env_get MIYU_INVITE_CODE)" ]; then info "邀请码：已设置"; else info "邀请码：没有设置"; fi
	u="$(env_get MIYU_MAX_USERS)"; d="$(env_get MIYU_MAX_DB_MB)"
	info "最多用户数：$(show_limit "$u" " 人")    数据库上限：$(show_limit "$d" " MB")"
	if [ "$MODE" = "tunnel" ]; then
		echo "  ---- Cloudflare Tunnel（$CF_SVC） ----"
		if [ "$INIT" = "systemd" ]; then systemctl --no-pager status $CF_SVC | head -n 5 || true; else rc-service $CF_SVC status || true; fi
		if cf_ready; then info "Tunnel 已连上 Cloudflare。"
		else warn "Tunnel 现在没连上 Cloudflare，看日志："; cf_log_hint; fi
		info "Tunnel 转发目标请设为 http://127.0.0.1:$PORT"
	fi
}

# ---------- 卸载 ----------
# 删得干干净净：服务、程序、配置、聊天数据、运行用户、邀请码设置，以及安装时脚本自己加的那条防火墙规则；
# Tunnel 模式还会删 cloudflared 服务、令牌文件，以及本脚本装的 cloudflared 程序和 miyu-cf 用户。
# 不会卸载你的防火墙软件，也不会删你原来就有的规则和你自己装的 cloudflared。curl 等常用工具保留。
do_uninstall() {
	need_root; detect_os
	if [ "$MIYU_YES" = "1" ]; then REPLY="yes"
	else ask "卸载会删除程序、服务和【全部聊天数据】，无法恢复。确定吗？输入 yes 继续："; fi
	[ "$REPLY" = "yes" ] || { info "已取消卸载。"; exit 0; }
	PORT=""; FW=""
	if [ -f "$CONF" ]; then load_conf; fi
	# 停止并删除服务
	if [ "$INIT" = "systemd" ]; then
		systemctl disable --now $APP >/dev/null 2>&1 || true
		rm -f /etc/systemd/system/$APP.service
		systemctl daemon-reload
	else
		rc-service $APP stop >/dev/null 2>&1 || true
		rc-update del $APP default >/dev/null 2>&1 || true
		rm -f /etc/init.d/$APP "$LOG_FILE"
	fi
	# cloudflared 服务、令牌（只删本脚本装的）
	remove_cloudflared
	# 删掉安装时加的防火墙规则
	close_firewall
	# 删程序、数据、配置、邀请码设置和运行用户
	rm -f "$BIN" "$CONF" "$ENV_FILE" "$ENV_FILE.new"
	rm -rf "$DATA_DIR"
	rmdir "$SECRET_DIR" 2>/dev/null || true
	if id "$RUN_USER" >/dev/null 2>&1; then
		if [ "$OS" = "alpine" ]; then deluser "$RUN_USER" 2>/dev/null || true; delgroup "$RUN_USER" 2>/dev/null || true
		else userdel "$RUN_USER" 2>/dev/null || true; fi
	fi
	info "卸载完成，所有文件都已删除。"
}

# ---------- 入口 ----------
# 所有代码都包在函数里，最后一行才真正开始执行：
# 这样用 curl | sh 时就算网络中断只下载了一半，也不会执行半截脚本。
main() {
	case "${1:-install}" in
		install) do_install ;;
		config|reconfigure|setup) do_config ;;
		uninstall|remove) do_uninstall ;;
		update|upgrade) do_update ;;
		status) do_status ;;
		*) echo "用法：sh install.sh [install|config|uninstall|update|status]"; exit 1 ;;
	esac
}

main "$@"
