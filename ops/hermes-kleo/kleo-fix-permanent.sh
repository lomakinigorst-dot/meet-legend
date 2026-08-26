#!/usr/bin/env bash
# КЛЕО — постоянное исправление. Рассчитан на запуск САМИМ агентом на сервере.
#
# Отличие от kleo-fix.sh: не обрывает hermes-gateway мгновенно (иначе агент
# оборвёт собственный ответ), а откладывает перезапуск на 20 секунд.
#
# Делает:
#   1. DeepSeek снова становится моделью по умолчанию в /root/.hermes/config.yaml
#   2. Ставит исправленный claude-code-openai-proxy.py (устранён NameError,
#      из-за которого прокси отдавал пустой ответ вместо текста)
#   3. Откладывает перезапуск gateway

set -uo pipefail

BASE="${KLEO_FIX_BASE:-https://raw.githubusercontent.com/lomakinigorst-dot/meet-legend/refs/heads/claude/hermesa-agent-tg-server-uuh7ms/ops/hermes-kleo}"
WORK="$(mktemp -d /tmp/kleo-perm-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "Нужен root."; exit 1; }

echo "[1/4] Скачиваю..."
for f in kleo-rollback-deepseek.sh claude-code-openai-proxy.fixed.py; do
  curl -fsSL "$BASE/$f" -o "$WORK/$f" || { echo "ОШИБКА: не скачался $f"; exit 1; }
done

echo "[2/4] Возвращаю DeepSeek по умолчанию..."
bash "$WORK/kleo-rollback-deepseek.sh" --defer-gateway-restart
RC=$?

echo "[3/4] Ставлю исправленный прокси..."
if python3 -m py_compile "$WORK/claude-code-openai-proxy.fixed.py" 2>/dev/null; then
  TARGET=/opt/kleo/bin/claude-code-openai-proxy.py
  [ -f "$TARGET" ] && cp -a "$TARGET" "$TARGET.bak-$(date +%Y%m%d-%H%M%S)"
  install -m 0755 "$WORK/claude-code-openai-proxy.fixed.py" "$TARGET"
  systemctl restart claude-code-proxy 2>/dev/null || true
  sleep 3
  HEALTH="$(curl -s --max-time 5 http://127.0.0.1:8787/healthz || echo 'нет ответа')"
  echo "      прокси: $HEALTH"
else
  echo "      ПРОПУЩЕНО: скачанный прокси не прошёл проверку синтаксиса"
fi

echo "[4/4] Чиню синхронизацию с GitHub (мертва с 20.08)..."
systemctl enable --now kleo-vault-sync.timer >/dev/null 2>&1 || true
systemctl start kleo-vault-sync.service >/dev/null 2>&1 || true
sleep 2
SYNC="$(systemctl is-active kleo-vault-sync.timer 2>&1)"
echo "      таймер синхронизации: $SYNC"
journalctl -u kleo-vault-sync.service -n 5 --no-pager 2>/dev/null | sed 's/^/      /'

echo
echo "ИТОГ:"
echo "  модель по умолчанию: $(grep -m1 -A2 '^model:' /root/.hermes/config.yaml | grep -m1 'default:' | sed 's/.*default: *//')"
echo "  откат конфига (если что): $(ls -t /root/.hermes/config.yaml.bak-* 2>/dev/null | head -1)"
echo "  hermes-gateway перезапустится сам через ~20 секунд, бот вернётся в строй."
[ "$RC" -eq 0 ] && echo "  Статус: ГОТОВО" || echo "  Статус: были предупреждения, посмотри вывод выше"
