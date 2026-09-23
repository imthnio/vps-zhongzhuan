#!/bin/bash
#======================================================================
# 端口转发一键脚本（基于 realm）
#----------------------------------------------------------------------
# realm 是什么？
#   一个用 Rust 写的高性能端口转发工具：单文件、不用装运行环境、
#   TCP 和 UDP 一起转，特别适合做"中转"用。
#
# 这个脚本能帮你做什么？（全程中文，跟着提示填就行）
#   1. 自动下载安装 realm，并设成开机自启
#   2. 添加转发规则：别人访问「这台机器:端口A」→ 自动转到「目标:端口B」
#   3. 查看 / 删除规则，重启服务、看状态，一键卸载
#
# 一键运行（复制粘贴下面这一行）：
#   wget -qO install.sh https://raw.githubusercontent.com/imthnio/duankouzhuanfa/main/install.sh && sudo bash install.sh
#
# 装好之后，以后直接在终端输入 zhuanfa 就能打开管理菜单。
#
# 支持的系统：Debian / Ubuntu（systemd）、Alpine（OpenRC）
# 支持的架构：x86_64、aarch64、armv7、armv6
#======================================================================

# set -u：引用了没定义的变量就直接报错退出。
# 防止变量名手滑写错了，脚本还傻乎乎地继续往下跑。
set -u

# ==================== 全局配置（一般不用改） ====================
REALM_PIN_VERSION="v2.9.6"          # 脚本内置的 realm 版本号
                                   # 安装时会先联网查官方最新版，查不到就用这个保底
UPSTREAM_REPO="zhboner/realm"      # realm 官方 GitHub 仓库
BIN_PATH="/usr/local/bin/realm"    # realm 二进制文件装到哪里
CONF_DIR="/etc/realm"              # 放配置的目录
CONF_FILE="$CONF_DIR/config.json"  # realm 主配置文件（脚本自动生成，不用手改）
RULES_FILE="$CONF_DIR/rules.list"  # 规则清单：纯文本，一行一条，格式见文件头注释
SHORTCUT="/usr/local/bin/zhuanfa"  # 快捷命令：装好后终端输入 zhuanfa 直达菜单
CURL_LOG="/tmp/zhuanfa-curl.log"   # 下载/装依赖出错时的日志，方便排查

# 下载镜像前缀（按顺序挨个试）。
# 有些 VPS 直连 GitHub 很慢甚至连不上，后面几个是加速镜像，
# 脚本会自动轮询，哪个能下就用哪个，你不用操心。
MIRROR_PREFIXES=(
    "https://github.com"
    "https://gh-proxy.com/https://github.com"
    "https://ghproxy.net/https://github.com"
    "https://ghfast.top/https://github.com"
)

# 系统信息（detect_os 函数会自动填好）
PKG_MGR=""      # 包管理器：apt-get（Debian/Ubuntu）或 apk（Alpine）
INIT_SYSTEM=""  # 服务管理：systemd 或 openrc

# ==================== 彩色输出小工具 ====================
# 为了让重要信息一眼能看到：绿色=成功，黄色=提醒，红色=出错，蓝色=说明
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'

say_ok()   { echo -e "${C_GREEN}✓ $*${C_NC}"; }
say_info() { echo -e "${C_BLUE}$*${C_NC}"; }
say_warn() { echo -e "${C_YELLOW}⚠ $*${C_NC}"; }
say_err()  { echo -e "${C_RED}✗ $*${C_NC}" >&2; }
say_step() { echo -e "\n${C_YELLOW}>>> $*${C_NC}"; }

# ==================== 输入校验小工具 ====================
# 端口：1~65535 的纯数字
is_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# IPv4：四段数字，每段 0~255
is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local n
    IFS='.' read -ra _p <<< "$ip"
    for n in "${_p[@]}"; do [ "$n" -le 255 ] || return 1; done
}

