#!/bin/bash
# Сторож сети видеовстреч. Смотрит на то, что раньше замечали только по жалобам людей:
#   • выброшенные пакеты на мосту (переполнение буфера UDP) — из-за них рассыпается картинка;
#   • ошибки моста и его доступность;
#   • сколько встреч идёт прямо сейчас.
# Пишет историю в лог (чтобы можно было разобрать конкретный созвон постфактум) и, если счётчик
# потерь пополз вверх, дёргает наш эндпоинт — он уже умеет писать владельцу без спама.
set -uo pipefail
LOG=/opt/legend/connect-net.log
STATE=/opt/legend/.connect-net-state
JVB=legend-connect-jvb-1
TS=$(date '+%Y-%m-%d %H:%M:%S')

# В /proc/net/snmp две строки «Udp:» — заголовок и значения. Нужна вторая.
udp_line=$(docker exec "$JVB" sh -c 'grep "^Udp:" /proc/net/snmp | tail -1' 2>/dev/null)
in_err=$(echo "$udp_line" | awk '{print $4}')
rcv_err=$(echo "$udp_line" | awk '{print $6}')
# Колонки: Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors ... — со сдвигом на метку.
case "${rcv_err:-}" in (''|*[!0-9]*) rcv_err=0 ;; esac
case "${in_err:-}" in (''|*[!0-9]*) in_err=0 ;; esac

health=$(docker exec "$JVB" sh -c 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/about/health' 2>/dev/null)
stress=$(docker exec "$JVB" sh -c 'curl -s http://localhost:8080/about/health >/dev/null 2>&1; curl -s http://localhost:8080/debug 2>/dev/null' 2>/dev/null \
         | grep -o '"stress":"[0-9.]*"' | head -1 | cut -d'"' -f4)
confs=$(docker exec "$JVB" sh -c 'curl -s http://localhost:8080/debug 2>/dev/null' 2>/dev/null \
        | grep -o '"conferences":{[^}]*}' | head -c 60)

prev=0
[ -f "$STATE" ] && prev=$(cat "$STATE" 2>/dev/null || echo 0)
# В состоянии могло остаться мусорное значение — не даём ему уронить арифметику.
case "${prev:-}" in (""|*[!0-9]*) prev=0 ;; esac
echo "${rcv_err:-0}" > "$STATE"
delta=$(( ${rcv_err:-0} - ${prev:-0} ))
[ "$delta" -lt 0 ] && delta=0     # мост перезапустили — счётчик обнулился

echo "$TS rcvbuf_err=$rcv_err (+$delta) in_err=$in_err health=$health stress=${stress:-?}" >> "$LOG"

# Лог не должен расти бесконечно
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 20000 ]; then
  tail -5000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# Пакеты начали выбрасываться — сообщаем. Порог 50 за интервал: единичные потери бывают всегда.
if [ "$delta" -gt 50 ] || [ "${health:-0}" != "200" ]; then
  K=$(grep -m1 "^INTERNAL_SECRET=" /opt/legend/.env | cut -d= -f2- | tr -d '"')
  curl -sk -m 30 "https://op.1leg.ru/api/connect/jitsi-health?key=$K&netdrop=$delta&jvbhealth=${health:-0}" >/dev/null 2>&1
  echo "$TS ALERT отправлен: delta=$delta health=$health" >> "$LOG"
fi
