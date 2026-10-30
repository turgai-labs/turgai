#!/bin/sh
# Builds Turgai for the Raspberry Pi, a Linux arm64 executable for Debian 13, in Docker on this
# Mac, into dist/pi: the executable and the resource bundles it needs beside it.
#
# The private packages come from the clones SwiftPM keeps in .build/repositories, mirrored into
# the container, which has no GitHub login.
#
# On the Pi, Turgai needs libcurl (`apt install libcurl4t64`) and its secret key, which systemd
# keeps encrypted and gives it as its `turgai-key` credential:
#
#   openssl rand -base64 32 | sudo systemd-creds encrypt --name=turgai-key - /etc/credstore.encrypted/turgai-key
#
# and, in the service's unit:
#
#   LoadCredentialEncrypted=turgai-key
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# The private packages, as Package.swift names them.
private_packages="doppel sqlite-event-store"

# SwiftPM's own clones, fetched as the package resolves: they hold the pinned revisions.
swift package resolve

mounts=""
mirrors=""
for name in $private_packages; do
    clone=$(ls -d .build/repositories/"$name"-* | head -1)
    mounts="$mounts -v $root/$clone:/mirrors/$name.git:ro"
    mirrors="$mirrors swift package config set-mirror --original https://github.com/turgai-labs/$name.git --mirror file:///mirrors/$name.git &&"
done

mkdir -p dist
# The build's own scratch volume keeps what's built between runs.
# shellcheck disable=SC2086
docker run --rm \
    -v "$root":/src:ro \
    $mounts \
    -v turgai-linux-release:/build \
    -v "$root/dist":/dist \
    swift:6.4-trixie bash -c "
        set -e
        git config --global --add safe.directory '*'
        mkdir -p /work/norby
        cd /src
        tar cf - --exclude=./.build --exclude=./.build-llama --exclude=./Clients --exclude=./.git --exclude=./dist . \
            | (cd /work/norby && tar xf -)
        cd /work/norby
        $mirrors true
        swift build -c release --static-swift-stdlib --product Turgai --scratch-path /build
        rm -rf /dist/pi
        mkdir -p /dist/pi
        cp /build/release/Turgai /dist/pi/turgai
        strip /dist/pi/turgai
        cp -R /build/release/Turgai_TurgaiBrand.bundle /build/release/swift-transformers_Hub.bundle /dist/pi/
    "

echo "Built into $root/dist/pi"
