#!/bin/bash
# 03-uci-defaults-network.sh - 预置多网口自动分配脚本

uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"

# --- 自动配置多网口网络（LAN/WAN自动分配） ---
# 兼容：物理机(eth*)、ESXi虚拟机(ens*/enp*)、任意口数
# 口1(sort最小) -> LAN, 口2 -> WAN, 口3+ -> 桥接至LAN
# 单网口设备：唯一口 -> LAN（自动删除WAN）
cat > "$uci_dir/97-auto-network" << 'EOF'
#!/bin/sh
if [ "$(uci -q get network.globals.auto_inited)" = "1" ]; then
    exit 0
fi

# 检测物理网口：通过 /device 路径排除 lo/br-*/veth*/tun 等所有虚拟接口
# 兼容 eth*(物理机) 和 ens*/enp*(ESXi/新内核可预测命名)
interfaces=""
for dev in $(ls /sys/class/net/ | sort); do
    [ -e "/sys/class/net/$dev/device" ] || continue
    interfaces="$interfaces $dev"
done
interfaces=$(echo "$interfaces" | sed 's/^ *//;s/ *$//')

# 未检测到任何物理接口时，跳过配置不写 auto_inited，等下次开机重试
[ -z "$interfaces" ] && exit 0

lan_ports=""
wan_port=""
count=0

for iface in $interfaces; do
    case $count in
        0) lan_ports="$iface" ;;
        1) wan_port="$iface" ;;
        *) lan_ports="$lan_ports $iface" ;;
    esac
    count=$((count+1))
done

lan_ports=$(echo $lan_ports | sed 's/^ *//;s/ *$//')

if [ -n "$lan_ports" ]; then
    # 判断是否为 OpenWrt 新版配置语法（包含 device section）
    if uci -q get network.@device[0] >/dev/null; then
        has_br=0
        idx=0
        while uci -q get network.@device[$idx] >/dev/null; do
            if [ "$(uci -q get network.@device[$idx].name)" = "br-lan" ]; then
                has_br=1
                break
            fi
            idx=$((idx+1))
        done

        if [ "$has_br" -eq 1 ]; then
            uci delete network.@device[$idx].ports
            for p in $lan_ports; do
                uci add_list network.@device[$idx].ports="$p"
            done
        else
            uci add network device
            uci set network.@device[-1].name='br-lan'
            uci set network.@device[-1].type='bridge'
            for p in $lan_ports; do
                uci add_list network.@device[-1].ports="$p"
            done
        fi
        
        uci delete network.lan.ifname 2>/dev/null
        uci set network.lan.device='br-lan'
    else
        # Fallback 兼容分支：针对尚未采用 DSA 架构的旧环境（如早期的 swconfig 框架），保留通过 ifname 扁平化绑定网桥的语法作为保底。
        uci set network.lan.type='bridge'
        uci set network.lan.ifname="$lan_ports"
    fi
fi

if [ -n "$wan_port" ]; then
    uci delete network.wan.ifname 2>/dev/null
    uci set network.wan.device="$wan_port" 2>/dev/null || uci set network.wan.ifname="$wan_port"
    
    # 删除默认出现的 wan6 接口
    uci delete network.wan6 2>/dev/null || true
else
    # 单网口时无 WAN
    uci delete network.wan 2>/dev/null || true
    uci delete network.wan6 2>/dev/null || true
fi

uci set network.globals='globals' 2>/dev/null || true
uci set network.globals.auto_inited='1'
uci commit network

EOF
chmod +x "$uci_dir/97-auto-network"

# --- 修复 x86 软路由 LuCI 首页网口状态显示不全 ---
# 通过 board.d 机制让 board_detect 正确生成 board.json
# board.d 脚本在 config_generate 之前运行，使用 ucidef_* API 安全合并写入
board_d_dir="package/base-files/files/etc/board.d"
mkdir -p "$board_d_dir"

cat > "$board_d_dir/99-custom-ports" << 'BOARDEOF'
#!/bin/sh

. /lib/functions/uci-defaults.sh

board_config_update

# 检测物理网口（与 97-auto-network 保持一致）
interfaces=""
for dev in $(ls /sys/class/net/ | sort); do
    [ -e "/sys/class/net/$dev/device" ] || continue
    interfaces="$interfaces $dev"
done
interfaces=$(echo "$interfaces" | sed 's/^ *//;s/ *$//')

lan_ports=""
wan_port=""
count=0

for iface in $interfaces; do
    case $count in
        0) lan_ports="$iface" ;;
        1) wan_port="$iface" ;;
        *) lan_ports="$lan_ports $iface" ;;
    esac
    count=$((count+1))
done

lan_ports=$(echo $lan_ports | sed 's/^ *//;s/ *$//')

# 使用官方 API 写入 board.json（merge 而非覆盖）
if [ -n "$wan_port" ]; then
    ucidef_set_interfaces_lan_wan "$lan_ports" "$wan_port"
else
    ucidef_set_interface_lan "$lan_ports"
fi

board_config_flush
BOARDEOF
chmod +x "$board_d_dir/99-custom-ports"

