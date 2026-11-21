#!/bin/bash
# ZAPRET CONTROL - macOS client
#
# Modes:
#   local - run native tpws DPI engine locally on this Mac (standalone, no Windows host needed)
#   lan   - route this Mac through a LAN proxy on a Windows host running zapret/winws
#
# Usage:
#   ./zapret-proxy.command                  # interactive menu
#   ./zapret-proxy.command --local          # local mode (native tpws engine)
#   ./zapret-proxy.command --on 192.168.1.10
#   ./zapret-proxy.command --off
#   ./zapret-proxy.command --restart
#   ./zapret-proxy.command --status
#   ./zapret-proxy.command --test [IP]
#   ./zapret-proxy.command --doctor
#   ./zapret-proxy.command --logs [N]
#   ./zapret-proxy.command --install | --uninstall
#   ./zapret-proxy.command --autostart on|off
#   ./zapret-proxy.command --service "Wi-Fi"
#   ./zapret-proxy.command --http-port 8080 --socks-port 1080
#   ./zapret-proxy.command --desync "ARGS"
#   ./zapret-proxy.command --build-engine
#   ./zapret-proxy.command --version
set -u

APP_NAME="ZAPRET CONTROL"
APP_VERSION="0.5.0"
ENGINE_NAME="tpws"
DEFAULT_HTTP_PORT=8080
DEFAULT_SOCKS_PORT=1080
HTTP_PORT=$DEFAULT_HTTP_PORT
SOCKS_PORT=$DEFAULT_SOCKS_PORT
# Default DPI-desync profile for tpws (SOCKS mode). Can be overridden with --desync.
DEFAULT_DESYNC="--split-pos=1,midsld --disorder --tlsrec=midsld+1"
DESYNC_ARGS="$DEFAULT_DESYNC"
BYPASS_DOMAINS="localhost 127.0.0.1 *.local 192.168.* 10.* 172.16.* 172.17.* 172.18.* 172.19.* 172.2*.* 172.30.* 172.31.*"
DEFAULT_SERVICE="Wi-Fi"
LOCAL_HOST="127.0.0.1"
LAUNCHD_LABEL="com.zapretcontrol.proxy"

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

# ---------- helpers ----------

die() { echo "Error: $*" >&2; exit 1; }

need_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "This client is for macOS only (detected $(uname -s))"
    command -v networksetup >/dev/null 2>&1 || die "networksetup not found"
}

real_user() {
    local user="${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null)}"
    if [ -n "$user" ] && [ "$user" != "root" ]; then echo "$user"; fi
}

real_home() {
    # Test/sim override
    if [ -n "${SIM_HOME:-}" ]; then echo "$SIM_HOME"; return; fi
    local user home
    user=$(real_user)
    if [ -n "$user" ]; then
        home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        [ -n "$home" ] && { echo "$home"; return; }
    fi
    echo "$HOME"
}

real_uid() {
    local user; user=$(real_user); [ -n "$user" ] || return 1; id -u "$user" 2>/dev/null
}

conf_dir() { echo "$(real_home)/Library/Application Support/ZapretControl"; }
conf_file() { echo "$(conf_dir)/proxy.conf"; }
app_dir() { echo "$(real_home)/Applications/ZapretControl"; }
plist_file() { echo "$(real_home)/Library/LaunchAgents/$LAUNCHD_LABEL.plist"; }
log_file() { echo "$(conf_dir)/proxy.log"; }
pid_file() { echo "$(conf_dir)/proxy.pid"; }
bridge_pid_file() { echo "$(conf_dir)/bridge.pid"; }

installed_engine() { echo "$(app_dir)/bin/tpws"; }
installed_bridge() { echo "$(app_dir)/lib/http-bridge.pl"; }

