#!/bin/bash
set -u

cd "$(dirname "$0")" || exit 1
tmp="$(mktemp -d)" || exit 1
source ./install.sh
trap 'rm -rf "$tmp"; rm -f "$CURL_LOG"' EXIT

CONF_DIR="$tmp/realm"
CONF_FILE="$CONF_DIR/config.json"
RULES_FILE="$CONF_DIR/rules.list"
FIREWALL_FILE="$CONF_DIR/firewall.list"
HOP_FILE="$CONF_DIR/hop.list"
HOP_SCRIPT="$CONF_DIR/hop.sh"
BIN_PATH="$tmp/realm-bin"
SHORTCUT="$tmp/zhuanfa"
SYSTEMD_UNIT="$tmp/realm.service"
OPENRC_INIT="$tmp/realm.init"
printf '#!/bin/sh\nexit 0\n' > "$BIN_PATH"
chmod +x "$BIN_PATH"

restart_ok=1
stop_calls=0
restart_calls=0
original_open_firewall="$(declare -f open_firewall)"
original_close_firewall="$(declare -f close_firewall)"
original_save_firewall="$(declare -f save_firewall)"
original_run_hop_script="$(declare -f run_hop_script)"

service_restart() { restart_calls=$((restart_calls + 1)); [ "$restart_ok" -eq 1 ]; }
service_stop() { stop_calls=$((stop_calls + 1)); [ "$restart_ok" -eq 1 ]; }
service_is_active() { [ "$restart_ok" -eq 1 ]; }
ss() { printf 'LISTEN 0 128 0.0.0.0:10000 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:10001 0.0.0.0:*\n'; }
sleep() { :; }
get_public_ip() { :; }
open_firewall() { :; }
close_firewall() { :; }
save_firewall() { :; }
ensure_iptables() { :; }
hop_runs=0
hop_fail=0
run_hop_script() {
    hop_runs=$((hop_runs + 1))
    [ "$hop_fail" -eq 0 ]
}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_rule() { grep -qxF "$1" "$RULES_FILE" || fail "expected rule: $1"; }

# ---------- 1. 输入校验 ----------
is_port 1 || fail 'is_port 1'
is_port 443 || fail 'is_port 443'
is_port 65535 || fail 'is_port 65535'
is_port 0 && fail 'is_port 0 accepted'
is_port 0443 && fail 'is_port leading zero accepted'
is_port 65536 && fail 'is_port 65536 accepted'
is_port 99999999999999999999 && fail 'is_port huge number accepted'
is_port abc && fail 'is_port alpha accepted'

is_target_addr 1.2.3.4 || fail 'valid ipv4 rejected'
is_target_addr 163.com || fail 'numeric-label domain 163.com rejected'
is_target_addr 1.hk.example.com || fail 'numeric-label subdomain rejected'
is_target_addr xn--fiqs8s.cn || fail 'punycode domain rejected'
is_target_addr localhost || fail 'localhost rejected'
is_target_addr ::1 || fail '::1 rejected'
is_target_addr 2001:db8::1 || fail '2001:db8::1 rejected'
is_target_addr fe80:: || fail 'fe80:: rejected'
is_target_addr ::ffff:192.0.2.128 || fail 'ipv4-mapped ipv6 rejected'
is_target_addr 2001:0db8:85a3:0000:0000:8a2e:0370:7334 || fail 'full ipv6 rejected'
[ "$(normalize_target_addr ' [2001:db8::1] ')" = '2001:db8::1' ] || fail 'bracketed ipv6 not normalized'

for bad_addr in '' '0.0.0.0' '01.2.3.4' '999.1.1.1' '1.2.3.g' 'a..b.com' '-bad.com' 'bad-.com' 'foo.123' \
    ':' '::' '::0' ':::' 'cafe:443' '1::2::3' '2001:db8::12345' ':2001:db8::1' '2001:db8::1:' '1.2.3.4:443'; do
    is_target_addr "$bad_addr" && fail "bad target addr accepted: $bad_addr"
done

if ask_yes 'confirm' y </dev/null; then fail 'EOF was treated as yes'; fi
printf 'yes\n' | ask_yes 'confirm' n || fail '"yes" was not accepted by ask_yes'
printf 'NO\n' | ask_yes 'confirm' y && fail '"NO" was accepted by ask_yes'

