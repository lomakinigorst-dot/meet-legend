# Аварийный набор для КЛЕО / Hermes (Telegram-агент, vm-10107)

Набор для случая «агент в Telegram молчит после переключения на подписку Claude Code».
Разбор причины — в [DIAGNOSIS.md](DIAGNOSIS.md).

> Основной репозиторий агента — `lomakinigorst-dot/kleo-wiki`
> (`ops/restore-kit/`). Эти файлы логичнее перенести туда; здесь они лежат потому,
> что работа велась в ветке `claude/hermesa-agent-tg-server-uuh7ms` этого репозитория.

## Файлы

| Файл | Назначение |
|---|---|
| `DIAGNOSIS.md` | разбор: что переключили 20.08 и почему это дало тишину |
| `kleo-rollback-deepseek.sh` | вернуть маршрут модели на DeepSeek API и перезапустить сервисы |
| `kleo-diagnose.sh` | собрать диагностику (только чтение, секреты не печатает) |
| `claude-code-openai-proxy.fixed.py` | прокси с устранённым `NameError` и защитой от перегрузки |
| `claude-code-openai-proxy.patch` | тот же фикс в виде диффа для ревью |

## Быстрый порядок

```bash
scp kleo-rollback-deepseek.sh kleo-diagnose.sh root@31.76.102.165:/root/
ssh root@31.76.102.165

bash /root/kleo-rollback-deepseek.sh     # вернуть DeepSeek
bash /root/kleo-diagnose.sh              # собрать доказательства причины
```

Отчёт диагностики пишется в `/root/kleo-diagnose-<дата>.txt`. Его можно прислать
целиком: значения ключей в нём не печатаются, только «есть/нет» и длина.

## Что делает откат

Правит три ключа в живом `/root/.hermes/config.yaml`:

| Ключ | Было (с 20.08) | Станет |
|---|---|---|
| `model.default` | `claude-code:claude-code-opus` | `deepseek-v4-flash` |
| `model.provider` | `claude-code` | `deepseek` |
| `providers.claude-code.default_model` | `claude-code-opus` | `claude-code-sonnet` |

Это ровно состояние снимка от 11.08 — последнего, при котором агент работал.

Перед правкой: проверка `DEEPSEEK_API_KEY` живым запросом к `api.deepseek.com`
и бэкап `config.yaml.bak-<дата>`. После правки: снятие зависших процессов
`claude -p`, перезапуск `claude-code-proxy` и `hermes-gateway`, проверка состояния.

Флаги:

- `--dry-run` — показать изменения, ничего не трогать;
- `--stop-claude-proxy` — дополнительно погасить `claude-code-proxy.service`
  (если подозреваете, что память ест именно он).

Алиасы не трогаются: `/model claude`, `/model opus`, `/model deepseek` в топике
продолжают работать. `delegation` (агент-промптер на opus, создан 11.08) тоже
оставлен как есть — он ходит через тот же прокси, поэтому после отката его стоит
проверить отдельно.

Откатить сам откат: `cp /root/.hermes/config.yaml.bak-<дата> /root/.hermes/config.yaml && systemctl restart hermes-gateway`.

## Возврат на подписку Claude Code

Только после установки исправленного прокси:

```bash
install -m 0755 claude-code-openai-proxy.fixed.py /opt/kleo/bin/claude-code-openai-proxy.py
systemctl restart claude-code-proxy
curl -s http://127.0.0.1:8787/healthz
```

Что исправлено:

1. **`NameError: _resp_model`** — переменная объявлялась в `do_POST`, а читалась в
   `send_sse_completion`. Любой запрос со `stream: true` падал уже после отправки
   заголовков, и клиент получал `200 OK` с пустым телом. Передаётся параметром.
2. **Нет ограничения параллелизма** — добавлен семафор
   `CLAUDE_CODE_PROXY_MAX_CONCURRENCY` (по умолчанию 2). Сверх лимита — честный
   503 вместо ещё одного процесса Node на сотни МБ.
3. **Прокси вёл себя как второй агент** — `--add-dir`, `--allowedTools`,
   `--max-turns 12` вынесены под флаг `CLAUDE_CODE_PROXY_AGENTIC` (по умолчанию
   выключен, `--max-turns 1`). Это приводит код в соответствие с комментарием в нём
   же: «Прокси — мост к модели, а не второй агент». Vault КЛЕО читает сам, своими
   инструментами Hermes.

Новые переменные (все необязательные, задаются в `/root/.hermes/.env`):

```
CLAUDE_CODE_PROXY_MAX_CONCURRENCY=2    # одновременных процессов claude
CLAUDE_CODE_PROXY_QUEUE_WAIT=90        # сколько ждать слот, сек
CLAUDE_CODE_PROXY_AGENTIC=0            # 1 — вернуть инструменты и 12 ходов
CLAUDE_CODE_PROXY_MAX_TURNS=1          # переопределить число ходов
```

`GET /healthz` теперь показывает режим и свободные слоты.

Рекомендация: держать дефолтом `sonnet`, а `opus` — алиасом по требованию.
Opus расходует недельный лимит подписки в разы быстрее, а при исчерпании падает
весь основной маршрут агента.

## Проверено

- Правка YAML прогнана на реальном снимке `config.yaml` — все три ключа найдены,
  результат проходит `yaml.safe_load`.
- `NameError` воспроизведён на исходном прокси (`HTTP 200, тело 0 байт`) и
  отсутствует в исправленном (`HTTP 200, тело 720 байт`, корректный SSE).
- Оба bash-скрипта проходят `bash -n`, python — `py_compile`.
- На самом сервере скрипты **не запускались**: из этой среды исходящая сеть до
  `31.76.102.165` закрыта политикой (`request blocked: no rule or allowlist entry
  allows host`), порт 22 недоступен.
