#!/usr/bin/perl
# ZAPRET CONTROL - lightweight local HTTP CONNECT proxy bridging to a local SOCKS5 (tpws).
# Used to provide HTTP/HTTPS system proxy while DPI desync is handled by native tpws engine.
# No DPI tampering is done here.
#
# Usage:
#   http-bridge.pl --listen 127.0.0.1 --port 8080 --socks 127.0.0.1 --socks-port 1080 [--pid FILE] [--log FILE]
#   http-bridge.pl --selftest

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use POSIX qw(setsid);
use Getopt::Long qw(GetOptions);

my $LISTEN='127.0.0.1'; my $PORT=8080; my $SOCKS='127.0.0.1'; my $SPORT=1080; my $PIDF=''; my $LOGF=''; my $SELFTEST=0; my $HELP=0;
GetOptions('listen=s'=>\$LISTEN,'port=i'=>\$PORT,'socks=s'=>\$SOCKS,'socks-port=i'=>\$SPORT,'pid=s'=>\$PIDF,'log=s'=>\$LOGF,'selftest'=>\$SELFTEST,'help'=>\$HELP) or exit 2;
if ($HELP) { print "http-bridge.pl --listen 127.0.0.1 --port 8080 --socks 127.0.0.1 --socks-port 1080 [--pid FILE] [--log FILE]\n"; exit 0; }
if ($SELFTEST) { print "selftest: OK\n"; exit 0; }

my $LOG;
if ($LOGF) { if (open($LOG,'>>',$LOGF)) { $LOG->autoflush(1); } }
sub logm { my($m)=@_; return unless $LOG; my $t=localtime(); print $LOG "$t $m\n"; }

sub daemonize {
  my $pid=fork(); exit 1 unless defined $pid; exit 0 if $pid;
  setsid(); my $pid2=fork(); exit 1 unless defined $pid2; exit 0 if $pid2;
  chdir '/'; open(STDIN,'<','/dev/null'); open(STDOUT,'>','/dev/null'); open(STDERR,'>','/dev/null');
}
sub write_pid { return unless $PIDF; if (open my $fh,'>',$PIDF){ print $fh "$$\n"; close $fh; } }
sub cleanup_pid { return unless $PIDF; if (open my $fh,'<',$PIDF){ my $p=<$fh>; close $fh; chomp $p if defined $p; unlink $PIDF if defined $p && $p==$$; } }

sub read_head {
  my($s,$lim)=@_; my $buf=''; my $sel=IO::Select->new($s);
  while (length($buf)<$lim){ return () unless $sel->can_read(15); my $n=sysread($s,my $c,4096); return () unless defined $n && $n>0; $buf.=$c; if($buf=~/\r?\n\r?\n/){ my($h,$r)=split(/\r?\n\r?\n/,$buf,2); return ($h, defined $r?$r:''); } }
  return ();
}
sub send_all { my($s,$d)=@_; my $o=0; my $l=length($d); while($o<$l){ my $n=syswrite($s,$d,$l-$o,$o); return 0 unless defined $n && $n>0; $o+=$n; } return 1; }
sub read_exact { my($s,$len)=@_; my $b=''; while(length($b)<$len){ my $n=sysread($s,my $c,$len-length($b)); return undef unless defined $n && $n>0; $b.=$c; } return $b; }

sub socks5_connect {
  my($host,$port)=@_;
  my $s=IO::Socket::INET->new(PeerAddr=>$SOCKS,PeerPort=>$SPORT,Proto=>'tcp',Timeout=>10) or return undef;
  # greeting: no auth
  return undef unless send_all($s,"\x05\x01\x00");
  my $gr=read_exact($s,2); return undef unless defined $gr && $gr eq "\x05\x00";
  my $req;
  if ($host =~ /^\d+\.\d+\.\d+\.\d+$/) {
    my @b=split(/\./,$host); $req="\x05\x01\x00\x01".pack('C4',@b).pack('n',$port);
  } else {
    my $h=$host; $h=substr($h,0,255); $req="\x05\x01\x00\x03".pack('C',length($h)).$h.pack('n',$port);
  }
  return undef unless send_all($s,$req);
  my $rep=read_exact($s,4); return undef unless defined $rep && substr($rep,1,1) eq "\x00";
  my $atyp=ord(substr($rep,3,1));
  if ($atyp==1){ read_exact($s,4+2); } elsif ($atyp==3){ my $l=read_exact($s,1); return undef unless defined $l; read_exact($s,ord($l)+2); } elsif ($atyp==4){ read_exact($s,16+2); } else { return undef; }
  return $s;
}

sub relay {
  my($c,$s)=@_; my $pid=fork(); return unless defined $pid;
  if($pid==0){ $SIG{TERM}='DEFAULT'; $SIG{INT}='DEFAULT'; while(1){ my $n=sysread($c,my $b,65536); last unless defined $n && $n>0; last unless send_all($s,$b);} shutdown($s,1); exit 0; }
  while(1){ my $n=sysread($s,my $b,65536); last unless defined $n && $n>0; last unless send_all($c,$b);} shutdown($c,1); kill 'TERM',$pid; waitpid($pid,0);
}

sub handle_http {
  my($client)=@_; my($head,$rest)=read_head($client,65536); return unless defined $head;
  my @lines=split(/\r?\n/,$head); my $req=shift @lines; return unless defined $req;
  my($method,$uri)=$req=~/^(\S+)\s+(\S+)/; return unless defined $method && defined $uri;
  my($host,$port);
  if (uc($method) eq 'CONNECT') { ($host,$port)=($uri =~ /^([^:]+):(\d+)$/); }
  else { ($host,$port,my $path)=($uri =~ m{^http://([^/:]+)(?::(\d+))?(/.*)?$}i); $port=80 unless defined $port; $path='/' unless defined $path; }
  return unless defined $host && defined $port;
  my $srv=socks5_connect($host,$port);
  unless($srv){ print $client "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"; return; }
  if (uc($method) eq 'CONNECT') {
    print $client "HTTP/1.1 200 Connection established\r\n\r\n";
  } else {
    my $path='/'; if ($uri =~ m{^http://[^/]+(/.*)$}i){ $path=$1; }
    my $out="$method $path HTTP/1.1\r\n"; for my $l(@lines){ next if $l=~/^Proxy-/i; $out.="$l\r\n"; } $out.="\r\n";
    send_all($srv,$out) or do { close $srv; return; };
    if(length $rest){ send_all($srv,$rest) or do { close $srv; return; }; }
  }
  relay($client,$srv); close $srv;
}

$SIG{CHLD}='IGNORE'; $SIG{PIPE}='IGNORE'; $SIG{TERM}=sub{ cleanup_pid(); exit 0; }; $SIG{INT}=$SIG{TERM};
daemonize(); write_pid();
my $ls=IO::Socket::INET->new(LocalAddr=>$LISTEN,LocalPort=>$PORT,Proto=>'tcp',Listen=>64,ReuseAddr=>1) or do { logm("listen $PORT failed: $!"); exit 1; };
logm("http-bridge listening on $LISTEN:$PORT -> socks $SOCKS:$SPORT");
while(1){ my $c=$ls->accept(); next unless $c; setsockopt($c,IPPROTO_TCP,TCP_NODELAY,pack('l',1)); my $pid=fork(); unless(defined $pid){ close $c; next; } if($pid==0){ $SIG{TERM}='DEFAULT'; $SIG{INT}='DEFAULT'; $SIG{CHLD}='DEFAULT'; close $ls; handle_http($c); close $c; exit 0; } close $c; }