# 目标地址：IPv4、IPv6（含冒号就行，不细抠）或域名都算合法
is_target_addr() {
    local a="$1"
    # 纯数字加点（长得像 IPv4）：必须是合法 IPv4，不合法就直接判错，
    # 不能蒙混成"域名"过关，不然 999.1.1.1 这种也会被放行
    if [[ "$a" =~ ^[0-9.]+$ ]]; then
        is_ipv4 "$a"
        return $?
    fi
    [[ "$a" == *":"* ]] && [[ "$a" =~ ^[0-9a-fA-F:.]+$ ]] && return 0   # IPv6
    [[ "$a" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && return 0  # 域名/localhost
    return 1
}

# 通用提问函数：ask "提示语" "默认值" 变量名
# 用户直接回车 → 用默认值；没给默认值 → 原样收下输入（由调用处再校验）
ask() {
    local prompt="$1" default="$2" var="$3"
    local input=""
    if [ -n "$default" ]; then
        read -rp "$prompt [默认: $default]: " input
        [ -z "$input" ] && input="$default"
    else
        read -rp "$prompt: " input
    fi
    printf -v "$var" '%s' "$input"
}

# 是/否提问：ask_yes "提示语" "默认(y/n)"，返回 0=是，1=否
ask_yes() {
    local prompt="$1" default="${2:-n}"
    local hint="y/N" ans=""
    [ "$default" = "y" ] && hint="Y/n"
    read -rp "$prompt [$hint]: " ans
    [ -z "$ans" ] && ans="$default"
    [[ "$ans" =~ ^[Yy]$ ]]
}

# realm 配置里 remote 的写法：IPv6 地址要加方括号，不然会跟端口的冒号混淆
# 比如 ::1:8080 是错的，[::1]:8080 才对
fmt_remote() {
    if [[ "$1" == *":"* ]]; then echo "[$1]:$2"; else echo "$1:$2"; fi
}

# ==================== 系统检测 ====================
need_root() {
    # realm 要监听端口、写系统目录，必须 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        say_err "请用 root 权限运行，比如前面加 sudo："
        say_err "  sudo bash install.sh"
        exit 1
    fi
}

detect_os() {
    # 包管理器：Debian/Ubuntu 用 apt-get，Alpine 用 apk
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt-get"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    else
        say_err "没找到 apt-get 也没找到 apk，这个系统我不认识，装不了"
        exit 1
    fi
    # 服务管理：有 systemctl 就是 systemd，有 rc-service 就是 OpenRC（Alpine）
    if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        say_err "没找到 systemctl 也没找到 rc-service，不知道怎么管理服务"
        exit 1
    fi
    say_info "检测到系统：包管理=$PKG_MGR，服务管理=$INIT_SYSTEM"
}

install_deps() {
    # 脚本依赖的几个小工具：curl/wget 下载、tar 解压、ss 看端口占用
    say_step "检查必备小工具（curl/wget/tar/ss）"
    local need=()
    command -v curl >/dev/null 2>&1 || need+=("curl")
    command -v wget >/dev/null 2>&1 || need+=("wget")
    command -v tar  >/dev/null 2>&1 || need+=("tar")
    command -v ss   >/dev/null 2>&1 || need+=("iproute2")  # ss 在 iproute2 包里
    if [ "${#need[@]}" -eq 0 ]; then
        say_ok "小工具都齐了"
        return 0
    fi
    say_info "需要安装：${need[*]}，正在用 $PKG_MGR 安装…"
    # apt 装包时把输出记到日志里：成功了保持界面干净，失败了打印最后几行，
    # 不然两眼一抹黑，不知道卡在哪一步
    if [ "$PKG_MGR" = "apt-get" ]; then
        if ! apt-get update -qq >"$CURL_LOG" 2>&1; then
            say_warn "apt-get update 出错了，最后几行日志："
            tail -n 5 "$CURL_LOG" 2>/dev/null | sed 's/^/  /'
        fi
        if ! apt-get install -y "${need[@]}" >>"$CURL_LOG" 2>&1; then
            say_err "依赖安装失败，最后几行日志："
            tail -n 8 "$CURL_LOG" 2>/dev/null | sed 's/^/  /'
            exit 1
        fi
    else
        if ! apk add --no-cache "${need[@]}" >>"$CURL_LOG" 2>&1; then
            say_err "依赖安装失败，最后几行日志："
            tail -n 8 "$CURL_LOG" 2>/dev/null | sed 's/^/  /'
            exit 1
        fi
    fi
    say_ok "小工具安装完成"
}

# ==================== 下载安装 realm ====================
detect_arch() {
    # realm 官方提供的是 musl 静态编译版：不依赖系统运行库，
    # Debian 和 Alpine 都能直接跑，所以这里直接选 musl 的包。
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64)        echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        armv7l|armv7)  echo "armv7-unknown-linux-musleabihf" ;;
        armv6l|armv6)  echo "arm-unknown-linux-musleabihf" ;;
        *)
            say_err "你的 CPU 架构是 $m，realm 官方没提供这个架构的包，装不了"
            exit 1
            ;;
    esac
}

