#!/bin/bash
# ZAPRET CONTROL — macOS client (beta).
#
# Два режима:
#   lan   — трафик Mac идёт через LAN-прокси Windows-ПК, где работает zapret.
#   local — локальный прокси на этом Mac с обходом DPI (split TLS ClientHello),
#           Windows-ПК не нужен.
#
# Использование:
#   ./zapret-proxy.command                  # меню
#   ./zapret-proxy.command --local          # локальный режим (без Windows)
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
#   ./zapret-proxy.command --version
set -u

APP_NAME="ZAPRET CONTROL"
APP_VERSION="0.3.1-beta"
DEFAULT_HTTP_PORT=8080
DEFAULT_SOCKS_PORT=1080
HTTP_PORT=$DEFAULT_HTTP_PORT
SOCKS_PORT=$DEFAULT_SOCKS_PORT
BYPASS_DOMAINS="localhost 127.0.0.1 *.local 192.168.* 10.* 172.16.* 172.17.* 172.18.* 172.19.* 172.2*.* 172.30.* 172.31.*"
DEFAULT_SERVICE="Wi-Fi"
LOCAL_HOST="127.0.0.1"
LAUNCHD_LABEL="com.zapretcontrol.proxy"

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_FILE="$SELF_DIR/lib/desync-proxy.pl"

# ---------- вспомогательные функции ----------

die() { echo "Ошибка: $*" >&2; exit 1; }

need_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "этот скрипт только для macOS (сейчас $(uname -s))"
    command -v networksetup >/dev/null 2>&1 || die "не найден networksetup"
}

# Под sudo $HOME указывает на /var/root, поэтому берём домашнюю папку
# настоящего пользователя.
real_user() {
    local user="${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null)}"
    if [ -n "$user" ] && [ "$user" != "root" ]; then
        echo "$user"
    fi
}

real_home() {
    local user home
    user=$(real_user)
    if [ -n "$user" ]; then
        home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        [ -n "$home" ] && { echo "$home"; return; }
    fi
    echo "$HOME"
}

real_uid() {
    local user
    user=$(real_user)
    [ -n "$user" ] || return 1
    id -u "$user" 2>/dev/null
}

conf_dir() { echo "$(real_home)/Library/Application Support/ZapretControl"; }
conf_file() { echo "$(conf_dir)/proxy.conf"; }
app_dir() { echo "$(real_home)/Applications/ZapretControl"; }
plist_file() { echo "$(real_home)/Library/LaunchAgents/$LAUNCHD_LABEL.plist"; }
log_file() { echo "$(conf_dir)/proxy.log"; }
pid_file() { echo "$(conf_dir)/proxy.pid"; }
installed_lib() { echo "$(app_dir)/lib/desync-proxy.pl"; }

load_conf() {
    MODE="lan"
    HOST=""
    SERVICE="$DEFAULT_SERVICE"
    SPLIT=0
    DELAY=0
    HTTP_PORT=$DEFAULT_HTTP_PORT
    SOCKS_PORT=$DEFAULT_SOCKS_PORT
    local file key value
    file=$(conf_file)
    [ -f "$file" ] || return 0
    while IFS='=' read -r key value; do
        value=$(printf '%s' "$value" | tr -d '"')
        case "$key" in
            MODE) [ "$value" = "local" ] && MODE="local" ;;
            HOST) HOST="$value" ;;
            SERVICE) [ -n "$value" ] && SERVICE="$value" ;;
            SPLIT) case "$value" in ''|*[!0-9]*) ;; *) SPLIT="$value" ;; esac ;;
            DELAY) case "$value" in ''|*[!0-9]*) ;; *) DELAY="$value" ;; esac ;;
            HTTP_PORT) case "$value" in ''|*[!0-9]*) ;; *) HTTP_PORT="$value" ;; esac ;;
            SOCKS_PORT) case "$value" in ''|*[!0-9]*) ;; *) SOCKS_PORT="$value" ;; esac ;;
        esac
    done <"$file"
    [ -n "${HOST:-}" ] || HOST=""
    [ -n "${SERVICE:-}" ] || SERVICE="$DEFAULT_SERVICE"
}