load_conf() {
    MODE="lan"; HOST=""; SERVICE="$DEFAULT_SERVICE"; DESYNC_ARGS="$DEFAULT_DESYNC"
    HTTP_PORT=$DEFAULT_HTTP_PORT; SOCKS_PORT=$DEFAULT_SOCKS_PORT
    local file key value
    file=$(conf_file); [ -f "$file" ] || return 0
    while IFS='=' read -r key value; do
        value=$(printf '%s' "$value" | sed 's/^"//; s/"$//')
        case "$key" in
            MODE) [ "$value" = "local" ] && MODE="local" || MODE="lan" ;;
            HOST) HOST="$value" ;;
            SERVICE) [ -n "$value" ] && SERVICE="$value" ;;
            DESYNC_ARGS) [ -n "$value" ] && DESYNC_ARGS="$value" ;;
            HTTP_PORT) case "$value" in ''|*[!0-9]*) ;; *) HTTP_PORT="$value" ;; esac ;;
            SOCKS_PORT) case "$value" in ''|*[!0-9]*) ;; *) SOCKS_PORT="$value" ;; esac ;;
            # legacy keys (ignored, kept for compatibility)
            SPLIT|DELAY) : ;;
        esac
    done <"$file"
    [ -n "${SERVICE:-}" ] || SERVICE="$DEFAULT_SERVICE"
}

save_conf() {
    local dir file owner
    dir=$(conf_dir); file=$(conf_file)
    mkdir -p "$dir" || return 1
    {
        echo "# ZAPRET CONTROL macOS client"
        echo "MODE=\"$MODE\""
        echo "HOST=\"${HOST:-}\""
        echo "SERVICE=\"$SERVICE\""
        echo "HTTP_PORT=\"$HTTP_PORT\""
        echo "SOCKS_PORT=\"$SOCKS_PORT\""
        echo "DESYNC_ARGS=\"$DESYNC_ARGS\""
    } >"$file"
    owner=$(real_user)
    if [ -n "$owner" ]; then chown "$owner" "$file" "$dir" 2>/dev/null || true; fi
}

valid_host() {
    case "$1" in ''|-*|*[!A-Za-z0-9._:-]*) return 1 ;; *) return 0 ;; esac
}

list_services() {
    networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//'
}

set_proxy() {
    local host _service
    host="${1:-}"; _service="${2:-${SERVICE:-$DEFAULT_SERVICE}}"
    networksetup -setwebproxy "$_service" "$host" "$HTTP_PORT" >/dev/null 2>&1
    networksetup -setsecurewebproxy "$_service" "$host" "$HTTP_PORT" >/dev/null 2>&1
    networksetup -setsocksfirewallproxy "$_service" "$host" "$SOCKS_PORT" >/dev/null 2>&1
    networksetup -setproxybypassdomains "$_service" $BYPASS_DOMAINS >/dev/null 2>&1
    echo "Proxy set for '${_service}': HTTP ${host}:$HTTP_PORT, SOCKS5 ${host}:$SOCKS_PORT"
}

unset_proxy() {
    local _service="${1:-${SERVICE:-$DEFAULT_SERVICE}}"
    networksetup -setwebproxystate "$_service" off >/dev/null 2>&1
    networksetup -setsecurewebproxystate "$_service" off >/dev/null 2>&1
    networksetup -setsocksfirewallproxystate "$_service" off >/dev/null 2>&1
    echo "Proxy disabled for '${_service}'"
}

mode_label() {
    if [ "$MODE" = "local" ]; then echo "local (native tpws engine on this Mac)"
    elif [ -n "${HOST:-}" ]; then echo "LAN (Windows host $HOST)"
    else echo "not configured"; fi
}

read_pid() { local f="$1"; [ -f "$f" ] || return 1; local p; p=$(tr -dc '0-9' <"$f" | head -n1); [ -n "$p" ] || return 1; echo "$p"; }
proc_running() { local p; p=$(read_pid "$1") || return 1; kill -0 "$p" 2>/dev/null; }

daemon_label() {
    if proc_running "$(pid_file)"; then echo "running (pid $(read_pid "$(pid_file)"))"; else echo "stopped"; fi
}

# ---------- engine / bridge discovery ----------