get_realm_version() {
    # 先问 GitHub API 拿最新版本号；问不到（比如 GitHub 连不上）就用内置版本保底，
    # 反正下载时还有镜像可以轮询，不至于卡死。
    say_info "正在查询 realm 最新版本…"
    local ver=""
    ver="$(curl -fsSL --connect-timeout 8 --max-time 15 \
        "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^" ]*"' | head -1 | cut -d'"' -f4)"
    if [ -n "$ver" ]; then
        say_ok "官方最新版本：$ver"
    else
        ver="$REALM_PIN_VERSION"
        say_warn "查不到最新版本（可能 GitHub 连不上），用内置版本 $ver 继续"
    fi
    echo "$ver"
}

download_realm() {
    # $1=版本号  $2=架构包名  $3=保存路径
    # 按 MIRROR_PREFIXES 的顺序挨个试，哪个成功用哪个。
    local ver="$1" asset="$2" dest="$3"
    local rel="/$UPSTREAM_REPO/releases/download/$ver/realm-$asset.tar.gz"
    local prefix url
    for prefix in "${MIRROR_PREFIXES[@]}"; do
        url="${prefix}${rel}"
        say_info "尝试下载：$url"
        # -f：服务器报错（如404）就直接失败，不把错页存下来当压缩包
        # -L：跟随跳转；--connect-timeout 10：10秒连不上就换源
        # --max-time 300：单个源最多等5分钟，免得卡死
        if curl -fSL --connect-timeout 10 --max-time 300 -o "$dest" "$url" 2>"$CURL_LOG"; then
            # 简单验货：压缩包里必须能解出名叫 realm 的文件，
            # 防止下到个 HTML 错页还当宝贝供着
            if tar -tzf "$dest" 2>/dev/null | grep -qx "realm"; then
                say_ok "下载成功，验货通过"
                return 0
            fi
            say_warn "下载下来的文件解不开（可能下了个错页），换下一个源"
        else
            say_warn "这个源失败了，换下一个（报错：$(tail -n 1 "$CURL_LOG" 2>/dev/null | head -c 100)）"
        fi
    done
    say_err "所有下载源都失败了。常见原因：这台机器连不上 GitHub，换个网络或挂代理再试"
    return 1
}

install_realm_bin() {
    say_step "安装 realm 二进制文件"
    # 已经装过且能跑 → 问一句要不要重装，避免手滑覆盖
    if [ -x "$BIN_PATH" ] && "$BIN_PATH" --help >/dev/null 2>&1; then
        say_ok "检测到 realm 已经装过了（$BIN_PATH）"
        if ! ask_yes "是否重新下载安装（覆盖现有版本）" "n"; then
            say_info "保留现有版本，跳过下载"
            return 0
        fi
        service_stop >/dev/null 2>&1 || true
    fi
    local ver asset tmpdir
    ver="$(get_realm_version)"
    asset="$(detect_arch)"
    say_info "目标安装包：realm-$asset.tar.gz（版本 $ver）"
    tmpdir="$(mktemp -d)"
    # 不管中途成不成功，退出时都把临时目录清掉，不留垃圾
    trap "rm -rf '$tmpdir'" EXIT
    download_realm "$ver" "$asset" "$tmpdir/realm.tar.gz" || exit 1
    say_info "正在解压安装…"
    tar -xzf "$tmpdir/realm.tar.gz" -C "$tmpdir"
    cp -f "$tmpdir/realm" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$tmpdir"
    trap - EXIT
    # 最终验货：二进制必须能跑起来（架构不对时这里会挂）
    if "$BIN_PATH" --help >/dev/null 2>&1; then
        say_ok "realm 安装成功：$BIN_PATH（版本 $ver）"
    else
        say_err "文件装好了但运行失败，可能是 CPU 架构不匹配，请检查"
        exit 1
    fi
}

