#!/usr/bin/env bash
# Стенд для практики iptables: роутер с файрволом между клиентом и внутренней сетью.
#
#   [fw-client] 10.10.0.2 <--veth--> 10.10.0.1 [fw-server] 192.168.50.1 <--veth--> 192.168.50.2 [fw-internal]
#                                    (роутер, NAT, firewall)                        (http на :80)
#
# Использование:
#   sudo ./firewall-lab.sh up      поднять стенд
#   sudo ./firewall-lab.sh down    снести стенд
#   sudo ./firewall-lab.sh status  что сейчас есть

set -euo pipefail

NS_SERVER=fw-server
NS_CLIENT=fw-client
NS_INTERNAL=fw-internal

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Нужны права root: sudo $0 $*" >&2
        exit 1
    fi
}

down() {
    for ns in "$NS_SERVER" "$NS_CLIENT" "$NS_INTERNAL"; do
        ip netns del "$ns" 2>/dev/null || true
    done
    echo "Стенд снесён (namespace удалены вместе с интерфейсами, правилами и процессами внутри)."
}

up() {
    down

    # --- namespace ---
    ip netns add "$NS_SERVER"
    ip netns add "$NS_CLIENT"
    ip netns add "$NS_INTERNAL"

    # --- внешний сегмент: client <-> server ---
    ip link add vfw0 type veth peer name vfw1
    ip link set vfw0 netns "$NS_SERVER"
    ip link set vfw1 netns "$NS_CLIENT"

    ip netns exec "$NS_SERVER" ip addr add 10.10.0.1/24 dev vfw0
    ip netns exec "$NS_CLIENT" ip addr add 10.10.0.2/24 dev vfw1
    ip netns exec "$NS_SERVER" ip link set vfw0 up
    ip netns exec "$NS_CLIENT" ip link set vfw1 up

    # --- внутренний сегмент: server <-> internal ---
    ip link add vint0 type veth peer name vint1
    ip link set vint0 netns "$NS_SERVER"
    ip link set vint1 netns "$NS_INTERNAL"

    ip netns exec "$NS_SERVER" ip addr add 192.168.50.1/24 dev vint0
    ip netns exec "$NS_INTERNAL" ip addr add 192.168.50.2/24 dev vint1
    ip netns exec "$NS_SERVER" ip link set vint0 up
    ip netns exec "$NS_INTERNAL" ip link set vint1 up

    # --- loopback (без него часть сервисов не работает) ---
    for ns in "$NS_SERVER" "$NS_CLIENT" "$NS_INTERNAL"; do
        ip netns exec "$ns" ip link set lo up
    done

    # --- маршрут по умолчанию для внутреннего узла ---
    ip netns exec "$NS_INTERNAL" ip route add default via 192.168.50.1

    # --- forwarding на роутере ---
    ip netns exec "$NS_SERVER" sysctl -qw net.ipv4.ip_forward=1

    # --- http-серверы; nohup обязателен, иначе процесс уходит в Stopped ---
    ip netns exec "$NS_SERVER" nohup python3 -m http.server 8080 \
        >/tmp/netlab-server.log 2>&1 &
    ip netns exec "$NS_INTERNAL" nohup python3 -m http.server 80 \
        >/tmp/netlab-internal.log 2>&1 &

    sleep 1

    echo "Стенд поднят. Проверка:"
    echo "  sudo ip netns exec $NS_CLIENT curl -s -m3 http://10.10.0.1:8080 | head -2"
    echo "  sudo ip netns exec $NS_SERVER curl -s -m3 http://192.168.50.2 | head -2"
    echo
    echo "Правила iptables НЕ настроены намеренно — это предмет практики (см. README)."
}

status() {
    echo "=== namespace ==="
    ip netns list
    for ns in "$NS_SERVER" "$NS_CLIENT" "$NS_INTERNAL"; do
        if ip netns list | grep -q "^$ns"; then
            echo
            echo "=== $ns ==="
            ip netns exec "$ns" ip -brief addr show
        fi
    done
}

case "${1:-}" in
    up)     need_root "$@"; up ;;
    down)   need_root "$@"; down ;;
    status) status ;;
    *)      echo "Использование: $0 {up|down|status}" >&2; exit 1 ;;
esac
