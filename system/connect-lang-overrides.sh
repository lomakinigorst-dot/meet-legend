#!/bin/bash
# Русские надписи в зале встречи.
#
# Зачем: в самой сборке Jitsi русский перевод машинный — «Отпинить», «Скрыть собственное
# представление», «Отразить». Выглядит как чужой кустарный сервис. Свои формулировки лежат
# в lang-ru-overrides.json, этот скрипт накладывает их поверх словаря ИЗ ОБРАЗА.
#
# Почему из образа, а не поверх готового файла: иначе правки наслаивались бы сами на себя,
# и при обновлении Jitsi новые надписи не появились бы вовсе.
#
# ЗАПУСКАТЬ ПОСЛЕ КАЖДОГО ОБНОВЛЕНИЯ ОБРАЗА jitsi/web — без этого в зале вернётся машинный перевод.
set -euo pipefail

CFG=/opt/legend-connect/config/web
OVR="$CFG/lang/ru-overrides.json"
OUT="$CFG/lang/main-ru.json"

mkdir -p "$CFG/lang"
[ -f "$OVR" ] || { echo "нет файла правок: $OVR"; exit 1; }

IMAGE=$(docker inspect -f '{{.Config.Image}}' legend-connect-web-1)
docker run --rm --entrypoint cat "$IMAGE" /usr/share/jitsi-meet/lang/main-ru.json > /tmp/main-ru.orig.json

python3 - "$OVR" /tmp/main-ru.orig.json "$OUT.tmp" <<'PY'
import json, sys
ovr_path, orig_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(orig_path, encoding='utf-8') as f: base = json.load(f)
with open(ovr_path, encoding='utf-8') as f: ovr = json.load(f)

missing, applied = [], 0
def merge(dst, src, path=''):
    global applied
    for k, v in src.items():
        if k.startswith('_'): continue      # строки-комментарии в файле правок
        p = f'{path}.{k}' if path else k
        if isinstance(v, dict):
            if k not in dst or not isinstance(dst[k], dict):
                missing.append(p); continue
            merge(dst[k], v, p)
        else:
            if k not in dst:
                missing.append(p); continue   # строка исчезла из новой версии Jitsi — не выдумываем
            dst[k] = v; applied += 1
merge(base, ovr)

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(base, f, ensure_ascii=False, indent=2)

print(f'заменено надписей: {applied}')
if missing:
    print('НЕ НАЙДЕНЫ в словаре Jitsi (проверить после обновления образа):')
    for m in missing: print('  -', m)
PY

mv "$OUT.tmp" "$OUT"
echo "готово: $OUT"