# ---------- 2. 首次添加失败回滚到空规则（应调用 service_stop 而非 service_restart） ----------
restart_ok=0
stop_calls=0
restart_calls=0
LISTEN_PORT=10000 TARGET_ADDR=1.2.3.4 TARGET_PORT=443 NOTE=first
if add_rule >/dev/null 2>&1; then fail 'first add succeeded with broken service'; fi
[ "$stop_calls" -eq 1 ] || fail "rollback to empty rules did not call service_stop (got $stop_calls)"
[ "$restart_calls" -eq 1 ] || fail "rollback to empty rules unexpectedly retried service_restart (got $restart_calls)"
has_rules && fail 'rules not empty after failed first add'

# ---------- 3. 规则增删、回滚、自环防护、正则注入防护、无末尾换行 ----------
restart_ok=1
add_rule >/dev/null || fail 'initial add'
expect_rule '10000|1.2.3.4|443|first'

# 自环拒绝
LISTEN_PORT=10000 TARGET_ADDR=127.0.0.1 TARGET_PORT=10000 NOTE=loop
if add_rule >/dev/null 2>&1; then fail 'loopback self-forward accepted'; fi
expect_rule '10000|1.2.3.4|443|first'

# 进程名归属检查：若 ss -tlnp 显示端口被 nginx 而非 realm 占用，应判为未生效并回滚
ss() { printf 'LISTEN 0 128 0.0.0.0:10000 0.0.0.0:* users:(("realm",pid=1,fd=3))\nLISTEN 0 128 0.0.0.0:10001 0.0.0.0:* users:(("nginx",pid=2,fd=4))\n'; }
LISTEN_PORT=10001 TARGET_ADDR=1.2.3.4 TARGET_PORT=443 NOTE=nginxport
if add_rule >/dev/null 2>&1; then fail 'port owned by nginx falsely verified as realm'; fi
rule_exists 10001 && fail 'failed nginx-owned port rule not rolled back'
ss() { printf 'LISTEN 0 128 0.0.0.0:10000 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:10001 0.0.0.0:*\n'; }

LISTEN_PORT=10000 TARGET_ADDR=5.6.7.8 TARGET_PORT=443 NOTE=first
restart_ok=0
if add_rule >/dev/null 2>&1; then fail 'failed restart accepted replacement'; fi
expect_rule '10000|1.2.3.4|443|first'
grep -q '1.2.3.4:443' "$CONF_FILE" || fail 'config not rolled back after add'

if del_rule >/dev/null 2>&1; then fail 'failed restart accepted deletion'; fi
expect_rule '10000|1.2.3.4|443|first'
grep -q '1.2.3.4:443' "$CONF_FILE" || fail 'config not rolled back after delete'

restart_ok=1
NOTE='bad|entry'
if add_rule >/dev/null 2>&1; then fail 'pipe in note accepted'; fi
expect_rule '10000|1.2.3.4|443|first'

# del_rule 非法/正则注入端口必须拒绝
for bad_del in '.*' '10000/d' '010000' '0'; do
    LISTEN_PORT="$bad_del"
    if del_rule >/dev/null 2>&1; then fail "del_rule accepted bad LISTEN_PORT: $bad_del"; fi
done
expect_rule '10000|1.2.3.4|443|first'

# rules.list 缺少末尾换行时，gen_config 与 list_rules 仍能读到最后一行
printf '10000|1.2.3.4|443|no_newline' > "$RULES_FILE"
gen_config || fail 'gen_config without trailing newline'
grep -q '1.2.3.4:443' "$CONF_FILE" || fail 'gen_config dropped line without trailing newline'
list_rules | grep -F 'no_newline' >/dev/null || fail 'list_rules dropped line without trailing newline'
printf '# 格式：监听端口|目标地址|目标端口|备注\n10000|1.2.3.4|443|first\n' > "$RULES_FILE"

