# macOS-клиент ZAPRET CONTROL 0.3.1-beta

**Версия клиента: 0.3.1-beta (бета).** Версии Windows-панели и macOS-клиента
нумеруются раздельно: Windows — `1.12.1`, macOS — `0.3.1-beta`.
Проверить версию: `./zapret-proxy.command --version`.

Клиент работает на Mac самостоятельно: поднимает локальный прокси и включает
системный прокси macOS на `127.0.0.1`. Windows-ПК не нужен (но поддерживается
как запасной режим).

## Как это работает

`winws.exe` использует драйвер **WinDivert** и Windows Filtering Platform.
В macOS их нет, поэтому оригинальный zapret на Mac не запускается.

Локальный режим делает другое: принимает HTTP/HTTPS(SOCKS5) на `127.0.0.1` и
отправляет TLS ClientHello двумя сегментами, так что SNI попадает в разные
части потока. Многие DPI-системы не склеивают сегменты и пропускают соединение
без вмешательства в содержимое (TLS и сертификаты остаются подлинными).

Это не «полный» эквивалент всех стратегий `winws` и не помогает, если
блокировка идёт не по SNI/DPI-паттерну, а по IP, по DNS-ответу без обхода,
по QUIC/UDP или по другим признакам. Для таких случаев оставлен LAN-режим
через Windows-ПК с zapret.

## Быстрый старт (локально, без Windows)

```bash
cd macos
chmod +x zapret-proxy.command
./zapret-proxy.command --local
```

Команда запустит локальный прокси на `127.0.0.1:8080` (HTTP) и
`127.0.0.1:1080` (SOCKS5), включит системный прокси для текущего подключения
и сохранит настройки. Для изменения системных настроек потребуется пароль
администратора macOS.

Проверка, перезапуск и выключение:

```bash
./zapret-proxy.command --status
./zapret-proxy.command --test
./zapret-proxy.command --doctor      # диагностика
./zapret-proxy.command --logs        # журнал локального прокси
./zapret-proxy.command --restart     # перезапустить текущий режим
./zapret-proxy.command --off
```

`--off` останавливает локальный прокси и возвращает системные настройки
прокси в исходное состояние.

## Установка и автозапуск

```bash
./zapret-proxy.command --install
```

Клиент копируется в `~/Applications/ZapretControl/` вместе с `lib/desync-proxy.pl`.
Запуск после установки:

```bash
~/Applications/ZapretControl/zapret-proxy.command
```

Автозапуск локального прокси при входе в систему (через LaunchAgent):

```bash
~/Applications/ZapretControl/zapret-proxy.command --local
~/Applications/ZapretControl/zapret-proxy.command --autostart on
```

Отключить автозапуск:

```bash
./zapret-proxy.command --autostart off
```

Удаление клиента и агента автозапуска:

```bash
./zapret-proxy.command --uninstall
```

Конфигурация и журнал хранятся отдельно в
`~/Library/Application Support/ZapretControl/` и при удалении клиента не стираются
(их можно удалить вручную).

## LAN-режим (через Windows-ПК с zapret)

Если локальный режим не помогает или нужен обход именно стратегиями `winws`,
можно направить трафик Mac через прокси на Windows-ПК, где запущен zapret:

```bash
./zapret-proxy.command --on 192.168.1.10
```

Требования: на ПК запущен `proxy\start-all.bat` или панель ZAPRET CONTROL
(вкладка «Прокси»), Mac и ПК в одной сети, порт 8080 открыт.
Адрес ПК можно посмотреть в ZAPRET CONTROL или командой `ipconfig`.

## Меню

`./zapret-proxy.command` без аргументов открывает меню:

1. **LAN** — указать IP Windows-ПК и включить прокси.
2. **Локальный режим** — запустить обход на этом Mac.
3. Выключить прокси (и остановить локальный прокси).
4. Перезапустить текущий режим.
5. Показать статус.
6. Проверить связь.
7. Выбрать сетевое подключение (Wi-Fi, Ethernet и т.д.).
8. Показать журнал локального прокси.
9. Диагностика.
10. Установить клиент в `~/Applications`.
11. Включить/выключить автозапуск.