find_engine() {
    local c
    for c in \
        "$SELF_DIR/bin/tpws" \
        "$SELF_DIR/../bin/tpws" \
        "$(installed_engine)" \
        "$SELF_DIR/engine/bin/tpws" \
        "$SELF_DIR/../Resources/bin/tpws" \
        "$SELF_DIR/../Resources/tpws"
    do
        [ -x "$c" ] && { echo "$c"; return 0; }
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

find_bridge() {
    local c
    for c in \
        "$SELF_DIR/lib/http-bridge.pl" \
        "$SELF_DIR/../lib/http-bridge.pl" \
        "$(installed_bridge)" \
        "$SELF_DIR/../Resources/lib/http-bridge.pl"
    do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

build_engine() {
    local bdir="$SELF_DIR/engine"
    [ -d "$bdir/tpws-src" ] || bdir="$SELF_DIR/../engine"
    [ -d "$bdir/tpws-src" ] || die "Engine sources not found (expected macos/engine/tpws-src)"
    command -v make >/dev/null 2>&1 || die "'make' not found. Install Xcode Command Line Tools: xcode-select --install"
    command -v cc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || die "C compiler not found. Install Xcode Command Line Tools: xcode-select --install"
    echo "Building native tpws engine..."
    ( cd "$bdir/tpws-src" && make clean >/dev/null 2>&1 || true; make mac ) || ( cd "$bdir/tpws-src" && make bsd ) || ( cd "$bdir/tpws-src" && make )
    mkdir -p "$SELF_DIR/bin" "$bdir/../bin" 2>/dev/null || true
    cp -f "$bdir/tpws-src/tpws" "$SELF_DIR/bin/tpws" 2>/dev/null || cp -f "$bdir/tpws-src/tpws" "$bdir/bin/tpws"
    chmod +x "$SELF_DIR/bin/tpws" 2>/dev/null || true
    echo "Engine built: $(find_engine 2>/dev/null || echo "$SELF_DIR/bin/tpws")"
}

# ---------- launchd ----------

launchd_load() {
    local plist uid; plist=$(plist_file); [ -f "$plist" ] || return 1
    launchctl load -w "$plist" >/dev/null 2>&1 && return 0
    uid=$(real_uid) || uid=$(id -u)
    launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1
}

launchd_unload() {
    local plist uid; plist=$(plist_file); [ -f "$plist" ] || return 1
    uid=$(real_uid) || uid=$(id -u)
    launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1 && return 0
    launchctl unload -w "$plist" >/dev/null 2>&1
}

write_plist() {
    local owner cli
    cli="$(app_dir)/zapret-proxy.command"
    [ -f "$cli" ] || cli="$SELF_DIR/$(basename "$0")"
    mkdir -p "$(dirname "$(plist_file)")" || return 1
    cat >"$(plist_file)" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$cli</string>
    <string>--local</string>
    <string>--foreground-launchd</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$(log_file)</string>
  <key>StandardErrorPath</key><string>$(log_file)</string>
</dict>
</plist>
EOF
    owner=$(real_user); [ -n "$owner" ] && chown "$owner" "$(plist_file)" 2>/dev/null || true
}

# ---------- daemon control (local tpws engine) ----------

stop_proc() {
    local pf="$1" p i
    p=$(read_pid "$pf") || { rm -f "$pf"; return 0; }
    if kill -0 "$p" 2>/dev/null; then
        kill -TERM "$p" 2>/dev/null || true
        i=0; while [ "$i" -lt 30 ] && kill -0 "$p" 2>/dev/null; do i=$((i+1)); sleep 0.1; done
        kill -KILL "$p" 2>/dev/null || true
    fi
    rm -f "$pf"
}

stop_daemon() {
    if [ -f "$(plist_file)" ]; then launchd_unload || true; fi
    stop_proc "$(bridge_pid_file)"
    stop_proc "$(pid_file)"
}

start_daemon() {
    local engine bridge owner i
    engine=$(find_engine) || die "Native tpws engine not found. Run: $0 --build-engine (requires Xcode CLT on macOS) or place tpws in macos/bin/"
    [ -x "$engine" ] || chmod +x "$engine" 2>/dev/null || true
    if proc_running "$(pid_file)"; then
        echo "Local engine already running (pid $(read_pid "$(pid_file)"))."; return 0
    fi
    mkdir -p "$(conf_dir)" || true
    owner=$(real_user)

    # Start tpws (SOCKS5 DPI-desync proxy) - the macOS DPI core
    # shellcheck disable=SC2086
    nohup "$engine" --socks --bind-addr=127.0.0.1 --port="$SOCKS_PORT" $DESYNC_ARGS \
        --pidfile="$(pid_file)" >>"$(log_file)" 2>&1 &
    sleep 0.2

    # HTTP CONNECT bridge -> local tpws SOCKS (for system HTTP/HTTPS proxy settings)
    bridge=$(find_bridge 2>/dev/null || true)
    if [ -n "$bridge" ]; then
        if [ -n "$owner" ]; then
            sudo -u "$owner" nohup perl "$bridge" --listen 127.0.0.1 --port "$HTTP_PORT" --socks 127.0.0.1 --socks-port "$SOCKS_PORT" --pid "$(bridge_pid_file)" >>"$(log_file)" 2>&1 &
        else
            nohup perl "$bridge" --listen 127.0.0.1 --port "$HTTP_PORT" --socks 127.0.0.1 --socks-port "$SOCKS_PORT" --pid "$(bridge_pid_file)" >>"$(log_file)" 2>&1 &
        fi
    else
        echo "Warning: HTTP bridge not found; only SOCKS5 proxy on port $SOCKS_PORT will be available." >&2
    fi

    i=0
    while [ "$i" -lt 50 ]; do
        if proc_running "$(pid_file)"; then
            echo "Local tpws engine started (pid $(read_pid "$(pid_file)"))."; return 0
        fi
        i=$((i+1)); sleep 0.1
    done
    echo "Failed to start tpws engine. See: $(log_file)" >&2
    tail -n 10 "$(log_file)" 2>/dev/null >&2 || true
    return 1
}

# ---------- actions ----------

show_status() {
    local service="${1:-$SERVICE}"
    echo "Mode: $(mode_label)"
    echo "Engine: $(daemon_label)"
    if proc_running "$(bridge_pid_file)"; then echo "HTTP bridge: running (pid $(read_pid "$(bridge_pid_file)"))"; else echo "HTTP bridge: stopped"; fi
    if [ -f "$(plist_file)" ]; then echo "Autostart: enabled"; else echo "Autostart: disabled"; fi
    echo "Service: $service"
    echo "Ports: HTTP $HTTP_PORT, SOCKS5 $SOCKS_PORT"
    echo "Desync: $DESYNC_ARGS"
    echo "--- HTTP ---"; networksetup -getwebproxy "$service" 2>/dev/null || true
    echo "--- HTTPS ---"; networksetup -getsecurewebproxy "$service" 2>/dev/null || true
    echo "--- SOCKS5 ---"; networksetup -getsocksfirewallproxy "$service" 2>/dev/null || true
}

run_doctor() {
    local ok=0 warn=0 bad=0 eng
    echo "=== $APP_NAME macOS $APP_VERSION - doctor ==="
    echo "Platform: $(uname -s) $(uname -m 2>/dev/null || echo '')"
    if [ "$(uname -s)" = "Darwin" ]; then echo "[OK] macOS"; ok=$((ok+1)); else echo "[!!] Not macOS"; bad=$((bad+1)); fi
    if eng=$(find_engine 2>/dev/null); then echo "[OK] tpws engine: $eng"; ok=$((ok+1)); else echo "[--] tpws engine not found (run --build-engine)"; warn=$((warn+1)); fi
    if find_bridge >/dev/null 2>&1; then echo "[OK] HTTP bridge present"; ok=$((ok+1)); else echo "[--] HTTP bridge missing (SOCKS-only)"; warn=$((warn+1)); fi
    command -v perl >/dev/null 2>&1 && { echo "[OK] perl"; ok=$((ok+1)); } || { echo "[--] perl missing"; warn=$((warn+1)); }
    command -v curl >/dev/null 2>&1 && { echo "[OK] curl"; ok=$((ok+1)); } || { echo "[--] curl missing"; warn=$((warn+1)); }
    command -v networksetup >/dev/null 2>&1 && { echo "[OK] networksetup"; ok=$((ok+1)); } || { echo "[!!] networksetup missing"; bad=$((bad+1)); }
    echo "[..] Mode: $(mode_label), service: $SERVICE, HTTP:$HTTP_PORT SOCKS:$SOCKS_PORT"
    echo "[..] Engine: $(daemon_label)"
    [ -f "$(conf_file)" ] && { echo "[OK] Config: $(conf_file)"; ok=$((ok+1)); } || echo "[--] No config yet"
    [ -f "$(plist_file)" ] && { echo "[OK] Autostart plist present"; ok=$((ok+1)); } || echo "[--] Autostart disabled"
    [ -f "$(log_file)" ] && { echo "[OK] Log: $(log_file)"; ok=$((ok+1)); } || echo "[--] No log yet"
    echo "Summary: ok=$ok warn=$warn bad=$bad"
    [ "$bad" -eq 0 ]
}

show_logs() {
    local n="${1:-40}" file; file=$(log_file)
    [ -f "$file" ] || { echo "No log file yet: $file"; return 1; }
    echo "=== $(basename "$file") (last $n lines) ==="
    tail -n "$n" "$file"
}

test_proxy() {
    local host="$1" code yt
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -x "http://$host:$HTTP_PORT" "http://example.com" 2>/dev/null)
    if [ "$code" = "200" ]; then
        echo "Proxy $host:$HTTP_PORT reachable (HTTP 200)."
        yt=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -x "http://$host:$HTTP_PORT" "https://www.youtube.com/generate_204" 2>/dev/null)
        echo "YouTube via proxy: HTTP $yt (204 = OK)"
        return 0
    fi
    echo "Proxy $host:$HTTP_PORT not reachable (code '$code')."
    if [ "$MODE" = "local" ]; then echo "Check engine/logs: $(log_file)"; else echo "Check Windows host/proxy and firewall."; fi
    return 1
}