# ---------- 4. 端口跳跃（含失败回滚与空 hop.sh 退出码） ----------
LISTEN_PORT=10000 TARGET_ADDR=5.6.7.8 TARGET_PORT=443 NOTE=hy HOP_RANGE=20000-50000
add_rule >/dev/null || fail 'add with port hopping'
grep -qxF '10000|20000|50000' "$HOP_FILE" || fail 'hop range not recorded'
grep -qF -- '--dport 20000:50000 -j REDIRECT --to-ports 10000' "$HOP_SCRIPT" || fail 'hop script missing redirect'
[ "$hop_runs" -gt 0 ] || fail 'hop script not run'
list_rules | grep -F '20000-50000' >/dev/null || fail 'hop range not listed'

# set_hop 失败时回滚 hop.list，保留原有 10000 的跳跃，不记录失败的 10001
hop_fail=1
if set_hop 10001 60000-61000 >/dev/null 2>&1; then fail 'set_hop succeeded when run_hop_script failed'; fi
if grep -q '^10001|' "$HOP_FILE"; then fail 'failed hop range was not rolled back'; fi
grep -qxF '10000|20000|50000' "$HOP_FILE" || fail 'existing hop range lost after rollback'
hop_fail=0

LISTEN_PORT=30000 HOP_RANGE=
if add_rule >/dev/null 2>&1; then fail 'port inside another hop range accepted'; fi
LISTEN_PORT=10001 HOP_RANGE=40000-60000
if add_rule >/dev/null 2>&1; then fail 'overlapping hop range accepted'; fi
HOP_RANGE=500-100
if add_rule >/dev/null 2>&1; then fail 'reversed hop range accepted'; fi
HOP_RANGE=60000:61000
add_rule >/dev/null || fail 'second hop rule'
grep -qxF '10001|60000|61000' "$HOP_FILE" || fail 'colon range not normalised'
LISTEN_PORT=10001
del_rule >/dev/null || fail 'delete hop rule'
if grep -q '^10001|' "$HOP_FILE"; then fail 'hop range left after delete'; fi
HOP_RANGE=
runs_before="$hop_runs"
add_rule >/dev/null || fail 'plain add next to hop rule'
[ "$hop_runs" -gt "$runs_before" ] || fail 'other hop rules not reapplied after plain add'
grep -qxF '10000|20000|50000' "$HOP_FILE" || fail 'plain add touched other hop range'
del_rule >/dev/null || fail 'delete plain rule'

LISTEN_PORT=10000 HOP_RANGE=
add_rule >/dev/null || fail 'overwrite without hopping'
if grep -q '^10000|' "$HOP_FILE"; then fail 'old hop range kept after overwrite'; fi
if grep -q REDIRECT "$HOP_SCRIPT"; then fail 'hop script still redirects'; fi

# 真实运行空的 hop.sh：即使 iptables -X 返回非 0（链不存在），hop.sh 也必须退出 0
eval "$original_run_hop_script"
fake_bin="$tmp/fakebin"
mkdir -p "$fake_bin"
cat > "$fake_bin/iptables" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$fake_bin/iptables"
PATH="$fake_bin:$PATH" run_hop_script || fail 'empty hop.sh exited non-zero when ZHUANFA_HOP chain was absent'
run_hop_script() { hop_runs=$((hop_runs + 1)); [ "$hop_fail" -eq 0 ]; }

NOTE=second
add_rule >/dev/null || fail 'replacement add'
expect_rule '10000|5.6.7.8|443|second'
if grep -qF '1.2.3.4' "$RULES_FILE"; then fail 'old rule still present'; fi

del_rule >/dev/null || fail 'delete'
if grep -q '^10000|' "$RULES_FILE"; then fail 'deleted rule still present'; fi

# 无规则时 do_restart 应拒绝启动，防止空配置崩溃循环
if do_restart >/dev/null 2>&1; then fail 'do_restart succeeded with no rules'; fi

