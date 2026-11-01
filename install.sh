#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_RAW="https://raw.githubusercontent.com/omnix-project/remnanode-cert-sync/main"
TARGET="/usr/local/sbin/sync-remnanode-certs.sh"
TMP="$(mktemp)"

cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите установщик от root: sudo bash install.sh" >&2
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$REPO_RAW/sync-remnanode-certs.sh" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP" "$REPO_RAW/sync-remnanode-certs.sh"
else
  echo "Не найден curl или wget. Установите один из них и повторите." >&2
  exit 1
fi

bash -n "$TMP"
install -o root -g root -m 755 "$TMP" "$TARGET"
echo "Скрипт установлен: $TARGET"

# При запуске через curl | sudo bash stdin занят потоком установщика.
# Перенаправляем ввод настройки с управляющего терминала.
if [[ -r /dev/tty ]]; then
  exec "$TARGET" --configure </dev/tty
else
  echo "Установка завершена. Для настройки запустите:"
  echo "  $TARGET --configure"
fi
