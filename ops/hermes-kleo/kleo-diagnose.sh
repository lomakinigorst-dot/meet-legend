#!/usr/bin/env bash
# KLEO / Hermes — сбор диагностики (только чтение, ничего не меняет).
#
#   bash kleo-diagnose.sh
#
# Пишет отчёт в /root/kleo-diagnose-<дата>.txt и в stdout.
# Секреты не печатаются: по ключам из .env выводится только "есть/нет" и длина.

set -uo pipefail

OUT="/root/kleo-diagnose-$(date +%Y%m%d-%H%M%S).txt"
HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
VAULT="${VAULT:-/opt/kleo/obsidian-vault}"

exec > >(tee "$OUT") 2>&1

hr() { printf '\n===== %s =====\n' "$1"; }
run() { echo "\$ $*"; eval "$@" 2>&1; echo; }

hr "ВРЕМЯ И ХОСТ"
run "date -u '+%Y-%m-%d %H:%M:%S UTC'"
run "uptime"
run "hostnamectl 2>/dev/null | head -6"

hr "СЕРВИСЫ"
for s in hermes-gateway hermes-dashboard claude-code-proxy kleo-vault-sync.timer; do
  printf '%-28s %s\n' "$s" "$(systemctl is-active "$s" 2>&1) / $(systemctl is-enabled "$s" 2>&1)"
done
echo
run "systemctl status hermes-gateway --no-pager -n 25"
run "systemctl status claude-code-proxy --no-pager -n 15"
run "systemctl show hermes-gateway -p NRestarts -p ExecMainStatus -p Result -p ActiveEnterTimestamp"

hr "РЕСУРСЫ"
run "free -h"
run "df -h / /opt /var 2>/dev/null"
run "swapon --show"

hr "OOM-KILLER (главный подозреваемый)"
run "dmesg -T 2>/dev/null | grep -i -E 'out of memory|oom-kill|killed process' | tail -40"
run "journalctl -k --since '10 days ago' --no-pager 2>/dev/null | grep -i -E 'out of memory|oom-kill|killed process' | tail -40"

hr "ПРОЦЕССЫ claude / hermes"
run "ps -eo pid,ppid,etime,rss,pcpu,cmd --sort=-rss | grep -E 'claude|hermes' | grep -v grep | head -30"
run "pgrep -f 'claude -p' | wc -l | xargs -I{} echo 'процессов claude -p: {}'"

hr "ПОРТЫ"
run "ss -lntp 2>/dev/null | grep -E '8787|9119' || echo 'порты 8787/9119 не слушаются'"
run "curl -s -o /dev/null -w 'proxy /healthz -> HTTP %{http_code}\n' --max-time 5 http://127.0.0.1:8787/healthz"

hr "ЖУРНАЛ hermes-gateway (ошибки за 10 дней)"
run "journalctl -u hermes-gateway --since '10 days ago' --no-pager 2>/dev/null | grep -i -E 'error|traceback|exception|failed|timeout|limit|refused|nameerror|500' | tail -60"
hr "ЖУРНАЛ hermes-gateway (последние 60 строк)"
run "journalctl -u hermes-gateway -n 60 --no-pager"

hr "ЖУРНАЛ claude-code-proxy (последние 60 строк)"
run "journalctl -u claude-code-proxy -n 60 --no-pager"
hr "ЖУРНАЛ claude-code-proxy (NameError / лимиты)"
run "journalctl -u claude-code-proxy --since '10 days ago' --no-pager 2>/dev/null | grep -i -E 'nameerror|_resp_model|traceback|weekly limit|rate limit|unauthorized|oauth' | tail -40"

hr "МАРШРУТИЗАЦИЯ МОДЕЛИ (живой config.yaml)"
run "sed -n '/^model:/,/^providers:/p' $HERMES_HOME/config.yaml"
run "sed -n '/^providers:/,/^database:/p' $HERMES_HOME/config.yaml"
run "grep -n -A3 '^delegation:' $HERMES_HOME/config.yaml"
run "ls -la $HERMES_HOME/config.yaml*"

hr "КЛЮЧИ В .env (значения НЕ печатаются)"
if [ -f "$HERMES_HOME/.env" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    k="${line%%=*}"; v="${line#*=}"
    if [ -n "$v" ]; then printf '%-42s есть (длина %s)\n' "$k" "${#v}"; else printf '%-42s ПУСТО\n' "$k"; fi
  done < "$HERMES_HOME/.env"
else
  echo "НЕТ ФАЙЛА $HERMES_HOME/.env"
fi

hr "ПРОВЕРКА КЛЮЧА DEEPSEEK (живой запрос)"
DS_KEY="$(grep -m1 '^DEEPSEEK_API_KEY=' "$HERMES_HOME/.env" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')"
if [ -n "${DS_KEY:-}" ]; then
  code="$(curl -s -o /tmp/ds.json -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer $DS_KEY" https://api.deepseek.com/v1/models)"
  echo "GET https://api.deepseek.com/v1/models -> HTTP $code"
  [ "$code" = "200" ] && echo "КЛЮЧ DEEPSEEK РАБОЧИЙ" || { echo "ОТВЕТ:"; head -c 400 /tmp/ds.json; echo; }
  rm -f /tmp/ds.json
else
  echo "DEEPSEEK_API_KEY не найден в $HERMES_HOME/.env"
fi

hr "CLAUDE CODE CLI"
run "command -v claude && claude --version"
run "ls -la $HERMES_HOME/.anthropic_oauth.json $HERMES_HOME/auth.json 2>&1"

hr "VAULT / СИНХРОНИЗАЦИЯ"
run "git -C $VAULT log -3 --format='%h %ad %s' --date=iso"
run "git -C $VAULT status -sb"
run "systemctl list-timers kleo-vault-sync.timer --no-pager"
run "journalctl -u kleo-vault-sync.service -n 20 --no-pager"

hr "HERMES STATUS"
run "hermes status"

echo
echo "Отчёт сохранён: $OUT"