# ---------- 5. 防火墙归属、ufw 误判防护、firewalld 重载次数、save_firewall 不误装包 ----------
eval "$original_open_firewall"
eval "$original_close_firewall"
tcp_present=1
udp_present=0
save_calls=0
save_firewall() { save_calls=$((save_calls + 1)); }
ufw() { return 1; }
firewall-cmd() { return 1; }
iptables() {
    if [ "${1:-}" = -w ]; then shift 2; fi
    local operation="$1" proto="$4"
    case "$operation:$proto" in
        -C:tcp) [ "$tcp_present" -eq 1 ] ;;
        -C:udp) [ "$udp_present" -eq 1 ] ;;
        -I:udp) udp_present=1 ;;
        -D:udp) udp_present=0 ;;
        -D:tcp) fail 'preexisting TCP firewall rule was deleted' ;;
        *) fail "unexpected iptables command: $*" ;;
    esac
}
open_firewall 10000 >/dev/null
[ "$udp_present" -eq 1 ] || fail 'UDP firewall rule not opened'
grep -qxF '10000|iptables|udp' "$FIREWALL_FILE" || fail 'UDP firewall ownership missing'
if grep -q '|tcp$' "$FIREWALL_FILE"; then fail 'preexisting TCP rule marked as owned'; fi
close_firewall 10000 >/dev/null
[ "$udp_present" -eq 0 ] || fail 'owned UDP firewall rule not removed'
[ "$tcp_present" -eq 1 ] || fail 'preexisting TCP firewall rule changed'

# 若管理员已手动删掉 iptables 规则，close_firewall 不应报错或残留僵尸记录
printf '10000|iptables|udp\n' > "$FIREWALL_FILE"
close_firewall 10000 >/dev/null
if grep -q '^10000|' "$FIREWALL_FILE"; then fail 'stale iptables firewall record kept after manual removal'; fi

# ufw: DENY 规则和限制来源 IP 的规则不应被当成已放行；裸端口 ALLOW Anywhere 应被识别
ufw_allowed=""
ufw() {
    if [ "${1:-}" = status ]; then
        printf 'Status: active\n\nTo                         Action      From\n--                         ------      ----\n10000/tcp                  DENY        Anywhere\n10000/udp                  ALLOW       10.0.0.1\n10001                      ALLOW       Anywhere\n'
        return 0
    elif [ "${1:-}" = allow ]; then
        ufw_allowed="${ufw_allowed}${2} "
        return 0
    fi
    return 0
}
: > "$FIREWALL_FILE"
open_firewall 10000 >/dev/null
case "$ufw_allowed" in
    *"10000/tcp"*) ;;
    *) fail 'ufw DENY rule tricked open_firewall into skipping 10000/tcp' ;;
esac
case "$ufw_allowed" in
    *"10000/udp"*) ;;
    *) fail 'ufw IP-restricted rule tricked open_firewall into skipping 10000/udp' ;;
esac
ufw_allowed=""
open_firewall 10001 >/dev/null
[ -z "$ufw_allowed" ] || fail "ufw bare port rule was not recognized: $ufw_allowed"

# firewalld: 仅变更时 reload，且删双协议只 reload 一次
ufw() { return 1; }
fw_tcp=0
fw_udp=0
fw_reloads=0
firewall-cmd() {
    case "${1:-}" in
        --state) return 0 ;;
        --reload) fw_reloads=$((fw_reloads + 1)); return 0 ;;
        --permanent)
            case "${2:-}" in
                --query-port=10000/tcp) [ "$fw_tcp" -eq 1 ] ;;
                --query-port=10000/udp) [ "$fw_udp" -eq 1 ] ;;
                --add-port=10000/tcp) fw_tcp=1 ;;
                --add-port=10000/udp) fw_udp=1 ;;
                --remove-port=10000/tcp) fw_tcp=0 ;;
                --remove-port=10000/udp) fw_udp=0 ;;
                *) return 1 ;;
            esac
            ;;
        --query-port=10000/tcp) [ "$fw_tcp" -eq 1 ] ;;
        --query-port=10000/udp) [ "$fw_udp" -eq 1 ] ;;
        *) return 1 ;;
    esac
}
: > "$FIREWALL_FILE"
open_firewall 10000 >/dev/null
[ "$fw_tcp" -eq 1 ] && [ "$fw_udp" -eq 1 ] || fail 'firewalld did not open tcp+udp'
[ "$fw_reloads" -eq 1 ] || fail "firewalld expected 1 reload on open, got $fw_reloads"
# 已放行时重复调用不应再 reload
open_firewall 10000 >/dev/null
[ "$fw_reloads" -eq 1 ] || fail "firewalld reloaded unnecessarily when already open ($fw_reloads)"
close_firewall 10000 >/dev/null
[ "$fw_tcp" -eq 0 ] && [ "$fw_udp" -eq 0 ] || fail 'firewalld did not close tcp+udp'
[ "$fw_reloads" -eq 2 ] || fail "firewalld expected 1 reload on close (total 2), got $fw_reloads"
firewall-cmd() { return 1; }