save_conf() {
    local dir file owner
    dir=$(conf_dir)
    file=$(conf_file)
    mkdir -p "$dir" || return 1
    {
        echo "# ZAPRET CONTROL macOS client"
        echo "MODE=\"$MODE\""
        echo "HOST=\"$HOST\""
        echo "SERVICE=\"$SERVICE\""
        echo "HTTP_PORT=\"$HTTP_PORT\""
        echo "SOCKS_PORT=\"$SOCKS_PORT\""
        echo "SPLIT=\"$SPLIT\""
        echo "DELAY=\"$DELAY\""
    } >"$file"
    owner=$(real_user)
    if [ -n "$owner" ]; then
        chown "$owner" "$file" 2>/dev/null || true
        chown "$owner" "$dir" 2>/dev/null || true
    fi
}

valid_host() {
    case "$1" in
        ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

list_services() {
    networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//'
}

set_proxy() {
    local host service
    host="${1:-}"
    if [ $# -ge 2 ]; then
        service="$2"
    else
        service="${SERVICE:-$DEFAULT_SERVICE}"
    fi
    networksetup -setwebproxy "$service" "$host" "$HTTP_PORT" >/dev/null 2>&1
    networksetup -setsecurewebproxy "$service" "$host" "$HTTP_PORT" >/dev/null 2>&1
    networksetup -setsocksfirewallproxy "$service" "$host" "$SOCKS_PORT" >/dev/null 2>&1
    networksetup -setproxybypassdomains "$service" $BYPASS_DOMAINS >/dev/null 2>&1
    echo "Прокси включён для «$service»: HTTP $host:$HTTP_PORT, SOCKS5 $host:$SOCKS_PORT"
    echo "Локальные адреса идут напрямую (bypass: $BYPASS_DOMAINS)"
}

unset_proxy() {
    local service
    if [ $# -ge 1 ]; then
        service="$1"
    else
        service="${SERVICE:-$DEFAULT_SERVICE}"
    fi
    networksetup -setwebproxystate "$service" off >/dev/null 2>&1
    networksetup -setsecurewebproxystate "$service" off >/dev/null 2>&1
    networksetup -setsocksfirewallproxystate "$service" off >/dev/null 2>&1
    echo "Прокси выключен для «$service»"
}

show_status() {
    local service="${1:-$SERVICE}"
    echo "Режим: $(mode_label)"
    echo "Локальный прокси: $(daemon_label)"
    if [ -f "$(plist_file)" ]; then
        echo "Автозапуск: включён"
    else
        echo "Автозапуск: выключен"
    fi
    echo "Подключение: $service"
    echo "--- HTTP ---"
    networksetup -getwebproxy "$service" 2>/dev/null
    echo "--- HTTPS ---"
    networksetup -getsecurewebproxy "$service" 2>/dev/null
    echo "--- SOCKS5 ---"
    networksetup -getsocksfirewallproxy "$service" 2>/dev/null
}

mode_label() {
    if [ "$MODE" = "local" ]; then
        echo "локальный (на этом Mac)"
    elif [ -n "$HOST" ]; then
        echo "LAN (Windows-ПК $HOST)"
    else
        echo "не задан"
    fi
}

daemon_pid() {
    local file pid
    file=$(pid_file)
    [ -f "$file" ] || return 1
    pid=$(head -n 1 "$file" 2>/dev/null | tr -dc '0-9')
    [ -n "$pid" ] || return 1
    echo "$pid"
}

daemon_running() {
    local pid
    pid=$(daemon_pid) || return 1
    kill -0 "$pid" 2>/dev/null
}

daemon_label() {
    if daemon_running; then
        echo "работает (pid $(daemon_pid))"
    else
        echo "не запущен"
    fi
}

local_lib() {
    if [ -f "$(installed_lib)" ]; then
        echo "$(installed_lib)"
        return 0
    fi
    if [ -f "$LIB_FILE" ]; then
        echo "$LIB_FILE"
        return 0
    fi
    return 1
}

launchd_load() {
    local plist uid
    plist=$(plist_file)
    [ -f "$plist" ] || return 1
    launchctl load -w "$plist" >/dev/null 2>&1 && return 0
    uid=$(real_uid) || uid=$(id -u)
    launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1
}

launchd_unload() {
    local plist uid
    plist=$(plist_file)
    [ -f "$plist" ] || return 1
    uid=$(real_uid) || uid=$(id -u)
    launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1 && return 0
    launchctl unload -w "$plist" >/dev/null 2>&1
}

write_plist() {
    local lib owner
    lib=$(installed_lib)
    [ -f "$lib" ] || die "сначала установи клиент: $0 --install"
    mkdir -p "$(dirname "$(plist_file)")" || return 1
    cat >"$(plist_file)" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/perl</string>
        <string>$lib</string>
        <string>--http-port</string>
        <string>$HTTP_PORT</string>
        <string>--socks-port</string>
        <string>$SOCKS_PORT</string>
        <string>--split</string>
        <string>$SPLIT</string>
        <string>--delay</string>
        <string>$DELAY</string>
        <string>--log</string>
        <string>$(log_file)</string>
        <string>--pid</string>
        <string>$(pid_file)</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(log_file)</string>
    <key>StandardErrorPath</key>
    <string>$(log_file)</string>
</dict>
</plist>
EOF
    owner=$(real_user)
    [ -n "$owner" ] && chown "$owner" "$(plist_file)" 2>/dev/null || true
}

start_daemon() {
    local lib owner i
    lib=$(local_lib) || die "не найден lib/desync-proxy.pl рядом со скриптом"
    command -v perl >/dev/null 2>&1 || die "не найден perl (в macOS он входит в систему; если удалён — brew install perl)"
    if daemon_running; then
        echo "Локальный прокси уже запущен (pid $(daemon_pid))."
        return 0
    fi
    owner=$(real_user)
    if [ -f "$(plist_file)" ]; then
        launchd_load || true
    else
        local extra=()
        [ -n "$owner" ] && extra=(--user "$owner")
        nohup perl "$lib" --http-port "$HTTP_PORT" --socks-port "$SOCKS_PORT" \
            --split "$SPLIT" --delay "$DELAY" \
            ${extra[@]+"${extra[@]}"} \
            --log "$(log_file)" --pid "$(pid_file)" >/dev/null 2>&1 &
    fi
    i=0
    while [ "$i" -lt 50 ]; do
        if daemon_running; then
            echo "Локальный прокси запущен (pid $(daemon_pid))."
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "Не удалось запустить локальный прокси." >&2
    if [ -f "$(log_file)" ]; then
        echo "Последние строки журнала:" >&2
        tail -n 5 "$(log_file)" >&2
    fi
    return 1
}

stop_daemon() {
    local pid i
    if [ -f "$(plist_file)" ]; then
        launchd_unload || true
    fi
    pid=$(daemon_pid) || pid=""
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        i=0
        while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
            i=$((i + 1))
            sleep 0.1
        done
        kill -KILL "$pid" 2>/dev/null || true
        echo "Локальный прокси остановлен."
    fi
    rm -f "$(pid_file)"
}

enable_autostart() {
    [ "$MODE" = "local" ] || die "автозапуск доступен в локальном режиме: сначала --local"
    [ -f "$(installed_lib)" ] || die "сначала установи клиент: $0 --install"
    write_plist || die "не удалось создать $LAUNCHD_LABEL"
    launchd_load || true
    echo "Автозапуск включён: прокси будет стартовать при входе в систему."
}

disable_autostart() {
    if [ -f "$(plist_file)" ]; then
        launchd_unload || true
        rm -f "$(plist_file)"
        echo "Автозапуск выключен."
    else
        echo "Автозапуск уже выключен."
    fi
}

install_client() {
    local dir src
    dir=$(app_dir)
    src="$SELF_DIR"
    [ -f "$src/$(basename "$0")" ] || src="$PWD"
    mkdir -p "$dir/lib" || die "не удалось создать $dir"
    cp "$src/$(basename "$0")" "$dir/zapret-proxy.command" || die "не удалось скопировать клиент"
    cp "$src/lib/desync-proxy.pl" "$dir/lib/desync-proxy.pl" || die "не удалось скопировать прокси"
    [ -f "$src/README.md" ] && cp "$src/README.md" "$dir/README.md" 2>/dev/null || true
    chmod +x "$dir/zapret-proxy.command" "$dir/lib/desync-proxy.pl" 2>/dev/null || true
    echo "Установлено в $dir"
    echo "Запуск: $dir/zapret-proxy.command"
}

uninstall_client() {
    local dir plist
    dir=$(app_dir)
    plist=$(plist_file)
    stop_daemon
    if [ -f "$plist" ]; then
        launchd_unload || true
        rm -f "$plist"
    fi
    case "$dir" in
        */Applications/ZapretControl)
            rm -rf "$dir"
            echo "Удалено: $dir"
            ;;
        *)
            echo "Пропущено удаление неожиданного пути: $dir" >&2
            ;;
    esac
}

test_proxy() {
    local host="$1"
    local code
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -x "http://$host:$HTTP_PORT" "http://example.com" 2>/dev/null)
    if [ "$code" = "200" ]; then
        echo "Прокси $host:$HTTP_PORT отвечает (HTTP 200)."
        local yt
        yt=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -x "http://$host:$HTTP_PORT" "https://www.youtube.com/generate_204" 2>/dev/null)
        echo "YouTube через прокси: HTTP $yt (204 = норма)"
        return 0
    fi
    echo "Прокси $host:$HTTP_PORT не отвечает (код '$code')."
    if [ "$MODE" = "local" ]; then
        echo "Проверь: локальный прокси запущен (--local), порт $HTTP_PORT не занят,"
        echo "журнал: $(log_file)."
    else
        echo "Проверь: ПК включён, zapret и прокси запущены (start-all.bat или ZAPRET CONTROL),"
        echo "Mac и ПК в одной сети, порт 8080 не блокирует брандмауэр Windows."
    fi
    return 1
}

