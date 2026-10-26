#!/usr/bin/env bash

set -euo pipefail
umask 077

VERSION=1.0.0

REPO=v74all/amneziawg-hop
BIN_DIR=/usr/local/bin
ETC=/etc/amnezia/amneziawg
IFACE=awg0
CONF=$ETC/$IFACE.conf
STATE=$ETC/amneziawg-hop.env
USERS=$ETC/users
UNIT=/etc/systemd/system/awg-quick@.service
SYSCTL=/etc/sysctl.d/99-amneziawg.conf
SUBNET=10.66.66
MTU=1280
PRIV_NETS=169.254.0.0/16,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10

GO_TAG=v3.1.20260828
GO_SHA=24c656cfb80ff6855702710eaf2e3729fa710bf6bfdbbbdfba01984ccd17de95
TOOLS_TAG=v3.1.20260812
TOOLS_SHA=dbd8ce0748d835d18f30bb76720246b7bfc80bd09cd17c379b1c59f683a18493
GOLANG_VER=1.26.8
GOLANG_SHA_AMD64=d0f743b33e8d8945e6b1f432edd15785c70507121d6e2a723b21285eddf8b57b
GOLANG_SHA_ARM64=211ffced9dcb9633a55eac6364816ec0ddd951389a740e88fa8b3337971bdda0
BUNDLE_SHA_AMD64=ce9df51c8938319bffcb37f998a671df522c8502d300a7f4a96e131dd1ecec36
BUNDLE_SHA_ARM64=c723c67f4ccdd8bf3ee51ca9e061c9f6c097e5bc61cb5dfda927cdbd37b33506

STATE_VARS=(port hop address oracle dns spriv spub jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 binver)

port=
hop=
address=
oracle=0
dns=
spriv=
spub=
jc=
jmin=
jmax=
s1=
s2=
s3=
s4=
h1=
h2=
h3=
h4=
i1=
binver=
user=main
firewall=0
new_keys=0
from_source=0
qr=0

usage() {
	cat <<EOF
amneziawg-hop $VERSION

usage: bash install.sh [install] [options]
       bash install.sh show [NAME] [--qr]
       bash install.sh add NAME | del NAME | users
       bash install.sh hop <START:END|off>
       bash install.sh rotate [NAME]
       bash install.sh status
       bash install.sh uninstall

install options:
  --port N           udp listen port (51820)
  --hop START:END    udp port-hopping range redirected to --port (30000:50000, or off)
  --user NAME        first client name (main)
  --address HOST     server IP or domain put in client configs (auto)
  --dns A,B          dns servers put in client configs (1.1.1.1,9.9.9.9)
  --firewall         turn ufw on: ssh + existing proxy ports + awg udp port
  --new-keys         rotate the obfuscation parameters on reinstall
  --from-source      build amneziawg-go and awg from the pinned upstream sources
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '[%s/6] %-8s %s\n' "$1" "$2" "$3"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run it with sudo"; }
have() { command -v "$1" >/dev/null 2>&1; }

valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "names may use A-Z a-z 0-9 _ - (max 32): $1"; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] || die "bad port (1024-65535): $1"; }
valid_dns() {
	local re='^[0-9A-Fa-f:.]+(, ?[0-9A-Fa-f:.]+)*$'
	[[ $1 =~ $re ]] || die "bad dns list: $1"
}

norm_hop() {
	local h=${1//-/':'} a b
	if [ "$h" = off ] || [ "$h" = none ]; then
		echo off
		return
	fi
	[[ $h =~ ^([0-9]+):([0-9]+)$ ]] || die "bad hop range (expected START:END or off): $1"
	a=${BASH_REMATCH[1]}
	b=${BASH_REMATCH[2]}
	[ "$a" -ge 1024 ] && [ "$b" -le 65535 ] && [ "$a" -lt "$b" ] ||
		die "hop range must satisfy 1024 <= START < END <= 65535: $1"
	echo "$a:$b"
}

rnd() {
	local lo=$1 hi=$2 n
	n=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
	echo $((lo + n % (hi - lo + 1)))
}

arch_name() {
	case $(uname -m) in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	*) die "unsupported cpu: $(uname -m)" ;;
	esac
}

os_label() {
	# shellcheck source=/dev/null
	(. /etc/os-release 2>/dev/null && echo "$ID $VERSION_ID") || echo linux
}

