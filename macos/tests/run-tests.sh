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
expect_exit0() {
    if [ "$RC" -eq 0 ]; then
        ok "exit 0"
    else
        bad "exit $RC"
        echo "    --- output ---"
        echo "$OUT" | sed 's/^/    | /'
        echo "    --- end ---"
    fi
}

setup() {
    if [ -n "${SIM_HOME:-}" ]; then
        local old
        old=$(cat "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" 2>/dev/null)
        [ -n "${old:-}" ] && kill "$old" 2>/dev/null || true
    fi
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
expect_exit0
out_has "Использование:" && ok "печатает справку" || bad "нет справки"
[ ! -s "$SIM_LOG" ] && ok "не трогает систему" || bad "вызвал $(head -1 "$SIM_LOG")"

# --- 2. --on от обычного пользователя (через sudo) ---
echo "2) --on 192.168.1.50 (не root)"
setup 501
run --on 192.168.1.50
expect_exit0
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
expect_exit0
out_has "Enabled: Yes" && ok "прокси включён" || bad "не видит включения"
out_has "Server: 192.168.1.50" && ok "сервер из конфига" || bad "нет сервера"
out_has "Port: 8080" && ok "порт 8080" || bad "нет порта"

# --- 4. --test без аргумента берёт адрес из конфига ---
echo "4) --test"
run --test
expect_exit0
out_has "отвечает" && ok "видит рабочий прокси" || bad "не видит прокси"
log_has "http://192.168.1.50:8080" && ok "проверяет через конфиг" || bad "не тот адрес"
log_has "youtube.com" && ok "проверяет YouTube" || bad "нет проверки YouTube"

# --- 5. другое сетевое подключение и hostname ---
echo "5) --on 10.0.0.7 --service Ethernet"
flush_case
run --on my-pc.local --service "USB 10/100/1000 LAN"
expect_exit0
log_has "-setwebproxy USB 10/100/1000 LAN my-pc.local 8080" && ok "выбрано другое подключение" || bad "подключение не применилось"
conf_has 'HOST="my-pc.local"' && ok "hostname сохранён" || bad "hostname не сохранён"
conf_has 'SERVICE="USB 10/100/1000 LAN"' && ok "подключение сохранено" || bad "подключение не сохранено"

# --- 6. --off ---
echo "6) --off"
flush_case
run --off
expect_exit0
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
expect_exit0
out_has "Прокси включён для «Wi-Fi»" && ok "включил прокси" || bad "не включил"
state_has "setwebproxy|Wi-Fi|192.168.1.99|8080|on" && ok "применил введённый IP" || bad "IP не применился"
out_has "IP или имя Windows-ПК" && ok "спросил адрес" || bad "не спросил адрес"
conf_has 'HOST="192.168.1.99"' && ok "сохранил адрес" || bad "не сохранил"
out_has "0.3.0-beta" && ok "показывает версию с пометкой бета" || bad "нет версии в шапке"

# --- 10. под root sudo не нужен ---
echo "10) --off под root"
setup 0
run --off
expect_exit0
if log_has "sudo"; then bad "зачем-то вызвал sudo"; else ok "без sudo"; fi

# --- 11. --version ---
echo "11) --version"
setup 501
run --version
expect_exit0
out_has "0.3.0-beta" && ok "версия клиента 0.3.0-beta" || bad "нет версии"
[ ! -s "$SIM_LOG" ] && ok "не трогает систему" || bad "вызвал $(head -1 "$SIM_LOG")"

# --- 12. локальный режим: прокси на этом Mac ---
echo "12) --local (локальный прокси без Windows-ПК)"
setup 501
run --local
expect_exit0
log_has "sudo" && ok "поднял права через sudo" || bad "не вызвал sudo"
log_has "perl " && ok "запустил локальный прокси" || bad "прокси не запущен"
state_has "setwebproxy|Wi-Fi|127.0.0.1|8080|on" && ok "HTTP на 127.0.0.1:8080" || bad "HTTP не включён"
state_has "setsocksfirewallproxy|Wi-Fi|127.0.0.1|1080|on" && ok "SOCKS5 на 127.0.0.1:1080" || bad "SOCKS5 не включён"
conf_has 'MODE="local"' && ok "режим local сохранён" || bad "режим не сохранён"
pid=$(cat "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" 2>/dev/null)
[ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null && ok "процесс прокси жив (pid $pid)" || bad "процесс не жив"

# --- 13. статус в локальном режиме ---
echo "13) --status (local)"
run --status
expect_exit0
out_has "Режим: локальный" && ok "показывает локальный режим" || bad "нет режима"
out_has "Локальный прокси: работает" && ok "видит работающий прокси" || bad "не видит прокси"
out_has "Enabled: Yes" && ok "системный прокси включён" || bad "прокси не включён"

# --- 14. выключение останавливает демон ---
echo "14) --off (local)"
run --off
expect_exit0
if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then bad "процесс остался жив"; else ok "процесс остановлен"; fi
[ ! -f "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" ] && ok "pid-файл убран" || bad "pid-файл остался"
state_has "setwebproxystate|Wi-Fi|||off" && ok "HTTP выключен" || bad "HTTP не выключен"

# --- 15. установка в ~/Applications ---
echo "15) --install"
setup 501
run --install
expect_exit0
app="$SIM_HOME/Applications/ZapretControl"
[ -x "$app/zapret-proxy.command" ] && ok "клиент установлен" || bad "нет клиента"
[ -f "$app/lib/desync-proxy.pl" ] && ok "локальный прокси установлен" || bad "нет lib"
[ -f "$app/README.md" ] && ok "документация установлена" || bad "нет README"
if log_has "sudo"; then bad "install потребовал root"; else ok "install без root"; fi

# --- 16. автозапуск через launchd ---
echo "16) --autostart on/off"
plist="$SIM_HOME/Library/LaunchAgents/com.zapretcontrol.proxy.plist"
run --local
run --autostart on
expect_exit0
[ -f "$plist" ] && ok "plist создан" || bad "plist не создан"
grep -q "com.zapretcontrol.proxy" "$plist" 2>/dev/null && ok "label в plist" || bad "нет label"
grep -q "desync-proxy.pl" "$plist" 2>/dev/null && ok "путь к прокси в plist" || bad "нет пути"
log_has "launchctl" && ok "вызван launchctl" || bad "launchctl не вызван"
run --autostart off
[ ! -f "$plist" ] && ok "plist удалён" || bad "plist остался"
log_has "bootout" || log_has "unload" && ok "launchd выгружен" || bad "launchd не выгружен"

# --- 17. удаление клиента ---
echo "17) --uninstall"
run --uninstall
expect_exit0
[ ! -d "$app" ] && ok "папка клиента удалена" || bad "папка осталась"
[ ! -f "$plist" ] && ok "plist удалён" || bad "plist остался"

# --- 18. самопроверка локального прокси (настоящий perl) ---
echo "18) desync-proxy.pl --selftest"
if [ -x /usr/bin/perl ]; then
    out=$(/usr/bin/perl "$HERE/../lib/desync-proxy.pl" --selftest 2>&1)
    rc=$?
    [ "$rc" -eq 0 ] && ok "selftest exit 0" || bad "selftest exit $rc"
    echo "$out" | grep -q "selftest: OK" && ok "split/private проверки прошли" || bad "selftest не OK"
else
    ok "perl недоступен — пропущено"
fi

# --- 19. диагностика и журнал ---
echo "19) --doctor и --logs"
setup 501
run --local
run --doctor
[ "$RC" -eq 0 ] && ok "doctor exit 0" || bad "doctor exit $RC"
out_has "диагностика" && ok "показывает заголовок" || bad "нет заголовка"
out_has "perl" && ok "проверяет perl" || bad "нет проверки perl"
out_has "локальный прокси работает" && ok "видит запущенный прокси" || bad "не видит прокси"
echo "log line 1" >>"$SIM_HOME/Library/Application Support/ZapretControl/proxy.log"
run --logs 20
[ "$RC" -eq 0 ] && ok "logs exit 0" || bad "logs exit $RC"
out_has "log line 1" && ok "читает журнал" || bad "журнал не прочитан"
run --off

# --- 20. перезапуск локального режима ---
echo "20) --restart (local)"
setup 501
run --local
oldpid=$(cat "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" 2>/dev/null)
run --restart
expect_exit0
log_has "perl " && ok "перезапустил прокси" || bad "прокси не перезапущен"
state_has "setwebproxy|Wi-Fi|127.0.0.1|8080|on" && ok "системный прокси на месте" || bad "прокси сброшен"
newpid=$(cat "$SIM_HOME/Library/Application Support/ZapretControl/proxy.pid" 2>/dev/null)
[ -n "${newpid:-}" ] && kill -0 "$newpid" 2>/dev/null && ok "новый процесс жив" || bad "процесс не жив"
run --off

# --- 21. пользовательские порты ---
echo "21) --local с --http-port/--socks-port"
setup 501
run --local --http-port 18080 --socks-port 11080
expect_exit0
state_has "setwebproxy|Wi-Fi|127.0.0.1|18080|on" && ok "HTTP на 18080" || bad "HTTP порт не применён"
state_has "setsocksfirewallproxy|Wi-Fi|127.0.0.1|11080|on" && ok "SOCKS на 11080" || bad "SOCKS порт не применён"
conf_has 'HTTP_PORT="18080"' && ok "HTTP порт сохранён" || bad "порт не сохранён"
conf_has 'SOCKS_PORT="11080"' && ok "SOCKS порт сохранён" || bad "порт не сохранён"
log_has "--http-port 18080" && ok "perl получил --http-port" || bad "perl без http-port"
log_has "--socks-port 11080" && ok "perl получил --socks-port" || bad "perl без socks-port"
run --off

echo
echo "Итого: $PASS успешно, $FAIL провалов"
[ "$FAIL" -eq 0 ] || exit 1
