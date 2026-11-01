#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="2.0.0"
CERTBOT_ROOT="/opt/certbot"
SOURCE_ROOT="$CERTBOT_ROOT/certs/live"
DEST_DIR="/opt/remnanode/configs/xray/ssl"
REMNA_COMPOSE_DIR="/opt/remnanode"
REMNA_COMPOSE_FILE="$REMNA_COMPOSE_DIR/docker-compose.yml"
CERTBOT_COMPOSE_FILE="$CERTBOT_ROOT/docker-compose.yml"
CONFIG="/etc/remnanode-cert-sync.conf"
LOG_FILE="/var/log/remnanode-cert-sync.log"
LOCK_FILE="/run/lock/remnanode-cert-sync.lock"
TARGET_MOUNT="/var/lib/remnawave/configs/xray/ssl"
MOUNT_LINE="/opt/remnanode/configs/xray/ssl:/var/lib/remnawave/configs/xray/ssl:ro"
CURRENT_STAGE="запуск"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ОШИБКА: $*"; exit 1; }
on_error() {
  local status=$?
  log "ОШИБКА на этапе «$CURRENT_STAGE», строка $LINENO, код завершения $status."
  exit "$status"
}
trap on_error ERR

usage() {
  cat <<EOF
RemnaNode certificate manager v$VERSION

Использование:
  $0                 Синхронизировать сертификат по сохранённой конфигурации
  $0 --configure     Выполнить первоначальную настройку / перенастройку
  $0 --help          Показать справку
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Запустите скрипт от root."
}
valid_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}
valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

check_requirements() {
  local cmd
  for cmd in docker openssl flock python3 crontab; do
    command -v "$cmd" >/dev/null 2>&1 || die "Не найдена команда $cmd."
  done
  docker compose version >/dev/null 2>&1 || die "Не найден Docker Compose plugin."
  [[ -f "$REMNA_COMPOSE_FILE" ]] || die "Не найден $REMNA_COMPOSE_FILE. Проверьте расположение RemnaNode."
}

ensure_certbot_compose() {
  install -d -o root -g root -m 755 "$CERTBOT_ROOT" "$CERTBOT_ROOT/certs" "$CERTBOT_ROOT/var-lib-letsencrypt"
  if [[ ! -f "$CERTBOT_COMPOSE_FILE" ]]; then
    cat > "$CERTBOT_COMPOSE_FILE" <<'EOF'
services:
  certbot:
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
      - ./var-lib-letsencrypt:/var/lib/letsencrypt
EOF
    chmod 644 "$CERTBOT_COMPOSE_FILE"
    log "Создан $CERTBOT_COMPOSE_FILE для продления сертификата."
  elif ! (cd "$CERTBOT_ROOT" && docker compose config --services | grep -Fxq certbot); then
    die "В существующем $CERTBOT_COMPOSE_FILE нет сервиса certbot. Файл не перезаписывал."
  fi
}

issue_certificate() {
  CURRENT_STAGE="выпуск TLS-сертификата через Certbot"
  log "ЭТАП 1/6: Выпускаю сертификат для $DOMAIN."
  log "Standalone HTTP-01 требует доступный из интернета и свободный на сервере TCP-порт 80."
  (
    cd "$CERTBOT_ROOT"
    docker run --rm \
      -v "$CERTBOT_ROOT/certs:/etc/letsencrypt" \
      -v "$CERTBOT_ROOT/var-lib-letsencrypt:/var/lib/letsencrypt" \
      --network host \
      certbot/certbot certonly --standalone \
      --non-interactive --agree-tos \
      --email "$EMAIL" --cert-name "$DOMAIN" -d "$DOMAIN"
  )
  [[ -s "$SOURCE_ROOT/$DOMAIN/fullchain.pem" ]] || die "Certbot не создал fullchain.pem."
  [[ -s "$SOURCE_ROOT/$DOMAIN/privkey.pem" ]] || die "Certbot не создал privkey.pem."
  log "Сертификат получен."
}