## Режим для скриптов

```bash
./zapret-proxy.command --local                   # локальный режим
./zapret-proxy.command --on 192.168.1.10         # LAN-режим
./zapret-proxy.command --restart                 # перезапустить текущий режим
./zapret-proxy.command --off                     # выключить всё
./zapret-proxy.command --status                  # статус
./zapret-proxy.command --doctor                  # диагностика
./zapret-proxy.command --test                    # проверка
./zapret-proxy.command --logs [N]                # журнал (последние N строк)
./zapret-proxy.command --service "Ethernet"      # другое подключение
./zapret-proxy.command --http-port 8080 --socks-port 1080  # порты
./zapret-proxy.command --install                 # установка
./zapret-proxy.command --uninstall               # удаление
./zapret-proxy.command --autostart on|off        # автозапуск
./zapret-proxy.command --split 0 --delay 0       # параметры split (экспертно)
./zapret-proxy.command --version                 # версия
```

## Параметры и файлы

| Путь / параметр | Назначение |
|---|---|
| `127.0.0.1:8080` | HTTP/HTTPS-прокси (локальный режим, по умолчанию) |
| `127.0.0.1:1080` | SOCKS5-прокси (локальный режим, по умолчанию) |
| `--http-port N` / `--socks-port N` | пользовательские порты (сохраняются в конфиг) |
| `~/Library/Application Support/ZapretControl/proxy.conf` | режим, адрес, подключение |
| `~/Library/Application Support/ZapretControl/proxy.log` | журнал локального прокси |
| `~/Library/Application Support/ZapretControl/proxy.pid` | pid локального прокси |
| `~/Library/LaunchAgents/com.zapretcontrol.proxy.plist` | автозапуск |
| `--split N` | точка разрыва ClientHello (`0` — середина SNI, по умолчанию) |
| `--delay MS` | пауза между сегментами в мс (по умолчанию 0) |

Локальные адреса (`localhost`, `192.168.*`, `10.*`, `172.16-31.*`, `*.local`)
всегда идут напрямую (bypass).

## Зависимости

- macOS с `networksetup` (штатно).
- `/usr/bin/perl` — входит в macOS (используется локальным прокси).
- `curl` — входит в macOS (используется для `--test`).

Дополнительных пакетов, Python или Homebrew не требуется.

## Ограничения

- Локальный режим использует split TLS ClientHello. Это эффективно против
  части DPI, но не универсально: при другом типе блокировки может помочь только
  LAN-режим с zapret/`winws` на Windows.
- Системный прокси читают не все приложения (игры, часть CLI, приложения с
  собственным сетевым стеком). Для них нужна ручная настройка HTTP/SOCKS5
  внутри приложения.
- QUIC/HTTP3 (UDP 443) системный HTTP/SOCKS-прокси может не перехватывать;
  браузеры при неудаче обычно откатываются на TCP/TLS.
- Реальная эффективность зависит от провайдера и DPI; при необходимости
  попробуйте параметры `--split`/`--delay` или LAN-режим.

## Проверка без Mac

```bash
cd macos/tests
./run-tests.sh          # 21 сценарий, 91 проверка
```

Эмулятор использует заглушки `uname`, `id`, `sudo`, `networksetup`, `dscl`,
`stat`, `curl`, `perl` и `launchctl`; системные настройки не меняются.
Проверяются: справка, версия, LAN-включение, статус, `--test`, другое
подключение, ошибки адреса, меню, локальный режим, остановка, установка,
автозапуск, удаление, `--doctor`, `--logs`, `--restart`, пользовательские порты
и `desync-proxy.pl --selftest`. Реальный `networksetup`, LaunchAgent и сеть
проверяются только на Mac.
