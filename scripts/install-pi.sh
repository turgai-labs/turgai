#!/bin/sh
# Installs Turgai on this machine from the folder this script is in, as a service of the user who
# runs it with sudo, with its data in their ~/.turgai: it starts now and at every boot. Running it
# again updates Turgai, and keeps its data and its key.
#
# It answers on this machine only, unless it's given where to listen, such as every network it's on,
# for a phone on the same network to reach it:
#
#     sudo ./install.sh --listen 0.0.0.0
#
# Whoever reaches it signs in all the same. Running it again without --listen keeps it on this
# machine only.
set -eu

listen=127.0.0.1
while [ $# -gt 0 ]; do
    case "$1" in
    --listen)
        [ $# -ge 2 ] || { echo "--listen needs an address, such as 0.0.0.0" >&2; exit 1; }
        listen=$2
        shift 2
        ;;
    *)
        echo "Unknown option: $1. It takes --listen ADDRESS." >&2
        exit 1
        ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Run it with sudo: sudo ./install.sh" >&2
    exit 1
fi
user=${SUDO_USER:-}
if [ -z "$user" ] || [ "$user" = root ]; then
    echo "Run it with sudo as the user Turgai runs as, not as root." >&2
    exit 1
fi
home=$(getent passwd "$user" | cut -d: -f6)
here=$(cd "$(dirname "$0")" && pwd)

# Stopped while it's replaced, when it's running.
systemctl stop turgai 2>/dev/null || true

# Turgai itself, with its resources beside it.
rm -rf /opt/turgai
install -d /opt/turgai
install -m 755 "$here/turgai" /opt/turgai/turgai
cp -R "$here"/*.bundle /opt/turgai/
ln -sf /opt/turgai/turgai /usr/local/bin/turgai

# Its key, made once: only root can read it, and the service is given it as it starts.
install -d -m 700 /etc/turgai
if [ ! -f /etc/turgai/secret-key ]; then
    (umask 077 && head -c 32 /dev/urandom | base64 > /etc/turgai/secret-key)
fi

cat > /etc/systemd/system/turgai.service <<EOF
[Unit]
Description=Turgai
Wants=network-online.target
After=network-online.target

[Service]
User=$user
WorkingDirectory=$home
ExecStart=/opt/turgai/turgai serve --directory $home/.turgai --listen $listen
LoadCredential=turgai-key:/etc/turgai/secret-key
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable turgai >/dev/null 2>&1
systemctl start turgai
echo "Turgai is running, listening on $listen. Its log: journalctl -u turgai -f"
