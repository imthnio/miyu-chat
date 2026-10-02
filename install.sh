#!/bin/sh
# =====================================================================
#  密语 miyu-chat 一键安装脚本
#  支持系统：Debian / Ubuntu（systemd）、Alpine（OpenRC）
#  支持机器：独立服务器（母鸡）、VPS（小鸡）、NAT 小鸡
#
#  用法：
#    安装：  sh install.sh            （或 sh install.sh install）
#    卸载：  sh install.sh uninstall  （删除程序、服务、数据、防火墙规则，删得干干净净）
#    更新：  sh install.sh update     （只换程序，聊天数据保留）
#    状态：  sh install.sh status
#
#  免交互安装（给会写脚本的人用，可选）：
#    MIYU_PORT=8080 MIYU_EXT_PORT=8080 sh install.sh     直接指定端口，不再提问
#    MIYU_YES=1 sh install.sh uninstall                 卸载时不再二次确认
#    MIYU_BIN=/root/miyu-chat-linux-amd64 sh install.sh 用你自己下载好的程序文件
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
# =====================================================================

# 出错就停，避免装到一半留下烂摊子
set -e

# ---------- 基本配置（一般不用改） ----------
REPO="imthnio/miyu-chat"                 # GitHub 仓库，程序从这里的 Release 下载
APP="miyu-chat"
BIN="/usr/local/bin/miyu-chat"           # 程序装在这里
DATA_DIR="/var/lib/miyu-chat"            # 聊天数据放这里
CONF="/etc/miyu-chat.conf"               # 记录你选的端口，卸载/更新时要用
RUN_USER="miyu"                          # 用一个没有登录权限的普通用户运行，更安全
LOG_FILE="/var/log/miyu-chat.log"        # Alpine 下的运行日志

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

# ---------- 必须用 root 运行 ----------
# 安装服务、写 /usr/local/bin 都需要管理员权限
need_root() {
	[ "$(id -u)" = "0" ] || die "请用 root 用户运行（先执行 sudo -i 或 su - 切到 root，再重新运行脚本）。"
}

# ---------- 识别系统 ----------
# 看 /etc/os-release 判断是 Alpine 还是 Debian/Ubuntu，决定用 apk 还是 apt、OpenRC 还是 systemd
detect_os() {
	[ -f /etc/os-release ] || die "认不出你的系统（没有 /etc/os-release）。本脚本只支持 Debian、Ubuntu、Alpine。"
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

# ---------- 让用户自己选端口 ----------
# NAT 小鸡只能用商家分配的端口，所以必须问；最多问 3 次，免得卡死
ask_port() {
	if [ "$IS_NAT" = "1" ]; then
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
	if [ -n "$MIYU_EXT_PORT" ]; then
		EXT_PORT="$MIYU_EXT_PORT"
	elif [ "$IS_NAT" = "1" ]; then
		ask "商家后台里，这个内部端口对应的“外部端口”是多少？（一样就直接回车）："
		e="$(printf '%s' "$REPLY" | tr -d ' ')"
		case "$e" in
			'') ;;
			*[!0-9]*) warn "输入的不是数字，先按和内部端口相同处理。" ;;
			*) EXT_PORT="$e" ;;
		esac
	fi
}

# ---------- 获取最新版本号 ----------
# 先问 GitHub 接口；被限流时，改看 releases/latest 网页跳转到哪个版本
get_version() {
	VER="$(curl -fsS --max-time 10 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
		| sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1 || true)"
	if [ -z "$VER" ]; then
		VER="$(curl -fsSI --max-time 10 "https://github.com/$REPO/releases/latest" 2>/dev/null \
			| tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/\(.*\)$#\1#p' | head -n1 || true)"
	fi
}