# ==================== 服务管理（屏蔽 systemd / OpenRC 差异） ====================
# 不管你是 Debian 还是 Alpine，后面统一调 service_start/stop/restart 就行，
# 不用记两套命令。
service_start()   { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm start;   else systemctl start realm;   fi; }
service_stop()    { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm stop;    else systemctl stop realm;    fi; }
service_restart() { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm restart; else systemctl restart realm; fi; }
service_enable() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then rc-update add realm default >/dev/null 2>&1
    else systemctl enable realm >/dev/null 2>&1; fi
}
service_is_active() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm status >/dev/null 2>&1
    else [ "$(systemctl is-active realm 2>/dev/null)" = "active" ]; fi
}
service_is_enabled() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then rc-update show default 2>/dev/null | grep -q "realm"
    else [ "$(systemctl is-enabled realm 2>/dev/null)" = "enabled" ]; fi
}

write_service() {
    # 给 realm 写服务文件，并设开机自启。
    # 服务文件是脚本自己生成的，不依赖系统自带——
    # Alpine 很多软件包根本不带 OpenRC 脚本，这个坑我们替你踩过了。
    say_step "配置 realm 系统服务（开机自启）"
    mkdir -p "$CONF_DIR"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > /etc/systemd/system/realm.service <<'EOF'
[Unit]
Description=realm 高性能端口转发
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        # OpenRC：realm 自己不会转后台，靠 command_background=true 让 OpenRC 托管它
        cat > /etc/init.d/realm <<'EOF'
#!/sbin/openrc-run
name="realm 高性能端口转发"
command="/usr/local/bin/realm"
command_args="-c /etc/realm/config.json"
command_background=true
pidfile="/run/realm.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/realm
    fi
    service_enable
    say_ok "服务已配置，开机自动启动"
}

# ==================== 配置生成 ====================
# 规则清单 rules.list：纯文本，一行一条，格式：
#   监听端口|目标地址|目标端口|备注
# 比如：
#   10000|8.8.8.8|443|转发到香港落地机
gen_config() {
    # 每次增删规则后都调它，根据 rules.list 重新生成 realm 的 config.json。
    # realm 的 v2 版用 JSON 配置：endpoints 里一条就是一条转发。
    {
        echo '{'
        echo '  "log": {"level": "warn", "output": "stdout"},'
        # no_tcp=false 且 use_udp=true：TCP 和 UDP 一起转，小白不用纠结选协议
        echo '  "network": {"no_tcp": false, "use_udp": true},'
        echo '  "endpoints": ['
        local first=1 lport raddr rport note
        if [ -f "$RULES_FILE" ]; then
            while IFS='|' read -r lport raddr rport note; do
                [ -z "${lport:-}" ] && continue        # 跳过空行
                case "$lport" in \#*) continue ;; esac # 跳过注释行
                if [ "$first" -eq 1 ]; then first=0; else echo ","; fi
                # 监听地址写 0.0.0.0：本机所有 IPv4 地址都能连（IPv6 场景极少，先不折腾）
                printf '    {"listen": "0.0.0.0:%s", "remote": "%s"}' \
                    "$lport" "$(fmt_remote "$raddr" "$rport")"
            done < "$RULES_FILE"
            echo ""
        fi
        echo '  ]'
        echo '}'
    } > "$CONF_FILE"
}

# 查某个监听端口是否已经有规则了
rule_exists() { [ -f "$RULES_FILE" ] && grep -q "^$1|" "$RULES_FILE"; }

# ==================== 防火墙放行 ====================
open_firewall() {
    # $1=端口。转发端口必须在防火墙放行，不然外面连不进来。
    # 按 ufw → firewalld → iptables 的顺序，能用哪个用哪个。
    # 注意：云厂商的安全组/防火墙在控制台里，脚本够不着，那个要自己去开。
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
        say_ok "系统防火墙已放行 $port（ufw，TCP+UDP）"
        return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port="$port"/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        say_ok "系统防火墙已放行 $port（firewalld，TCP+UDP）"
        return 0
    fi
    if command -v iptables >/dev/null 2>&1; then
        # -C 先检查规则在不在，不在才加，避免重复添加一堆一样的
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
        say_ok "系统防火墙已放行 $port（iptables，TCP+UDP）"
        return 0
    fi
    say_warn "没找到能用的防火墙工具，端口 $port 没自动放行；如果外面连不进来，先检查防火墙/安全组"
}

get_public_ip() {
    # 尽量拿个公网 IP 显示出来，方便你知道"别人该连哪个 IP"。
    # 拿不到也不影响，就是少显示一行。
    curl -fsSL --connect-timeout 5 --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \n\r' || true
}

