# RemnaNode Cert Sync

Автоматическая установка и продление TLS-сертификата для RemnaNode с помощью Certbot в Docker.

## Что делает установщик

1. Запрашивает домен и email для Let's Encrypt.
2. Создаёт `/opt/certbot` и выпускает сертификат через `certbot/certbot` в режиме `standalone`.
3. Создаёт `/opt/certbot/docker-compose.yml` с сервисом `certbot`, который используется для последующего продления.
4. Создаёт резервную копию `/opt/remnanode/docker-compose.yml` и добавляет в тома сервиса RemnaNode bind mount:
   `/opt/remnanode/configs/xray/ssl:/var/lib/remnawave/configs/xray/ssl:ro`.
5. Проверяет пару сертификат/ключ и копирует `fullchain.pem` и `privkey.pem` в каталог RemnaNode. Права: `644` и `600`.
6. Добавляет в root crontab задание на 00:00 28-го числа каждого месяца: `docker compose run --rm certbot renew`, затем синхронизация файлов и перезапуск RemnaNode.
7. Выполняет `docker compose down` и `docker compose up -d` в `/opt/remnanode`.

Все этапы выводятся в терминал и записываются в `/var/log/remnanode-cert-sync.log`.

## Установка

На сервере RemnaNode выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/omnix-project/remnanode-cert-sync/main/install.sh | sudo bash
```

Установщик запросит домен и email, затем выполнит настройку автоматически. Для HTTP-01 standalone порт TCP 80 должен быть доступен из интернета и свободен на сервере на время выпуска и продления сертификата.

## Повторная настройка

```bash
sudo /usr/local/sbin/sync-remnanode-certs.sh --configure
```

## Ручная синхронизация

```bash
sudo /usr/local/sbin/sync-remnanode-certs.sh
```

## Проверка расписания и логов

```bash
sudo crontab -l
sudo tail -f /var/log/remnanode-cert-sync.log
```

Конфигурация домена и email хранится в `/etc/remnanode-cert-sync.conf` с правами доступа только для root. Резервные копии Compose создаются рядом с исходным файлом с суффиксом `.backup.ДАТА-ВРЕМЯ`.

## Важно

- Скрипт рассчитан на расположение RemnaNode в `/opt/remnanode` и файл `/opt/remnanode/docker-compose.yml`.
- Установщик ожидает сервис `remnanode` в Compose; если в файле только один сервис, он использует его. При неоднозначном составе сервисов скрипт остановится, не выбирая сервис наугад.
- Если `/opt/certbot/docker-compose.yml` уже существует, в нём должен быть сервис `certbot`; существующий файл не перезаписывается.
- Для Certbot standalone входящий TCP-порт 80 должен доходить до этого VPS. Если порт занят другим веб-сервером или прокси, выпуск/продление не пройдёт.
- Ежемесячное задание запускает синхронизацию и перезапуск только если команда `certbot renew` завершилась успешно.