ask_host() {
    local current="${1:-}"
    local answer
    printf "IP или имя Windows-ПК%s: " "${current:+ [$current]}" >&2
    read -r answer
    [ -n "$answer" ] || answer="$current"
    valid_host "$answer" || die "некорректный адрес: $answer"
    echo "$answer"
}

ask_service() {
    local current="${1:-$SERVICE}"
    local services
    services=$(list_services)
    [ -n "$services" ] || die "не удалось получить список сетевых подключений"
    echo "Сетевые подключения:" >&2
    local i=1
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        printf "  %d) %s\n" "$i" "$name" >&2
        i=$((i + 1))
    done <<EOF
$services
EOF
    local answer
    printf "Номер подключения [текущее: %s]: " "$current" >&2
    read -r answer
    [ -n "$answer" ] || { echo "$current"; return; }
    name=$(echo "$services" | sed -n "${answer}p")
    [ -n "$name" ] || die "нет подключения с номером $answer"
    echo "$name"
}

show_logs() {
    local n="${1:-40}" file
    file=$(log_file)
    if [ ! -f "$file" ]; then
        echo "Журнал не найден: $file"
        echo "Он создаётся при запуске локального прокси (--local)."
        return 1
    fi
    echo "=== $(basename "$file") (последние $n строк) ==="
    tail -n "$n" "$file"
}

