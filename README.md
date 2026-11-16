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

**[Скачать установщик (ZapretControlSetup.exe)](https://github.com/egftmixmkur/zapret-discord-youtube/releases/latest)** — Windows 10/11 x64, права администратора.

## Что внутри

| Путь | Назначение |
|---|---|
| `bin\` | сам zapret: `winws.exe`, `WinDivert.dll`/`WinDivert64.sys`, `cygwin1.dll`, `.bin`-файлы подделок |
| `general*.bat`, `service.bat` | 23 стратегии обхода и установка zapret службой |
| `lists\` | списки доменов и IP-подсетей |
| `proxy\` | LAN-прокси (`zapret-proxy.py`), GUI (`zapret-gui.ps1`), установщик, скрипты задач |
| `proxy\ZapretControl.exe` | собранная панель управления (UAC при запуске) |
| `proxy\ZapretControlSetup.exe` | установщик «всё в одном» (~2,2 МБ, внутри весь пакет) |
| `utils\test zapret.ps1` | тесты стратегий и `-AutoApply` для автоподбора |

## Быстрый старт

1. Запусти `proxy\start-all.bat` — скрипт сам запросит права администратора,
   поставит задачи автозапуска и вотчдог, правила брандмауэра для локальных
   подсетей и запустит прокси + zapret.
2. Либо запусти `proxy\ZapretControlSetup.exe` и поставь всё как обычную
   программу: папка установки, ярлыки, автозапуск, удаление через
   «Установка и удаление программ».
3. Настройки других устройств (адрес прокси в Wi-Fi) — на вкладке «Прокси»
   в ZAPRET CONTROL.

Подробности по прокси, вкладкам GUI, установщику и сборке —
в [`proxy/README.md`](proxy/README.md).

## Сборка из исходников

```powershell
# GUI -> proxy\ZapretControl.exe (нужен admin-манифест; -TestBuild без UAC)
powershell -ExecutionPolicy Bypass -File proxy\build-exe.ps1

# Установщик -> proxy\ZapretControlSetup.exe
powershell -ExecutionPolicy Bypass -File proxy\build-installer.ps1
```

Для сборки используется `ps2exe` из `proxy\tools\ps2exe`.

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
