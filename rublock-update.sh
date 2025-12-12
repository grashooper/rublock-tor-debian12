#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/etc/rublock"
LUA_SCRIPT="/usr/local/lib/rublock/rublupdate.lua"

LUA_BIN="$(command -v lua5.4 || command -v lua5.3 || command -v lua || true)"

if [[ -z "$LUA_BIN" ]]; then
  echo "Не найден исполняемый файл lua. Установите пакет lua5.4."
  exit 1
fi

if [[ ! -x "$LUA_SCRIPT" ]]; then
  echo "Не найден $LUA_SCRIPT. Запустите install_debian12.sh."
  exit 1
fi

install -d "$DATA_DIR"
touch "$DATA_DIR/runblock.dnsmasq" "$DATA_DIR/runblock.ipset" 2>/dev/null || true

echo "[rublock] Обновление списков"
if ! "$LUA_BIN" "$LUA_SCRIPT"; then
  echo "[rublock] Ошибка генерации списков"
  exit 1
fi

echo "[rublock] Подготовка ipset наборов"
# Удаляем старые наборы полностью
ipset destroy rublack-ip 2>/dev/null || true
ipset destroy rublack-ip-tmp 2>/dev/null || true
ipset destroy rublack-dns 2>/dev/null || true

if [[ -s "$DATA_DIR/runblock.ipset" ]]; then
  echo "[rublock] Загрузка IP-адресов через ipset restore"
  # Загружаем файл ipset напрямую (он содержит все команды: create, flush, add, swap)
  if ipset restore < "$DATA_DIR/runblock.ipset" 2>&1; then
    echo "[rublock] IP-адреса загружены успешно"
  else
    echo "[rublock] Ошибка загрузки ipset"
    exit 1
  fi
fi

# Создаём rublack-dns если не существует
ipset create rublack-dns hash:ip family inet hashsize 131072 maxelem 2097152 -exist 2>/dev/null || true

# Подсчитываем загруженные IP
IP_COUNT=$(ipset list rublack-ip 2>/dev/null | grep -c "^[0-9]" || echo 0)
echo "[rublock] Загружено IP-адресов: $IP_COUNT"

echo "[rublock] Применение правил iptables"
for chain in PREROUTING OUTPUT; do
  for proto in tcp udp; do
    for setname in rublack-dns rublack-ip; do
      if ! iptables -t nat -C "$chain" -p "$proto" -m set --match-set "$setname" dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I "$chain" -p "$proto" -m set --match-set "$setname" dst -j REDIRECT --to-ports 9040
      fi
    done
  done
done

echo "[rublock] Перезагрузка сервисов"
systemctl reload tor 2>/dev/null || systemctl restart tor || true
systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq || true

DOMAIN_COUNT=$(wc -l < "$DATA_DIR/runblock.dnsmasq" 2>/dev/null || echo 0)
echo "[rublock] Готово (доменов: $DOMAIN_COUNT, IP: $IP_COUNT)"