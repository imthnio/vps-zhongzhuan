#!/bin/bash
set -u

cd "$(dirname "$0")" || exit 1
tmp="$(mktemp -d)" || exit 1
source ./install.sh
trap 'rm -rf "$tmp"; rm -f "$CURL_LOG"' EXIT
if [ "$(uname -s)" = Darwin ]; then
    sed() {
        if [ "${1:-}" = -i ]; then
            shift
            command sed -i '' "$@"
        else
            command sed "$@"
        fi
    }
fi
CONF_DIR="$tmp/realm"
CONF_FILE="$CONF_DIR/config.json"
RULES_FILE="$CONF_DIR/rules.list"
FIREWALL_FILE="$CONF_DIR/firewall.list"
HOP_FILE="$CONF_DIR/hop.list"
HOP_SCRIPT="$CONF_DIR/hop.sh"
BIN_PATH="$tmp/realm-bin"
printf '#!/bin/sh\nexit 0\n' > "$BIN_PATH"
chmod +x "$BIN_PATH"

restart_ok=1
original_open_firewall="$(declare -f open_firewall)"
original_close_firewall="$(declare -f close_firewall)"
service_restart() { [ "$restart_ok" -eq 1 ]; }
service_stop() { [ "$restart_ok" -eq 1 ]; }
service_is_active() { [ "$restart_ok" -eq 1 ]; }
ss() { printf 'LISTEN 0 128 0.0.0.0:10000 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:10001 0.0.0.0:*\n'; }
sleep() { :; }
get_public_ip() { :; }
open_firewall() { :; }
close_firewall() { :; }
save_firewall() { :; }
ensure_iptables() { :; }
hop_runs=0
run_hop_script() { hop_runs=$((hop_runs + 1)); }

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_rule() { grep -qxF "$1" "$RULES_FILE" || fail "expected rule: $1"; }

if ask_yes 'confirm' y </dev/null; then fail 'EOF was treated as yes'; fi

LISTEN_PORT=10000 TARGET_ADDR=1.2.3.4 TARGET_PORT=443 NOTE=first
add_rule >/dev/null || fail 'initial add'
expect_rule '10000|1.2.3.4|443|first'

restart_ok=0
TARGET_ADDR=5.6.7.8
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

NOTE=hy
HOP_RANGE=20000-50000
add_rule >/dev/null || fail 'add with port hopping'
grep -qxF '10000|20000|50000' "$HOP_FILE" || fail 'hop range not recorded'
grep -qF -- '--dport 20000:50000 -j REDIRECT --to-ports 10000' "$HOP_SCRIPT" || fail 'hop script missing redirect'
[ "$hop_runs" -gt 0 ] || fail 'hop script not run'
list_rules | grep -F '20000-50000' >/dev/null || fail 'hop range not listed'

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

LISTEN_PORT=10000 HOP_RANGE=
add_rule >/dev/null || fail 'overwrite without hopping'
if grep -q '^10000|' "$HOP_FILE"; then fail 'old hop range kept after overwrite'; fi
if grep -q REDIRECT "$HOP_SCRIPT"; then fail 'hop script still redirects'; fi

NOTE=second
add_rule >/dev/null || fail 'replacement add'
expect_rule '10000|5.6.7.8|443|second'
if grep -qF '1.2.3.4' "$RULES_FILE"; then fail 'old rule still present'; fi

del_rule >/dev/null || fail 'delete'
if grep -q '^10000|' "$RULES_FILE"; then fail 'deleted rule still present'; fi

eval "$original_open_firewall"
eval "$original_close_firewall"
tcp_present=1
udp_present=0
ufw() { return 1; }
firewall-cmd() { return 1; }
iptables() {
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

printf 'PASS: rules, rollback, EOF, firewall ownership, upgrade recovery, port hopping\n'