# ==================== 规则管理 ====================
need_installed() {
# 加/删规则前先确认 realm 装好了，没装就指条明路
if [ ! -x "$BIN_PATH" ]; then
say_err "realm 还没安装，请先选菜单 1 安装"
return 1
fi
}

list_rules() {
echo ""
say_info "========== 当前转发规则 =========="
if [ ! -f "$RULES_FILE" ] || [ -z "$(grep -v '^#' "$RULES_FILE" 2>/dev/null | grep -v '^$' || true)" ]; then
say_info "还没有任何规则，选菜单 2 添加第一条吧"
return 1
fi
local i=0 lport raddr rport note
while IFS='|' read -r lport raddr rport note; do
[ -z "${lport:-}" ] && continue
case "$lport" in \#*) continue;; esac
i=$((i + 1))
printf "  [%d] 本机 :%s  →  %s" "$i" "$lport" "$(fmt_remote "$raddr" "$rport")"
[ -n "${note:-}" ] && printf " （%s）" "$note"
echo ""
done < "$RULES_FILE"
say_info "共 $i 条规则（TCP 和 UDP 都转）"
return 0
}

# 重启服务让新配置生效，并确认端口真的在监听
apply_and_verify() {
local port="$1"
gen_config
say_info "正在重启 realm 服务使规则生效…"
if ! service_restart; then
say_err "服务重启失败！用菜单 6 看看状态，或检查配置文件：$CONF_FILE"
return 1
fi
sleep 1
if ss -tln 2>/dev/null | grep -q ":$port "; then
say_ok "端口 $port 已在监听，规则生效！"
return 0
fi
say_warn "服务起来了，但暂时没看到端口 $port 在监听，等几秒再用菜单 6 检查"
return 0
}

add_rule() {
need_installed || return 1
# 两种用法：
# 交互：直接调 add_rule，跟着向导一步步填（菜单 2 就是这么进来的）
# 非交互：环境变量传参，适合老手写脚本调用：
# LISTEN_PORT=10000 TARGET_ADDR=1.2.3.4 TARGET_PORT=443 NOTE="备注" bash install.sh add
local lport="${LISTEN_PORT:-}" raddr="${TARGET_ADDR:-}" rport="${TARGET_PORT:-}" note="${NOTE:-}"
if [ -z "$lport$raddr$rport" ]; then
# ---------------- 交互式向导 ----------------
echo ""
say_info "========== 添加转发规则 =========="
say_info "先理解一句话：转发 = 别人访问→ 自动转到"
echo ""
# 第 1 步：监听端口
while true; do
say_info "本机监听端口：别人要连你这台机器的哪个端口？"
say_info " 比如填 10000，别人访问「你这台机器的IP:10000」就会被转发走。"
ask "请输入监听端口 (1-65535)" "" lport
if ! is_port "$lport"; then say_err "端口不合法，请输入 1~65535 的数字"; continue; fi
if rule_exists "$lport"; then
say_warn "端口 $lport 已经有一条规则了"
ask_yes "是否覆盖旧规则" "n" || { say_info "已取消"; return 1;}
sed -i "/^$lport|/d" "$RULES_FILE"
break
fi
# 端口被别的程序占了就提醒一声；被谁占了一目了然，自己判断
local holder
holder="$(ss -tlnp 2>/dev/null | grep ":$lport " | head -1 || true)"
if [ -n "$holder" ]; then
say_warn "端口 $lport 已经被占用了："
echo " $(echo "$holder" | head -c 200)"
ask_yes "仍要继续吗（可能转发不起来）" "n" || { say_info "已取消"; return 1;}
fi
break
done
# 第 2 步：目标地址
while true; do
echo ""
say_info "目标地址：要把流量转发到哪台服务器？"
say_info " 填它的 IP 或域名，比如 8.8.8.8 或 example.com。"
ask "请输入目标地址" "" raddr
raddr="$(echo "$raddr" | tr -d ' ')" # 顺手去掉不小心带上的空格
is_target_addr "$raddr" && break
say_err "地址格式不对，IP 或域名都行，比如 1.2.3.4"
done
# 第 3 步：目标端口
while true; do
echo ""
say_info "目标端口：目标服务器上的哪个端口？"
say_info " 比如目标上跑的服务端口是 443 就填 443。"
ask "请输入目标端口 (1-65535)" "" rport
is_port "$rport" && break
say_err "端口不合法，请输入 1~65535 的数字"
done
# 第 4 步：备注（可选）
echo ""
say_info "备注（可选）：给这条规则起个名，比如\"转发到香港落地机\"，直接回车跳过"
ask "请输入备注" "" note
# 最后跟你确认一遍，免得手滑填错
echo ""
say_info "---------- 请确认 ----------"
echo " 本机监听： 0.0.0.0:$lport"
echo " 转发目标： $(fmt_remote "$raddr" "$rport")"
[ -n "$note" ] && echo " 备注： $note"
echo " （TCP 和 UDP 都会转）"
ask_yes "确认添加这条规则" "y" || { say_info "已取消"; return 1;}
# 目标连通性顺手测一下：连不上就提醒（多半是地址/端口填错了），但不强制拦你，
# 毕竟对方可能只是暂时没开机
if ! timeout 5 bash -c "echo >/dev/tcp/$raddr/$rport" 2>/dev/null; then
say_warn "现在连 $(fmt_remote "$raddr" "$rport") 没连上：可能是地址/端口填错了，也可能是对方暂时没开机"
ask_yes "仍要添加吗" "n" || { say_info "已取消"; return 1;}
else
say_ok "目标 $(fmt_remote "$raddr" "$rport") 现在能连通"
fi
else
# ---------------- 非交互：参数走环境变量 ----------------
is_port "$lport" || { say_err "LISTEN_PORT 不合法：$lport"; return 1;}
is_target_addr "$raddr" || { say_err "TARGET_ADDR 不合法：$raddr"; return 1;}
is_port "$rport" || { say_err "TARGET_PORT 不合法：$rport"; return 1;}
fi
# 写入规则清单（同端口旧规则先删掉，保证一个端口只对应一条）
[ -f "$RULES_FILE" ] || touch "$RULES_FILE"
sed -i "/^$lport|/d" "$RULES_FILE" 2>/dev/null || true
echo "$lport|$raddr|$rport|$note" >> "$RULES_FILE"
open_firewall "$lport"
apply_and_verify "$lport" || return 1
local pubip
pubip="$(get_public_ip)"
echo ""
say_ok "完成！别人现在可以访问 ${pubip:-这台机器的IP}:$lport，流量会自动转到 $(fmt_remote "$raddr" "$rport")"
}

