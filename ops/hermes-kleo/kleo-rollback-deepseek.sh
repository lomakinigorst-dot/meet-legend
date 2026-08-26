#!/usr/bin/env bash
# KLEO / Hermes — возврат маршрута модели на DeepSeek (прямой API-ключ).
#
# Откатывает ровно то, что было изменено 20.08.2026 и после чего агент замолчал:
#   model.default                      claude-code:claude-code-opus -> deepseek-v4-flash
#   model.provider                     claude-code                  -> deepseek
#   providers.claude-code.default_model claude-code-opus            -> claude-code-sonnet
#
# Живой /root/.hermes/config.yaml правится точечно (НЕ перезаписывается копией из
# restore-kit — там значения затёрты на REDACTED). Перед правкой делается бэкап.
#
#   bash kleo-rollback-deepseek.sh              # откат + перезапуск
#   bash kleo-rollback-deepseek.sh --dry-run    # показать, что изменится
#   bash kleo-rollback-deepseek.sh --stop-claude-proxy   # ещё и погасить claude-code-proxy

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
CFG="$HERMES_HOME/config.yaml"
ENV_FILE="$HERMES_HOME/.env"
DRY_RUN=0
STOP_PROXY=0
DEFER_GW=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --stop-claude-proxy) STOP_PROXY=1 ;;
    --defer-gateway-restart) DEFER_GW=1 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Запускать от root." >&2; exit 1; }
[ -f "$CFG" ] || { echo "Не найден $CFG" >&2; exit 1; }

echo "== 1. Проверка ключа DeepSeek =="
DS_KEY="$(grep -m1 '^DEEPSEEK_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ' || true)"
if [ -z "${DS_KEY:-}" ]; then
  echo "ОСТАНОВ: DEEPSEEK_API_KEY пуст или отсутствует в $ENV_FILE." >&2
  echo "Без него переключение на DeepSeek не имеет смысла." >&2
  exit 1
fi
CODE=""
CODE="$(curl -s -o /tmp/kleo-ds.json -w '%{http_code}' --max-time 25 \
  -H "Authorization: Bearer $DS_KEY" https://api.deepseek.com/v1/models)" || true
