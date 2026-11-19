# zapret-discord-youtube + ZAPRET CONTROL

Готовый к запуску набор для обхода DPI-блокировок (YouTube, Discord и др.)
на Windows: дистрибутив **zapret** с набором стратегий, LAN-прокси для
других устройств в сети и графическая панель управления **ZAPRET CONTROL**
с установщиком.

```
Интернет ──► zapret (winws.exe + WinDivert) ──► этот ПК
                                                   ▲
Телефон / ТВ / ноутбук ──► HTTP :8080, SOCKS5 :1080 ┘
```

**[Скачать для Windows (ZapretControlSetup.exe)](https://github.com/egftmixmkur/zapret-discord-youtube/releases/latest)** — Windows 10/11 x64, права администратора.
**[Скачать для macOS (ZapretControl.app / CLI, 0.4.0)](https://github.com/egftmixmkur/zapret-discord-youtube/releases/tag/macos-v0.4.0)** — отдельный релиз `macos-v0.4.0`.

## Что внутри

| Путь | Назначение |
|---|---|
| `bin\` | сам zapret: `winws.exe`, `WinDivert.dll`/`WinDivert64.sys`, `cygwin1.dll`, `.bin`-файлы подделок |
| `general*.bat`, `service.bat` | 23 стратегии обхода и установка zapret службой |
| `lists\` | списки доменов и IP-подсетей |
| `proxy\` | LAN-прокси (`zapret-proxy.py`), GUI (`zapret-gui.ps1`), установщик, скрипты задач |
| `proxy\ZapretControl.exe` | собранная панель управления (UAC при запуске) |
| `proxy\ZapretControlSetup.exe` | установщик «всё в одном» для Windows (внутри весь пакет) |
| `utils\test zapret.ps1` | тесты стратегий и `-AutoApply` для автоподбора |
| `macos\` | клиент для macOS (0.4.0): GUI (`ZapretControl.app`) и CLI, локальный обход DPI, установка/автозапуск, диагностика или LAN-режим (отдельный релиз) |

## Возможности ZAPRET CONTROL (Windows)

- **Отдельная вкладка «Обновления»**: проверка, скачивание и автоустановка новых версий прямо из приложения (GitHub Releases, без сторонних серверов).
- **Быстрое вкл/выкл обхода**: глобальная горячая клавиша `Ctrl+Alt+Z`, кнопка на «Обзоре» и пункт в системном трее — удобно для игр/сервисов, которым обход мешает.
- **Графики и авто-подбор стратегий**: визуализация результатов DPI-тестов и применение лучшей стратегии в один клик.
- **LAN-прокси для всей сети**: HTTP `:8080` и SOCKS5 `:1080` для телефона, ТВ и других устройств.
- **Трей, автозапуск, диагностика**: сворачивание в трей, задачи автозапуска/вотчдог, проверка соединения, логи и отчёты.
- **Удобные списки**: быстрый доступ к пользовательским доменам и исключениям (`list-general-user.txt`, `list-exclude-user.txt`, `ipset-exclude-user.txt`).

## Быстрый старт

1. Запусти `proxy\start-all.bat` — скрипт сам запросит права администратора,
   поставит задачи автозапуска и вотчдог, правила брандмауэра для локальных
   подсетей и запустит прокси + zapret.
2. Либо скачай `proxy\ZapretControlSetup.exe` и поставь как обычную программу
   (папка установки, ярлыки, автозапуск, удаление через «Программы и
   компоненты»). Для macOS скачай отдельный релиз `macos-v0.4.0` (см. раздел macOS).
3. Настройки других устройств (адрес прокси в Wi-Fi) — на вкладке «Прокси»
   в ZAPRET CONTROL.

Подробности по прокси, вкладкам GUI, установщику и сборке —
в [`proxy/README.md`](proxy/README.md).

## Сборка из исходников

```powershell
# GUI -> proxy\ZapretControl.exe (нужен admin-манифест; -TestBuild без UAC)
powershell -ExecutionPolicy Bypass -File proxy\build-exe.ps1

# Установщик (Windows) -> proxy\ZapretControlSetup.exe
powershell -ExecutionPolicy Bypass -File proxy\build-installer.ps1
```

Для сборки используется `ps2exe` из `proxy\tools\ps2exe`.

## macOS

**Отдельный релиз:** [macos-v0.4.0](https://github.com/egftmixmkur/zapret-discord-youtube/releases/tag/macos-v0.4.0). Версии раздельные: Windows — `1.12.13`, macOS — `0.4.0`.

Сам zapret (`winws.exe` + WinDivert) работает только на Windows, поэтому
оригинальный `winws` на Mac не запускается. В папке [`macos/`](macos/README.md)
лежит автономный клиент: **графическое приложение `ZapretControl.app`** (GUI)
и CLI `zapret-proxy.command`. Клиент поднимает локальный прокси на `127.0.0.1`,
обходит DPI (split TLS ClientHello) и включает системный прокси macOS —
Windows-ПК не нужен. Также есть LAN-режим через прокси Windows-ПК с zapret.

```bash
cd macos
# GUI: откройте ZapretControl.app в Finder
# CLI:
chmod +x zapret-proxy.command
./zapret-proxy.command --local          # локальный режим на этом Mac
./zapret-proxy.command --status         # статус, --doctor / --logs / --restart
./zapret-proxy.command --install        # установка в ~/Applications
./zapret-proxy.command --autostart on   # автозапуск (LaunchAgent)
./zapret-proxy.command --off            # выключить
./zapret-proxy.command --version
```

Подробнее, ограничения и LAN-режим — [`macos/README.md`](macos/README.md).

## Что не хранится в репозитории

Логи, локальные настройки окна, выбранная стратегия, скачанный `ipset-all.txt`
и пользовательские списки исключены через `.gitignore` — они создаются на
каждой машине свои. После клонирования достаточно запустить установщик или
`start-all.bat`.

## Благодарности

* [zapret](https://github.com/bol-van/zapret) — bol-van (обход DPI, `winws`).
* Дистрибутив стратегий `zapret-discord-youtube` 1.10.4.
* [ps2exe](https://github.com/MScholtes/PS2EXE) — сборка PowerShell в EXE.

Проект не связан с Discord, Google/YouTube и правообладателями; используйте
на свой страх и риск и в рамках законодательства своей страны.
