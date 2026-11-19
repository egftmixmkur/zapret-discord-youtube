#!/usr/bin/perl
# ZAPRET CONTROL — локальный прокси с обходом DPI для macOS.
#
# Принимает HTTP (CONNECT) и SOCKS5 на 127.0.0.1, открывает соединение
# с целевым сервером и отправляет TLS ClientHello двумя частями. Многие
# DPI-системы не склеивают такие сегменты и не видят SNI, поэтому
# соединение проходит. Данные не изменяются: TLS остаётся целым.
#
# Зависимостей нет: только модули из штатного Perl macOS.
#
# Использование:
#   perl desync-proxy.pl [--http-port 8080] [--socks-port 1080]
#                        [--split 0] [--delay 0] [--log FILE] [--pid FILE]
#   perl desync-proxy.pl --selftest
#
# --split 0   — делить посередине имени хоста в SNI (по умолчанию);
# --split N   — делить на байте N (1..65535);
# --delay MS  — пауза между частями, миллисекунды;
# --no-split  — не трогать TLS (обычный прокси).

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Socket qw(SOL_SOCKET SO_REUSEADDR IPPROTO_TCP TCP_NODELAY);
use POSIX qw(:sys_wait_h);
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time sleep);

my $VERSION   = '0.1.0';
my $HTTP_PORT = $ENV{ZAPRET_PROXY_HTTP_PORT} || 8080;
my $SOCKS_PORT = $ENV{ZAPRET_PROXY_SOCKS_PORT} || 1080;
my $SPLIT     = 0;      # 0 = автоматически (середина SNI)
my $DELAY_MS  = 0;
my $NO_SPLIT  = 0;
my $LOG_FILE  = $ENV{ZAPRET_PROXY_LOG} || '';
my $PID_FILE  = $ENV{ZAPRET_PROXY_PID} || '';
my $SELFTEST  = 0;
my $HELP      = 0;
my $SHOW_VER  = 0;
my $RUN_USER  = $ENV{ZAPRET_RUN_USER} || '';
my $IDLE      = 600;
my $CONNECT_TIMEOUT = 15;

GetOptions(
    'http-port=i'  => \$HTTP_PORT,
    'socks-port=i' => \$SOCKS_PORT,
    'split=i'      => \$SPLIT,
    'delay=i'      => \$DELAY_MS,
    'no-split'     => \$NO_SPLIT,
    'log=s'        => \$LOG_FILE,
    'pid=s'        => \$PID_FILE,
    'user=s'       => \$RUN_USER,
    'selftest'     => \$SELFTEST,
    'help|h'       => \$HELP,
    'version|V'    => \$SHOW_VER,
) or usage(2);

sub usage {
    my ($code) = @_;
    print STDERR <<"USAGE";
ZAPRET CONTROL local proxy $VERSION

  desync-proxy.pl [--http-port 8080] [--socks-port 1080]
                  [--split N|0] [--delay MS] [--no-split]
                  [--log FILE] [--pid FILE] [--user NAME]
  desync-proxy.pl --selftest
  desync-proxy.pl --version
USAGE
    exit $code;
}

if ($SHOW_VER) { print "ZAPRET CONTROL local proxy $VERSION\n"; exit 0; }
usage(0) if $HELP;
$SPLIT = 1 if $SPLIT < 0;
$DELAY_MS = 0 if $DELAY_MS < 0;
$DELAY_MS = 1000 if $DELAY_MS > 1000;

my $LOG;
sub logmsg {
    my ($msg) = @_;
    return unless $LOG;
    my $t = localtime();
    print $LOG "$t $msg\n";
}

# ------------------------------ утилиты ----------------------------------

sub ip_is_private {
    my ($addr) = @_;
    return 1 unless defined $addr && length($addr) == 4;
    my @b = unpack('C4', $addr);
    return 1 if $b[0] == 0 || $b[0] == 10 || $b[0] == 127;
    return 1 if $b[0] == 169 && $b[1] == 254;
    return 1 if $b[0] == 172 && $b[1] >= 16 && $b[1] <= 31;
    return 1 if $b[0] == 192 && $b[1] == 168;
    return 1 if $b[0] == 100 && $b[1] >= 64 && $b[1] <= 127;
    return 1 if $b[0] >= 224;
    return 0;
}

sub resolve_ipv4 {
    my ($host) = @_;
    return undef unless defined $host && length $host;
    if ($host =~ /^\d+\.\d+\.\d+\.\d+$/) {
        my $packed = inet_aton($host);
        return $packed;
    }
    my $packed = inet_aton($host);
    return $packed;
}

