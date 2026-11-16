#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
zapret LAN proxy — прокси для передачи обхода zapret на другие устройства
в локальной сети (телефоны, ТВ, приставки, ноутбуки).

Принцип работы:
  1. Устройство в локальной сети подключается к этому прокси
     (HTTP  :8080 или SOCKS5 :1080)
  2. Прокси открывает исходящие соединения С ЭТОГО ПК
  3. zapret (winws.exe) перехватывает эти исходящие соединения и применяет
     DPI-обход автоматически. Доменные списки (hostlist) работают как обычно:
     ClientHello пробрасывается через туннель без изменений, SNI сохраняется.

Разрешение имён:
  сначала системный DNS; если он вернул NXDOMAIN/ошибку (типичная DNS-блокировка
  провайдером) ИЛИ если подключение по полученным адресам не удалось
  (провайдерская «заглушка» или устаревшая запись в hosts) — автоматически
  используется DNS-over-HTTPS (dns.google, dns.quad9.net, cloudflare-dns.com,
  эти домены сами проходят через zapret). Благодаря этому устройствам НЕ
  обязателен свой DoH.

Управление (см. README.md):
  proxy.disabled — файл-флаг: если существует, прокси молча не запускается
  (ставится stop-all.bat, снимается start-all.bat)

Только стандартная библиотека Python 3 (asyncio), зависимостей нет.

Настройка портов (переменные окружения перед запуском):
  ZAPRET_PROXY_HTTP_PORT   (по умолчанию 8080)
  ZAPRET_PROXY_SOCKS_PORT  (по умолчанию 1080)
  ZAPRET_PROXY_DOH         (список DoH-URL через запятую)

Безопасность:
  - подключаться могут только адреса локальной сети (RFC1918, loopback)
  - цели внутри приватных/зарезервированных диапазонов запрещены
    (защита от SSRF и от закольцовки прокси на самого себя)
  - аутентификации нет: доступ только из LAN, дополнительно ограничивается
    правилом брандмауэра из start-all.bat
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import os
import random
import socket
import struct
import sys
import time
import urllib.request
from logging.handlers import RotatingFileHandler

VERSION = "1.4"
START_TIME = time.time()

HTTP_PORT = int(os.environ.get("ZAPRET_PROXY_HTTP_PORT", "8080"))
SOCKS_PORT = int(os.environ.get("ZAPRET_PROXY_SOCKS_PORT", "1080"))
UDP_RANGE_START = int(os.environ.get("ZAPRET_PROXY_UDP_RANGE_START", "31000"))
UDP_RANGE_END = int(os.environ.get("ZAPRET_PROXY_UDP_RANGE_END", "31999"))
DOH_URLS = [u.strip() for u in os.environ.get(
    "ZAPRET_PROXY_DOH",
    "https://dns.google/dns-query,"
    "https://dns.quad9.net/dns-query,"
    "https://cloudflare-dns.com/dns-query").split(",") if u.strip()]

CONNECT_TIMEOUT = 15.0   # таймаут установки исходящего соединения, сек
IDLE_TIMEOUT = 600.0     # таймаут простоя TCP-туннеля, сек
UDP_IDLE_TIMEOUT = 180.0 # таймаут простоя UDP-сессии SOCKS5, сек
DNS_TTL = 60.0           # кэш DNS-разрешений, сек
DOH_TIMEOUT = 6.0        # таймаут запроса к DoH-серверу, сек
MAX_HEADER = 65536       # максимум байт заголовка HTTP-запроса
CHUNK = 65536            # размер буфера релея

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Кто может подключаться к прокси (локальная сеть + loopback)
_CLIENT_NETS = (
    "127.0.0.0/8", "::1/128",
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "169.254.0.0/16", "fe80::/10",
)
# Куда прокси не подключается (приватные и зарезервированные диапазоны)
_DENY_NETS = (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
    "192.0.2.0/24", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
    "255.255.255.255/32",
    "::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
)
ALLOWED_CLIENTS = tuple(ipaddress.ip_network(n) for n in _CLIENT_NETS)
DENIED_TARGETS = tuple(ipaddress.ip_network(n) for n in _DENY_NETS)