run_doctor() {
    local ok=0 warn=0 bad=0 lib host
    echo "=== $APP_NAME macOS клиент $APP_VERSION — диагностика ==="
    echo "Платформа: $(uname -s)  пользователь: $(id -un 2>/dev/null || echo '?')  uid=$(id -u)"
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "[OK] macOS"
        ok=$((ok + 1))
    else
        echo "[!!] этот клиент предназначен для macOS"
        bad=$((bad + 1))
    fi
    if command -v perl >/dev/null 2>&1; then
        echo "[OK] perl: $(command -v perl)"
        ok=$((ok + 1))
    else
        echo "[!!] perl не найден (нужен для локального режима)"
        bad=$((bad + 1))
    fi
    if command -v networksetup >/dev/null 2>&1; then
        echo "[OK] networksetup найден"
        ok=$((ok + 1))
    else
        echo "[!!] networksetup не найден"
        bad=$((bad + 1))
    fi
    if command -v curl >/dev/null 2>&1; then
        echo "[OK] curl найден"
        ok=$((ok + 1))
    else
        echo "[--] curl не найден (не будет работать --test)"
        warn=$((warn + 1))
    fi
    if lib=$(local_lib 2>/dev/null); then
        echo "[OK] локальный прокси: $lib"
        ok=$((ok + 1))
    else
        echo "[--] lib/desync-proxy.pl не найден рядом со скриптом"
        warn=$((warn + 1))
    fi
    echo "[..] режим: $(mode_label), подключение: $SERVICE, HTTP:$HTTP_PORT SOCKS:$SOCKS_PORT"
    if [ -f "$(conf_file)" ]; then
        echo "[OK] конфиг: $(conf_file)"
        ok=$((ok + 1))
    else
        echo "[--] конфиг ещё не создан"
        warn=$((warn + 1))
    fi
    if daemon_running; then
        echo "[OK] локальный прокси работает (pid $(daemon_pid))"
        ok=$((ok + 1))
    else
        echo "[--] локальный прокси не запущен"
        warn=$((warn + 1))
    fi
    if [ -f "$(plist_file)" ]; then
        echo "[OK] автозапуск включён: $(plist_file)"
        ok=$((ok + 1))
    else
        echo "[--] автозапуск не настроен"
        warn=$((warn + 1))
    fi
    if [ -f "$(log_file)" ]; then
        echo "[OK] журнал: $(log_file)"
        ok=$((ok + 1))
    else
        echo "[--] журнала ещё нет"
        warn=$((warn + 1))
    fi
    echo "--- системный прокси ($SERVICE) ---"
    networksetup -getwebproxy "$SERVICE" 2>/dev/null || echo "(не удалось прочитать)"
    echo "---"
    if [ "$MODE" = "local" ]; then
        host="$LOCAL_HOST"
    else
        host="$HOST"
    fi
    if [ -n "$host" ]; then
        echo "Подсказка: проверь связь командой --test $host"
    fi
    echo "Итог: ok=$ok warn=$warn bad=$bad"
    [ "$bad" -eq 0 ]
}

