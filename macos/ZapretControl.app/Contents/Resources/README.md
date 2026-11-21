# ZAPRET CONTROL for macOS (0.5.0)

Standalone macOS client for DPI bypass using a **native `tpws` engine** (zapret) in SOCKS mode.
No Windows host is required for local mode.

## What changed in 0.5.0

- **Local mode is now powered by native `tpws` (Mac core)** instead of the old Perl-only split proxy.
- `zapret-proxy.command` manages the engine lifecycle, system proxy settings, logs, autostart, install, and diagnostics.
- A lightweight local HTTP bridge (`lib/http-bridge.pl`) forwards system HTTP/HTTPS proxy traffic to local `tpws` SOCKS.
- Engine sources and build script are included: `macos/engine/tpws-src` + `macos/engine/build.sh`.

> Note: macOS does not provide a WinDivert equivalent. The native zapret engine for macOS/BSD is `tpws`
> (stream-level TCP desync/tampering in proxy mode). This client uses `tpws --socks` with configurable desync profiles.

## Modes

- **Local (standalone):** runs native `tpws` on this Mac and configures macOS system proxy to `127.0.0.1`.
- **LAN:** routes this Mac through an existing proxy on a Windows host running zapret/winws (no local engine started).

## Requirements

- macOS with `networksetup`, `bash`, `perl`, `curl` (standard on macOS).
- **Xcode Command Line Tools** to build the native engine (`xcode-select --install`) if a prebuilt `tpws` binary is not present.

## Quick start (local, standalone)

```bash
cd macos
chmod +x zapret-proxy.command engine/build.sh
./zapret-proxy.command --build-engine   # builds bin/tpws from included sources (once)
./zapret-proxy.command --local
./zapret-proxy.command --status
./zapret-proxy.command --test
```

`--local` starts `tpws` (SOCKS5 DPI-desync) + HTTP bridge and enables system HTTP/HTTPS/SOCKS proxy for the selected network service.

## LAN mode (via Windows zapret host)

```bash
./zapret-proxy.command --on 192.168.1.10
./zapret-proxy.command --off
```

## Commands

```bash
./zapret-proxy.command --local                      # standalone local mode (native tpws)
./zapret-proxy.command --on <IP>                    # LAN mode via Windows host
./zapret-proxy.command --off                        # disable proxy / stop local engine
./zapret-proxy.command --restart                    # restart current mode
./zapret-proxy.command --status                     # status
./zapret-proxy.command --doctor                     # diagnostics
./zapret-proxy.command --test [IP]                  # connectivity test
./zapret-proxy.command --logs [N]                   # tail logs
./zapret-proxy.command --service "Wi-Fi"            # select network service
./zapret-proxy.command --http-port 8080 --socks-port 1080
./zapret-proxy.command --desync "--split-pos=1,midsld --disorder --tlsrec=midsld+1"
./zapret-proxy.command --build-engine               # build native tpws from macos/engine/tpws-src
./zapret-proxy.command --install                    # install to ~/Applications/ZapretControl
./zapret-proxy.command --uninstall
./zapret-proxy.command --autostart on|off           # LaunchAgent (local mode)
./zapret-proxy.command --version
```

## DPI desync profile

Default profile (can be changed with `--desync` and saved in config):

```
--split-pos=1,midsld --disorder --tlsrec=midsld+1
```

You can use other `tpws` tampering options supported on macOS (e.g. `--split-any-protocol`, `--oob`, `--mss`, hostlists/ipsets if configured). Run `./bin/tpws --help` after build for full options.

## GUI

`ZapretControl.app` is a lightweight AppleScript wrapper around `zapret-proxy.command` (run from Finder/dock).
It requires the CLI/resources inside the app bundle or installed client.

## Files and paths

| Path | Purpose |
|---|---|
| `macos/bin/tpws` | Native DPI engine (built locally) |
| `macos/lib/http-bridge.pl` | HTTP CONNECT bridge to local tpws SOCKS |
| `macos/engine/tpws-src/` | tpws sources (zapret) |
| `macos/engine/build.sh` | Engine build script (`make mac`) |
| `~/Library/Application Support/ZapretControl/proxy.conf` | Saved mode/service/ports/desync |
| `~/Library/Application Support/ZapretControl/proxy.log` | Engine/bridge log |
| `~/Library/LaunchAgents/com.zapretcontrol.proxy.plist` | Autostart |

## Limitations

- `tpws` is a **stream-level** local proxy engine (not packet-level WinDivert/NFQUEUE). Effectiveness depends on DPI behavior and chosen desync profile.
- QUIC/HTTP3 (UDP/443) is not handled by TCP proxying; disable QUIC in browser or rely on TCP fallback where possible.
- System proxy settings apply to apps that honor macOS proxy settings.
- You may need to allow local networking prompts and grant admin rights to modify network proxy settings.

## CI / tests

GitHub Actions workflow `.github/workflows/test-macos.yml` builds the native `tpws` engine on macOS runners, runs syntax/self-tests, and executes `macos/tests/run-tests.sh`.