log = logging.getLogger("zapret-proxy")


# ------------------------------ утилиты ----------------------------------

def _init_log() -> None:
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s",
                            "%Y-%m-%d %H:%M:%S")
    try:
        handler = RotatingFileHandler(
            os.path.join(_SCRIPT_DIR, "proxy.log"),
            maxBytes=2 * 1024 * 1024, backupCount=1, encoding="utf-8")
        handler.setFormatter(fmt)
        log.addHandler(handler)
    except OSError:
        pass


def _loop_exc_handler(loop, context) -> None:
    """Логировать необработанные исключения задач (не падать молча)."""
    exc = context.get("exception")
    msg = context.get("message") or ""
    if exc is not None:
        log.error("asyncio %s: %r", msg, exc)
    else:
        log.error("asyncio %s", msg)


def _stopped_by_user() -> bool:
    """Файл-флаг proxy.disabled: пользователь выключил прокси скриптом."""
    return os.path.exists(os.path.join(_SCRIPT_DIR, "proxy.disabled"))


def _port_in_use(port: int) -> bool:
    """Слушает ли кто-то порт (защита от двойного запуска — без ошибок
    сокета 10048, второй экземпляр просто тихо выходит)."""
    for addr in ("127.0.0.1", "::1"):
        try:
            with socket.create_connection((addr, port), timeout=0.5):
                return True
        except OSError:
            continue
    return False


def _pid_path() -> str:
    return os.path.join(_SCRIPT_DIR, "proxy.pid")


def _write_pid() -> None:
    try:
        with open(_pid_path(), "w", encoding="ascii") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass


def _remove_pid() -> None:
    """Удалить proxy.pid, только если он принадлежит этому процессу."""
    try:
        with open(_pid_path(), "r", encoding="ascii") as f:
            owner = f.read().strip()
    except OSError:
        return
    if owner == str(os.getpid()):
        try:
            os.remove(_pid_path())
        except OSError:
            pass


def _ip(text: str):
    try:
        return ipaddress.ip_address(text)
    except ValueError:
        return None


def _client_ok(peer) -> bool:
    if not peer:
        return False
    ip = _ip(peer[0])
    return ip is not None and any(ip in net for net in ALLOWED_CLIENTS)


def _target_ok(ip) -> bool:
    return not any(ip in net for net in DENIED_TARGETS)


def _close(writer) -> None:
    try:
        writer.close()
    except Exception:
        pass


def _split_hostport(target: bytes):
    """host:port, [v6]:port -> (host, port)."""
    t = target.decode("latin-1")
    if t.startswith("["):
        host, _, rest = t.partition("]")
        host = host[1:]
        port = int(rest.lstrip(":")) if rest.lstrip(":") else 443
        return host, port
    host, sep, port = t.rpartition(":")
    if not sep:
        return t, 443
    return host, int(port)


_udp_port_next = UDP_RANGE_START


def _bind_relay_socket(family):
    """UDP-сокет релея в фиксированном диапазоне портов
    (нужно для правила брандмауэра). При исчерпании — эфемерный порт."""
    global _udp_port_next
    any_addr = "::" if family == socket.AF_INET6 else "0.0.0.0"
    span = UDP_RANGE_END - UDP_RANGE_START + 1
    for _ in range(span):
        port = _udp_port_next
        _udp_port_next = UDP_RANGE_START if _udp_port_next >= UDP_RANGE_END \
            else _udp_port_next + 1
        s = socket.socket(family, socket.SOCK_DGRAM)
        s.setblocking(False)
        try:
            s.bind((any_addr, port))
            return s
        except OSError:
            try:
                s.close()
            except OSError:
                pass
    s = socket.socket(family, socket.SOCK_DGRAM)
    s.setblocking(False)
    s.bind((any_addr, 0))
    return s