do_restart() {
    if [ "$MODE" = "local" ]; then
        stop_daemon
        save_conf
        start_daemon || exit 1
        set_proxy "$LOCAL_HOST" "$SERVICE"
        echo "Локальный режим перезапущен."
        return 0
    fi
    if [ -z "$HOST" ]; then
        die "не задан режим: используй --local или --on 192.168.1.10"
    fi
    stop_daemon
    set_proxy "$HOST" "$SERVICE"
    echo "LAN-режим применён заново ($HOST)."
}

# ---------- разбор аргументов ----------

ORIG_ARGS=("$@")
ACTION=""
ARG_HOST=""
ARG_SERVICE=""
ARG_AUTOSTART=""
ARG_SPLIT=""
ARG_DELAY=""
ARG_HTTP_PORT=""
ARG_SOCKS_PORT=""
ARG_LOGS="40"
while [ $# -gt 0 ]; do
    case "$1" in
        --on) ACTION="on"; [ $# -ge 2 ] && { ARG_HOST="$2"; shift; } ;;
        --lan) ACTION="on"; [ $# -ge 2 ] && { ARG_HOST="$2"; shift; } ;;
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
        --autostart)
            ACTION="autostart"
            [ $# -ge 2 ] && { ARG_AUTOSTART="$2"; shift; }
            ;;
        --split) [ $# -ge 2 ] && { ARG_SPLIT="$2"; shift; } ;;
        --delay) [ $# -ge 2 ] && { ARG_DELAY="$2"; shift; } ;;
        --http-port) [ $# -ge 2 ] && { ARG_HTTP_PORT="$2"; shift; } ;;
        --socks-port) [ $# -ge 2 ] && { ARG_SOCKS_PORT="$2"; shift; } ;;
        -h|--help)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -V|--version)
            echo "$APP_NAME macOS client $APP_VERSION"
            exit 0
            ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
    shift
