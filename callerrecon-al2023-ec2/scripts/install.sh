#!/usr/bin/env bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo 'Run as root: sudo bash scripts/install.sh /path/to/spam-caller-recon-v1.7.zip' >&2; exit 1; fi
ZIP="${1:-}"; [[ -f "$ZIP" ]] || { echo 'Provide an absolute path to the v1.7 ZIP' >&2; exit 1; }
[[ -f /etc/os-release ]] && source /etc/os-release
[[ "${ID:-}" == 'amzn' && "${VERSION_ID:-}" == '2023' ]] || { echo 'Amazon Linux 2023 required' >&2; exit 1; }
dnf install -y python3.11 python3.11-pip nginx httpd-tools openssl unzip tar awscli
id callerrecon &>/dev/null || useradd --system --home-dir /opt/callerrecon --shell /sbin/nologin callerrecon
install -d -o callerrecon -g callerrecon -m 0750 /opt/callerrecon/app /var/backups/callerrecon
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
unzip -q "$ZIP" -d "$TMP"
APP=$(find "$TMP" -name requirements.txt -type f -print -quit); [[ -n "$APP" ]] || { echo 'requirements.txt not found' >&2; exit 1; }
APP=$(dirname "$APP")
cp -a "$APP"/. /opt/callerrecon/app/
chown -R callerrecon:callerrecon /opt/callerrecon
chmod 0750 /opt/callerrecon/app
python3.11 -m venv /opt/callerrecon/venv
/opt/callerrecon/venv/bin/pip install --upgrade pip
/opt/callerrecon/venv/bin/pip install -r /opt/callerrecon/app/requirements.txt 'gunicorn>=22,<24'
install -d -m 0700 /etc/callerrecon
if [[ ! -f /etc/callerrecon/app.env ]]; then printf 'FLASK_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" > /etc/callerrecon/app.env; fi
chmod 0600 /etc/callerrecon/app.env
cp "$(dirname "$0")/../config/callerrecon.service" /etc/systemd/system/callerrecon.service
cp "$(dirname "$0")/../config/nginx.conf" /etc/nginx/conf.d/callerrecon.conf
install -d -m 0700 /etc/nginx/callerrecon
if [[ ! -f /etc/nginx/callerrecon/server.crt ]]; then openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 30 -keyout /etc/nginx/callerrecon/server.key -out /etc/nginx/callerrecon/server.crt -subj '/CN=callerrecon.internal' -addext 'subjectAltName=DNS:callerrecon.internal'; fi
chmod 0600 /etc/nginx/callerrecon/server.key
if [[ ! -f /etc/nginx/callerrecon/users ]]; then
  echo 'Set the initial dashboard password (input hidden):'
  htpasswd -c /etc/nginx/callerrecon/users analyst
fi
chmod 0640 /etc/nginx/callerrecon/users
chown root:nginx /etc/nginx/callerrecon/users
nginx -t
systemctl daemon-reload
systemctl enable --now callerrecon nginx
printf '\nInstalled. Access via restricted HTTPS on port 443, or SSM tunnel.\nReplace the 30-day self-signed certificate with a trusted certificate before regular use.\n'