ensure_pkgs() {
	have apt-get || die "install these first: $*"
	{
		DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
			DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ca-certificates
	} >/dev/null 2>&1 || die "apt-get install $* failed"
}

public_ip() {
	local ip
	ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }' |
		grep -Ev '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -n1 || true)
	if [ -z "$ip" ]; then
		for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
			ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && break
		done
	fi
	[ -n "$ip" ] || die "can't find the public address, pass --address"
	echo "$ip"
}

listen_ports() {
	local proto=$1 re=$2 flag=-tlnpH
	[ "$proto" = udp ] && flag=-ulnpH
	ss "$flag" 2>/dev/null | awk -v re="$re" '$0 ~ re { n = split($4, a, ":"); print a[n] }' | sort -u
}

format_host() {
	if [[ $1 == *:* ]] && [[ $1 != \[* ]]; then
		printf '[%s]' "$1"
	else
		printf '%s' "$1"
	fi
}

save_state() {
	local v
	: >"$STATE"
	for v in "${STATE_VARS[@]}"; do
		printf '%s=%q\n' "$v" "${!v}" >>"$STATE"
	done
	chmod 600 "$STATE"
}

load_state() {
	[ -f "$STATE" ] || die "not installed yet"
	# shellcheck source=/dev/null
	. "$STATE"
}

gen_params() {
	local order=(0 1 2 3) i j t k lo hi
	jc=$(rnd 4 8)
	jmin=$(rnd 32 128)
	jmax=$(rnd 384 900)
	while :; do
		s1=$(rnd 15 150)
		s2=$(rnd 15 150)
		s3=$(rnd 15 150)
		s4=$(rnd 4 32)
		if [ $((s1 + 148)) -ne $((s2 + 92)) ] && [ $((s1 + 148)) -ne $((s3 + 64)) ] && [ $((s2 + 92)) -ne $((s3 + 64)) ]; then
			break
		fi
	done
	for i in 3 2 1; do
		j=$(rnd 0 "$i")
		t=${order[i]}
		order[i]=${order[j]}
		order[j]=$t
	done
	for k in 0 1 2 3; do
		lo=$((order[k] * 1073741824 + $(rnd 0 268435456)))
		[ "${order[k]}" -ne 0 ] || lo=$((lo + 5))
		hi=$((lo + 134217728 + $(rnd 0 268435456)))
		printf -v "h$((k + 1))" '%s-%s' "$lo" "$hi"
	done
	i1='<b 0xc00000000108><r 8><b 0x0000><r 64>'
}

pick_hop() {
	local cand a b ok line rng x y
	for cand in 30000:50000 50001:60000; do
		a=${cand%:*}
		b=${cand#*:}
		ok=1
		while read -r line; do
			rng=$(grep -oE -e '--dports? [0-9]+(:[0-9]+)?' <<<"$line" | awk '{ print $2 }' | head -n1)
			[ -n "$rng" ] || continue
			x=${rng%:*}
			y=${rng#*:}
			if [ "$a" -le "$y" ] && [ "$x" -le "$b" ]; then
				ok=0
			fi
		done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -E -e '-p udp' | grep -E -e '-j (REDIRECT|DNAT)' || true)
		if [ $ok -eq 1 ]; then
			echo "$cand"
			return
		fi
	done
	die "both default hop ranges overlap existing udp redirects, pass --hop START:END"
}

check_hop_free() {
	local a=${hop%:*} b=${hop#*:} line rng x y
	[ "$hop" != off ] || return 0
	while read -r line; do
		[[ $line == *"--to-ports $port"* && $line == *addrtype* ]] && continue
		rng=$(grep -oE -e '--dports? [0-9]+(:[0-9]+)?' <<<"$line" | awk '{ print $2 }' | head -n1)
		[ -n "$rng" ] || continue
		x=${rng%:*}
		y=${rng#*:}
		if [ "$a" -le "$y" ] && [ "$x" -le "$b" ]; then
			die "hop range $hop overlaps an existing udp redirect ($rng)"
		fi
	done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -E -e '-p udp' | grep -E -e '-j (REDIRECT|DNAT)' || true)
}

fw_rules() {
	cat <<EOF
filter INPUT -i $IFACE -j DROP
filter INPUT -i $IFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
filter INPUT -i $IFACE -p icmp -j ACCEPT
filter FORWARD -o $IFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
filter FORWARD -i $IFACE -j ACCEPT
filter FORWARD -i $IFACE -d $PRIV_NETS -j REJECT
filter FORWARD -i $IFACE -o $IFACE -j DROP
nat POSTROUTING -s $SUBNET.0/24 ! -o $IFACE -j MASQUERADE
mangle FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -i $IFACE -j TCPMSS --clamp-mss-to-pmtu
mangle FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -o $IFACE -j TCPMSS --clamp-mss-to-pmtu
EOF
	if [ "$hop" != off ]; then
		echo "nat PREROUTING -p udp -m udp --dport $hop -m addrtype --dst-type LOCAL -j REDIRECT --to-ports $port"
	fi
	if [ "$oracle" -eq 1 ]; then
		echo "filter INPUT -p udp -m udp --dport $port -j ACCEPT"
	fi
}

hop_rule() {
	local op=$1 rng=$2 dst=$3
	local spec=(-p udp -m udp --dport "$rng" -m addrtype --dst-type LOCAL -j REDIRECT --to-ports "$dst")
	if [ "$op" = add ]; then
		iptables -t nat -C PREROUTING "${spec[@]}" 2>/dev/null || iptables -t nat -I PREROUTING 1 "${spec[@]}"
	else
		while iptables -t nat -D PREROUTING "${spec[@]}" 2>/dev/null; do :; done
	fi
}

rules_state() {
	local t c rest spec total=0 present=0
	while read -r t c rest; do
		read -ra spec <<<"$rest"
		total=$((total + 1))
		if iptables -t "$t" -C "$c" "${spec[@]}" 2>/dev/null; then
			present=$((present + 1))
		fi
	done < <(fw_rules)
	echo "$present/$total"
}

render_conf() {
	local n priv pub psk ip ep t c spec tmp
	tmp=$(mktemp "$ETC/.conf.XXXXXX")
	{
		cat <<EOF
[Interface]
PrivateKey = $spriv
Address = $SUBNET.1/24
ListenPort = $port
MTU = $MTU
Jc = $jc
Jmin = $jmin
Jmax = $jmax
S1 = $s1
S2 = $s2
S3 = $s3
S4 = $s4
H1 = $h1
H2 = $h2
H3 = $h3
H4 = $h4
EOF
		while read -r t c spec; do
			printf 'PostUp = iptables -t %s -I %s 1 %s\n' "$t" "$c" "$spec"
		done < <(fw_rules)
		while read -r t c spec; do
			printf 'PostDown = iptables -t %s -D %s %s || true\n' "$t" "$c" "$spec"
		done < <(fw_rules)
		while read -r n priv pub psk ip ep; do
			cat <<EOF

[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $ip/32
EOF
		done <"$USERS"
	} >"$tmp"
	chmod 600 "$tmp"
	mv "$tmp" "$CONF"
}

client_conf() {
	local name=$1 priv pub psk ip ep host
	read -r _ priv _ psk ip ep < <(grep "^$name " "$USERS")
	host=$(format_host "$address")
	[ "$hop" != off ] || ep=$port
	cat <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = $dns
MTU = $MTU
Jc = $jc
Jmin = $jmin
Jmax = $jmax
S1 = $s1
S2 = $s2
S3 = $s3
S4 = $s4
H1 = $h1
H2 = $h2
H3 = $h3
H4 = $h4
I1 = $i1

[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = $host:$ep
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
}

new_peer() {
	local name=$1 priv pub psk ip i ep
	priv=$("$BIN_DIR/awg" genkey)
	pub=$("$BIN_DIR/awg" pubkey <<<"$priv")
	psk=$("$BIN_DIR/awg" genpsk)
	for i in $(seq 2 254); do
		grep -q " $SUBNET.$i " "$USERS" 2>/dev/null || break
	done
	[ "$i" -lt 254 ] || die "no free address left in $SUBNET.0/24"
	ip=$SUBNET.$i
	ep=$port
	[ "$hop" = off ] || ep=$(rnd "${hop%:*}" "${hop#*:}")
	printf '%s %s %s %s %s %s\n' "$name" "$priv" "$pub" "$psk" "$ip" "$ep" >>"$USERS"
	chmod 600 "$USERS"
}

reload_conf() {
	render_conf
	if "$BIN_DIR/awg" show "$IFACE" >/dev/null 2>&1; then
		"$BIN_DIR/awg" syncconf "$IFACE" <("$BIN_DIR/awg-quick" strip "$IFACE")
	fi
}

fetch_verified() {
	local url=$1 want=$2 dst=$3 got
	curl -fsSL --retry 2 -o "$dst" "$url" || die "download failed: $url"
	got=$(sha256sum "$dst" | cut -d' ' -f1)
	[ "$got" = "$want" ] || die "sha256 mismatch for $url"
}

build_from_source() {
	local tmp=$1 a gosha
	a=$(arch_name)
	if ! have gcc || ! have make; then
		ensure_pkgs build-essential
	fi
	case $a in
	amd64) gosha=$GOLANG_SHA_AMD64 ;;
	arm64) gosha=$GOLANG_SHA_ARM64 ;;
	esac
	fetch_verified "https://github.com/amnezia-vpn/amneziawg-go/archive/refs/tags/$GO_TAG.tar.gz" "$GO_SHA" "$tmp/go.tar.gz"
	fetch_verified "https://github.com/amnezia-vpn/amneziawg-tools/archive/refs/tags/$TOOLS_TAG.tar.gz" "$TOOLS_SHA" "$tmp/tools.tar.gz"
	fetch_verified "https://dl.google.com/go/go$GOLANG_VER.linux-$a.tar.gz" "$gosha" "$tmp/golang.tar.gz"
	mkdir -p "$tmp/go-src" "$tmp/tools-src" "$tmp/x"
	tar -xzf "$tmp/golang.tar.gz" -C "$tmp"
	tar -xzf "$tmp/go.tar.gz" --strip-components=1 -C "$tmp/go-src"
	tar -xzf "$tmp/tools.tar.gz" --strip-components=1 -C "$tmp/tools-src"
	(
		cd "$tmp/go-src"
		PATH="$tmp/go/bin:$PATH" GOCACHE="$tmp/gocache" GOPATH="$tmp/gopath" CGO_ENABLED=0 \
			go build -trimpath -buildvcs=false -ldflags "-s -w" -o "$tmp/x/amneziawg-go" .
	) >/dev/null 2>&1 || die "go build failed"
	make -C "$tmp/tools-src/src" -j"$(nproc)" >/dev/null 2>&1 || die "awg build failed"
	install -m 755 "$tmp/tools-src/src/wg" "$tmp/x/awg"
	install -m 755 "$tmp/tools-src/src/wg-quick/linux.bash" "$tmp/x/awg-quick"
	printf 'amneziawg-go %s\namneziawg-tools %s\n' "$GO_TAG" "$TOOLS_TAG" >"$tmp/x/VERSION"
}

install_binary() {
	local a bundle want src='' dir tmp
	a=$(arch_name)
	tmp=$(mktemp -d)
	TMPD=$tmp
	trap 'rm -rf "${TMPD:-}"' EXIT
	mkdir -p "$tmp/x"
	bundle=amneziawg-linux-$a.tar.gz
	case $a in
	amd64) want=$BUNDLE_SHA_AMD64 ;;
	arm64) want=$BUNDLE_SHA_ARM64 ;;
	esac
	if [ $from_source -eq 1 ]; then
		build_from_source "$tmp"
		src="built from source"
	else
		for dir in "$(dirname "$0")" .; do
			if [ -f "$dir/$bundle" ]; then
				cp "$dir/$bundle" "$tmp/$bundle"
				src="local bundle"
				break
			fi
		done
		if [ -z "$src" ]; then
			fetch_verified "https://github.com/$REPO/releases/download/v$VERSION/$bundle" "$want" "$tmp/$bundle"
			src="github release"
		fi
		[ "$(sha256sum "$tmp/$bundle" | cut -d' ' -f1)" = "$want" ] || die "sha256 mismatch for $bundle, not installing it"
		tar -xzf "$tmp/$bundle" -C "$tmp/x"
	fi
	install -d -m 755 "$BIN_DIR"
	install -m 755 "$tmp/x/amneziawg-go" "$tmp/x/awg" "$tmp/x/awg-quick" "$BIN_DIR/"
	binver=$(awk '$1 == "amneziawg-go" { print $2 }' "$tmp/x/VERSION")
	if [ $from_source -eq 1 ]; then
		step 2 binary "amneziawg-go $binver, $src"
	else
		step 2 binary "amneziawg-go $binver, $src, sha256 ok"
	fi
}

write_unit() {
	cat >"$UNIT" <<EOF
[Unit]
Description=AmneziaWG 2.0 tunnel %i (amneziawg-hop)
Documentation=https://github.com/$REPO
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity
ExecStart=$BIN_DIR/awg-quick up %i
ExecStop=$BIN_DIR/awg-quick down %i
ExecReload=/bin/bash -c 'exec $BIN_DIR/awg syncconf %i <(exec $BIN_DIR/awg-quick strip %i)'
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/run
ProtectHome=true
PrivateTmp=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
	chmod 644 "$UNIT"
}

start_service() {
	systemctl daemon-reload
	systemctl enable "awg-quick@$IFACE" >/dev/null 2>&1
	systemctl restart "awg-quick@$IFACE" || true
	sleep 1
	if ! systemctl is-active --quiet "awg-quick@$IFACE" || ! "$BIN_DIR/awg" show "$IFACE" >/dev/null 2>&1; then
		journalctl -u "awg-quick@$IFACE" -n 20 --no-pager >&2 || true
		die "awg-quick@$IFACE did not start"
	fi
}

setup_network() {
	local fw_note p
	cat >"$SYSCTL" <<EOF
net.ipv4.ip_forward=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=2621440
net.core.wmem_default=2621440
EOF
	chmod 644 "$SYSCTL"
	sysctl -q -e -p "$SYSCTL" >/dev/null 2>&1 || true
	[ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || die "can't enable net.ipv4.ip_forward"

	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		ufw allow "$port/udp" >/dev/null
		fw_note="ufw updated"
	elif [ $firewall -eq 1 ]; then
		have ufw || ensure_pkgs ufw
		ufw default deny incoming >/dev/null
		ufw default allow outgoing >/dev/null
		for p in $(listen_ports tcp '"sshd"') 22; do ufw allow "$p/tcp" >/dev/null; done
		for p in $(listen_ports tcp '"(xray|sing-box|nginx|caddy)"'); do ufw allow "$p/tcp" >/dev/null; done
		for p in $(listen_ports udp '"(hysteria|sing-box)"'); do ufw allow "$p/udp" >/dev/null; done
		ufw allow "$port/udp" >/dev/null
		ufw --force enable >/dev/null
		fw_note="ufw on"
	else
		fw_note="ufw untouched"
	fi
	if [ "$hop" != off ]; then
		step 6 network "udp $hop -> $port, forward on, $fw_note"
	else
		step 6 network "hop off (udp $port only), forward on, $fw_note"
	fi
}

cmd_install() {
	need_root
	have systemctl && [ -d /run/systemd/system ] || die "this needs a systemd server"
	valid_name "$user"

	local reinstall=0 c_port=$port c_hop=$hop c_address=$address c_dns=$dns old_hop=off old_port=51820
	if [ -f "$STATE" ]; then
		reinstall=1
		load_state
		old_hop=$hop
		old_port=$port
		port=${c_port:-$port}
		hop=${c_hop:-$hop}
		address=${c_address:-$address}
		dns=${c_dns:-$dns}
	fi
	port=${port:-51820}
	dns=${dns:-1.1.1.1,9.9.9.9}
	valid_port "$port"
	valid_dns "$dns"
	dns=$(tr -d ' ' <<<"$dns" | sed 's/,/, /g')

	local os p missing=()
	os=$(os_label)
	have curl || missing+=(curl)
	have iptables || missing+=(iptables)
	have ip || missing+=(iproute2)
	if [ ${#missing[@]} -gt 0 ]; then
		ensure_pkgs "${missing[@]}"
	fi
	if [ ! -c /dev/net/tun ]; then
		mkdir -p /dev/net
		mknod /dev/net/tun c 10 200 2>/dev/null || true
	fi
	[ -c /dev/net/tun ] || die "no /dev/net/tun, enable TUN/TAP in the server panel"

	if ss -ulnpH "sport = :$port" 2>/dev/null | grep -v amneziawg | grep -q .; then
		die "udp port $port is already used by: $(ss -ulnpH "sport = :$port" | grep -o 'users:(("[^"]*' | cut -d'"' -f2 | head -n1)"
	fi

	if [ $reinstall -eq 1 ]; then
		hop=$(norm_hop "${hop:-off}")
	elif [ -n "$hop" ]; then
		hop=$(norm_hop "$hop")
		check_hop_free
	else
		hop=$(pick_hop)
	fi
	if [ "$old_hop" != off ] && { [ "$old_hop" != "$hop" ] || [ "$old_port" != "$port" ]; }; then
		hop_rule del "$old_hop" "$old_port"
	fi
	oracle=0
	if iptables -S INPUT 2>/dev/null | grep -q 'icmp-host-prohibited'; then
		oracle=1
	fi
	step 1 system "$os, $(uname -m), systemd, tun ok"

	install_binary

	install -d -m 700 "$ETC"
	local keynote
	if [ $reinstall -eq 0 ]; then
		spriv=$("$BIN_DIR/awg" genkey)
		spub=$("$BIN_DIR/awg" pubkey <<<"$spriv")
		gen_params
		: >"$USERS"
		chmod 600 "$USERS"
		[ -n "$address" ] || address=$(public_ip)
		save_state
		new_peer "$user"
		keynote="server + $user keys, psk, jc=$jc s1-s4 h1-h4 random"
	elif [ $new_keys -eq 1 ]; then
		gen_params
		save_state
		keynote="obfuscation parameters rotated, keys kept"
	else
		save_state
		keynote="kept (reinstall), pass --new-keys to rotate"
	fi
	step 3 keys "$keynote"

	render_conf
	step 4 config "$CONF, mtu $MTU"

	write_unit
	start_service
	local kind=userspace
	[ -S "/var/run/amneziawg/$IFACE.sock" ] || kind=kernel
	step 5 service "awg-quick@$IFACE active, $kind amneziawg"

	setup_network
	echo "done. client config: sudo bash install.sh show"
}

cmd_show() {
	need_root
	load_state
	local name=${1:-}
	[ -n "$name" ] || name=$(awk 'NR == 1 { print $1 }' "$USERS")
	valid_name "$name"
	grep -q "^$name " "$USERS" || die "no client named $name"
	if [ $qr -eq 1 ]; then
		have qrencode || ensure_pkgs qrencode
		client_conf "$name" | qrencode -t ANSIUTF8 -m 1
	else
		client_conf "$name"
	fi
}

cmd_add() {
	need_root
	load_state
	local name=${1:-}
	[ -n "$name" ] || die "usage: install.sh add NAME"
	valid_name "$name"
	grep -q "^$name " "$USERS" && die "$name already exists"
	new_peer "$name"
	reload_conf
	cmd_show "$name"
}

cmd_del() {
	need_root
	load_state
	local name=${1:-}
	[ -n "$name" ] || die "usage: install.sh del NAME"
	valid_name "$name"
	grep -q "^$name " "$USERS" || die "no client named $name"
	[ "$(grep -c . "$USERS")" -gt 1 ] || die "$name is the last client; uninstall instead"
	sed -i "/^$name /d" "$USERS"
	reload_conf
	echo "removed $name (its config stops working now)"
}

cmd_users() {
	need_root
	load_state
	awk '{ printf "%-16s %-12s udp %s\n", $1, $5, $6 }' "$USERS"
}

cmd_hop() {
	need_root
	load_state
	[ -n "${1:-}" ] || die "usage: install.sh hop <START:END|off>"
	local new_hop old_hop=$hop tmp n priv pub psk ip ep
	new_hop=$(norm_hop "$1")
	hop=$new_hop
	check_hop_free
	[ "$old_hop" = off ] || hop_rule del "$old_hop" "$port"
	[ "$new_hop" = off ] || hop_rule add "$new_hop" "$port"
	tmp=$(mktemp)
	while read -r n priv pub psk ip ep; do
		if [ "$hop" = off ]; then
			ep=$port
		elif [ "$ep" -lt "${hop%:*}" ] || [ "$ep" -gt "${hop#*:}" ]; then
			ep=$(rnd "${hop%:*}" "${hop#*:}")
		fi
		printf '%s %s %s %s %s %s\n' "$n" "$priv" "$pub" "$psk" "$ip" "$ep"
	done <"$USERS" >"$tmp"
	install -m 600 "$tmp" "$USERS"
	rm -f "$tmp"
	save_state
	render_conf
	if [ "$hop" = off ]; then
		printf 'hop       off (udp %s only)\n' "$port"
	else
		printf 'hop       udp %s -> %s (saved)\n' "$hop" "$port"
	fi
	printf 'configs   sudo bash install.sh show\n'
}

cmd_rotate() {
	need_root
	load_state
	[ "$hop" != off ] || die "hop is off, nothing to rotate"
	local target=${1:-} tmp n priv pub psk ip ep found=0
	[ -z "$target" ] || valid_name "$target"
	tmp=$(mktemp)
	while read -r n priv pub psk ip ep; do
		if [ -z "$target" ] || [ "$n" = "$target" ]; then
			ep=$(rnd "${hop%:*}" "${hop#*:}")
			found=1
			printf '%-16s udp %s\n' "$n" "$ep" >&2
		fi
		printf '%s %s %s %s %s %s\n' "$n" "$priv" "$pub" "$psk" "$ip" "$ep"
	done <"$USERS" >"$tmp"
	if [ $found -eq 0 ]; then
		rm -f "$tmp"
		die "no client named $target"
	fi
	install -m 600 "$tmp" "$USERS"
	rm -f "$tmp"
}

cmd_status() {
	need_root
	load_state
	local svc kind listen nat peers rules n pub ts line age
	svc=$(systemctl is-active "awg-quick@$IFACE" 2>/dev/null || true)
	kind=kernel
	[ -S "/var/run/amneziawg/$IFACE.sock" ] && kind=userspace
	listen=$("$BIN_DIR/awg" show "$IFACE" listen-port 2>/dev/null || true)
	rules=$(rules_state)
	if [ "$hop" = off ]; then
		nat=off
	elif iptables -t nat -C PREROUTING -p udp -m udp --dport "$hop" -m addrtype --dst-type LOCAL -j REDIRECT --to-ports "$port" 2>/dev/null; then
		nat="udp $hop -> $port"
	else
		nat="missing ($hop -> $port)"
	fi
	peers=
	while read -r pub ts; do
		[ -n "${pub:-}" ] || continue
		n=$(awk -v k="$pub" '$3 == k { print $1 }' "$USERS")
		if [ "${ts:-0}" -gt 0 ]; then
			age=$(($(date +%s) - ts))
			line="$n ${age}s"
		else
			line="$n never"
		fi
		peers+="${peers:+, }$line"
	done < <("$BIN_DIR/awg" show "$IFACE" latest-handshakes 2>/dev/null || true)
	printf 'service   %s (%s, amneziawg-go %s)\n' "${svc:-inactive}" "$kind" "$binver"
	printf 'listen    udp %s\n' "${listen:-not bound}"
	printf 'hop       %s\n' "$nat"
	printf 'rules     %s active (isolation, private blocked, mss)\n' "$rules"
	printf 'forward   %s\n' "$([ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] && echo on || echo off)"
	printf 'address   %s\n' "$address"
	printf 'clients   %s\n' "${peers:-none}"
}

cmd_uninstall() {
	need_root
	systemctl disable --now "awg-quick@$IFACE" >/dev/null 2>&1 || true
	rm -f "$UNIT" "$SYSCTL" "$BIN_DIR/amneziawg-go" "$BIN_DIR/awg" "$BIN_DIR/awg-quick"
	rm -rf "$ETC" /run/amneziawg
	rmdir /etc/amnezia 2>/dev/null || true
	systemctl daemon-reload
	echo "removed amneziawg, port-hopping and firewall rules, config and keys (ufw rules stay as they are)"
}

cmd=install
case ${1:-} in
install | show | add | del | users | hop | rotate | status | uninstall) cmd=$1; shift ;;
esac
args=()
while [ $# -gt 0 ]; do
	case $1 in
	--port) port=${2:?--port needs a number}; shift ;;
	--hop) hop=${2:?--hop needs START:END or off}; shift ;;
	--user) user=${2:?--user needs a name}; shift ;;
	--address) address=${2:?--address needs a host}; shift ;;
	--dns) dns=${2:?--dns needs a list}; shift ;;
	--firewall) firewall=1 ;;
	--new-keys) new_keys=1 ;;
	--from-source) from_source=1 ;;
	--qr) qr=1 ;;
	-h | --help) usage; exit 0 ;;
	--version) echo "$VERSION"; exit 0 ;;
	-*) die "unknown option: $1 (see --help)" ;;
	*) args+=("$1") ;;
	esac
	shift
done

case $cmd in
install) cmd_install ;;
show) cmd_show "${args[0]:-}" ;;
add) cmd_add "${args[0]:-}" ;;
del) cmd_del "${args[0]:-}" ;;
users) cmd_users ;;
hop) cmd_hop "${args[0]:-}" ;;
rotate) cmd_rotate "${args[0]:-}" ;;
status) cmd_status ;;
uninstall) cmd_uninstall ;;
esac