# ------------------------------ DoH-резолвер ------------------------------

def _doh_query_blocking(url: str, name: str, qtype: int):
    """Синхронный DoH-запрос (RFC 8484). Возврат: список IP или None."""
    labels = name.rstrip(".").split(".")
    qname = b"".join(bytes([len(l)]) + l.encode("ascii") for l in labels)
    qname += b"\x00"
    if len(qname) > 255:
        return None
    qid = random.getrandbits(16)
    query = (struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
             + qname + struct.pack(">HH", qtype, 1))
    try:
        req = urllib.request.Request(
            url, data=query, method="POST",
            headers={"Content-Type": "application/dns-message",
                     "Accept": "application/dns-message"})
        # без системного прокси — только напрямую (через zapret)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=DOH_TIMEOUT) as resp:
            data = resp.read()
    except Exception:
        return None
    try:
        if len(data) < 12:
            return None
        rcode = struct.unpack(">H", data[2:4])[0] & 0xF
        qd = struct.unpack(">H", data[4:6])[0]
        an = struct.unpack(">H", data[6:8])[0]
        if rcode != 0:
            return []
        off = 12
        for _ in range(qd):          # пропустить секцию вопроса
            while off < len(data):
                ln = data[off]
                off += 1
                if ln == 0:
                    break
                if ln & 0xC0:        # сжатие
                    off += 1
                    break
                off += ln
            off += 4
        out = []
        for _ in range(an):          # секция ответов
            while off < len(data):    # имя (возможно сжатое)
                ln = data[off]
                off += 1
                if ln == 0:
                    break
                if ln & 0xC0:
                    off += 1
                    break
                off += ln
            if off + 10 > len(data):
                break
            rtype, _rclass, _ttl, rdlen = struct.unpack(
                ">HHIH", data[off:off + 10])
            off += 10
            rdata = data[off:off + rdlen]
            off += rdlen
            if rtype == qtype:
                if qtype == 1 and rdlen == 4:
                    out.append(socket.inet_ntoa(rdata))
                elif qtype == 28 and rdlen == 16:
                    out.append(socket.inet_ntop(socket.AF_INET6, rdata))
        return out
    except (struct.error, IndexError, OSError):
        return None


async def _doh_resolve(name: str) -> list:
    """Разрешить имя через DoH (A + AAAA), вернуть список IP."""
    loop = asyncio.get_running_loop()

    def fetch(url: str, qtype: int):
        return _doh_query_blocking(url, name, qtype)

    for url in DOH_URLS:
        a, aaaa = await asyncio.gather(
            loop.run_in_executor(None, fetch, url, 1),
            loop.run_in_executor(None, fetch, url, 28))
        ips = [ip for ip in (a or []) + (aaaa or []) if ip]
        if ips:
            log.debug("doh %s -> %s via %s", name, ips, url)
            return ips
    return []


_dns_cache: dict = {}


async def resolve_host(name: str) -> list:
    """Разрешить имя в список (family, sockaddr).

    Порядок: системный DNS, при ошибке/NXDOMAIN — DoH.
    Результат кэшируется на DNS_TTL секунд.
    """
    loop = asyncio.get_running_loop()
    now = time.monotonic()
    hit = _dns_cache.get(name)
    if hit and hit[1] > now:
        return hit[0]

    infos: list = []
    try:
        raw = await loop.getaddrinfo(name, None, family=socket.AF_UNSPEC,
                                     type=socket.SOCK_STREAM)
        infos = [(i[0], i[4]) for i in raw]
    except OSError:
        pass
    if not infos:
        ips = await _doh_resolve(name)
        for ip in ips:
            ipobj = _ip(ip)
            if ipobj is None:
                continue
            family = (socket.AF_INET6 if ipobj.version == 6
                      else socket.AF_INET)
            infos.append((family, (ip, 0)))
        if ips:
            log.info("resolved %s via DoH -> %s", name, ips)
    if infos:
        _dns_cache[name] = (infos, now + DNS_TTL)
    return infos