configure_remnanode_compose() {
  CURRENT_STAGE="подключение каталога сертификатов к RemnaNode"
  log "ЭТАП 2/6: Настраиваю bind mount в $REMNA_COMPOSE_FILE."
  local services service backup count
  mapfile -t services < <(cd "$REMNA_COMPOSE_DIR" && docker compose config --services)
  count="$(printf '%s\n' "${services[@]}" | sed '/^$/d' | wc -l)"
  (( count > 0 )) || die "Не удалось определить сервисы Compose."
  if printf '%s\n' "${services[@]}" | grep -Fxq remnanode; then
    service="remnanode"
  elif (( count == 1 )); then
    service="$(printf '%s\n' "${services[@]}" | sed -n '1p')"
  else
    die "Не удалось определить сервис RemnaNode. Найдены сервисы: $(printf '%s ' "${services[@]}")."
  fi

  backup="$REMNA_COMPOSE_FILE.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$REMNA_COMPOSE_FILE" "$backup"
  log "Резервная копия: $backup"

  SERVICE_NAME="$service" COMPOSE_FILE_PATH="$REMNA_COMPOSE_FILE" MOUNT_LINE="$MOUNT_LINE" TARGET_MOUNT="$TARGET_MOUNT" python3 <<'PY'
import os, re
from pathlib import Path
p = Path(os.environ["COMPOSE_FILE_PATH"])
service = os.environ["SERVICE_NAME"]
mount = os.environ["MOUNT_LINE"]
target = os.environ["TARGET_MOUNT"]
lines = p.read_text().splitlines(keepends=True)
header = re.compile(r"^  " + re.escape(service) + r":\s*(?:#.*)?(?:\r?\n)?$")
start = next((i for i, x in enumerate(lines) if header.match(x)), None)
if start is None:
    raise SystemExit("Не найден сервис " + service + " в docker-compose.yml")
def next_service(x):
    return re.match(r"^  [A-Za-z0-9_.-]+:\s*(?:#.*)?(?:\r?\n)?$", x) is not None
end = len(lines)
for i in range(start + 1, len(lines)):
    if next_service(lines[i]) or (lines[i].strip() and not lines[i].startswith((" ", "\t", "#"))):
        end = i
        break
block = lines[start:end]
if any(target in x for x in block):
    print("Bind mount уже существует; повторно не добавляю.")
else:
    vi = next((i for i, x in enumerate(block) if re.match(r"^    volumes:\s*(?:#.*)?(?:\r?\n)?$", x)), None)
    if vi is None:
        block.extend(["    volumes:\n", "      - '" + mount + "'\n"])
    else:
        insert = len(block)
        children = []
        for i in range(vi + 1, len(block)):
            x = block[i]
            if x.strip() and not x.lstrip().startswith("#") and len(x) - len(x.lstrip(" ")) <= 4:
                insert = i
                break
            children.append(x)
        real = [x for x in children if x.strip() and not x.lstrip().startswith("#")]
        if real and not any(re.match(r"^      -\s", x) for x in real):
            raise SystemExit("Секция volumes имеет неподдерживаемый формат; Compose не изменён.")
        block.insert(insert, "      - '" + mount + "'\n")
    lines[start:end] = block
    p.write_text("".join(lines))
    print("Bind mount добавлен в сервис " + service)
PY

  if ! (cd "$REMNA_COMPOSE_DIR" && docker compose config -q); then
    cp -a "$backup" "$REMNA_COMPOSE_FILE"
    die "docker compose config не прошёл проверку; исходный файл восстановлен."
  fi
  log "Конфигурация RemnaNode Compose проверена."
}

validate_pair() {
  local cert="$1" key="$2" cert_pub key_pub
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "Некорректный PEM-сертификат: $cert"
  openssl pkey -in "$key" -noout -check >/dev/null 2>&1 || die "Некорректный приватный ключ: $key"
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || die "Сертификат и приватный ключ не соответствуют."
}

sync_certs() {
  local source_dir="$SOURCE_ROOT/$DOMAIN"
  local tmp cert_new key_new cert_dest="$DEST_DIR/fullchain.pem" key_dest="$DEST_DIR/privkey.pem"
  local backup_cert backup_key had_cert=0 had_key=0
  [[ -s "$source_dir/fullchain.pem" && -s "$source_dir/privkey.pem" ]] || die "Нет файлов сертификата/ключа в $source_dir."
  install -d -o root -g root -m 755 "$DEST_DIR"
  exec 9>"$LOCK_FILE"
  flock -n 9 || { log "Другая синхронизация уже выполняется; пропускаю."; return 0; }
  tmp="$(mktemp -d "$DEST_DIR/.cert-sync.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  cert_new="$tmp/fullchain.pem"
  key_new="$tmp/privkey.pem"
  backup_cert="$tmp/old-fullchain.pem"
  backup_key="$tmp/old-privkey.pem"
  cp -L -- "$source_dir/fullchain.pem" "$cert_new"
  cp -L -- "$source_dir/privkey.pem" "$key_new"
  validate_pair "$cert_new" "$key_new"
  chmod 644 "$cert_new"
  chmod 600 "$key_new"
  chown root:root "$cert_new" "$key_new"
  if [[ -f "$cert_dest" && -f "$key_dest" ]] && cmp -s "$cert_new" "$cert_dest" && cmp -s "$key_new" "$key_dest"; then
    log "Сертификаты не изменились."
    return 0
  fi
  if [[ -e "$cert_dest" ]]; then cp -a "$cert_dest" "$backup_cert"; had_cert=1; fi
  if [[ -e "$key_dest" ]]; then cp -a "$key_dest" "$backup_key"; had_key=1; fi
  install -o root -g root -m 644 "$cert_new" "$cert_dest" || die "Не удалось установить fullchain.pem."
  if ! install -o root -g root -m 600 "$key_new" "$key_dest"; then
    if (( had_cert )); then cp -a "$backup_cert" "$cert_dest"; else rm -f "$cert_dest"; fi
    if (( had_key )); then cp -a "$backup_key" "$key_dest"; else rm -f "$key_dest"; fi
    die "Не удалось установить privkey.pem; предыдущие файлы восстановлены."
  fi
  log "Сертификат и ключ скопированы в $DEST_DIR (права 644/600)."
}