done

# ---------- основной сценарий ----------

need_macos

# Адрес проверяем до элевации: незачем спрашивать пароль администратора,
# чтобы потом сообщить об опечатке в IP.
[ -n "$ARG_HOST" ] && { valid_host "$ARG_HOST" || die "некорректный адрес: $ARG_HOST"; }

# Права root нужны для изменения системных настроек прокси и управления демоном.
# Без аргументов запускается интерактивное меню — ему тоже нужен root.
case "$ACTION" in
    ""|on|local|off|restart|status|test|uninstall)
        if [ "$(id -u)" -ne 0 ]; then
            exec sudo -p "Пароль администратора: " "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
        fi
        ;;
esac

load_conf
[ -n "$ARG_SERVICE" ] && SERVICE="$ARG_SERVICE"
[ -n "$ARG_SPLIT" ] && { case "$ARG_SPLIT" in ''|*[!0-9]*) die "некорректный --split: $ARG_SPLIT" ;; esac; SPLIT="$ARG_SPLIT"; }
[ -n "$ARG_DELAY" ] && { case "$ARG_DELAY" in ''|*[!0-9]*) die "некорректный --delay: $ARG_DELAY" ;; esac; DELAY="$ARG_DELAY"; }
[ -n "$ARG_HTTP_PORT" ] && { case "$ARG_HTTP_PORT" in ''|*[!0-9]*) die "некорректный --http-port: $ARG_HTTP_PORT" ;; esac; HTTP_PORT="$ARG_HTTP_PORT"; }
[ -n "$ARG_SOCKS_PORT" ] && { case "$ARG_SOCKS_PORT" in ''|*[!0-9]*) die "некорректный --socks-port: $ARG_SOCKS_PORT" ;; esac; SOCKS_PORT="$ARG_SOCKS_PORT"; }

case "$ACTION" in
    install)
        install_client
        exit 0
        ;;
    uninstall)
        unset_proxy "$SERVICE"
        uninstall_client
        exit 0
        ;;
    autostart)
        case "$ARG_AUTOSTART" in
            on)  enable_autostart ;;
            off) disable_autostart ;;
            *)   die "укажи: --autostart on|off" ;;
        esac
        exit 0
        ;;
    status) show_status "$SERVICE"; exit 0 ;;
    doctor) run_doctor; exit $? ;;
    logs) show_logs "$ARG_LOGS"; exit $? ;;
    restart)
        do_restart
        exit $?
        ;;
    off)
        stop_daemon
        unset_proxy "$SERVICE"
        exit 0
        ;;
    test)
        TEST_HOST="${ARG_HOST:-}"
        if [ -z "$TEST_HOST" ]; then
            if [ "$MODE" = "local" ]; then
                TEST_HOST="$LOCAL_HOST"
                if ! daemon_running; then
                    echo "Внимание: локальный прокси не запущен. Запусти --local или --restart." >&2
                fi
            else
                TEST_HOST="$HOST"
            fi
        fi
        [ -n "$TEST_HOST" ] || die "не указан адрес: --test 192.168.1.10"
        test_proxy "$TEST_HOST"; exit $? ;;
    local)
        MODE="local"
        save_conf
        start_daemon || exit 1
        set_proxy "$LOCAL_HOST" "$SERVICE"
        exit 0
        ;;
    on)
        MODE="lan"
        HOST="${ARG_HOST:-$HOST}"
        [ -n "$HOST" ] || die "не указан адрес: --on 192.168.1.10"
        valid_host "$HOST" || die "некорректный адрес: $HOST"
        stop_daemon
        save_conf
        set_proxy "$HOST" "$SERVICE"
        exit 0
        ;;
