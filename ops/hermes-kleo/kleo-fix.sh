#!/usr/bin/env bash
# КЛЕО / Hermes — одна команда: вернуть агента на DeepSeek и собрать диагностику.
#
# Запуск на сервере 31.76.102.165 (от root):
#
#   curl -fsSL https://raw.githubusercontent.com/lomakinigorst-dot/meet-legend/refs/heads/claude/hermesa-agent-tg-server-uuh7ms/ops/hermes-kleo/kleo-fix.sh | bash
#
# Ничего не спрашивает. В конце печатает понятный итог.

set -uo pipefail

BASE_DEFAULT="https://raw.githubusercontent.com/lomakinigorst-dot/meet-legend/refs/heads/claude/hermesa-agent-tg-server-uuh7ms/ops/hermes-kleo"
BASE="${KLEO_FIX_BASE:-$BASE_DEFAULT}"
WORK="$(mktemp -d /tmp/kleo-fix-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "=================================================="
echo "  КЛЕО — восстановление работы через DeepSeek"
echo "=================================================="
echo

if [ "$(id -u)" -ne 0 ]; then
  echo "ОШИБКА: нужно запускать от root."
  echo "Попробуйте:  sudo bash -c 'curl -fsSL $BASE/kleo-fix.sh | bash'"
  exit 1
fi

echo "[1/3] Скачиваю скрипты..."
for f in kleo-rollback-deepseek.sh kleo-diagnose.sh; do
  if ! curl -fsSL "$BASE/$f" -o "$WORK/$f"; then
    echo "ОШИБКА: не удалось скачать $f с GitHub."
    echo "Проверьте, что с сервера есть интернет:  curl -I https://raw.githubusercontent.com"
    exit 1
  fi
done
echo "      готово"
echo

echo "[2/3] Возвращаю маршрут модели на DeepSeek..."
echo "--------------------------------------------------"
bash "$WORK/kleo-rollback-deepseek.sh"
ROLLBACK_RC=$?
echo "--------------------------------------------------"
echo

echo "[3/3] Собираю диагностику..."
bash "$WORK/kleo-diagnose.sh" >/dev/null 2>&1
REPORT="$(ls -t /root/kleo-diagnose-*.txt 2>/dev/null | head -1)"
echo "      готово"
echo

echo "=================================================="
echo "  ИТОГ"
echo "=================================================="

GATEWAY="$(systemctl is-active hermes-gateway 2>&1)"
ROUTE="$(grep -m1 -A2 '^model:' /root/.hermes/config.yaml 2>/dev/null | grep -m1 'default:' | sed 's/.*default: *//')"

echo "  Сервис агента (hermes-gateway): $GATEWAY"
echo "  Модель по умолчанию:            ${ROUTE:-не определена}"
echo

if [ "$GATEWAY" = "active" ] && [ "$ROLLBACK_RC" -eq 0 ]; then
  echo "  ГОТОВО. Напишите боту в Telegram любое сообщение."
  echo "  Первый ответ может прийти через 10-20 секунд."
else
  echo "  ЧТО-ТО НЕ ТАК — агент не поднялся."
fi

echo
if [ -n "$REPORT" ]; then
  echo "  Отчёт для разбора: $REPORT"
  echo "  Показать его целиком:   cat $REPORT"
  echo "  (паролей и ключей в нём нет — только 'есть/нет' и длина)"
fi
echo "=================================================="
