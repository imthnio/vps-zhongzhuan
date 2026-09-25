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
BIN_PATH="$tmp/realm-bin"
printf '#!/bin/sh\nexit 0\n' > "$BIN_PATH"
chmod +x "$BIN_PATH"

restart_ok=1
original_open_firewall="$(declare -f open_firewall)"
original_close_firewall="$(declare -f close_firewall)"
service_restart() { [ "$restart_ok" -eq 1 ]; }
service_stop() { [ "$restart_ok" -eq 1 ]; }
service_is_active() { [ "$restart_ok" -eq 1 ]; }
ss() { printf 'LISTEN 0 128 0.0.0.0:10000 0.0.0.0:*\n'; }
sleep() { :; }
get_public_ip() { :; }
open_firewall() { :; }
close_firewall() { :; }
save_firewall() { :; }

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

printf 'PASS: rules, rollback, EOF, firewall ownership, upgrade recovery\n'
