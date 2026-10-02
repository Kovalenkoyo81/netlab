#!/usr/bin/env bash
# Стенд для практики nftables: сервер с файрволом и клиент.
#
#   [nft-client] 10.20.0.2 <--veth--> 10.20.0.1 [nft-server]
#                                     (nftables, http на :8080)
#
# Использование:
#   sudo ./nft-lab.sh up      поднять стенд
#   sudo ./nft-lab.sh rules   залить базовый набор правил nftables
#   sudo ./nft-lab.sh down    снести стенд

set -euo pipefail

NS_SERVER=nft-server
NS_CLIENT=nft-client

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Нужны права root: sudo $0 $*" >&2
        exit 1
    fi
}

down() {
    for ns in "$NS_SERVER" "$NS_CLIENT"; do
        ip netns del "$ns" 2>/dev/null || true
    done
    echo "Стенд снесён."
}

up() {
    down

    ip netns add "$NS_SERVER"
    ip netns add "$NS_CLIENT"

    ip link add vnft0 type veth peer name vnft1
    ip link set vnft0 netns "$NS_SERVER"
    ip link set vnft1 netns "$NS_CLIENT"

    ip netns exec "$NS_SERVER" ip addr add 10.20.0.1/24 dev vnft0
    ip netns exec "$NS_CLIENT" ip addr add 10.20.0.2/24 dev vnft1
    ip netns exec "$NS_SERVER" ip link set vnft0 up
    ip netns exec "$NS_CLIENT" ip link set vnft1 up

    for ns in "$NS_SERVER" "$NS_CLIENT"; do
        ip netns exec "$ns" ip link set lo up
    done

    ip netns exec "$NS_SERVER" nohup python3 -m http.server 8080 \
        >/tmp/netlab-nft.log 2>&1 &

    sleep 1

    echo "Стенд поднят. Проверка:"
    echo "  sudo ip netns exec $NS_CLIENT curl -s -m3 http://10.20.0.1:8080 | head -2"
    echo
    echo "Залить базовые правила: sudo $0 rules"
}

rules() {
    local ns="$NS_SERVER"

    # В nftables нет предопределённых таблиц и цепочек — создаём сами,
    # явно указывая семейство (inet = IPv4+IPv6), hook и приоритет.
    ip netns exec "$ns" nft add table inet fw
    ip netns exec "$ns" nft add chain inet fw input \
        '{ type filter hook input priority 0 ; policy drop ; }'

    ip netns exec "$ns" nft add rule inet fw input iif lo accept
    ip netns exec "$ns" nft add rule inet fw input ct state invalid drop
    ip netns exec "$ns" nft add rule inet fw input ct state established,related accept

    # set с таймаутами: самоистекающий блоклист на уровне ядра
    ip netns exec "$ns" nft add set inet fw blocklist \
        '{ type ipv4_addr ; flags timeout ; }'
    ip netns exec "$ns" nft add rule inet fw input ip saddr @blocklist drop

    ip netns exec "$ns" nft add rule inet fw input tcp dport 8080 ct state new accept

    echo "Правила залиты. Посмотреть:"
    echo "  sudo ip netns exec $ns nft -a list ruleset"
    echo
    echo "Забанить клиента на минуту:"
    echo "  sudo ip netns exec $ns nft add element inet fw blocklist '{ 10.20.0.2 timeout 1m }'"
}

case "${1:-}" in
    up)    need_root "$@"; up ;;
    rules) need_root "$@"; rules ;;
    down)  need_root "$@"; down ;;
    *)     echo "Использование: $0 {up|rules|down}" >&2; exit 1 ;;
esac