[ -n "$CODE" ] || CODE="000"
if [ "$CODE" = "200" ]; then
  MODELS="$(grep -o '"id":"[^"]*"' /tmp/kleo-ds.json 2>/dev/null | head -5 | cut -d'"' -f4 | tr '\n' ' ' || true)"
  echo "   ключ рабочий (HTTP 200), модели: $MODELS"
else
  echo "   ВНИМАНИЕ: api.deepseek.com вернул HTTP $CODE (000 = сети/DNS нет)"
  [ -s /tmp/kleo-ds.json ] && { head -c 300 /tmp/kleo-ds.json || true; echo; }
  echo "   Продолжаю: маршрут всё равно надо вернуть, но ключ проверьте отдельно."
fi
rm -f /tmp/kleo-ds.json

echo
echo "== 2. Правка $CFG =="
BACKUP="$CFG.bak-$(date +%Y%m%d-%H%M%S)"
[ "$DRY_RUN" -eq 1 ] || cp -a "$CFG" "$BACKUP"

DRY_RUN="$DRY_RUN" CFG="$CFG" python3 <<'PY'
import os, re, sys

cfg = os.environ["CFG"]
dry = os.environ["DRY_RUN"] == "1"
lines = open(cfg, encoding="utf-8").read().split("\n")

WANT = {
    ("model", None, "default"): "deepseek-v4-flash",
    ("model", None, "provider"): "deepseek",
    ("providers", "claude-code", "default_model"): "claude-code-sonnet",
}

top = None
sub = None
changed, already, missing = [], [], dict(WANT)

for i, line in enumerate(lines):
    m_top = re.match(r"^([A-Za-z_][\w-]*):", line)
    if m_top:
        top, sub = m_top.group(1), None
        continue
    m_sub = re.match(r"^  ([A-Za-z_][\w-]*):\s*$", line)
    if m_sub:
        sub = m_sub.group(1)
    indent = len(line) - len(line.lstrip(" "))
    m_kv = re.match(r"^(\s+)([A-Za-z_][\w-]*):\s*(.*)$", line)
    if not m_kv:
        continue
    pad, key, val = m_kv.groups()
    if top == "model" and indent == 2:
        target = WANT.get(("model", None, key))
    elif top == "providers" and sub == "claude-code" and indent == 4:
        target = WANT.get(("providers", "claude-code", key))
    else:
        target = None
    if target is None:
        continue
    ident = (top, sub, key)
    missing.pop(ident, None)
    if val.strip() == target:
        already.append(f"{'.'.join(p for p in ident if p)}: уже {target}")
        continue
    changed.append(f"{'.'.join(p for p in ident if p)}: {val.strip()} -> {target}")
    lines[i] = f"{pad}{key}: {target}"

for msg in already:
    print("   =", msg)
for msg in changed:
    print("   *", msg)
for ident in missing:
    print("   ! НЕ НАЙДЕН ключ", ".".join(p for p in ident if p), file=sys.stderr)

if not changed:
    print("   изменений нет — конфиг уже на DeepSeek")
    sys.exit(0)

if dry:
    print("   --dry-run: файл не изменён")
    sys.exit(0)

text = "\n".join(lines)
open(cfg, "w", encoding="utf-8").write(text)

try:
    import yaml
    yaml.safe_load(text)
    print("   YAML валиден")
except ImportError:
    print("   (pyyaml нет — проверка синтаксиса пропущена)")
except Exception as exc:
    print(f"   YAML СЛОМАН: {exc}", file=sys.stderr)
    sys.exit(3)
PY

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Режим --dry-run: ничего не перезапускаю."
  exit 0
fi
[ -f "$BACKUP" ] && echo "   бэкап: $BACKUP"

echo
echo "== 3. Снятие зависших процессов claude -p =="
STRAY="$(pgrep -f 'claude -p' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$STRAY" -gt 0 ]; then
  echo "   найдено $STRAY — завершаю"
  pkill -f 'claude -p' 2>/dev/null || true
  sleep 3
  pkill -9 -f 'claude -p' 2>/dev/null || true
else
  echo "   зависших нет"
fi

echo
echo "== 4. Перезапуск сервисов =="
if [ "$STOP_PROXY" -eq 1 ]; then
  systemctl disable --now claude-code-proxy 2>&1 | sed 's/^/   /' || true
  echo "   claude-code-proxy остановлен и выключен из автозапуска"
else
  systemctl restart claude-code-proxy 2>&1 | sed 's/^/   /' || echo "   claude-code-proxy перезапустить не удалось (не критично для DeepSeek)"
fi
if [ "$DEFER_GW" -eq 1 ]; then
  # Скрипт может выполняться самим агентом внутри hermes-gateway.
  # Мгновенный restart оборвал бы его ответ на полуслове, поэтому откладываем.
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --on-active=20 --unit=kleo-gw-restart-$$ \
      systemctl restart hermes-gateway >/dev/null 2>&1 \
      && echo "   hermes-gateway перезапустится через 20 секунд"
  else
    setsid bash -c 'sleep 20; systemctl restart hermes-gateway' >/dev/null 2>&1 &
    echo "   hermes-gateway перезапустится через 20 секунд"
  fi
else
  systemctl restart hermes-gateway
  sleep 6
fi

echo
echo "== 5. Проверка =="
for s in hermes-gateway hermes-dashboard claude-code-proxy kleo-vault-sync.timer; do
  printf '   %-26s %s\n' "$s" "$(systemctl is-active "$s" 2>&1)"
done
echo
echo "   активный маршрут:"
sed -n '/^model:/,/^  aliases:/p' "$CFG" | sed 's/^/     /'
echo
echo "   последние строки журнала gateway:"
journalctl -u hermes-gateway -n 25 --no-pager | sed 's/^/     /'
echo
echo "Готово. Напишите боту в Telegram любое сообщение."
echo "Если ответа нет — пришлите вывод: bash kleo-diagnose.sh"
