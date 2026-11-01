#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
SOURCE_ROOT="/opt/certbot/certs/live"
DEST_DIR="/opt/remnanode/configs/xray/ssl"
CONFIG="/etc/remnanode-cert-sync.conf"
CRON_FILE="/etc/cron.d/remnanode-cert-sync"
LOG_FILE="/var/log/remnanode-cert-sync.log"
LOCK_FILE="/run/lock/remnanode-cert-sync.lock"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ОШИБКА: $*"; exit 1; }

usage() {
  cat <<EOF
RemnaNode certificate sync v$VERSION

Использование:
  $0                 Синхронизировать сертификат по сохранённой конфигурации
  $0 --configure     Настроить домен и расписание заново
  $0 --help          Показать эту справку

Сертификаты:
  Источник: $SOURCE_ROOT/ДОМЕН/{fullchain.pem,privkey.pem}
  Назначение: $DEST_DIR/{fullchain.pem,privkey.pem}

Скрипт копирует и проверяет файлы. Контейнеры и службы не перезапускаются.
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Запустите скрипт от root."
}

valid_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

check_source_files() {
  local domain="$1" dir="$SOURCE_ROOT/$1"
  local missing=()
  [[ -f "$dir/fullchain.pem" ]] || missing+=("fullchain.pem")
  [[ -f "$dir/privkey.pem" ]] || missing+=("privkey.pem")
  if (("${#missing[@]}" > 0)); then
    die "В каталоге $dir отсутствуют файлы: ${missing[*]}"
  fi
}

configure() {
  local domain answer
  while true; do
    read -r -p "Введите домен сертификата (например, example.com): " domain
    if valid_domain "$domain"; then break; fi
    printf 'Некорректный домен. Введите только имя домена, без пути и команд.\n' >&2
  done

  check_source_files "$domain"
  install -d -m 700 /etc
  printf 'DOMAIN=%q\n' "$domain" > "$CONFIG"
  chown root:root "$CONFIG"
  chmod 600 "$CONFIG"
  log "Домен $domain сохранён в $CONFIG"

  read -r -p "Добавить автоматическую проверку и обновление каждые 6 часов? [y/N]: " answer || true
  case "$answer" in
    y|Y|yes|YES|д|Д|да|ДА)
      cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 */6 * * * root $0 >> $LOG_FILE 2>&1
EOF
      chown root:root "$CRON_FILE"
      chmod 644 "$CRON_FILE"
      log "Автоматическая проверка включена: каждые 6 часов."
      ;;
    *)
      rm -f "$CRON_FILE"
      log "Автоматическая проверка отключена."
      ;;
  esac
}

load_config() {
  [[ -f "$CONFIG" ]] || die "Нет конфигурации $CONFIG. Сначала выполните: $0 --configure"
  [[ "$(stat -c '%u' "$CONFIG")" == "0" ]] || die "Файл конфигурации должен принадлежать root."
  # Файл создаётся самим скриптом и имеет права 600.
  # shellcheck disable=SC1090
  source "$CONFIG"
  [[ -n "${DOMAIN:-}" ]] || die "В конфигурации не задан DOMAIN."
  valid_domain "$DOMAIN" || die "В конфигурации указан некорректный домен."
}

validate_pair() {
  local cert="$1" key="$2" cert_pub key_pub
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "Файл сертификата не является корректным PEM: $cert"
  openssl pkey -in "$key" -noout -check >/dev/null 2>&1 || die "Файл приватного ключа некорректен: $key"

  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || die "Сертификат и приватный ключ не соответствуют друг другу."
}

sync_certs() {
  local source_dir="$SOURCE_ROOT/$DOMAIN"
  local tmp cert_new key_new cert_dest="$DEST_DIR/fullchain.pem" key_dest="$DEST_DIR/privkey.pem"
  local backup_cert backup_key had_cert=0 had_key=0

  check_source_files "$DOMAIN"
  command -v openssl >/dev/null 2>&1 || die "Не найден openssl."
  command -v flock >/dev/null 2>&1 || die "Не найден flock (обычно входит в util-linux)."

  install -d -o root -g root -m 755 "$DEST_DIR"
  exec 9>"$LOCK_FILE"
  flock -n 9 || { log "Другая синхронизация уже выполняется; пропускаю запуск."; return 0; }

  tmp="$(mktemp -d "$DEST_DIR/.cert-sync.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  cert_new="$tmp/fullchain.pem"
  key_new="$tmp/privkey.pem"
  backup_cert="$tmp/old-fullchain.pem"
  backup_key="$tmp/old-privkey.pem"

  # -L разыменовывает certbot symlink из live/ в archive/.
  cp -L -- "$source_dir/fullchain.pem" "$cert_new"
  cp -L -- "$source_dir/privkey.pem" "$key_new"
  validate_pair "$cert_new" "$key_new"
  chmod 644 "$cert_new"
  chmod 600 "$key_new"
  chown root:root "$cert_new" "$key_new"

  if [[ -f "$cert_dest" && -f "$key_dest" ]] && cmp -s "$cert_new" "$cert_dest" && cmp -s "$key_new" "$key_dest"; then
    log "Сертификаты не изменились; копирование не требуется."
    return 0
  fi

  if [[ -e "$cert_dest" ]]; then cp -a -- "$cert_dest" "$backup_cert"; had_cert=1; fi
  if [[ -e "$key_dest" ]]; then cp -a -- "$key_dest" "$backup_key"; had_key=1; fi

  # При ошибке второй установки восстанавливаем предыдущую пару файлов.
  if ! install -o root -g root -m 644 "$cert_new" "$cert_dest"; then
    die "Не удалось установить fullchain.pem."
  fi
  if ! install -o root -g root -m 600 "$key_new" "$key_dest"; then
    if (( had_cert )); then cp -a -- "$backup_cert" "$cert_dest"; else rm -f "$cert_dest"; fi
    if (( had_key )); then cp -a -- "$backup_key" "$key_dest"; else rm -f "$key_dest"; fi
    die "Не удалось установить privkey.pem; предыдущие файлы восстановлены."
  fi

  log "Сертификат и ключ для $DOMAIN обновлены."
  log "Права: fullchain.pem = root:root 644; privkey.pem = root:root 600."
  log "Перезапуск контейнера или служб не выполнялся."
}

main() {
  require_root
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --configure) configure; exit 0 ;;
    "") ;;
    *) usage; exit 2 ;;
  esac
  load_config
  sync_certs
}

main "$@"
