# netlab — стенды для практики сетевого стека Linux

Сетевые лаборатории на network namespaces. Ломать внутри можно что угодно —
рабочая машина не затрагивается, снос одной командой.

**Важно:** namespaces живут в памяти ядра и **не переживают перезагрузку**.
После ребута стенд поднимается заново скриптом.

---

## firewall-lab.sh — iptables, NAT, маршрутизация

```
[fw-client] 10.10.0.2 <--veth--> 10.10.0.1 [fw-server] 192.168.50.1 <--veth--> 192.168.50.2 [fw-internal]
                                  роутер + firewall                              http на :80
                                  http на :8080
```

```bash
sudo ./firewall-lab.sh up      # поднять
sudo ./firewall-lab.sh status  # что сейчас есть
sudo ./firewall-lab.sh down    # снести
```

Правила iptables скрипт намеренно не настраивает — это и есть предмет практики.

### Сценарий 1. Stateful firewall

Порядок важен: сначала разрешающие правила, политика DROP в конце.
Если поставить политику первой на реальном сервере по SSH — отрежешь себе доступ.

```bash
NS="sudo ip netns exec fw-server"

$NS iptables -A INPUT -i lo -j ACCEPT
$NS iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
$NS iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$NS iptables -A INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
$NS iptables -P INPUT DROP
```

Проверка и чтение счётчиков:

```bash
sudo ip netns exec fw-client curl -s -m3 http://10.10.0.1:8080 | head -2
sudo ip netns exec fw-server iptables -L INPUT -n -v --line-numbers
```

Что увидеть: правило `NEW` ловит ровно **1 пакет** (SYN), правило `ESTABLISHED`
— остальные 5. Один SYN открывает дверь, весь дальнейший обмен идёт по conntrack.
Это и есть смысл stateful firewall.

### Сценарий 2. DNAT — проброс порта

Клиент не знает о сети 192.168.50.0/24 и обращается к адресу роутера.

```bash
NS="sudo ip netns exec fw-server"

$NS iptables -t nat -A PREROUTING -p tcp --dport 8888 -j DNAT --to-destination 192.168.50.2:80
$NS iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$NS iptables -A FORWARD -p tcp -d 192.168.50.2 --dport 80 -m conntrack --ctstate NEW -j ACCEPT
$NS iptables -P FORWARD DROP

sudo ip netns exec fw-client curl -s -m3 http://10.10.0.1:8888 | head -2
```

DNAT обязан быть в PREROUTING — адрес назначения нужно подменить **до**
решения о маршрутизации, иначе ядро отправит пакет по старому адресу.

### Сценарий 3. Когда нужен MASQUERADE

Сценарий 2 работает без MASQUERADE, потому что у внутреннего узла есть
маршрут обратно. Ломаем его:

```bash
sudo ip netns exec fw-internal ip route del default
sudo ip netns exec fw-client curl -s -m3 http://10.10.0.1:8888   # таймаут
```

В tcpdump видно три SYN подряд без ответа: внутренний узел сформировал
SYN-ACK для 10.10.0.2, не нашёл маршрута и отбросил пакет локально.

Лечение — подменить ещё и адрес источника:

```bash
sudo ip netns exec fw-server iptables -t nat -A POSTROUTING -o vint0 -j MASQUERADE
```

Теперь внутренний узел видит запрос от 192.168.50.1 — адреса в своей подсети.
Это **hairpin NAT**: двойная трансляция, внутренний сервис вообще не знает
о клиенте. Платой становится потеря реального адреса клиента в логах —
отсюда заголовок `X-Forwarded-For` у L7-балансировщиков и PROXY protocol у L4.

### Сценарий 4. Лимиты по источнику

```bash
NS="sudo ip netns exec fw-server"

# ограничить СКОРОСТЬ новых соединений с одного адреса
$NS iptables -A INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-above 3/min --hashlimit-burst 5 \
  --hashlimit-mode srcip --hashlimit-name http -j DROP

# временно БЛОКИРОВАТЬ после N попыток (встроенный мини-fail2ban)
$NS iptables -A INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW \
  -m recent --set --name HTTP
$NS iptables -A INPUT -p tcp --dport 8080 -m conntrack --ctstate NEW \
  -m recent --update --seconds 60 --hitcount 4 --name HTTP -j DROP
```

`limit` — общая квота на всех. `hashlimit` — счётчик на каждый источник.
`recent` — блокировка на срок, а не ограничение скорости.

---

## nft-lab.sh — nftables

```
[nft-client] 10.20.0.2 <--veth--> 10.20.0.1 [nft-server, http на :8080]
```

```bash
sudo ./nft-lab.sh up       # поднять стенд
sudo ./nft-lab.sh rules    # залить базовый набор правил
sudo ./nft-lab.sh down     # снести
```

### Что посмотреть

```bash
NS="sudo ip netns exec nft-server"

$NS nft list ruleset       # весь набор одной командой
$NS nft -a list ruleset    # с handle у каждого правила
```

