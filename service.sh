#!/system/bin/sh

TUN_NAME=tun0

ip="/system/bin/ip"
iptables="/system/bin/iptables"
ip6tables="/system/bin/ip6tables"

ipv6_enabled=true

if [[ ! -x $ip ]] || [[ ! -x $iptables ]]; then
    echo "command 'ip' or 'iptables' not found"
    exit 1
fi
if [[ ! -x $ip6tables ]]; then
    echo "warning: command 'ip6tables' not found; IPv6 forwarding will not be blocked"
    ipv6_enabled=false
fi

function ip_rules_for() {
    local tun_name=$1
    local tun_table_index=$2

    cat <<EOF
iif lo goto 6000 pref 5000
iif $tun_name lookup main suppress_prefixlength 0 pref 5010
iif $tun_name goto 6000 pref 5020
from 10.0.0.0/8 lookup $tun_table_index pref 5030
from 172.16.0.0/12 lookup $tun_table_index pref 5040
from 192.168.0.0/16 lookup $tun_table_index pref 5050
nop pref 6000
EOF
}

function iptables_rules_for() {
    local tun_name=$1

    cat <<EOF
FORWARD -s 10.0.0.0/8 -o $tun_name -j ACCEPT
FORWARD -s 172.16.0.0/12 -o $tun_name -j ACCEPT
FORWARD -s 192.168.0.0/16 -o $tun_name -j ACCEPT
FORWARD -i $tun_name -j ACCEPT
-t nat PREROUTING ! -i $tun_name -s 10.0.0.0/8 -p udp --dport 53 -j DNAT --to 1.1.1.1
-t nat PREROUTING ! -i $tun_name -s 172.16.0.0/12 -p udp --dport 53 -j DNAT --to 1.1.1.1
-t nat PREROUTING ! -i $tun_name -s 192.168.0.0/16 -p udp --dport 53 -j DNAT --to 1.1.1.1
EOF
}

function read_table_index() {
    local iface=$1

    cat /data/misc/net/rt_tables | while read -r index name; do
        if [[ "$name" = "$iface" ]]; then
            echo $index
            return 0
        fi
    done

    return 1
}

function cleanup() {
    local tun_name=$1
    local tun_table_index=$2

    iptables_rules_for $tun_name | while read -r rule; do
        if [[ $rule == "-t nat "* ]]; then
            $iptables -t nat -D ${rule#-t nat } 2>/dev/null
        else
            $iptables -D $rule 2>/dev/null
        fi
    done

    if [[ -n "$tun_table_index" ]]; then
        ip_rules_for $tun_name $tun_table_index | while read -r rule; do
            $ip rule del $rule 2>/dev/null
        done
    else
        echo "Skip ip rule cleanup: $tun_name has no table index"
    fi

    if [[ "$ipv6_enabled" == true ]]; then
        $ip6tables -D FORWARD -j REJECT --reject-with icmp6-no-route
    else
        echo "Skip IPv6 cleanup: ip6tables unavailable"
    fi
}

function setup() {
    local tun_name=$1
    local tun_table_index=$2

    cleanup $tun_name $tun_table_index

    iptables_rules_for $tun_name | while read -r rule; do
        if [[ $rule == "-t nat "* ]]; then
            $iptables -t nat -I ${rule#-t nat }
        else
            $iptables -I $rule
        fi
    done

    ip_rules_for $tun_name $tun_table_index | while read -r rule; do
        $ip rule add $rule
    done

    if [[ "$ipv6_enabled" == true ]]; then
        $ip6tables -I FORWARD -j REJECT --reject-with icmp6-no-route
    else
        echo "Skip IPv6 setup: ip6tables unavailable"
    fi
}

while [[ ! -f /data/misc/net/rt_tables ]]; do
    sleep 5
done

tun_table_index=$(read_table_index $TUN_NAME)
echo "Initialize: $TUN_NAME $tun_table_index"

if [[ ! -z "$tun_table_index" ]]; then
    setup $TUN_NAME $tun_table_index
fi

echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /dev/ip_forward_stub
chown $(stat -c '%u:%g' /data/misc/net/rt_tables) /dev/ip_forward_stub
chcon $(stat -Z -c '%C' /data/misc/net/rt_tables) /dev/ip_forward_stub
mount -o bind /dev/ip_forward_stub /proc/sys/net/ipv4/ip_forward

inotifyd - /data/misc/net::w | while read -r event; do
    sleep 1

    tun_table_index_new=$(read_table_index $TUN_NAME)
    if [[ "$tun_table_index" != "$tun_table_index_new" ]]; then
        echo "Network changed: $TUN_NAME $tun_table_index_new"

        cleanup $TUN_NAME $tun_table_index

        tun_table_index=$tun_table_index_new

        if [[ ! -z "$tun_table_index" ]]; then
            setup $TUN_NAME $tun_table_index
        fi
    fi
done