sub connect_target {
    my ($host, $port, $peer) = @_;
    my $ip = resolve_ipv4($host);
    unless (defined $ip) {
        logmsg("connect $host:$port failed: dns");
        return undef;
    }
    if (ip_is_private($ip)) {
        logmsg("connect $host:$port denied: private address");
        return undef;
    }
    my $sock = IO::Socket::INET->new(
        PeerAddr => inet_ntoa($ip),
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $CONNECT_TIMEOUT,
    );
    logmsg("connect $host:$port " . ($sock ? 'ok' : "failed: $!"));
    return $sock;
}

sub send_all {
    my ($sock, $data) = @_;
    my $off = 0;
    my $len = length($data);
    while ($off < $len) {
        my $n = syswrite($sock, $data, $len - $off, $off);
        return 0 unless defined $n && $n > 0;
        $off += $n;
    }
    return 1;
}

# --------------------------- разбор TLS ClientHello ------------------------

# Вернуть позицию, на которой безопасно разорвать ClientHello.
# 0 — это не TLS ClientHello (трогать не нужно).
sub tls_split_point {
    my ($buf) = @_;
    return 0 if length($buf) < 6;
    return 0 unless ord(substr($buf, 0, 1)) == 0x16;      # handshake
    return 0 unless ord(substr($buf, 1, 1)) == 3;         # TLS

    my $rec_len = unpack('n', substr($buf, 3, 2));
    my $end = 5 + $rec_len;
    $end = length($buf) if $end > length($buf);
    return 0 if $end < 6;
    return int($end / 2) if $SPLIT > 0 && $SPLIT < $end;

    # ClientHello: type(1) + len(3) + version(2) + random(32) = 43
    return int($end / 2) unless ord(substr($buf, 5, 1)) == 1;
    my $p = 43;
    return int($end / 2) if $p + 1 > $end;

    my $sid = ord(substr($buf, $p, 1));
    $p += 1 + $sid;
    return int($end / 2) if $p + 2 > $end;
    my $cs = unpack('n', substr($buf, $p, 2));
    $p += 2 + $cs;
    return int($end / 2) if $p + 1 > $end;
    my $comp = ord(substr($buf, $p, 1));
    $p += 1 + $comp;
    return int($end / 2) if $p + 2 > $end;

    my $ext_len = unpack('n', substr($buf, $p, 2));
    $p += 2;
    my $ext_end = $p + $ext_len;
    $ext_end = $end if $ext_end > $end;

    while ($p + 4 <= $ext_end) {
        my $type = unpack('n', substr($buf, $p, 2));
        my $len  = unpack('n', substr($buf, $p + 2, 2));
        if ($type == 0) {                       # server_name
            if ($p + 9 <= $ext_end) {
                my $nlen = unpack('n', substr($buf, $p + 7, 2));
                my $start = $p + 9;
                if ($nlen > 2 && $start + $nlen <= $ext_end) {
                    # делим имя хоста примерно посередине
                    return $start + int($nlen / 2);
                }
            }
            last;
        }
        $p += 4 + $len;
    }
    return int($end / 2);
}

sub send_first_chunk {
    my ($sock, $buf) = @_;
    if ($NO_SPLIT) {
        return send_all($sock, $buf);
    }
    my $at = tls_split_point($buf);
    return send_all($sock, $buf) unless $at > 0 && $at < length($buf);

    my $one = substr($buf, 0, $at);
    my $two = substr($buf, $at);
    logmsg('tls split at ' . $at . '/' . length($buf));
    send_all($sock, $one) or return 0;
    sleep($DELAY_MS / 1000) if $DELAY_MS > 0;
    return send_all($sock, $two);
}

# ------------------------------ релей -------------------------------------

sub relay {
    my ($client, $server) = @_;
    my $pid = fork();
    if (!defined $pid) {
        logmsg('fork failed');
        return;
    }
    if ($pid == 0) {
        # ребёнок: client -> server
        $SIG{TERM} = 'DEFAULT';
        $SIG{INT}  = 'DEFAULT';
        my $first = 1;
        while (1) {
            my $n = sysread($client, my $buf, 65536);
            last unless defined $n && $n > 0;
            my $ok = $first ? send_first_chunk($server, $buf) : send_all($server, $buf);
            last unless $ok;
            $first = 0;
        }
        shutdown($server, 1);
        exit 0;
    }

    # родитель: server -> client
    while (1) {
        my $n = sysread($server, my $buf, 65536);
        last unless defined $n && $n > 0;
        last unless send_all($client, $buf);
    }
    shutdown($client, 1);
    kill 'TERM', $pid;
    waitpid($pid, 0);
}

# ------------------------------ HTTP --------------------------------------

