# DEPLOY — Legend Connect (движок Jitsi)

> ⚠️ Деплой только ПОСЛЕ подтверждённого переезда Legend на новый сервер и готового домена.
> Работать строго в `/opt/legend-connect`. Не трогать op-dashboard / другие сервисы.

## 0. Предпосылки
- Сервер: новый Legend `85.198.82.188` (Docker + docker compose установлены)
- Домен: `meet.1leg.ru` → A-запись на IP сервера (готовит Игорь)
- На сервере уже есть nginx (общий, от op-dashboard) — добавляем отдельный server-блок

## 1. Код на сервер
```bash
mkdir -p /opt/legend-connect && cd /opt/legend-connect
git clone https://github.com/lomakinigorst-dot/meet-legend.git .
```

## 2. Конфиг
```bash
cp .env.example .env
# заполнить:
#  JVB_ADVERTISE_IPS=85.198.82.188      (публичный IP сервера)
#  JWT_APP_SECRET=$(openssl rand -hex 32)
nano .env

# сгенерировать пароли сервис-компонентов:
#  вариант A (официальный скрипт из апстрима):
curl -fsSL https://raw.githubusercontent.com/jitsi/docker-jitsi-meet/master/gen-passwords.sh -o gen-passwords.sh
bash gen-passwords.sh   # запишет JICOFO/JVB/... пароли в .env
#  вариант B (вручную): openssl rand -hex 16 в каждое пустое *_PASSWORD

mkdir -p "$(grep ^CONFIG .env | cut -d= -f2)"
```

## 3. Порты (firewall)
Открыть:
- `443/tcp` — HTTPS (хостовый nginx)
- `80/tcp` — выпуск сертификата + редирект
- `10000/udp` — **JVB медиа (обязательно, иначе видео не пойдёт)**
- (опц.) `4443/tcp` — JVB fallback

## 4. TLS + nginx
```bash
# сертификат
certbot certonly --webroot -w /var/www/certbot -d meet.1leg.ru
# подключить server-блок
cp nginx/meet.1leg.ru.conf /etc/nginx/sites-available/meet.1leg.ru
ln -s /etc/nginx/sites-available/meet.1leg.ru /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

## 5. Запуск
```bash
cd /opt/legend-connect
docker compose up -d
docker compose ps      # контейнеры legend-connect-*
docker compose logs -f
```

## 6. Smoke-тест (1B.4 / 1B.5)
- Открыть https://meet.1leg.ru — должна отдаваться страница Jitsi
- Комнату создать можно только по JWT (см. модуль ЛК). Для проверки движка можно временно
  выставить `ENABLE_AUTH=0`, проверить звонок между двумя устройствами, потом вернуть `1`.
- Проверить видео между двумя устройствами (нужен открытый `10000/udp`)
- Мобильное приложение Jitsi Meet → Settings → Server URL → `https://meet.1leg.ru`

## Изоляция (проверить)
```bash
docker compose ps --format '{{.Name}}'   # все имена начинаются с legend-connect-
docker network ls | grep legend-connect  # своя сеть
# op-dashboard / bandurina контейнеры НЕ затронуты
```

## Обновление версии Jitsi
Поменять `JITSI_IMAGE_VERSION` в `.env` → `docker compose pull && docker compose up -d`.

## Грабли деплоя (решено 2026-07-01)
- **Реестр образов:** stable-теги (`stable-11031`) живут на **Docker Hub** (`jitsi/web:...`), НЕ на ghcr.io (там только unstable/дата-теги, манифесты могут 404-ить). Тег-compose использует `jitsi/*` по умолчанию — правильно.
- **compose ↔ образ:** брать `docker-compose.yml` из ТОГО ЖЕ git-тега, что и образ. master-версия использует `read_only:true`+tmpfs (س6-v3) и роняет prosody на образе stable-11031.
- **Порты:** образ stable-11031 web слушает контейнерный **80** (не 8000). Проксировать на `meet-web:80`.
- **legend-nginx:** контейнер; web Jitsi подключён в сеть `legend_default` (alias `meet-web`) — сам legend-nginx не трогаем, только добавляем server-блоки в `/opt/legend/nginx.conf` (бэкап + `nginx -t` перед reload).
- **TLS:** webroot `/var/www/certbot` (тот же механизм, что op.1leg.ru), certbot на хосте.
- **Память:** сервер 4ГБ — обязательно `JICOFO_MAX_MEMORY`/`VIDEOBRIDGE_MAX_MEMORY` + swap, иначе OOM.