enable_autostart() {
    [ "$MODE" = "local" ] || die "Autostart is supported in local mode (run --local first)"
    [ -f "$(app_dir)/zapret-proxy.command" ] || echo "Tip: run --install for a stable autostart path" >&2
    write_plist || die "Failed to write launchd plist"
    launchd_load || true
    echo "Autostart enabled."
}

disable_autostart() {
    if [ -f "$(plist_file)" ]; then launchd_unload || true; rm -f "$(plist_file)"; echo "Autostart disabled."; else echo "Autostart already disabled."; fi
}

install_client() {
    local dir src
    dir="$(app_dir)"; src="$SELF_DIR"
    mkdir -p "$dir/lib" "$dir/bin" "$dir/engine" || die "Cannot create $dir"
    cp "$src/$(basename "$0")" "$dir/zapret-proxy.command" || die "Copy failed"
    [ -f "$src/lib/http-bridge.pl" ] && cp "$src/lib/http-bridge.pl" "$dir/lib/http-bridge.pl"
    [ -f "$src/lib/desync-proxy.pl" ] && cp "$src/lib/desync-proxy.pl" "$dir/lib/desync-proxy.pl"
    [ -f "$src/README.md" ] && cp "$src/README.md" "$dir/README.md"
    if eng=$(find_engine 2>/dev/null); then cp "$eng" "$dir/bin/tpws" 2>/dev/null || true; fi
    chmod +x "$dir/zapret-proxy.command" "$dir/bin/tpws" "$dir/lib"/*.pl 2>/dev/null || true
    echo "Installed to $dir"; echo "Run: $dir/zapret-proxy.command"
}

uninstall_client() {
    stop_daemon
    disable_autostart
    local d
    for d in "$(app_dir)" "$(real_home)/Applications/ZapretControl"; do
        case "$d" in
            */Applications/ZapretControl) [ -d "$d" ] && rm -rf "$d" && echo "Removed $d" ;;
        esac
    done
}