# Прочитать заголовок до пустой строки. Вернуть ($head, $rest) или ().
sub read_head {
    my ($sock, $limit) = @_;
    my $buf = '';
    my $sel = IO::Select->new($sock);
    while (length($buf) < $limit) {
        return () unless $sel->can_read(15);
        my $n = sysread($sock, my $chunk, 4096);
        return () unless defined $n && $n > 0;
        $buf .= $chunk;
        if ($buf =~ /\r?\n\r?\n/) {
            my ($head, $rest) = split(/\r?\n\r?\n/, $buf, 2);
            return ($head, defined $rest ? $rest : '');
        }
    }
    return ();
}

sub parse_authority {
    my ($auth) = @_;
    return () unless defined $auth;
    if ($auth =~ /^\[([^\]]+)\]:(\d+)$/) { return ($1, $2); }
    if ($auth =~ /^([^:]+):(\d+)$/)      { return ($1, $2); }
    return ($auth, 80);
}

sub handle_http {
    my ($client) = @_;
    my ($head, $rest) = read_head($client, 65536);
    return unless defined $head;
    my @lines = split(/\r?\n/, $head);
    my $request = shift @lines;
    return unless defined $request;
    my ($method, $uri) = $request =~ /^(\S+)\s+(\S+)/;
    return unless defined $method && defined $uri;

    my ($host, $port, $first_line);
    if (uc($method) eq 'CONNECT') {
        ($host, $port) = parse_authority($uri);
        $first_line = $request;
    } else {
        my ($h, $p, $path) = $uri =~ m{^http://([^/:]+)(?::(\d+))?(/.*)?$}i;
        return unless defined $h;
        $host = $h;
        $port = defined $p ? $p : 80;
        $path = '/' unless defined $path && length $path;
        $first_line = "$method $path HTTP/1.1";
    }
    return unless defined $host;

    my $server = connect_target($host, $port);
    unless ($server) {
        print $client "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n";
        return;
    }

    if (uc($method) eq 'CONNECT') {
        print $client "HTTP/1.1 200 Connection established\r\n\r\n";
        logmsg("CONNECT $host:$port");
    } else {
        my $out = "$first_line\r\n";
        for my $line (@lines) {
            next if $line =~ /^Proxy-Connection:/i;
            next if $line =~ /^Proxy-Authorization:/i;
            $out .= "$line\r\n";
        }
        $out .= "\r\n";
        unless (send_all($server, $out)) { close $server; return; }
        if (length $rest && !send_first_chunk($server, $rest)) {
            close $server;
            return;
        }
        logmsg("$method $host:$port");
    }
    relay($client, $server);
    close $server;
}

# ------------------------------ SOCKS5 ------------------------------------

sub read_exact {
    my ($sock, $len) = @_;
    my $buf = '';
    while (length($buf) < $len) {
        my $n = sysread($sock, my $chunk, $len - length($buf));
        return undef unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    return $buf;
}

sub handle_socks {
    my ($client) = @_;
    my $greet = read_exact($client, 2);
    return unless defined $greet;
    my ($ver, $nmethods) = unpack('C2', $greet);
    return unless $ver == 5;
    my $methods = read_exact($client, $nmethods);
    return unless defined $methods;
    print $client "\x05\x00";                 # без аутентификации

    my $req = read_exact($client, 4);
    return unless defined $req;
    my ($rver, $cmd, $rsv, $atyp) = unpack('C4', $req);
    return unless $rver == 5 && $cmd == 1;

    my ($host, $port);
    if ($atyp == 1) {
        my $addr = read_exact($client, 4);
        return unless defined $addr;
        $host = join('.', unpack('C4', $addr));
    } elsif ($atyp == 3) {
        my $len = read_exact($client, 1);
        return unless defined $len;
        my $name = read_exact($client, ord($len));
        return unless defined $name;
        $host = $name;
    } elsif ($atyp == 4) {
        my $addr = read_exact($client, 16);
        return unless defined $addr;
        return;                                 # IPv6 пока не поддерживаем
    } else {
        return;
    }
    my $p = read_exact($client, 2);
    return unless defined $p;
    $port = unpack('n', $p);

    my $server = connect_target($host, $port);
    unless ($server) {
        print $client "\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00";
        return;
    }
    print $client "\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00";
    logmsg("SOCKS5 $host:$port");
    relay($client, $server);
    close $server;
}

# ------------------------------ запуск ------------------------------------

sub daemonize {
    my $pid = fork();
    exit 1 unless defined $pid;
    exit 0 if $pid;                             # родитель сразу выходит
    setsid();
    my $pid2 = fork();
    exit 1 unless defined $pid2;
    exit 0 if $pid2;
    chdir '/';
    open(STDIN,  '<', '/dev/null');
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');
}

sub write_pid {
    return unless $PID_FILE;
    if (open(my $fh, '>', $PID_FILE)) {
        print $fh "$$\n";
        close($fh);
    }
}

sub cleanup_pid {
    return unless $PID_FILE;
    if (open(my $fh, '<', $PID_FILE)) {
        my $pid = <$fh>;
        close($fh);
        chomp $pid if defined $pid;
        unlink $PID_FILE if defined $pid && $pid == $$;
    }
}

sub drop_privileges {
    return unless $> == 0 && $RUN_USER;
    my @pw = getpwnam($RUN_USER);
    return unless @pw;
    POSIX::setgid($pw[3]);
    POSIX::setuid($pw[2]);
}

sub selftest {
    my $fail = 0;
    my $check = sub {
        my ($name, $ok) = @_;
        print(($ok ? "ok   " : "FAIL "), $name, "\n");
        $fail++ unless $ok;
    };

    # Простейший ClientHello с SNI example.com
    my $sni = 'example.com';
    my $ext = "\x00\x00" . pack('n', 5 + length($sni)) .
              pack('n', 3 + length($sni)) . "\x00" .
              pack('n', length($sni)) . $sni;
    my $body = "\x03\x03" . ('A' x 32) . "\x00" .
               pack('n', 2) . "\x13\x01" . "\x01\x00" .
               pack('n', length($ext)) . $ext;
    # ClientHello: type + 3-байтовая длина + тело
    my $hs = "\x01" . substr(pack('N', length($body)), 1) . $body;
    my $rec = "\x16\x03\x01" . pack('n', length($hs)) . $hs;

    my $at = tls_split_point($rec);
    $check->('split внутри ClientHello', $at > 0 && $at < length($rec));
    $check->('части склеиваются в исходные данные', substr($rec,0,$at) . substr($rec,$at) eq $rec);
    my $mid = int(length($rec) / 2);
    $check->('split не в первых 5 байтах', $at > 5);
    $check->('не TLS не трогаем', tls_split_point("GET / HTTP/1.1\r\n") == 0);
    $check->('короткий буфер не трогаем', tls_split_point("\x16\x03") == 0);
    $check->('private 192.168', ip_is_private(inet_aton('192.168.1.1')) == 1);
    $check->('public 8.8.8.8', ip_is_private(inet_aton('8.8.8.8')) == 0);

    print $fail ? "selftest: FAIL ($fail)\n" : "selftest: OK\n";
    exit($fail ? 1 : 0);
}

selftest() if $SELFTEST;

drop_privileges();

if ($LOG_FILE) {
    if (open($LOG, '>>', $LOG_FILE)) {
        $LOG->autoflush(1);
    } else {
        print STDERR "cannot open log $LOG_FILE: $!\n";
    }
}

# Если запущены вручную для отладки — остаёмся на переднем плане
# (--pid задаёт клиент, которому нужен фоновый процесс).
daemonize() if $PID_FILE;

$SIG{CHLD} = 'IGNORE';
$SIG{PIPE} = 'IGNORE';
$SIG{TERM} = sub { cleanup_pid(); logmsg('stopped'); exit 0; };
$SIG{INT}  = $SIG{TERM};

my $http = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => $HTTP_PORT,
    Proto     => 'tcp',
    Listen    => 64,
    ReuseAddr => 1,
) or do { logmsg("cannot listen HTTP $HTTP_PORT: $!"); print STDERR "cannot listen HTTP $HTTP_PORT: $!\n"; exit 1; };
setsockopt($http, SOL_SOCKET, SO_REUSEADDR, pack('l', 1));

my $socks = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => $SOCKS_PORT,
    Proto     => 'tcp',
    Listen    => 64,
    ReuseAddr => 1,
) or do { logmsg("cannot listen SOCKS $SOCKS_PORT: $!"); print STDERR "cannot listen SOCKS $SOCKS_PORT: $!\n"; exit 1; };
setsockopt($socks, SOL_SOCKET, SO_REUSEADDR, pack('l', 1));

write_pid();
logmsg("started $VERSION http=$HTTP_PORT socks=$SOCKS_PORT split=" .
       ($NO_SPLIT ? 'off' : ($SPLIT || 'sni')) . " delay=$DELAY_MS");

my $sel = IO::Select->new($http, $socks);
while (1) {
    for my $listener ($sel->can_read(1)) {
        my $client = $listener->accept();
        next unless $client;
        setsockopt($client, IPPROTO_TCP, TCP_NODELAY, pack('l', 1));
        my $pid = fork();
        unless (defined $pid) {
            close $client;
            next;
        }
        if ($pid == 0) {
            $SIG{TERM} = 'DEFAULT';
            $SIG{INT}  = 'DEFAULT';
            $SIG{CHLD} = 'DEFAULT';
            close $http;
            close $socks;
            if ($listener == $http) { handle_http($client); }
            else                    { handle_socks($client); }
            close $client;
            exit 0;
        }
        close $client;
    }
}