### Самоистекающий блоклист

```bash
$NS nft add element inet fw blocklist '{ 10.20.0.2 timeout 1m }'
sudo ip netns exec nft-client curl -s -m3 http://10.20.0.1:8080   # таймаут
$NS nft list set inet fw blocklist                                 # виден обратный отсчёт
# через минуту запись исчезает сама, доступ восстанавливается
```

В iptables так нельзя — там пришлось бы добавлять и удалять правила скриптом.

### Работа с порядком правил

Правила адресуются по **handle**, который закреплён за правилом навсегда
(в iptables — по номеру, который сдвигается при каждом изменении).

```bash
$NS nft -a list ruleset                                    # узнать handle
$NS nft delete rule inet fw input handle 9                 # удалить
$NS nft add rule inet fw input position 6 ip saddr @blocklist drop   # вставить ПОСЛЕ handle 6
$NS nft insert rule inet fw input position 6 ...           # вставить ПЕРЕД handle 6
```

Типичная ошибка: правило с блоклистом добавлено в конец цепочки и не работает,
потому что разрешающее правило совпало раньше.

### Чем nftables лучше iptables

- одна утилита и один движок вместо `iptables`/`ip6tables`/`arptables`/`ebtables`
- семейство `inet` — правило работает для IPv4 и IPv6 сразу, без дублирования
- **sets** — блоклист на 5000 адресов это один набор с хеш-поиском, а не
  5000 правил с линейным просмотром
- несколько условий в одном правиле: `tcp dport { 22, 80, 443 } ct state new accept`
- атомарное применение всего набора: `nft -f /etc/nftables.conf`

В современных дистрибутивах `iptables` — обёртка над nftables.
Проверить: `iptables -V` покажет `(nf_tables)` или `(legacy)`.

---

## Шпаргалка по диагностике

### tcpdump — три картины, которые надо узнавать

```bash
sudo ip netns exec fw-server tcpdump -ni vint0 -c 10
```

| Что в захвате | Диагноз |
|---------------|---------|
| `[S]` → `[R.]` | порт закрыт, сервис не слушает |
| `[S]` → `[S.]` → `[.]` → данные | всё работает |
| `[S]`, `[S]`, `[S]` без ответа | retransmission: пакет не доходит или ответ не возвращается |

Флаги: `S` = SYN, `.` = ACK, `P` = PSH, `F` = FIN, `R` = RST.
Точка после буквы означает, что ACK стоит вместе с другим флагом.

Полезные ключи:

```bash
tcpdump -ni eth0 'tcp port 80'                    # фильтр по порту
tcpdump -ni eth0 'host 10.0.0.5'                  # по адресу
tcpdump -ni eth0 'tcp[tcpflags] & tcp-syn != 0'   # только SYN
tcpdump -ni eth0 -A 'port 80'                     # с содержимым пакетов
tcpdump -ni eth0 -w capture.pcap                  # в файл для Wireshark
```

Чтобы не ловить тайминг запуска:

```bash
sudo ip netns exec fw-server timeout 5 tcpdump -ni vint0 &
sleep 1
sudo ip netns exec fw-client curl -s -m3 http://10.10.0.1:8888
wait
```

### conntrack

```bash
sudo ip netns exec fw-server conntrack -L
```

- `[ASSURED]` — трафик шёл в обе стороны, запись не вытеснится при нехватке места
- `[UNREPLIED]` — ответа не было; долго висит = соединение мёртвое
- у ICMP нет портов, conntrack использует как ключ поле `id` из echo-запроса

### Счётчики iptables

```bash
sudo ip netns exec fw-server iptables -L -n -v --line-numbers   # все цепочки filter
sudo ip netns exec fw-server iptables -t nat -L -n -v           # другая таблица
sudo ip netns exec fw-server iptables -S -v                     # компактно, как команды
sudo ip netns exec fw-server iptables -Z                        # обнулить счётчики
```

Приём: обнулить счётчики → сделать действие → посмотреть. Сразу видно,
какие правила сработали именно сейчас. Правило с нулями либо не нужно,
либо стоит не в том месте.

Все таблицы разом:

```bash
for t in filter nat mangle raw; do
  echo "=== $t ==="
  sudo ip netns exec fw-server iptables -t $t -L -n -v
done
```

### Частая ловушка с фоновыми процессами

`python3 -m http.server 80 &` уходит в состояние `Stopped`, если процесс
обращается к терминалу. Симптом: сеть работает, DNAT отрабатывает, а в ответ
приходит RST. Запускать нужно отвязанным от терминала:

```bash
nohup python3 -m http.server 80 > /tmp/http.log 2>&1 &
```

---

## Что ещё стоит отработать на этих стендах

- policy routing: две таблицы маршрутизации, `ip rule`, source-based routing
- `fwmark`: пометить трафик в mangle и роутить по метке через `ip rule fwmark`
- failover по метрике маршрута
- WireGuard вручную между namespace, без `wg-quick`
- VXLAN поверх WireGuard, подбор MTU