do_restart() {
    if [ "$MODE" = "local" ]; then
        stop_daemon; save_conf; start_daemon || exit 1; set_proxy "$LOCAL_HOST" "$SERVICE"; echo "Local mode restarted."; return 0
    fi
    [ -n "${HOST:-}" ] || die "No mode configured: use --local or --on <IP>"
    stop_daemon; set_proxy "$HOST" "$SERVICE"; echo "LAN proxy reapplied ($HOST)."
}

# ---------- args ----------

need_macos
load_conf

ORIG_ARGS=("$@")
ACTION=""; ARG_HOST=""; ARG_SERVICE=""; ARG_AUTOSTART=""; ARG_DESYNC=""; ARG_HTTP_PORT=""; ARG_SOCKS_PORT=""; ARG_LOGS="40"; ARG_LAUNCHD_FG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --on|--lan) ACTION="on"; [ $# -ge 2 ] && { ARG_HOST="$2"; shift; } ;;
        --local) ACTION="local" ;;
        --off) ACTION="off" ;;
        --restart) ACTION="restart" ;;
        --status) ACTION="status" ;;
        --doctor) ACTION="doctor" ;;
        --test) ACTION="test"; [ $# -ge 2 ] && case "$2" in -*|"") ;; *) ARG_HOST="$2"; shift ;; esac ;;
        --logs|--log) ACTION="logs"; [ $# -ge 2 ] && case "$2" in ''|*[!0-9]*) ;; *) ARG_LOGS="$2"; shift ;; esac ;;
        --service) [ $# -ge 2 ] && { ARG_SERVICE="$2"; shift; } ;;
        --install) ACTION="install" ;;
        --uninstall) ACTION="uninstall" ;;
        --build-engine) ACTION="build-engine" ;;
        --autostart) ACTION="autostart"; [ $# -ge 2 ] && { ARG_AUTOSTART="$2"; shift; } ;;
        --desync) [ $# -ge 2 ] && { ARG_DESYNC="$2"; shift; } ;;
        --http-port) [ $# -ge 2 ] && { ARG_HTTP_PORT="$2"; shift; } ;;
        --socks-port) [ $# -ge 2 ] && { ARG_SOCKS_PORT="$2"; shift; } ;;
        --foreground-launchd) ARG_LAUNCHD_FG=1 ;; # internal
        --split|--delay) [ $# -ge 2 ] && shift ;; # legacy, ignored
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -V|--version) echo "$APP_NAME macOS client $APP_VERSION (engine: tpws)"; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

