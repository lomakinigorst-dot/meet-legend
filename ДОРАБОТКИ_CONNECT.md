# Доработки LEGENIX Connect — что мы поменяли поверх «коробочного» Jitsi

Обновлено: 02.09.2026 · сервер 85.198.82.188 · образы `stable-11031`

**Зачем этот файл.** Обновление образов Jitsi перегенерирует часть конфигов. Здесь перечислено
всё, что мы настроили, и помечено, что переживёт обновление, а что нужно проверить руками.

---

## Как устроено: что переживает обновление, а что нет

| Файл | Судьба при обновлении |
|---|---|
| `config/web/custom-config.js` | ✅ образ дописывает его В КОНЕЦ сгенерированного `config.js` |
| `config/web/custom-interface_config.js` | ✅ то же самое для `interface_config.js` |
| `config/jvb/custom-jvb.conf` | ✅ подключается строкой `include` в конце `jvb.conf` |
| `config/jicofo/custom-jicofo.conf` | ✅ подключается строкой `include` в конце `jicofo.conf` |
| `config/web/config.js`, `interface_config.js`, `jvb.conf`, `jicofo.conf` | ❌ **перегенерируются, правки в них пропадут** |
| `/opt/legend-connect/.env` | ✅ наш файл, образ его не трогает |
| `/opt/legend/nginx.conf` | ✅ наш файл |
| `/etc/sysctl.d/20-jvb-udp-buffers.conf`, cron, coturn | ✅ вне контейнеров |
| `public/*.js`, `public/*.css` в репозитории op-dashboard | ✅ наш код |

⚠️ **Главный риск обновления — не потеря файлов, а тихая смерть переопределений.** Наши файлы
останутся на месте, но если в новой версии ключ переименуют или уберут, переопределение перестанет
работать **молча**, без единой ошибки в логах. Поэтому после обновления — чек-лист в конце файла.

---

## 1. Качество картинки и раздача полосы

| Что | Где | Умолчание Jitsi | У нас | Зачем |
|---|---|---|---|---|
| Качество главного видео | `custom-jvb.conf` | 360p | **720p** | мост набирал главному видео только 360p, выше — по остатку |
| Нижний потолок | `custom-jvb.conf` | 180p | **360p** | отсюда была картинка 320×180 при свободном канале |
| Битрейт слоёв | `custom-jvb.conf` + `custom-jicofo.conf` | мост измеряет сам | **берёт заявленный (VLA)** | на статичной демонстрации измерение врёт → слой выбрасывался |
| Число видеопотоков | `custom-config.js` | не задано | **без ограничения** | чтобы демонстрация не выпадала, когда показывающий молчит |
| Одновременно в HD | `custom-config.js` | — | **4 участника** | |
| Кодеки | `custom-config.js` | AV1 первым | **VP8, VP9, H264, AV1** | AV1 кодируется процессором, сажает батарею |
| Битрейты VP8 и H264 | `custom-config.js` | пустой объект | заданы, вкл. `ssHigh` 4 Мбит | демонстрация уходила на минимальных умолчаниях |
| Чёткость демонстрации | `custom-config.js` | — | **5 кадров/с** | при >5 браузеру ставится «жертвуй резкостью» и текст плывёт |
| Разговор вдвоём | `custom-config.js` | напрямую (p2p) | **через наш мост** | прямой маршрут давал до 84% потерь |
| Защита звука | `custom-config.js` | выкл | **вкл (opusRed)** | речь переживает потери пакетов |
| Замер задержки | `custom-config.js` | выкл | **вкл (e2eping)** | видно, у кого рвётся связь |

## 2. Сеть и сервер

| Что | Где | Зачем |
|---|---|---|
| Буферы UDP 10 МБ (было 208 КБ) | `/etc/sysctl.d/20-jvb-udp-buffers.conf` | ядро отбрасывало пакеты моста; потери упали с 84% до нуля |
| Сторож сети каждые 5 минут | `/opt/legend/connect-net-watch.sh` + cron | лог `/opt/legend/connect-net.log`: потери, здоровье моста, нагрузка |
| Чужой STUN-сервер Jitsi отключён | `.env` → `JVB_DISABLE_STUN=1` | адрес задан явно, лишний поход наружу не нужен |
| coturn | `/opt/legend-coturn/turnserver.conf` | обход корпоративных сетей, порты 61000–64000 |

## 3. Поведение встречи