esac

# ---------- интерактивное меню ----------

ask_autostart() {
    if [ -f "$(plist_file)" ]; then
        disable_autostart
    else
        if [ "$MODE" != "local" ]; then
            echo "Сначала включи локальный режим (пункт 2)." >&2
            return 1
        fi
        enable_autostart
    fi
}

run_as_user() {
    local user
    user=$(real_user)
    if [ "$(id -u)" -eq 0 ] && [ -n "$user" ]; then
        sudo -u "$user" "$SELF_DIR/$(basename "$0")" "$@"
    else
        "$SELF_DIR/$(basename "$0")" "$@"
    fi
}

while true; do
    echo
    echo "=== $APP_NAME — macOS клиент $APP_VERSION ==="
    echo "Режим: $(mode_label)"
    echo "Локальный прокси: $(daemon_label)"
    if [ -f "$(plist_file)" ]; then
        echo "Автозапуск: включён"
    else
        echo "Автозапуск: выключен"
    fi
    echo "Подключение: $SERVICE"
    echo
    echo "  1) LAN: указать IP Windows-ПК и включить прокси"
    echo "  2) Локальный режим на этом Mac (без Windows-ПК)"
    echo "  3) Выключить прокси"
    echo "  4) Перезапустить текущий режим"
    echo "  5) Показать статус"
    echo "  6) Проверить связь"
    echo "  7) Выбрать сетевое подключение"
    echo "  8) Журнал локального прокси"
    echo "  9) Диагностика"
    echo " 10) Установить клиент в ~/Applications"
    echo " 11) Автозапуск вкл/выкл"
    echo "  0) Выход"
    printf "Выбор: "
    read -r choice
    case "$choice" in
        1)
            HOST=$(ask_host "$HOST") || exit 1
            MODE="lan"
            stop_daemon
            save_conf
            set_proxy "$HOST" "$SERVICE"
            test_proxy "$HOST" || true
            ;;
        2)
            MODE="local"
            save_conf
            start_daemon || true
            set_proxy "$LOCAL_HOST" "$SERVICE"
            test_proxy "$LOCAL_HOST" || true
            ;;
        3)
            stop_daemon
            unset_proxy "$SERVICE"
            ;;
        4) do_restart || true ;;
        5) show_status "$SERVICE" ;;
        6)
            if [ "$MODE" = "local" ]; then
                test_proxy "$LOCAL_HOST" || true
            else
                if [ -z "$HOST" ]; then
                    HOST=$(ask_host "") || exit 1
                    MODE="lan"
                    save_conf
                fi
                test_proxy "$HOST" || true
            fi
            ;;
        7)
            SERVICE=$(ask_service "$SERVICE") || exit 1
            save_conf
            echo "Выбрано подключение: $SERVICE"
            ;;
        8) show_logs 40 || true ;;
        9) run_doctor || true ;;
        10) run_as_user --install ;;
        11) ask_autostart || true ;;
        0|q|Q) echo "Пока."; exit 0 ;;
        *) echo "Нет такого пункта." ;;
    esac
done