# save_firewall 0 绝不应调用 apt-get install
eval "$original_save_firewall"
PKG_MGR="apt-get"
fake_sf="$tmp/fake_sf"
mkdir -p "$fake_sf"
printf '#!/bin/sh\nexit 0\n' > "$fake_sf/iptables-save"
printf '#!/bin/sh\necho APT_CALLED >&2; exit 1\n' > "$fake_sf/apt-get"
chmod +x "$fake_sf/iptables-save" "$fake_sf/apt-get"
sf_err="$(PATH="$fake_sf" save_firewall 0 2>&1)"
case "$sf_err" in
    *APT_CALLED*) fail 'save_firewall 0 unexpectedly called apt-get' ;;
esac
save_firewall() { :; }

# port_holder 同时检测 TCP 和 UDP 端口占用
ss() {
    case "${1:-}" in
        -tlnpH) printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n' ;;
        -ulnpH) printf 'UNCONN 0 0 0.0.0.0:51820 0.0.0.0:* users:(("wg",pid=2,fd=4))\n' ;;
    esac
}
[ -n "$(port_holder 22)" ] || fail 'port_holder missed TCP port'
[ -n "$(port_holder 51820)" ] || fail 'port_holder missed UDP port'
[ -z "$(port_holder 12345)" ] || fail 'port_holder falsely reported free port'
ss() { printf 'LISTEN 0 128 0.0.0.0:10000 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:10001 0.0.0.0:*\n'; }

# ---------- 6. install_shortcut 同文件保护 ----------
printf '#!/bin/bash\n# dummy\n' > "$SHORTCUT"
chmod +x "$SHORTCUT"
(
    exec -a "$SHORTCUT" bash -c 'source ./install.sh; SHORTCUT="'"$SHORTCUT"'"; install_shortcut'
) || fail 'install_shortcut failed on same-file copy'
grep -q '# dummy' "$SHORTCUT" || fail 'install_shortcut truncated file'

# ---------- 7. do_uninstall 清理孤儿防火墙记录与全部文件 ----------
closed_ports=""
close_firewall() { closed_ports="${closed_ports}${1} "; }
systemctl() { return 0; }
INIT_SYSTEM="systemd"
mkdir -p "$CONF_DIR"
printf '10000|1.2.3.4|443|keep\n' > "$RULES_FILE"
printf '10000|iptables|tcp\n20000|iptables|udp\n' > "$FIREWALL_FILE"
UNINSTALL_CONFIRM=yes do_uninstall >/dev/null || fail 'do_uninstall failed'
case "$closed_ports" in
    *"10000"*) ;;
    *) fail 'do_uninstall missed active rule port 10000' ;;
esac
case "$closed_ports" in
    *"20000"*) ;;
    *) fail 'do_uninstall missed orphan firewall port 20000' ;;
esac
[ ! -e "$BIN_PATH" ] && [ ! -e "$SHORTCUT" ] && [ ! -e "$CONF_DIR" ] || fail 'do_uninstall left files behind'
mkdir -p "$CONF_DIR"
close_firewall() { :; }

# ---------- 8. 升级失败回滚 ----------
printf '10000|1.2.3.4|443|first\n' >> "$RULES_FILE"
printf '#!/bin/sh\necho old\n' > "$BIN_PATH"
chmod +x "$BIN_PATH"
need_root() { :; }
detect_os() { :; }
install_deps() { :; }
write_service() { :; }
install_realm_bin() { printf '#!/bin/sh\necho new\n' > "$BIN_PATH"; chmod +x "$BIN_PATH"; }
restart_count=0
service_restart() {
    restart_count=$((restart_count + 1))
    [ "$restart_count" -gt 1 ]
}
if do_install >/dev/null 2>&1; then fail 'failed upgrade reported success'; fi
grep -q 'echo old' "$BIN_PATH" || fail 'previous realm binary not restored'
[ "$restart_count" -eq 2 ] || fail 'previous realm service not restarted'

printf 'PASS: validation, rules, rollback, EOF, port ownership, firewall, hop rollback, shortcut, upgrade recovery\n'