install_renewal_cron() {
  CURRENT_STAGE="настройка ежемесячного продления"
  log "ЭТАП 4/6: Добавляю root crontab на 00:00 28-го числа."
  local current tmp
  current="$(crontab -l 2>/dev/null || true)"
  tmp="$(mktemp)"
  {
    printf '%s\n' "$current" | awk '
      $0 == "# BEGIN REMNANODE CERT SYNC" { skip=1; next }
      $0 == "# END REMNANODE CERT SYNC" { skip=0; next }
      !skip { print }
    '
    cat <<EOF
# BEGIN REMNANODE CERT SYNC
0 0 28 * * (cd "$CERTBOT_ROOT" && docker compose run --rm certbot renew && "$0" && cd "$REMNA_COMPOSE_DIR" && docker compose restart) >> "$LOG_FILE" 2>&1
# END REMNANODE CERT SYNC
EOF
  } > "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  log "Cron добавлен: renew → синхронизация файлов → docker compose restart."
}

configure() {
  local domain email
  while true; do
    read -r -p "Введите домен сертификата (например, node.example.com): " domain </dev/tty
    if valid_domain "$domain"; then break; fi
    printf 'Некорректный домен. Введите только доменное имя.\n' >&2
  done
  while true; do
    read -r -p "Введите email для Certbot: " email </dev/tty
    if valid_email "$email"; then break; fi
    printf 'Некорректный email.\n' >&2
  done
  DOMAIN="$domain"
  EMAIL="$email"

  CURRENT_STAGE="проверка зависимостей"
  log "Проверяю Docker, Docker Compose, OpenSSL, Python 3, cron и файлы RemnaNode."
  check_requirements
  ensure_certbot_compose
  issue_certificate
  configure_remnanode_compose

  CURRENT_STAGE="синхронизация сертификатов"
  log "ЭТАП 3/6: Проверяю и копирую сертификат в каталог RemnaNode."
  sync_certs

  printf 'DOMAIN=%q\nEMAIL=%q\n' "$DOMAIN" "$EMAIL" > "$CONFIG"
  chown root:root "$CONFIG"
  chmod 600 "$CONFIG"
  log "Параметры сохранены в $CONFIG."

  install_renewal_cron

  CURRENT_STAGE="перезапуск RemnaNode"
  log "ЭТАП 5/6: Выполняю docker compose down."
  (cd "$REMNA_COMPOSE_DIR" && docker compose down)
  log "ЭТАП 6/6: Выполняю docker compose up -d."
  (cd "$REMNA_COMPOSE_DIR" && docker compose up -d)
  log "ГОТОВО: сертификат выпущен, подключён, продление настроено, RemnaNode запущен."
}

load_config() {
  [[ -f "$CONFIG" ]] || die "Нет конфигурации $CONFIG. Сначала выполните: $0 --configure"
  [[ "$(stat -c '%u' "$CONFIG")" == "0" ]] || die "Файл конфигурации должен принадлежать root."
  # shellcheck disable=SC1090
  source "$CONFIG"
  [[ -v DOMAIN && -n "$DOMAIN" ]] || die "В конфигурации не задан DOMAIN."
  [[ -v EMAIL && -n "$EMAIL" ]] || die "В конфигурации не задан EMAIL. Выполните --configure."
  valid_domain "$DOMAIN" || die "Некорректный DOMAIN в конфигурации."
  valid_email "$EMAIL" || die "Некорректный EMAIL в конфигурации."
}

main() {
  require_root
  local arg=""
  if (($# > 0)); then arg="$1"; fi
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    --configure) configure; exit 0 ;;
    "") ;;
    *) usage; exit 2 ;;
  esac
  load_config
  CURRENT_STAGE="ручная синхронизация сертификатов"
  sync_certs
}
main "$@"