del_rule() {
need_installed || return 1
# 两种用法：交互（按序号删）/ 非交互（LISTEN_PORT=端口 bash install.sh del）
local lport="${LISTEN_PORT:-}"
if [ -z "$lport" ]; then
list_rules || return 1
echo ""
local choice=""
ask "请输入要删除的规则序号（按上面 [数字] 填）" "" choice
[[ "$choice" =~ ^[0-9]+$ ]] || { say_err "请输入数字序号"; return 1; }
# 把序号换算成本机端口：第 N 条非空行 | 切出第一列
lport="$(grep -v '^#' "$RULES_FILE" | grep -v '^$' | sed -n "${choice}p" | cut -d'|' -f1)"
[ -z "$lport" ] && { say_err "没有这个序号"; return 1;}
ask_yes "确认删除本机端口 $lport 的规则" "n" || { say_info "已取消"; return 1;}
fi
rule_exists "$lport" || { say_err "端口 $lport 没有对应的规则"; return 1;}
sed -i "/^$lport|/d" "$RULES_FILE"
gen_config
service_restart >/dev/null 2>&1 || true
say_ok "已删除端口 $lport 的规则"
}

# ==================== 安装 / 卸载 ====================
do_install() {
say_step "开始安装 realm"
need_root
detect_os
install_deps
install_realm_bin
write_service
# 保证规则清单和配置文件存在。注意：已有规则不会被清空，放心重装。
[ -f "$RULES_FILE" ] || : > "$RULES_FILE"
gen_config
say_info "正在启动服务…"
if service_restart && sleep 1 && service_is_active; then
say_ok "realm 服务运行中，开机自启已设置"
else
say_warn "服务好像没起来，用菜单 6 看看状态"
fi
install_shortcut
echo ""
say_ok "安装完成！以后在终端输入 zhuanfa 就能打开管理菜单"
}

