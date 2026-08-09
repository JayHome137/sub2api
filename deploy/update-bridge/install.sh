#!/bin/sh

set -eu

BINARY=${1:-}
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行安装脚本" >&2
  exit 1
fi
if [ -z "$BINARY" ] || [ ! -f "$BINARY" ] || [ ! -x "$BINARY" ]; then
  echo "用法: $0 /path/to/aifoo-update-bridge" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

if ! getent group aifoo-update-bridge >/dev/null 2>&1; then
  groupadd --system aifoo-update-bridge
fi
if ! id aifoo-update-bridge >/dev/null 2>&1; then
  useradd --system --gid aifoo-update-bridge --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin aifoo-update-bridge
fi

install -d -o root -g aifoo-update-bridge -m 0750 /etc/aifoo-update-bridge
install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$BINARY" /usr/local/libexec/aifoo-update-bridge
install -o root -g root -m 0644 \
  "$SCRIPT_DIR/aifoo-update-bridge.service" \
  /etc/systemd/system/aifoo-update-bridge.service
systemctl daemon-reload

echo "bridge_installed=true"
if [ -s /etc/aifoo-update-bridge/github-token ]; then
  chown root:aifoo-update-bridge /etc/aifoo-update-bridge/github-token
  chmod 0640 /etc/aifoo-update-bridge/github-token
  echo "token_ready=true"
else
  echo "token_ready=false"
  echo "尚未启动服务：请先按 README 写入 GitHub Fine-grained PAT。"
fi
