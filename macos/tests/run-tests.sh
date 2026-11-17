#!/bin/bash
# Эмулятор macOS: прогон zapret-proxy.command на заглушках networksetup/sudo/etc.
# Ничего не меняет в системе: все "системные" вызовы пишутся в лог.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../zapret-proxy.command"
STUBS="$HERE/stubs"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  [OK]   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

setup() {
    SIM_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zapret-sim.XXXXXX")
    mkdir -p "$SIM_ROOT/home"
    export SIM_HOME="$SIM_ROOT/home"
    export SIM_USER="sdccd"
    export SIM_LOG="$SIM_ROOT/calls.log"
    export SIM_STATE="$SIM_ROOT/state.txt"
    export SIM_UID="${1:-501}"
    export HOME="$SIM_HOME"
    export PATH="$STUBS:$PATH"
    : >"$SIM_LOG"
    : >"$SIM_STATE"
}

flush_case() { : >"$SIM_LOG"; : >"$SIM_STATE"; }

run() {
    OUT=$(bash "$SCRIPT" "$@" 2>&1)
    RC=$?
}

log_has() { grep -qF -- "$1" "$SIM_LOG"; }
state_has() { grep -qF -- "$1" "$SIM_STATE"; }
conf_has() { grep -qF -- "$1" "$SIM_HOME/Library/Application Support/ZapretControl/proxy.conf" 2>/dev/null; }
out_has() { echo "$OUT" | grep -qF -- "$1"; }

echo "Эмулятор macOS: $SCRIPT"
echo

# --- 1. --help без прав и без системных вызовов ---
echo "1) --help"
setup 501
run --help
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
out_has "Использование:" && ok "печатает справку" || bad "нет справки"
[ ! -s "$SIM_LOG" ] && ok "не трогает систему" || bad "вызвал $(head -1 "$SIM_LOG")"

# --- 2. --on от обычного пользователя (через sudo) ---
echo "2) --on 192.168.1.50 (не root)"
setup 501
run --on 192.168.1.50
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
log_has "sudo" && ok "поднял права через sudo" || bad "не вызвал sudo"
log_has "-setwebproxy Wi-Fi 192.168.1.50 8080" && ok "HTTP-прокси 8080" || bad "нет -setwebproxy"
log_has "-setsecurewebproxy Wi-Fi 192.168.1.50 8080" && ok "HTTPS-прокси 8080" || bad "нет -setsecurewebproxy"
log_has "-setsocksfirewallproxy Wi-Fi 192.168.1.50 1080" && ok "SOCKS5 1080" || bad "нет SOCKS5"
log_has "-setproxybypassdomains Wi-Fi" && ok "bypass для локальных адресов" || bad "нет bypass"
state_has "setwebproxy|Wi-Fi|192.168.1.50|8080|on" && ok "состояние включено" || bad "состояние не on"
conf_has 'HOST="192.168.1.50"' && ok "адрес сохранён в конфиг" || bad "конфиг не сохранён"

# --- 3. --status читает состояние ---
echo "3) --status"
run --status
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
out_has "Enabled: Yes" && ok "прокси включён" || bad "не видит включения"
out_has "Server: 192.168.1.50" && ok "сервер из конфига" || bad "нет сервера"
out_has "Port: 8080" && ok "порт 8080" || bad "нет порта"

# --- 4. --test без аргумента берёт адрес из конфига ---
echo "4) --test"
run --test
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
out_has "отвечает" && ok "видит рабочий прокси" || bad "не видит прокси"
log_has "http://192.168.1.50:8080" && ok "проверяет через конфиг" || bad "не тот адрес"
log_has "youtube.com" && ok "проверяет YouTube" || bad "нет проверки YouTube"

# --- 5. другое сетевое подключение и hostname ---
echo "5) --on 10.0.0.7 --service Ethernet"
flush_case
run --on my-pc.local --service "USB 10/100/1000 LAN"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
log_has "-setwebproxy USB 10/100/1000 LAN my-pc.local 8080" && ok "выбрано другое подключение" || bad "подключение не применилось"
conf_has 'HOST="my-pc.local"' && ok "hostname сохранён" || bad "hostname не сохранён"
conf_has 'SERVICE="USB 10/100/1000 LAN"' && ok "подключение сохранено" || bad "подключение не сохранено"

# --- 6. --off ---
echo "6) --off"
flush_case
run --off
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
log_has "-setwebproxystate USB 10/100/1000 LAN off" && ok "HTTP выключен" || bad "HTTP не выключен"
log_has "-setsocksfirewallproxystate USB 10/100/1000 LAN off" && ok "SOCKS выключен" || bad "SOCKS не выключен"

# --- 7. некорректный адрес ---
echo "7) --on -evil (мусор)"
flush_case
run --on -evil
[ "$RC" -ne 0 ] && ok "ненулевой код ($RC)" || bad "принял мусор"
out_has "некорректный адрес" && ok "объяснил ошибку" || bad "нет сообщения"
[ ! -s "$SIM_LOG" ] && ok "систему не тронул" || bad "что-то вызвал"

# --- 8. --test без адреса и конфига ---
echo "8) --test без адреса"
setup 501
run --test
[ "$RC" -ne 0 ] && ok "ненулевой код ($RC)" || bad "принял пустой адрес"
out_has "не указан адрес" && ok "объяснил ошибку" || bad "нет сообщения"

# --- 9. интерактивное меню: пункт 1 -> IP -> выход ---
echo "9) меню: 1 -> 192.168.1.99 -> 0"
setup 501
OUT=$(printf '1\n192.168.1.99\n0\n' | bash "$SCRIPT" 2>&1)
RC=$?
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
out_has "Прокси включён для «Wi-Fi»" && ok "включил прокси" || bad "не включил"
state_has "setwebproxy|Wi-Fi|192.168.1.99|8080|on" && ok "применил введённый IP" || bad "IP не применился"
out_has "IP или имя Windows-ПК" && ok "спросил адрес" || bad "не спросил адрес"
conf_has 'HOST="192.168.1.99"' && ok "сохранил адрес" || bad "не сохранил"
out_has "0.1.0-beta" && ok "показывает версию с пометкой бета" || bad "нет версии в шапке"

# --- 10. под root sudo не нужен ---
echo "10) --off под root"
setup 0
run --off
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
if log_has "sudo"; then bad "зачем-то вызвал sudo"; else ok "без sudo"; fi

# --- 11. --version ---
echo "11) --version"
setup 501
run --version
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
out_has "0.1.0-beta" && ok "версия клиента 0.1.0-beta" || bad "нет версии"
[ ! -s "$SIM_LOG" ] && ok "не трогает систему" || bad "вызвал $(head -1 "$SIM_LOG")"

echo
echo "Итого: $PASS успешно, $FAIL провалов"
[ "$FAIL" -eq 0 ] || exit 1