install_shortcut() {
# 把脚本自身复制一份到 /usr/local/bin/zhuanfa，做成快捷命令。
# 如果是管道/进程替换方式运行的（$0 不是普通文件），就没东西可复制，跳过。
case "$0" in
/dev/fd/*|/proc/self/fd/*) return 0;;
esac
if [ -f "$0" ]; then
if cp -f "$0" "$SHORTCUT" && chmod +x "$SHORTCUT"; then
say_ok "快捷命令已创建：以后直接输入 zhuanfa 打开菜单"
fi
fi
}

do_uninstall() {
say_warn "即将删除：realm 程序、系统服务、全部转发规则和配置"
# 非交互卸载时传 UNINSTALL_CONFIRM=yes 跳过确认；默认必须手动确认，防手滑
if [ "${UNINSTALL_CONFIRM:-}" != "yes" ]; then
ask_yes "确认卸载吗" "n" || { say_info "已取消"; return 1;}
fi
service_stop >/dev/null 2>&1 || true
if [ "$INIT_SYSTEM" = "openrc" ]; then
rc-update del realm default >/dev/null 2>&1 || true
rm -f /etc/init.d/realm
else
systemctl disable realm >/dev/null 2>&1 || true
rm -f /etc/systemd/system/realm.service
systemctl daemon-reload >/dev/null 2>&1 || true
fi
rm -f "$BIN_PATH" "$SHORTCUT"
rm -rf "$CONF_DIR"
say_ok "卸载完成，干干净净"
}

show_status() {
echo ""
say_info "========== 运行状态 =========="
if [ -x "$BIN_PATH" ]; then echo " realm 程序：已安装（$BIN_PATH）"
else echo " realm 程序：未安装（先选菜单 1 安装）"; fi
if service_is_active; then echo " 服务状态：运行中"
else echo " 服务状态：未运行"; fi
if service_is_enabled; then echo " 开机自启：已开启"
else echo " 开机自启：未开启"; fi
echo ""
say_info "正在监听的端口（realm 的）："
if ss -tlnp 2>/dev/null | grep -q "realm"; then
ss -tlnp 2>/dev/null | grep "realm" | sed 's/^/ /'
else
say_info " （没有）"
fi
}

# ==================== 主菜单 ====================
show_menu() {
while true; do
echo ""
echo "========== 端口转发管理菜单 =========="
if service_is_active; then echo " realm 状态：运行中"
else echo " realm 状态：未运行"; fi
echo ""
echo " 1. 安装 / 更新 realm（第一次用先选这个）"
echo " 2. 添加转发规则"
echo " 3. 查看转发规则"
echo " 4. 删除转发规则"
echo " 5. 重启 realm 服务"
echo " 6. 查看运行状态"
echo " 7. 卸载（删除 realm 和所有规则）"
echo " 0. 退出"
echo "======================================"
local c=""
read -rp "请选择 [0-7]: " c
case "$c" in
1) do_install;;
2) add_rule;;
3) list_rules; read -rp "按回车返回…" _;;
4) del_rule;;
5) if service_restart; then say_ok "服务已重启"; else say_err "重启失败，用菜单 6 看看"; fi;;
6) show_status; read -rp "按回车返回…" _;;
7) do_uninstall;;
0) say_info "再见"; exit 0;;
*) say_err "请输入 0~7 的数字";;
esac
done
}

# ==================== 入口 ====================
main() {
# 参数优先，其次环境变量 ACTION，都没有就进交互菜单。
# 比如：bash install.sh install / ACTION=add LISTEN_PORT=... bash install.sh
local action="${1:-${ACTION:-}}"
case "$action" in
install) do_install;;
uninstall) need_root; detect_os; do_uninstall;;
add) need_root; detect_os; install_deps; add_rule;;
del) need_root; detect_os; del_rule;;
list) list_rules;;
restart) need_root; detect_os; if service_restart; then say_ok "已重启"; else say_err "重启失败"; fi;;
status) detect_os; show_status;;
""|menu)
# 没给参数 → 进交互菜单。但如果是管道方式运行（stdin 不是终端），
# read 会直接读到 EOF，菜单会瞎转。与其这样，不如直接告诉正确的打开方式。
if [ ! -t 0]; then
say_err "检测到不是交互终端，菜单需要键盘输入，进不去。"
say_info "请先下载再运行（这样才能进菜单）："
say_info " wget -qO install.sh https://raw.githubusercontent.com/imthnio/duankouzhuanfa/main/install.sh && sudo bash install.sh"
exit 1
fi
need_root; detect_os; install_deps
show_menu;;
*) say_err "未知参数：$action（可用：install / add / del / list / restart / status / uninstall）"; exit 1;;
esac
}

main "$@"
