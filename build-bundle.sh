#!/usr/bin/env bash

set -euo pipefail

GO_TAG=v3.1.20260828
GO_SHA=24c656cfb80ff6855702710eaf2e3729fa710bf6bfdbbbdfba01984ccd17de95
TOOLS_TAG=v3.1.20260812
TOOLS_SHA=dbd8ce0748d835d18f30bb76720246b7bfc80bd09cd17c379b1c59f683a18493
MUSL_AMD64_SHA=c5d410d9f82a4f24c549fe5d24f988f85b2679b452413a9f7e5f7b956f2fe7ea
MUSL_ARM64_SHA=c909817856d6ceda86aa510894fa3527eac7989f0ef6e87b5721c58737a06c38

here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() {
	local url=$1 sha=$2 dst=$3
	curl -fsSL --retry 3 -o "$dst" "$url"
	[ "$(sha256sum "$dst" | cut -d' ' -f1)" = "$sha" ] || {
		echo "sha256 mismatch: $url" >&2
		exit 1
	}
}

command -v go >/dev/null || { echo "go 1.25 or newer is required" >&2; exit 1; }
command -v make >/dev/null || { echo "make is required" >&2; exit 1; }

fetch "https://github.com/amnezia-vpn/amneziawg-go/archive/refs/tags/$GO_TAG.tar.gz" "$GO_SHA" "$work/go.tar.gz"
fetch "https://github.com/amnezia-vpn/amneziawg-tools/archive/refs/tags/$TOOLS_TAG.tar.gz" "$TOOLS_SHA" "$work/tools.tar.gz"
fetch "https://musl.cc/x86_64-linux-musl-cross.tgz" "$MUSL_AMD64_SHA" "$work/musl-amd64.tgz"
fetch "https://musl.cc/aarch64-linux-musl-cross.tgz" "$MUSL_ARM64_SHA" "$work/musl-arm64.tgz"

mkdir -p "$work/go-src" "$work/tools-src" "$work/musl"
tar -xzf "$work/go.tar.gz" --strip-components=1 -C "$work/go-src"
tar -xzf "$work/tools.tar.gz" --strip-components=1 -C "$work/tools-src"
tar -xzf "$work/musl-amd64.tgz" -C "$work/musl"
tar -xzf "$work/musl-arm64.tgz" -C "$work/musl"

for arch in amd64 arm64; do
	case $arch in
	amd64) triple=x86_64-linux-musl ;;
	arm64) triple=aarch64-linux-musl ;;
	esac
	stage=$work/stage-$arch
	mkdir -p "$stage"

	(
		cd "$work/go-src"
		CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -buildvcs=false \
			-ldflags "-s -w -buildid=" -o "$stage/amneziawg-go" .
	)

	rm -rf "$work/tools-$arch"
	cp -r "$work/tools-src" "$work/tools-$arch"
	PATH="$work/musl/$triple-cross/bin:$PATH" make -C "$work/tools-$arch/src" \
		CC="$triple-gcc" LDFLAGS="-static -s" -j"$(nproc)" >/dev/null
	install -m 755 "$work/tools-$arch/src/wg" "$stage/awg"
	install -m 755 "$work/tools-$arch/src/wg-quick/linux.bash" "$stage/awg-quick"
	printf 'amneziawg-go %s\namneziawg-tools %s\n' "$GO_TAG" "$TOOLS_TAG" >"$stage/VERSION"
	chmod 755 "$stage/amneziawg-go" "$stage/awg" "$stage/awg-quick"
	chmod 644 "$stage/VERSION"

	tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
		-cf - -C "$stage" amneziawg-go awg awg-quick VERSION | gzip -9n >"$out/amneziawg-linux-$arch.tar.gz"
	(cd "$out" && sha256sum "amneziawg-linux-$arch.tar.gz" >"amneziawg-linux-$arch.tar.gz.sha256")
	cat "$out/amneziawg-linux-$arch.tar.gz.sha256"
done