# --------------------------- исходящие соединения ------------------------

async def _connect_infos(host: str, port: int, infos):
    """Подключиться к первому доступному адресу из infos."""
    last_exc = None
    for family, sockaddr in infos:
        ip = _ip(sockaddr[0])
        if ip is None or not _target_ok(ip):
            continue
        s = socket.socket(family, socket.SOCK_STREAM)
        s.setblocking(False)
        try:
            await asyncio.wait_for(
                asyncio.get_running_loop().sock_connect(s, sockaddr),
                CONNECT_TIMEOUT)
            return await asyncio.open_connection(sock=s)
        except OSError as exc:
            last_exc = exc
            try:
                s.close()
            except OSError:
                pass
    if last_exc is not None:
        raise last_exc
    raise ConnectionRefusedError(f"no usable address for {host}:{port}")


async def connect_target(host: str, port: int):
    """Разрешить имя и подключиться.

    Сначала адреса из системного DNS; если подключиться не удалось
    (провайдерская заглушка вместо IP, битая запись в hosts) —
    повторяем с чистыми адресами из DoH.
    """
    ipobj = _ip(host)
    if ipobj is not None:
        infos = [(socket.AF_INET6 if ipobj.version == 6 else socket.AF_INET,
                  (host, port))]
        return await _connect_infos(host, port, infos)
    resolved = await resolve_host(host)
    infos = [(fam, (addr[0], port)) for fam, addr in resolved]
    try:
        return await _connect_infos(host, port, infos)
    except OSError as exc:
        ips = await _doh_resolve(host)
        doh_infos = []
        for ip in ips:
            o = _ip(ip)
            if o is None:
                continue
            fam = socket.AF_INET6 if o.version == 6 else socket.AF_INET
            doh_infos.append((fam, (ip, port)))
        if doh_infos:
            log.info("connect to %s:%s failed (%r), retrying via DoH",
                      host, port, exc)
            try:
                return await _connect_infos(host, port, doh_infos)
            except OSError:
                pass
        raise


# ------------------------------ релей TCP --------------------------------

async def _copy(src: asyncio.StreamReader, dst: asyncio.StreamWriter,
                tag: str) -> None:
    try:
        while True:
            data = await asyncio.wait_for(src.read(CHUNK), IDLE_TIMEOUT)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log.debug("relay %s: %r", tag, exc)