| Что | Где |
|---|---|
| Комната ожидания + автоматический стук гостя | `.env` `ENABLE_LOBBY=1` + `custom-config.js` `lobby.autoKnock` |
| Экран подготовки, обязательное имя, русский язык | `.env` |
| Никто не становится ведущим автоматически | `.env` `ENABLE_AUTO_OWNER=false` |
| Состав кнопок панели (без чужой записи и трансляции) | `custom-config.js` `toolbarButtons` |
| Комнаты для групповой работы | `.env` `ENABLE_BREAKOUT_ROOMS=1` |

## 4. Брендирование

| Что | Где |
|---|---|
| Название, логотип, ссылка на кабинет | `custom-interface_config.js` |
| Заголовок вкладки, превью ссылки в мессенджерах, фавикон | `nginx.conf` — блок `sub_filter` для meet.1leg.ru |
| Свой экран прощания вместо служебной страницы Jitsi | `nginx.conf` — редирект `/static/close*.html` → `op.1leg.ru/connect/bye` |
| Наши скрипты и стили вшиваются в страницу встречи | `nginx.conf` — `sub_filter` по `</head>` |

## 5. Наш код на странице встречи (репозиторий op-dashboard)

| Файл | Что делает |
|---|---|
| `public/legend-record.js` | запись встречи кусками, тема, показ своей демонстрации, панель ведения, перехват выхода ведущего |
| `public/jitsi-toolbar.js` | мобильная панель, полноэкранный режим на iPhone, сторож микрофона, комната ожидания, **закрытие зала без ведущего** |
| `public/legend-pip.js` | окно поверх окон: раскладка, имена, своя демонстрация |
| `public/jitsi-legend.css` | стили встречи и мобильная вёрстка |

## 6. Отложено: канал управления через WebSocket

Готово к включению, ждёт образа новее `stable-11031` — в текущем этот эндпоинт моста отвечает
ошибкой 500 (несовместимость Jetty внутри сборки, проверено запросом напрямую к мосту).
Подробности и порядок включения — в памяти проекта `connect-jvb-websocket-broken`.
В `.env` уже лежат `JVB_WS_SERVER_ID=jvb`, `JVB_WS_TLS=1`, `COLIBRI_WEBSOCKET_REGEX=jvb`,
маршрут `location ~ ^/colibri-ws/` в nginx добавлен и проверен.

---

## Чек-лист после обновления образов Jitsi

Выполнять по порядку, каждый пункт — фактом, а не на глаз.

```bash
# 1. Наши файлы на месте и подключены
ls -la /opt/legend-connect/config/{web/custom-config.js,web/custom-interface_config.js,jvb/custom-jvb.conf,jicofo/custom-jicofo.conf}
tail -1 /opt/legend-connect/config/jvb/jvb.conf        # ждём: include "custom-jvb.conf"
tail -1 /opt/legend-connect/config/jicofo/jicofo.conf  # ждём: include "custom-jicofo.conf"

# 2. Переопределения реально доехали до сгенерированных конфигов
grep -c "channelLastN\|e2eping\|preferSctp" /opt/legend-connect/config/web/config.js   # ждём 3+

# 3. Ключи моста не переименованы в новой версии — сверить с эталоном ВНУТРИ образа
docker exec legend-connect-jvb-1 sh -c 'cd /usr/share/jitsi-videobridge && unzip -p jitsi-videobridge.jar reference.conf | grep -E "onstage-preferred-height-px|default-max-height-px|use-vla-target-bitrate"'
# если ключа нет в выводе — наше переопределение стало мёртвым, искать новое имя

# 4. Ошибок нет
docker logs legend-connect-jvb-1 --since 5m 2>&1 | grep -cE "SEVERE|handleException"   # ждём 0
docker logs legend-connect-jicofo-1 --since 5m 2>&1 | grep -cE "SEVERE|ERROR"          # ждём 0

# 5. Живая проверка: две вкладки в ОДНОРАЗОВОЙ комнате legend-qa-*, затем
docker logs legend-connect-jvb-1 --since 3m 2>&1 | grep -o "video-layers-allocation00" | head -1  # VLA согласован
```

В браузере на встрече (консоль): `config.channelLastN` → `-1`, `config.e2eping.enabled` → `true`,
`config.p2p.enabled` → `false`, `config.videoQuality.codecPreferenceOrder[0]` → `VP8`.

⚠️ QA только в одноразовых комнатах `legend-qa-*`. Личные переговорные `legenix-*` не трогать.
