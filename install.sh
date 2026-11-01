#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_RAW="https://raw.githubusercontent.com/omnix-project/remnanode-cert-sync/main"
INSTALLER_URL="$REPO_RAW/install.sh"
TARGET="/usr/local/sbin/sync-remnanode-certs.sh"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите установщик от root: sudo bash install.sh" >&2
  exit 1
fi

# Если установщик запущен через curl | sudo bash, stdin занят потоком curl.
# Скачиваем установщик во временный файл и запускаем его повторно,
# подключив stdin к терминалу. Повторный запуск уже будет интерактивным.
if [[ ! -t 0 ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo "Не удалось получить доступ к терминалу для ввода домена." >&2
    echo "Скачайте install.sh в файл и запустите: sudo bash install.sh" >&2
    exit 1
  fi

  SELF_TMP="$(mktemp)"
  cleanup_self() { rm -f "$SELF_TMP"; }
  trap cleanup_self EXIT

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$INSTALLER_URL" -o "$SELF_TMP"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$SELF_TMP" "$INSTALLER_URL"
  else
    echo "Не найден curl или wget." >&2
    exit 1
  fi

  bash -n "$SELF_TMP"
  if bash "$SELF_TMP" </dev/tty; then
    exit 0
  else
    status=$?
    exit "$status"
  fi
fi

TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

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
echo "Запускаю первичную настройку..."
exec "$TARGET" --configure
