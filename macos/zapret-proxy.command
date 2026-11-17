#!/bin/bash
# ZAPRET CONTROL — macOS client.
#
# Сам zapret (winws + WinDivert) работает только на Windows: на macOS нет ни
# WinDivert, ни WFP. Этот скрипт настраивает Mac так, чтобы весь его трафик шёл
# через LAN-прокси на Windows-ПК, где zapret уже обходит DPI.
#
# Использование:
#   ./zapret-proxy.command                 # интерактивное меню
#   ./zapret-proxy.command --on 192.168.1.10
#   ./zapret-proxy.command --off
#   ./zapret-proxy.command --status
#   ./zapret-proxy.command --test 192.168.1.10
#   ./zapret-proxy.command --service "Wi-Fi"
#   ./zapret-proxy.command --version
set -u

APP_NAME="ZAPRET CONTROL"
APP_VERSION="0.1.0-beta"
HTTP_PORT=8080
SOCKS_PORT=1080
BYPASS_DOMAINS="localhost 127.0.0.1 *.local 192.168.* 10.* 172.16.* 172.17.* 172.18.* 172.19.* 172.2*.* 172.30.* 172.31.*"
DEFAULT_SERVICE="Wi-Fi"

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

conf_dir() { echo "$(real_home)/Library/Application Support/ZapretControl"; }
conf_file() { echo "$(conf_dir)/proxy.conf"; }

load_conf() {
    HOST=""
    SERVICE="$DEFAULT_SERVICE"
    local file key value
    file=$(conf_file)
    [ -f "$file" ] || return 0
    while IFS='=' read -r key value; do
        value=$(printf '%s' "$value" | tr -d '"')
        case "$key" in
            HOST) HOST="$value" ;;
            SERVICE) [ -n "$value" ] && SERVICE="$value" ;;
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
        echo "HOST=\"$HOST\""
        echo "SERVICE=\"$SERVICE\""
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
    local host="$1" service="${2:-$SERVICE}"
    networksetup -setwebproxy "$service" "$host" "$HTTP_PORT" >/dev/null 2>&1
    networksetup -setsecurewebproxy "$service" "$host" "$HTTP_PORT" >/dev/null 2>&1
    networksetup -setsocksfirewallproxy "$service" "$host" "$SOCKS_PORT" >/dev/null 2>&1
    networksetup -setproxybypassdomains "$service" $BYPASS_DOMAINS >/dev/null 2>&1
    echo "Прокси включён для «$service»: HTTP $host:$HTTP_PORT, SOCKS5 $host:$SOCKS_PORT"
    echo "Локальные адреса идут напрямую (bypass: $BYPASS_DOMAINS)"
}

unset_proxy() {
    local service="${1:-$SERVICE}"
    networksetup -setwebproxystate "$service" off >/dev/null 2>&1
    networksetup -setsecurewebproxystate "$service" off >/dev/null 2>&1
    networksetup -setsocksfirewallproxystate "$service" off >/dev/null 2>&1
    echo "Прокси выключен для «$service»"
}

show_status() {
    local service="${1:-$SERVICE}"
    echo "Подключение: $service"
    echo "--- HTTP ---"
    networksetup -getwebproxy "$service" 2>/dev/null
    echo "--- HTTPS ---"
    networksetup -getsecurewebproxy "$service" 2>/dev/null
    echo "--- SOCKS5 ---"
    networksetup -getsocksfirewallproxy "$service" 2>/dev/null
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
    echo "Проверь: ПК включён, zapret и прокси запущены (start-all.bat или ZAPRET CONTROL),"
    echo "Mac и ПК в одной сети, порт 8080 не блокирует брандмауэр Windows."
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

# ---------- разбор аргументов ----------

ORIG_ARGS=("$@")
ACTION=""
ARG_HOST=""
ARG_SERVICE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --on) ACTION="on"; [ $# -ge 2 ] && { ARG_HOST="$2"; shift; } ;;
        --off) ACTION="off" ;;
        --status) ACTION="status" ;;
        --test) ACTION="test"; [ $# -ge 2 ] && { ARG_HOST="$2"; shift; } ;;
        --service) [ $# -ge 2 ] && { ARG_SERVICE="$2"; shift; } ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
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

# networksetup и запись конфигурации требуют root, поэтому поднимаем права
# до любого действия (кроме --help, который завершается при разборе аргументов).
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -p "Пароль администратора: " "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi

load_conf
[ -n "$ARG_SERVICE" ] && SERVICE="$ARG_SERVICE"

case "$ACTION" in
    status) show_status "$SERVICE"; exit 0 ;;
    off) unset_proxy "$SERVICE"; exit 0 ;;
    test)
        TEST_HOST="${ARG_HOST:-$HOST}"
        [ -n "$TEST_HOST" ] || die "не указан адрес: --test 192.168.1.10"
        test_proxy "$TEST_HOST"; exit $? ;;
    on)
        HOST="${ARG_HOST:-$HOST}"
        [ -n "$HOST" ] || die "не указан адрес: --on 192.168.1.10"
        valid_host "$HOST" || die "некорректный адрес: $HOST"
        save_conf
        set_proxy "$HOST" "$SERVICE"
        exit 0
        ;;
esac

while true; do
    echo
    echo "=== $APP_NAME — macOS клиент $APP_VERSION (бета) ==="
    if [ -n "$HOST" ]; then
        echo "Windows-ПК: $HOST (HTTP $HTTP_PORT / SOCKS5 $SOCKS_PORT)"
    else
        echo "Windows-ПК: не задан"
    fi
    echo "Подключение: $SERVICE"
    echo
    echo "  1) Указать IP Windows-ПК и включить прокси"
    echo "  2) Выключить прокси"
    echo "  3) Показать текущий статус"
    echo "  4) Проверить связь через прокси"
    echo "  5) Выбрать сетевое подключение"
    echo "  0) Выход"
    printf "Выбор: "
    read -r choice
    case "$choice" in
        1)
            HOST=$(ask_host "$HOST") || exit 1
            save_conf
            set_proxy "$HOST" "$SERVICE"
            test_proxy "$HOST" || true
            ;;
        2) unset_proxy "$SERVICE" ;;
        3) show_status "$SERVICE" ;;
        4)
            if [ -z "$HOST" ]; then
                HOST=$(ask_host "") || exit 1
                save_conf
            fi
            test_proxy "$HOST" || true
            ;;
        5)
            SERVICE=$(ask_service "$SERVICE") || exit 1
            save_conf
            echo "Выбрано подключение: $SERVICE"
            ;;
        0|q|Q) echo "Пока."; exit 0 ;;
        *) echo "Нет такого пункта." ;;
    esac
done
