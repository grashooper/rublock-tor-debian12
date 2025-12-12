Это форк скрипта для обхода блокировок РКН через сеть TOR.

## Debian 12

Добавлена поддержка Debian 12 (iptables+nftables, systemd, tor из пакетов).

### Быстрый старт

```bash
sudo ./debian/install_debian12.sh
```

Скрипт:
- ставит `tor`, `dnsmasq`, `ipset`, `iptables-persistent`, `lua-socket`, `lua-sec`;
- ставит `tor-geoipdb`, `obfs4proxy` и включает obfs4 в torrc (нужно прописать мосты в `/etc/tor/torrc.d/rublock.bridges`);
- кладёт обновлённые скрипты в `/usr/local/lib/rublock` и `/usr/local/bin`;
- создаёт конфиги `dnsmasq` и `tor` под транспарентный прокси TOR на 9040/9053;
- создаёт systemd unit `rublock-update.service` + таймер на 05:00;
- запускает первый апдейт списков и применяет iptables/ipset правила.

Если нужен IDN (punycode) – установите `lua-idn` и в `debian/rublupdate.lua` выставьте `convertIdn = true`.

### Что делает `rublock-update.sh`

- Загружает актуальные списки:
  - `antifilter` (по умолчанию): domains/ip/subnet/ipresolve с https://antifilter.download/
  - `zapret-info`: dump-00..19.csv с https://github.com/zapret-info/z-i
  - `antizapret`: API https://api.antizapret.info (домен+ip)
  - (оставлен) `rublacklist` напрямую, если доступен
  - конфиг выбирается переменной `blSource` в `debian/rublupdate.lua`
  и генерирует:
  - `/etc/rublock/runblock.dnsmasq` (ipset записи для dnsmasq),
  - `/etc/rublock/runblock.ipset` (скрипт для `ipset restore`).
- Создаёт ipset `rublack-dns`, `rublack-ip` и вносит IP из списка.
- Проставляет правила `iptables -t nat` в `PREROUTING` и `OUTPUT` с редиректом на `9040`.
- Перезагружает `tor` и `dnsmasq`.

Если используется другой резолвер, убедитесь, что `dnsmasq` слушает и применяется как основной DNS.

## Исторические скрипты (Padavan/OpenWrt)

В каталоге `quick/install_tor.sh` и `opt/` остались оригинальные файлы для Padavan/OpenWrt. Они не менялись.