[ -n "$ARG_HOST" ] && { valid_host "$ARG_HOST" || die "Invalid host: $ARG_HOST"; }
[ -n "$ARG_SERVICE" ] && SERVICE="$ARG_SERVICE"
[ -n "$ARG_DESYNC" ] && DESYNC_ARGS="$ARG_DESYNC"
[ -n "$ARG_HTTP_PORT" ] && { case "$ARG_HTTP_PORT" in ''|*[!0-9]*) die "Invalid --http-port" ;; esac; HTTP_PORT="$ARG_HTTP_PORT"; }
[ -n "$ARG_SOCKS_PORT" ] && { case "$ARG_SOCKS_PORT" in ''|*[!0-9]*) die "Invalid --socks-port" ;; esac; SOCKS_PORT="$ARG_SOCKS_PORT"; }

# Re-exec with sudo for actions that change system proxy or manage daemons
case "$ACTION" in
    ""|on|local|off|restart|status|test|uninstall)
        if [ "$(id -u)" -ne 0 ]; then exec sudo -p "Admin password: " "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}; fi
        ;;
esac

case "$ACTION" in
    build-engine) build_engine; exit 0 ;;
    install) install_client; exit 0 ;;
    uninstall) unset_proxy "$SERVICE" 2>/dev/null || true; uninstall_client; exit 0 ;;
    autostart)
        case "$ARG_AUTOSTART" in on) enable_autostart ;; off) disable_autostart ;; *) die "Usage: --autostart on|off" ;; esac; exit 0 ;;
    status) show_status "$SERVICE"; exit 0 ;;
    doctor) run_doctor; exit $? ;;
    logs) show_logs "$ARG_LOGS"; exit $? ;;
    restart) do_restart; exit $? ;;
    off) stop_daemon; unset_proxy "$SERVICE"; exit 0 ;;
    local)
        MODE="local"; save_conf
        if [ -n "$ARG_LAUNCHD_FG" ]; then
            # under launchd KeepAlive: ensure engine runs in foreground-ish management
            stop_proc "$(bridge_pid_file)"; stop_proc "$(pid_file)"; start_daemon || exit 1; set_proxy "$LOCAL_HOST" "$SERVICE"
            # stay alive while engine runs
            while proc_running "$(pid_file)"; do sleep 5; done
            exit 1
        fi
        start_daemon || exit 1; set_proxy "$LOCAL_HOST" "$SERVICE"; exit 0 ;;
    on)
        MODE="lan"; HOST="${ARG_HOST:-$HOST}"; [ -n "$HOST" ] || die "Usage: --on 192.168.1.10"; valid_host "$HOST" || die "Invalid host: $HOST"
        stop_daemon; save_conf; set_proxy "$HOST" "$SERVICE"; exit 0 ;;
    test)
        TEST_HOST="${ARG_HOST:-}"; if [ -z "$TEST_HOST" ]; then if [ "$MODE" = "local" ]; then TEST_HOST="$LOCAL_HOST"; else TEST_HOST="$HOST"; fi; fi
        [ -n "$TEST_HOST" ] || die "No host: --test 192.168.1.10"; test_proxy "$TEST_HOST"; exit $? ;;
