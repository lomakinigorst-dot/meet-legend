# Legend Connect — инфраструктура видеосвязи

Self-hosted видеосервис для команды Legend (аналог Zoom / VK Толк / Яндекс Телемост) на базе **Jitsi Meet**.

Этот репозиторий — **инфраструктура движка** (Jitsi): docker-compose, конфиги prosody/JWT, nginx.
UI-модуль (встраивается в ЛК Legend) живёт в кодовой базе **op-dashboard**.

## Архитектура

- **Ядро:** Jitsi Meet — `web` + `prosody` (XMPP + JWT auth) + `jicofo` + `jvb` (video bridge / SFU)
- **Домен движка:** `meet.1leg.ru` (нативные приложения Jitsi Meet указывают сюда)
- **Вход в ЛК:** звонок встроен в личный кабинет через Jitsi iframe API (`external_api.js`)
- **Аутентификация:** единые доступы Legend → JWT для prosody (moderator-флаг в токене)
- **Роли:** Главный админ → Админ → Менеджер → Сотрудник (модель `sections` Legend)
- **Деплой:** новый сервер Legend, изолированный стек `/opt/legend-connect`, контейнеры `legend-connect-*`

## Статус

🟡 Инициализация. Стек Jitsi собирается. Деплой — после переезда Legend на новый сервер.

## Структура (планируется)

```
meet-legend/
├── docker-compose.yml      # Jitsi: web, prosody, jicofo, jvb
├── .env.example            # переменные (секреты — не коммитим)
├── nginx/                  # конфиг meet.1leg.ru + TLS
├── prosody/                # JWT / secure domain
└── docs/                   # деплой, интеграция iframe, JWT-роли
```

## Изоляция

Работать только в `/opt/legend-connect`. НЕ трогать `/opt/legend`, `/opt/bandurina` и соседние сервисы.