# ---------- 下载程序 ----------
# 优先用你手动放的文件（MIYU_BIN=路径），其次 GitHub Release，最后 jsDelivr 备用地址
download_bin() {
	tmp="$(mktemp)"
	file="$APP-linux-$ARCH"
	ok=0
	if [ -n "$MIYU_BIN" ]; then
		[ -f "$MIYU_BIN" ] || die "MIYU_BIN 指定的文件不存在：$MIYU_BIN"
		cp "$MIYU_BIN" "$tmp" && ok=1 && info "使用本地程序文件：$MIYU_BIN"
	fi
	if [ $ok = 0 ]; then
		get_version
		if [ -n "$VER" ]; then
			info "最新版本：$VER，正在从 GitHub 下载…"
			curl -fL --retry 2 --max-time 120 -o "$tmp" "https://github.com/$REPO/releases/download/$VER/$file" 2>/dev/null && ok=1
		fi
	fi
	if [ $ok = 0 ]; then
		warn "GitHub 下载失败，改用 jsDelivr 备用地址…"
		curl -fL --retry 2 --max-time 120 -o "$tmp" "https://cdn.jsdelivr.net/gh/$REPO@dist/$file" 2>/dev/null && ok=1
	fi
	[ $ok = 1 ] || { rm -f "$tmp"; die "程序下载失败。请检查这台机器能不能访问 github.com，或者稍后再试。"; }

	# 检查下载的确实是能运行的程序，而不是一个报错网页
	if [ "$(head -c 4 "$tmp" | od -An -c | tr -d ' ')" != "177ELF" ]; then
		rm -f "$tmp"; die "下载到的文件不是程序（可能被网络劫持或地址失效），请稍后重试。"
	fi
	chmod 755 "$tmp"
	"$tmp" -version >/dev/null 2>&1 || { rm -f "$tmp"; die "程序无法在这台机器上运行，可能是 CPU 架构不匹配。"; }
	mv -f "$tmp" "$BIN"
	info "程序已安装到 $BIN（$("$BIN" -version 2>&1)）"
}

# ---------- 创建运行用户和数据目录 ----------
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

# ---------- 注册成系统服务（开机自启、崩溃自动重启） ----------
setup_service() {
	if [ "$INIT" = "systemd" ]; then
		cat > /etc/systemd/system/$APP.service <<UNIT
[Unit]
Description=miyu-chat 密语加密聊天
After=network-online.target
Wants=network-online.target

[Service]
User=$RUN_USER
Group=$RUN_USER
ExecStart=$BIN -listen 0.0.0.0:$PORT -db $DATA_DIR/miyu.db
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
command_args="-listen 0.0.0.0:$PORT -db $DATA_DIR/miyu.db"
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
RC
		chmod 755 /etc/init.d/$APP
		rc-update add $APP default >/dev/null 2>&1
		rc-service $APP restart >/dev/null 2>&1 || rc-service $APP start
	fi
}

# ---------- 防火墙放行 ----------
# 只给自己的端口加规则，不会关掉或卸载你的防火墙
open_firewall() {
	FW=""
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
		ufw allow "$PORT"/tcp comment "$APP" >/dev/null && FW="ufw"
		info "已在 ufw 防火墙放行 $PORT 端口。"
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null && firewall-cmd --reload >/dev/null && FW="firewalld"
		info "已在 firewalld 防火墙放行 $PORT 端口。"
	elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "policy drop"; then
		warn "检测到 nftables 默认拦截入站。为了不弄乱你的规则，脚本不自动改，请自己复制执行："
		echo "    nft add rule inet filter input tcp dport $PORT accept"
	elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -q -- "-P INPUT DROP"; then
		warn "检测到 iptables 默认拦截入站。请自己复制执行放行命令："
		echo "    iptables -I INPUT -p tcp --dport $PORT -j ACCEPT"
	fi
	printf 'PORT=%s\nEXT_PORT=%s\nFW=%s\n' "$PORT" "$EXT_PORT" "$FW" > "$CONF"
}

# ---------- 检查服务是否真的跑起来了 ----------
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