esac

# ---------- interactive menu ----------
ask_host() { local cur="${1:-}" ans; printf "Windows host IP%s: " "${cur:+ [$cur]}" >&2; read -r ans; [ -n "$ans" ] || ans="$cur"; valid_host "$ans" || die "Invalid host: $ans"; echo "$ans"; }
ask_service() {
    local cur="${1:-$SERVICE}" svcs i name ans
    svcs=$(list_services); [ -n "$svcs" ] || die "No network services found"
    echo "Network services:" >&2; i=1
    while IFS= read -r name; do [ -n "$name" ] || continue; printf "  %d) %s\n" "$i" "$name" >&2; i=$((i+1)); done <<EOF
$svcs
EOF
    printf "Select service [current: %s]: " "$cur" >&2; read -r ans; [ -n "$ans" ] || { echo "$cur"; return; }
    name=$(echo "$svcs" | sed -n "${ans}p"); [ -n "$name" ] || die "No such service: $ans"; echo "$name"
}

while true; do
    echo; echo "=== $APP_NAME - macOS $APP_VERSION ==="; echo "Mode: $(mode_label)"; echo "Engine: $(daemon_label)"
    if [ -f "$(plist_file)" ]; then echo "Autostart: enabled"; else echo "Autostart: disabled"; fi
    echo "Service: $SERVICE"; echo
    echo "  1) LAN mode: use Windows zapret host"
    echo "  2) Local mode: native tpws engine (standalone)"
    echo "  3) Disable proxy"
    echo "  4) Restart current mode"
    echo "  5) Status"
    echo "  6) Test connection"
    echo "  7) Select network service"
    echo "  8) Show logs"
    echo "  9) Doctor"
    echo " 10) Install to ~/Applications"
    echo " 11) Autostart on/off"
    echo " 12) Build native engine"
    echo "  0) Exit"
    printf "Choice: "; read -r choice
    case "$choice" in
        1) HOST=$(ask_host "$HOST") || exit 1; MODE="lan"; stop_daemon; save_conf; set_proxy "$HOST" "$SERVICE"; test_proxy "$HOST" || true ;;
        2) MODE="local"; save_conf; start_daemon || true; set_proxy "$LOCAL_HOST" "$SERVICE"; test_proxy "$LOCAL_HOST" || true ;;
        3) stop_daemon; unset_proxy "$SERVICE" ;;
        4) do_restart || true ;;
        5) show_status "$SERVICE" ;;
        6) if [ "$MODE" = "local" ]; then test_proxy "$LOCAL_HOST" || true; elif [ -n "$HOST" ]; then test_proxy "$HOST" || true; else echo "No host configured"; fi ;;
        7) SERVICE=$(ask_service "$SERVICE") || exit 1; save_conf; echo "Service: $SERVICE" ;;
        8) show_logs 40 || true ;;
        9) run_doctor || true ;;
        10) install_client ;;
        11) if [ -f "$(plist_file)" ]; then disable_autostart; else enable_autostart || true; fi ;;
        12) build_engine || true ;;
        0|q|Q) echo "Bye."; exit 0 ;;
        *) echo "Unknown choice" ;;
    esac
done