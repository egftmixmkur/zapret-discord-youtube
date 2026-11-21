#!/bin/bash
# macOS client emulator tests for zapret-proxy.command (v0.5+ tpws + http-bridge architecture).
# Runs with stubbed macOS tools and stubbed engine/bridge; does not modify the real system.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
SCRIPT="$ROOT/zapret-proxy.command"
STUBS="$HERE/stubs"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  [OK]   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
expect_exit0() {
    if [ "$RC" -eq 0 ]; then
        ok "exit 0"
    else
        bad "exit $RC (expected 0)"
        echo "    --- output ---"; echo "$OUT" | sed 's/^/    | /'; echo "    --- end ---"
    fi
}
expect_fail() {
    if [ "$RC" -ne 0 ]; then ok "failed as expected ($RC)"; else bad "expected failure but got exit 0"; fi
}

cleanup_pids() {
    for pf in \
        "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" \
        "$SIM_HOME/Library/Application Support/ZapretControl/bridge.pid"
    do
        [ -f "$pf" ] || continue
        p=$(tr -dc '0-9' <"$pf" 2>/dev/null | head -n1)
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null || true
    done
}

setup() {
    if [ -n "${SIM_HOME:-}" ]; then cleanup_pids; fi
    SIM_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zapret-sim.XXXXXX")
    mkdir -p "$SIM_ROOT/home"
    export SIM_HOME="$SIM_ROOT/home"
    export SIM_USER="sdccd"
    export SIM_LOG="$SIM_ROOT/calls.log"
    export SIM_STATE="$SIM_ROOT/state.txt"
    export SIM_UID="${1:-501}"
    export HOME="$SIM_HOME"
    export PATH="$STUBS:$PATH"
    : >"$SIM_LOG"; : >"$SIM_STATE"

    # Provide a discoverable tpws engine stub for tests (find_engine checks $SELF_DIR/bin/tpws).
    mkdir -p "$ROOT/bin"
    cp "$STUBS/tpws" "$ROOT/bin/tpws"
    chmod +x "$ROOT/bin/tpws" "$SCRIPT" "$STUBS"/* "$ROOT/lib"/*.pl 2>/dev/null || true
}

flush_case() { : >"$SIM_LOG"; : >"$SIM_STATE"; }
run() { OUT=$(bash "$SCRIPT" "$@" 2>&1); RC=$?; }

log_has() { grep -qF -- "$1" "$SIM_LOG"; }
state_has() { grep -qF -- "$1" "$SIM_STATE"; }
conf_has() { grep -qF -- "$1" "$SIM_HOME/Library/Application Support/ZapretControl/proxy.conf" 2>/dev/null; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

echo "Testing macOS client: $SCRIPT"
echo

# --- 1. --help ---
echo "1) --help"
setup 501
run --help
expect_exit0
out_has "Usage:" && ok "shows usage" || bad "missing usage"
[ ! -s "$SIM_LOG" ] && ok "no system calls" || bad "unexpected calls: $(head -n1 "$SIM_LOG")"

# --- 2. --version ---
echo "2) --version"
run --version
expect_exit0
out_has "0.5.0" && ok "version 0.5.0" || bad "missing version"
out_has "tpws" && ok "mentions tpws engine" || bad "missing engine name"
[ ! -s "$SIM_LOG" ] && ok "no system calls" || bad "unexpected calls"

# --- 3. LAN mode --on ---
echo "3) --on 192.168.1.50 (elevate via sudo)"
setup 501
run --on 192.168.1.50
expect_exit0
log_has "sudo" && ok "used sudo for elevation" || bad "sudo not called"
log_has "-setwebproxy Wi-Fi 192.168.1.50 8080" && ok "HTTP proxy set" || bad "missing HTTP proxy"
log_has "-setsecurewebproxy Wi-Fi 192.168.1.50 8080" && ok "HTTPS proxy set" || bad "missing HTTPS proxy"
log_has "-setsocksfirewallproxy Wi-Fi 192.168.1.50 1080" && ok "SOCKS proxy set" || bad "missing SOCKS proxy"
log_has "-setproxybypassdomains Wi-Fi" && ok "bypass domains set" || bad "missing bypass domains"
state_has "setwebproxy|Wi-Fi|192.168.1.50|8080|on" && ok "state enabled" || bad "state not enabled"
conf_has 'MODE="lan"' && ok "config MODE=lan" || bad "MODE not saved"
conf_has 'HOST="192.168.1.50"' && ok "config host saved" || bad "host not saved"

# --- 4. --status in LAN mode ---
echo "4) --status (lan)"
run --status
expect_exit0
out_has "Mode: LAN" && ok "shows LAN mode" || bad "missing LAN mode"
out_has "Engine: stopped" && ok "engine stopped" || bad "engine status unexpected"
out_has "Enabled: Yes" && ok "proxy enabled" || bad "proxy not enabled"
out_has "Server: 192.168.1.50" && ok "host shown" || bad "host missing"
out_has "Port: 8080" && ok "HTTP port shown" || bad "port missing"

# --- 5. --test in LAN mode ---
echo "5) --test (lan)"
run --test
expect_exit0
out_has "reachable" && ok "proxy reachable" || bad "not reachable"
log_has "http://192.168.1.50:8080" && ok "curl via proxy" || bad "curl not via proxy"
log_has "youtube.com" && ok "YouTube probe" || bad "missing YouTube probe"

# --- 6. custom host/service ---
echo "6) --on hostname with --service"
flush_case
run --on my-pc.local --service "USB 10/100/1000 LAN"
expect_exit0
log_has "-setwebproxy USB 10/100/1000 LAN my-pc.local 8080" && ok "custom service used" || bad "service not applied"
conf_has 'HOST="my-pc.local"' && ok "hostname saved" || bad "hostname not saved"
conf_has 'SERVICE="USB 10/100/1000 LAN"' && ok "service saved" || bad "service not saved"

# --- 7. invalid host ---
echo "7) --on invalid host"
flush_case
run --on -evil
expect_fail
out_has "Invalid host" && ok "rejects invalid host" || bad "missing invalid host error"
[ ! -s "$SIM_LOG" ] && ok "no network changes" || bad "unexpected calls"

# --- 8. --off ---
echo "8) --off"
flush_case
run --off
expect_exit0
log_has "-setwebproxystate Wi-Fi off" || log_has "-setwebproxystate USB 10/100/1000 LAN off" && ok "HTTP disabled" || bad "HTTP not disabled"
log_has "-setsocksfirewallproxystate" && ok "SOCKS disabled" || bad "SOCKS not disabled"

# --- 9. --test without configured host ---
echo "9) --test without host"
setup 501
run --test
expect_fail
out_has "No host" && ok "reports missing host" || bad "missing host error"

# --- 10. --local mode (standalone tpws + bridge) ---
echo "10) --local"
setup 501
run --local
expect_exit0
log_has "sudo" && ok "elevated for local mode" || bad "missing sudo"
log_has "tpws " && ok "started tpws engine" || bad "tpws not started"
log_has "--socks" && ok "tpws in socks mode" || bad "missing --socks"
log_has "--port=1080" && ok "tpws socks port" || bad "missing socks port"
log_has "http-bridge.pl" && ok "started HTTP bridge" || bad "bridge not started"
log_has "--socks-port 1080" && ok "bridge targets tpws socks" || bad "bridge socks port mismatch"
state_has "setwebproxy|Wi-Fi|127.0.0.1|8080|on" && ok "HTTP -> 127.0.0.1:8080" || bad "HTTP proxy not local"
state_has "setsocksfirewallproxy|Wi-Fi|127.0.0.1|1080|on" && ok "SOCKS -> 127.0.0.1:1080" || bad "SOCKS proxy not local"
conf_has 'MODE="local"' && ok "config MODE=local" || bad "MODE not local"
tpid=$(cat "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" 2>/dev/null || true)
bpid=$(cat "$SIM_HOME/Library/Application Support/ZapretControl/bridge.pid" 2>/dev/null || true)
[ -n "${tpid:-}" ] && kill -0 "$tpid" 2>/dev/null && ok "tpws pid running ($tpid)" || bad "tpws pid missing/stopped"
[ -n "${bpid:-}" ] && kill -0 "$bpid" 2>/dev/null && ok "bridge pid running ($bpid)" || bad "bridge pid missing/stopped"

# --- 11. --status in local mode ---
echo "11) --status (local)"
run --status
expect_exit0
out_has "Mode: local" && ok "shows local mode" || bad "missing local mode"
out_has "Engine: running" && ok "engine running" || bad "engine not running"
out_has "HTTP bridge: running" && ok "bridge running" || bad "bridge not running"
out_has "Enabled: Yes" && ok "system proxy enabled" || bad "proxy disabled"
out_has "Server: 127.0.0.1" && ok "points to localhost" || bad "not localhost"

# --- 12. --off in local mode stops engine/bridge ---
echo "12) --off (local)"
run --off
expect_exit0
if [ -n "${tpid:-}" ] && kill -0 "$tpid" 2>/dev/null; then bad "tpws still running"; else ok "tpws stopped"; fi
if [ -n "${bpid:-}" ] && kill -0 "$bpid" 2>/dev/null; then bad "bridge still running"; else ok "bridge stopped"; fi
[ ! -f "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" ] && ok "tpws pidfile removed" || bad "tpws pidfile remains"
[ ! -f "$SIM_HOME/Library/Application Support/ZapretControl/bridge.pid" ] && ok "bridge pidfile removed" || bad "bridge pidfile remains"
state_has "setwebproxystate|Wi-Fi|||off" && ok "proxy disabled" || bad "proxy not disabled"

# --- 13. --install ---
echo "13) --install"
setup 501
run --install
expect_exit0
app="$SIM_HOME/Applications/ZapretControl"
[ -x "$app/zapret-proxy.command" ] && ok "CLI installed" || bad "CLI missing"
[ -f "$app/lib/http-bridge.pl" ] && ok "bridge installed" || bad "bridge missing"
[ -f "$app/README.md" ] && ok "README installed" || bad "README missing"
[ -x "$app/bin/tpws" ] || [ -f "$app/bin/tpws" ] && ok "tpws copied if available" || bad "tpws not copied"
if log_has "sudo"; then bad "install should not require sudo"; else ok "no sudo on install"; fi

# --- 14. --autostart ---
echo "14) --autostart"
setup 501
run --autostart on
expect_fail
out_has "local mode" && ok "autostart requires local mode" || bad "missing local-mode guard"
run --local
run --autostart on
expect_exit0
plist="$SIM_HOME/Library/LaunchAgents/com.zapretcontrol.proxy.plist"
[ -f "$plist" ] && ok "plist created" || bad "plist missing"
grep -q "com.zapretcontrol.proxy" "$plist" 2>/dev/null && ok "plist label ok" || bad "label missing"
grep -q "zapret-proxy.command" "$plist" 2>/dev/null && ok "plist runs CLI" || bad "CLI missing in plist"
grep -q -- "--local" "$plist" 2>/dev/null && ok "plist uses local mode" || bad "--local missing in plist"
log_has "launchctl" && ok "launchctl invoked" || bad "launchctl not invoked"
run --autostart off
expect_exit0
[ ! -f "$plist" ] && ok "plist removed" || bad "plist still present"

# --- 15. --uninstall ---
echo "15) --uninstall"
app="$SIM_HOME/Applications/ZapretControl"
run --install
run --uninstall
expect_exit0
[ ! -d "$app" ] && ok "app dir removed" || bad "app dir still exists"

# --- 16. --doctor and --logs ---
echo "16) --doctor / --logs"
setup 501
run --local
run --doctor
[ "$RC" -eq 0 ] && ok "doctor exit 0" || bad "doctor exit $RC"
out_has "doctor" && ok "doctor output" || bad "missing doctor header"
out_has "tpws engine" && ok "mentions engine" || bad "engine not mentioned"
out_has "HTTP bridge" && ok "mentions bridge" || bad "bridge not mentioned"
echo "log line 1" >>"$SIM_HOME/Library/Application Support/ZapretControl/proxy.log"
run --logs 20
expect_exit0
out_has "log line 1" && ok "shows logs" || bad "log line missing"
run --off

# --- 17. --restart in local mode ---
echo "17) --restart (local)"
setup 501
run --local
run --restart
expect_exit0
log_has "tpws " && ok "engine restarted" || bad "engine not restarted"
state_has "setwebproxy|Wi-Fi|127.0.0.1|8080|on" && ok "proxy reapplied" || bad "proxy not reapplied"
np=$(cat "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" 2>/dev/null || true)
[ -n "${np:-}" ] && kill -0 "$np" 2>/dev/null && ok "new engine running" || bad "engine not running after restart"
run --off

# --- 18. custom ports ---
echo "18) --local with custom ports"
setup 501
run --local --http-port 18080 --socks-port 11080
expect_exit0
state_has "setwebproxy|Wi-Fi|127.0.0.1|18080|on" && ok "HTTP custom port" || bad "HTTP port not custom"
state_has "setsocksfirewallproxy|Wi-Fi|127.0.0.1|11080|on" && ok "SOCKS custom port" || bad "SOCKS port not custom"
conf_has 'HTTP_PORT="18080"' && ok "saved HTTP port" || bad "HTTP port not saved"
conf_has 'SOCKS_PORT="11080"' && ok "saved SOCKS port" || bad "SOCKS port not saved"
log_has "--port=11080" && ok "tpws uses custom socks port" || bad "tpws port not custom"
log_has "--port 18080" && ok "bridge listens on custom HTTP port" || bad "bridge HTTP port not custom"
run --off

# --- 19. http-bridge selftest (via stub fast-path) ---
echo "19) http-bridge.pl --selftest"
out=$(perl "$ROOT/lib/http-bridge.pl" --selftest 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "selftest exit 0" || bad "selftest exit $rc"
printf '%s\n' "$out" | grep -q "selftest: OK" && ok "selftest output ok" || bad "missing selftest output"

# cleanup
if [ -n "${SIM_HOME:-}" ]; then cleanup_pids; fi
rm -f "$ROOT/bin/tpws" 2>/dev/null || true

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1