async def _pipe(c_reader, c_writer, u_reader, u_writer, tag: str) -> None:
    up = asyncio.create_task(_copy(c_reader, u_writer, tag + " ->net"))
    down = asyncio.create_task(_copy(u_reader, c_writer, tag + " <-net"))
    try:
        await asyncio.wait({up, down}, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in (up, down):
            task.cancel()
        await asyncio.gather(up, down, return_exceptions=True)
    _close(c_writer)
    _close(u_writer)


# ------------------------------ HTTP-прокси -------------------------------

_HOP_HEADERS = {
    b"proxy-connection", b"connection", b"keep-alive",
    b"proxy-authenticate", b"proxy-authorization", b"te", b"trailer",
    b"upgrade", b"transfer-encoding",
}


async def _read_head(reader: asyncio.StreamReader):
    buf = bytearray()
    while b"\r\n\r\n" not in buf:
        chunk = await asyncio.wait_for(reader.read(CHUNK), IDLE_TIMEOUT)
        if not chunk:
            return None, b""
        buf += chunk
        if len(buf) > MAX_HEADER:
            raise ValueError("http header too large")
    head, _, rest = bytes(buf).partition(b"\r\n\r\n")
    return head, rest


async def _send_health(writer: asyncio.StreamWriter) -> None:
    """Простой health-check для GUI/вотчдога (только из LAN)."""
    body = json.dumps({
        "status": "ok",
        "version": VERSION,
        "uptime": round(time.time() - START_TIME, 1),
        "http_port": HTTP_PORT,
        "socks_port": SOCKS_PORT,
        "doh": DOH_URLS,
    }, ensure_ascii=False).encode("utf-8")
    writer.write(
        b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: application/json; charset=utf-8\r\n"
        b"Cache-Control: no-store\r\n"
        b"Connection: close\r\n"
        b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n"
        + body)
    await writer.drain()


async def handle_http(reader: asyncio.StreamReader,
                      writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername")
    try:
        if not _client_ok(peer):
            log.warning("http: refused non-LAN client %r", peer)
            return
        head, rest = await _read_head(reader)
        if head is None:
            return
        lines = head.split(b"\r\n")
        parts = lines[0].split()
        if len(parts) != 3:
            writer.write(b"HTTP/1.1 400 Bad Request\r\n"
                         b"Connection: close\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            return
        method, target, _version = parts

        if method.upper() == b"GET" and target in (b"/health", b"/healthz"):
            await _send_health(writer)
            return

        if method.upper() == b"CONNECT":
            host, port = _split_hostport(target)
            ur, uw = await connect_target(host, port)
            writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            await writer.drain()
            log.info("http CONNECT %s:%s <- %s", host, port, peer[0])
            await _pipe(reader, writer, ur, uw, f"{host}:{port}")
            return

        if target.startswith(b"http://") or target.startswith(b"https://"):
            from urllib.parse import urlsplit
            u = urlsplit(target.decode("latin-1"))
            host = u.hostname or ""
            port = u.port or (443 if u.scheme == "https" else 80)
            path = (u.path or "/") + (("?" + u.query) if u.query else "")
            out = [method + b" " + path.encode("latin-1") + b" HTTP/1.1"]
            for line in lines[1:]:
                if b":" not in line:
                    continue
                name = line.split(b":", 1)[0].strip().lower()
                if name in _HOP_HEADERS:
                    continue
                out.append(line)
            out.append(b"Connection: close")
            request = b"\r\n".join(out) + b"\r\n\r\n"
            ur, uw = await connect_target(host, port)
            uw.write(request + rest)
            await uw.drain()
            log.info("http %s %s://%s:%s%s <- %s",
                     method.decode("latin-1"), u.scheme, host, port,
                     path, peer[0])
            await _pipe(reader, writer, ur, uw, f"{host}:{port}")
            return

        writer.write(b"HTTP/1.1 400 Bad Request\r\n"
                     b"Connection: close\r\nContent-Length: 0\r\n\r\n")
        await writer.drain()
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log.info("http error from %r: %r", peer, exc)
        try:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n"
                         b"Connection: close\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
        except Exception:
            pass
    finally:
        _close(writer)


# ------------------------------ SOCKS5 ------------------------------------

def _socks_reply_bytes(rep: int, addr: str, port: int) -> bytes:
    ip = _ip(addr) or ipaddress.ip_address("0.0.0.0")
    if ip.version == 4:
        return (b"\x05" + bytes([rep]) + b"\x00\x01"
                + socket.inet_aton(str(ip)) + port.to_bytes(2, "big"))
    return (b"\x05" + bytes([rep]) + b"\x00\x04"
            + socket.inet_pton(socket.AF_INET6, str(ip))
            + port.to_bytes(2, "big"))


def _socks_udp_header(addr: str, port: int) -> bytes:
    ip = _ip(addr)
    if ip is None:
        return b""
    if ip.version == 4:
        return (b"\x00\x00\x00\x01" + socket.inet_aton(str(ip))
                + port.to_bytes(2, "big"))
    return (b"\x00\x00\x00\x04" + socket.inet_pton(socket.AF_INET6, str(ip))
            + port.to_bytes(2, "big"))


async def _udp_pump(sock: socket.socket,
                    tcp_reader: asyncio.StreamReader) -> None:
    """Релей SOCKS5 UDP ASSOCIATE: клиент <-> любые внешние узлы."""
    loop = asyncio.get_running_loop()
    client_addr = None
    targets: set = set()

    async def watch_eof():
        try:
            while True:
                if not await tcp_reader.read(CHUNK):
                    return
        except Exception:
            return

    eof_task = asyncio.create_task(watch_eof())
    try:
        while not eof_task.done():
            recv_task = asyncio.create_task(
                loop.sock_recvfrom(sock, 65535))
            try:
                await asyncio.wait_for(
                    asyncio.wait({recv_task, eof_task},
                                 return_when=asyncio.FIRST_COMPLETED),
                    UDP_IDLE_TIMEOUT)
            except asyncio.TimeoutError:
                recv_task.cancel()
                await asyncio.gather(recv_task, return_exceptions=True)
                log.debug("udp session idle timeout")
                break
            if recv_task.done():
                try:
                    data, src = recv_task.result()
                except asyncio.CancelledError:
                    raise
                except Exception:
                    break
                # определяем сторону: клиент всегда из приватной сети,
                # внешние цели всегда публичные (приватные запрещены)
                if _client_ok(src):
                    client_addr = src
                    await _udp_client_datagram(sock, data, targets)
                elif client_addr is not None and src[0] in targets:
                    header = _socks_udp_header(src[0], src[1])
                    if header:
                        await loop.sock_sendto(sock, header + data,
                                               client_addr)
                # иначе: посторонний внешний источник — игнорируем
            else:
                # eof_task завершился первым: клиент отключился
                recv_task.cancel()
                await asyncio.gather(recv_task, return_exceptions=True)
                break
    finally:
        eof_task.cancel()
        await asyncio.gather(eof_task, return_exceptions=True)
        sock.close()


async def _udp_client_datagram(sock: socket.socket, data: bytes,
                               targets: set) -> None:
    if len(data) < 4:
        return
    if data[2]:  # фрагментация не поддерживается
        return
    atyp = data[3]
    if atyp == 1:
        if len(data) < 10:
            return
        host = socket.inet_ntoa(data[4:8])
        off = 8
    elif atyp == 3:
        if len(data) < 5:
            return
        ln = data[4]
        if len(data) < 5 + ln + 2:
            return
        host = data[5:5 + ln].decode("latin-1")
        off = 5 + ln
    elif atyp == 4:
        if len(data) < 22:
            return
        host = socket.inet_ntop(socket.AF_INET6, data[4:20])
        off = 20
    else:
        return
    if len(data) < off + 2:
        return
    port = int.from_bytes(data[off:off + 2], "big")
    payload = data[off + 2:]
    if not payload:
        return
    ipobj = _ip(host)
    if ipobj is not None:
        ips = [host]
    else:
        resolved = await resolve_host(host)
        ips = [addr[0] for _fam, addr in resolved]
    for ip in ips:
        ipobj = _ip(ip)
        if ipobj is None or not _target_ok(ipobj):
            continue
        targets.add(ip)
        await loop_sendto(sock, payload, (ip, port))


async def loop_sendto(sock: socket.socket, payload: bytes, dest) -> None:
    try:
        await asyncio.get_running_loop().sock_sendto(sock, payload, dest)
    except OSError as exc:
        log.debug("udp sendto %r: %r", dest, exc)


async def handle_socks(reader: asyncio.StreamReader,
                       writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername")
    try:
        if not _client_ok(peer):
            log.warning("socks: refused non-LAN client %r", peer)
            return
        hdr = await asyncio.wait_for(reader.readexactly(2), IDLE_TIMEOUT)
        ver, nmethods = hdr[0], hdr[1]
        if ver != 5:
            return
        methods = await asyncio.wait_for(reader.readexactly(nmethods),
                                         IDLE_TIMEOUT)
        if 0 not in methods:
            writer.write(b"\x05\xff")
            await writer.drain()
            return
        writer.write(b"\x05\x00")  # без аутентификации
        await writer.drain()

        req = await asyncio.wait_for(reader.readexactly(4), IDLE_TIMEOUT)
        _ver, cmd, _rsv, atyp = req
        if atyp == 1:
            host = socket.inet_ntoa(
                await reader.readexactly(4))
        elif atyp == 3:
            ln = (await reader.readexactly(1))[0]
            host = (await reader.readexactly(ln)).decode("latin-1")
        elif atyp == 4:
            host = socket.inet_ntop(
                socket.AF_INET6, await reader.readexactly(16))
        else:
            writer.write(_socks_reply_bytes(0x08, "0.0.0.0", 0))
            await writer.drain()
            return
        port = int.from_bytes(await reader.readexactly(2), "big")

        if cmd == 0x01:  # CONNECT
            ipobj = _ip(host)
            if ipobj is not None and not _target_ok(ipobj):
                writer.write(_socks_reply_bytes(0x02, host, port))
                await writer.drain()
                return
            ur, uw = await connect_target(host, port)
            local = uw.get_extra_info("sockname")
            writer.write(_socks_reply_bytes(0x00,
                                            local[0] if local else host,
                                            port))
            await writer.drain()
            log.info("socks CONNECT %s:%s <- %s", host, port, peer[0])
            await _pipe(reader, writer, ur, uw, f"socks {host}:{port}")
        elif cmd == 0x03:  # UDP ASSOCIATE
            family = socket.AF_INET6 if ":" in peer[0] else socket.AF_INET
            sock = _bind_relay_socket(family)
            relay_port = sock.getsockname()[1]
            local = writer.get_extra_info("sockname")
            writer.write(_socks_reply_bytes(0x00, local[0], relay_port))
            await writer.drain()
            log.info("socks UDP-ASSOC client=%s relay_port=%s",
                     peer[0], relay_port)
            await _udp_pump(sock, reader)
        else:
            writer.write(_socks_reply_bytes(0x07, "0.0.0.0", 0))
            await writer.drain()
    except (asyncio.IncompleteReadError, asyncio.TimeoutError):
        pass
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log.info("socks error from %r: %r", peer, exc)
    finally:
        _close(writer)


# -------------------------------- запуск ----------------------------------

async def _serve(handler, port: int, name: str) -> list:
    servers = []
    for bind in ("0.0.0.0", "::"):
        try:
            srv = await asyncio.start_server(handler, host=bind, port=port)
            servers.append(srv)
        except OSError as exc:
            log.warning("%s: cannot bind %s:%s (%r)", name, bind, port, exc)
    if not servers:
        raise RuntimeError(f"cannot bind {name} port {port}")
    return servers


async def main() -> None:
    loop = asyncio.get_running_loop()
    loop.set_exception_handler(_loop_exc_handler)

    if _stopped_by_user():
        log.info("proxy.disabled found - proxy stopped by user, exiting")
        return

    if HTTP_PORT == SOCKS_PORT:
        log.error("HTTP and SOCKS ports must differ (both %s)", HTTP_PORT)
        return

    # защита от двойного запуска: если порт уже слушают (наш прошлый
    # экземпляр или кто-то ещё) — тихо выходим, никаких ошибок сокета
    busy = sorted({p for p in (HTTP_PORT, SOCKS_PORT) if _port_in_use(p)})
    if busy:
        log.info("port(s) %s already in use - another zapret LAN proxy "
                 "instance is running, exiting",
                 ", ".join(str(p) for p in busy))
        return

    log.info("zapret LAN proxy v%s starting: http=%s socks=%s doh=%s",
             VERSION, HTTP_PORT, SOCKS_PORT, ",".join(DOH_URLS))
    http_servers = await _serve(handle_http, HTTP_PORT, "http")
    socks_servers = await _serve(handle_socks, SOCKS_PORT, "socks")
    _write_pid()
    log.info("ready: devices in LAN may use this PC as proxy "
             "(http :%s, socks5 :%s)", HTTP_PORT, SOCKS_PORT)
    try:
        await asyncio.Event().wait()
    finally:
        _remove_pid()
        for srv in http_servers + socks_servers:
            srv.close()
        log.info("proxy stopped")


if __name__ == "__main__":
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsProactorEventLoopPolicy())
    _init_log()
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    except Exception:
        log.exception("fatal error, proxy stopped")