do_install() {
	need_root; detect_os; detect_arch; install_deps
	if [ -f "$CONF" ]; then
		warn "检测到已经安装过。想换端口请先卸载（sh install.sh uninstall），只想升级程序请用 sh install.sh update。"
		exit 1
	fi
	detect_machine; ask_port
	# 后面任何一步出错，都提示怎么清理装了一半的东西
	trap 'if [ $? -ne 0 ]; then err "安装没有完成。可以运行 sh install.sh uninstall 清理掉装了一半的文件，再重新安装。"; fi' EXIT
	download_bin; setup_user; setup_service; open_firewall; health_check
	echo
	info "安装完成！服务已在 $PORT 端口运行，并设置了开机自启。"
	echo "  ------------------------------------------------------------"
	echo "  本机测试地址：http://${PUBLIC_IP:-你的公网IP}:$EXT_PORT"
	echo "  接 Cloudflare 时需要的信息："
	echo "    公网 IP：${PUBLIC_IP:-请到商家后台查看}"
	echo "    外部端口：$EXT_PORT"
	if [ "$IS_NAT" = "1" ]; then
		echo "  NAT 提醒：请确认商家后台已把外部端口 $EXT_PORT 映射到内部端口 $PORT，"
		echo "           并且安全组/防火墙放行了这个端口。"
	fi
	echo "  建议通过 Cloudflare 加上 HTTPS 再给朋友用，浏览器的复制等功能需要 HTTPS。"
	echo "  ------------------------------------------------------------"
	trap - EXIT
}

do_update() {
	need_root; detect_os; detect_arch; install_deps
	[ -f "$CONF" ] || die "还没有安装过，请先运行：sh install.sh"
	. "$CONF"
	download_bin
	if [ "$INIT" = "systemd" ]; then systemctl restart $APP; else rc-service $APP restart >/dev/null; fi
	health_check
	info "更新完成，聊天数据没有动。"
}

do_status() {
	detect_os
	if [ -f "$CONF" ]; then . "$CONF"; info "已安装，内部端口 $PORT，外部端口 $EXT_PORT"; else warn "还没有安装。"; return; fi
	if [ "$INIT" = "systemd" ]; then systemctl --no-pager status $APP | head -n 5; else rc-service $APP status; fi
	if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then info "服务运行正常。"; else err "服务没响应，试试重新安装或看日志。"; fi
}

do_uninstall() {
	need_root; detect_os
	if [ "$MIYU_YES" = "1" ]; then REPLY="yes"
	else ask "卸载会删除程序、服务和【全部聊天数据】，无法恢复。确定吗？输入 yes 继续："; fi
	[ "$REPLY" = "yes" ] || { info "已取消卸载。"; exit 0; }
	PORT=""; FW=""
	[ -f "$CONF" ] && . "$CONF"
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
	# 删掉安装时加的防火墙规则
	if [ -n "$PORT" ] && [ "$FW" = "ufw" ]; then ufw delete allow "$PORT"/tcp >/dev/null 2>&1 || true; fi
	if [ -n "$PORT" ] && [ "$FW" = "firewalld" ]; then firewall-cmd --permanent --remove-port="$PORT"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || true; fi
	# 删程序、数据、配置和运行用户
	rm -f "$BIN" "$CONF"
	rm -rf "$DATA_DIR"
	if id "$RUN_USER" >/dev/null 2>&1; then
		if [ "$OS" = "alpine" ]; then deluser "$RUN_USER" 2>/dev/null || true; delgroup "$RUN_USER" 2>/dev/null || true
		else userdel "$RUN_USER" 2>/dev/null || true; fi
	fi
	info "卸载完成，所有文件都已删除。"
}

case "${1:-install}" in
	install) do_install ;;
	uninstall|remove) do_uninstall ;;
	update|upgrade) do_update ;;
	status) do_status ;;
	*) echo "用法：sh install.sh [install|uninstall|update|status]"; exit 1 ;;
esac
