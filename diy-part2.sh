#!/bin/bash
#
# diy-part2.sh - 在 install feeds 之后执行
# 用途：修改默认配置，预置自定义设置
#

# 0. 集成本地源码插件（源码已放入仓库 packages/ 目录，无需依赖第三方且防止访问失败）
# 直接从本工作区复制到 OpenWrt 的 package 编译目录
cp -r "$GITHUB_WORKSPACE/packages/luci-app-autoupdate" package/luci-app-autoupdate
cp -r "$GITHUB_WORKSPACE/packages/luci-app-aliddns" package/luci-app-aliddns
cp -r "$GITHUB_WORKSPACE/packages/luci-app-argon-config" package/luci-app-argon-config



# 1. 修改默认 LAN IP 为你习惯的网段 (3.1)
sed -i 's/192.168.1.1/192.168.3.1/g' package/base-files/files/bin/config_generate

# 2. 修改默认主机名
sed -i 's/OpenWrt/MyOpenWrt/g' package/base-files/files/bin/config_generate

# 3. 启用 BBR TCP 拥塞控制 + FQ 队列调度，并彻底全局禁用 IPv6
mkdir -p package/base-files/files/etc/sysctl.d
cat > package/base-files/files/etc/sysctl.d/10-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

# 4. 提高系统连接数上限（适合高负载 x86 路由场景）
cat > package/base-files/files/etc/sysctl.d/11-conntrack.conf << 'EOF'
net.netfilter.nf_conntrack_max=131072
net.nf_conntrack_max=131072
EOF

# 5. 预置开机 uci-defaults 脚本（首次启动自动执行，执行后自动删除）
uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"

# --- 自动配置多网口网络（LAN/WAN自动分配） ---
# 单网口：eth0 -> LAN
# 双网口：eth0 -> LAN, eth1 -> WAN
# 多网口：eth0 -> LAN, eth1 -> WAN, eth2及以后 -> 桥接至 LAN
cat > "$uci_dir/97-auto-network" << 'EOF'
#!/bin/sh
# 首次启动时自动识别并绑定多网卡

# 【安全判断】如果是升级且“保留配置”，则跳过网卡分配，避免覆盖用户自定义的网口、VLAN或链路聚合等高级设置
if [ "$(uci -q get network.globals.auto_inited)" = "1" ]; then
    logger -t "auto-network" "Retained settings detected. Skipping auto-network configuration."
    exit 0
fi

interfaces=$(ls -d /sys/class/net/eth* 2>/dev/null | awk -F '/' '{print $5}' | sort)
lan_ports=""
wan_port=""

for iface in $interfaces; do
    if [ "$iface" = "eth0" ]; then
        lan_ports="$lan_ports $iface"
    elif [ "$iface" = "eth1" ]; then
        wan_port="$iface"
    else
        lan_ports="$lan_ports $iface"
    fi
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
        # 旧版语法
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

# 写入初始化标志位，后续升级只要保留了配置，就不会再次执行覆盖
uci set network.globals='globals' 2>/dev/null || true
uci set network.globals.auto_inited='1'
uci commit network
logger -t "auto-network" "Network configured. LAN: $lan_ports, WAN: ${wan_port:-none}"
EOF
chmod +x "$uci_dir/97-auto-network"

cat > "$uci_dir/99-custom-settings" << 'EOF'
#!/bin/sh

# 设置系统时区为中国上海
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 设置 LuCI 默认语言为中文
uci set luci.main.lang='zh_cn'
uci commit luci

# 设置 LuCI 默认主题为 Argon
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci

# 关闭 Telnet（安全加固）
uci set telnet.general.enable='0' 2>/dev/null || true

# 彻底禁用网络配置中的 IPv6 (DHCPv6/RA/ULA 等)
uci delete network.wan6 2>/dev/null || true
uci set network.globals.ula_prefix=''
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra_slaac='0'
uci commit dhcp
uci commit network

# --- 自动配置 WireGuard 基础环境接口与防火墙 ---
# 判断 wg0 接口是否存在，防止系统升级保留配置时覆盖原有密钥等数据
if ! uci -q get network.wg0 > /dev/null; then
	# 1. 生成服务端私钥及两个客户端密钥对
	WG_SERVER_PRIV="$(wg genkey)"
	WG_CLIENT_PRIV="$(wg genkey)"
	WG_CLIENT_PUB="$(echo "$WG_CLIENT_PRIV" | wg pubkey)"
	WG_PC_PRIV="$(wg genkey)"
	WG_PC_PUB="$(echo "$WG_PC_PRIV" | wg pubkey)"

	# 2. 建立 wg0 接口，注入服务端私钥
	uci set network.wg0="interface"
	uci set network.wg0.proto="wireguard"
	uci set network.wg0.private_key="$WG_SERVER_PRIV"
	uci set network.wg0.listen_port="51820"
	uci set network.wg0.mtu="1280"
	uci add_list network.wg0.addresses="10.0.0.1/24"

	# 3. 手机节点 MyPhone（10.0.0.2），全流量走隧道
	uci set network.wg_client_phone="wireguard_wg0"
	uci set network.wg_client_phone.description="MyPhone"
	uci set network.wg_client_phone.public_key="$WG_CLIENT_PUB"
	uci set network.wg_client_phone.route_allowed_ips="1"
	uci set network.wg_client_phone.persistent_keepalive="25"
	uci add_list network.wg_client_phone.allowed_ips="10.0.0.2/32"

	# 4. 电脑节点 MyPC（10.0.0.3），仅隧道内网段流量
	uci set network.wg_client_pc="wireguard_wg0"
	uci set network.wg_client_pc.description="MyPC"
	uci set network.wg_client_pc.public_key="$WG_PC_PUB"
	uci set network.wg_client_pc.route_allowed_ips="1"
	uci set network.wg_client_pc.persistent_keepalive="25"
	uci add_list network.wg_client_pc.allowed_ips="10.0.0.3/32"
	uci commit network

	# 保存客户端私钥供人工查阅（公钥已注入 UCI，私钥需另分发给客户端）
	mkdir -p /etc/wireguard
	printf '%s\n' "$WG_CLIENT_PRIV" > /etc/wireguard/phone_client.key
	printf '%s\n' "$WG_PC_PRIV"     > /etc/wireguard/pc_client.key
	chmod 600 /etc/wireguard/phone_client.key /etc/wireguard/pc_client.key
fi

if ! uci -q get firewall.wg > /dev/null; then
	# 5. 建立 WireGuard 防火墙区域（不开 masq，由 lan zone 负责 NAT）
	uci set firewall.wg="zone"
	uci set firewall.wg.name="wireguard"
	uci set firewall.wg.input="ACCEPT"
	uci set firewall.wg.output="ACCEPT"
	uci set firewall.wg.forward="ACCEPT"
	uci add_list firewall.wg.network="wg0"

	# WAN 口放行 51820 UDP 端口
	uci set firewall.wg_rule="rule"
	uci set firewall.wg_rule.name="Allow-WireGuard"
	uci set firewall.wg_rule.src="wan"
	uci set firewall.wg_rule.dest_port="51820"
	uci set firewall.wg_rule.proto="udp"
	uci set firewall.wg_rule.target="ACCEPT"

	# 允许 wg 和 lan 互通
	uci set firewall.wg_lan_forward="forwarding"
	uci set firewall.wg_lan_forward.src="wireguard"
	uci set firewall.wg_lan_forward.dest="lan"

	uci set firewall.lan_wg_forward="forwarding"
	uci set firewall.lan_wg_forward.src="lan"
	uci set firewall.lan_wg_forward.dest="wireguard"
	
	# 新增：针对 fw4 (OpenWrt 22.03+) 配置 SNAT 伪装，解决 VPN 客户端无法访问局域网其他设备的问题
	# 原因是局域网设备（如 Windows）的防火墙通常会丢弃来自非本网段 (10.0.0.x) 的请求
	uci set firewall.wg_lan_masq="nat"
	uci set firewall.wg_lan_masq.name="wg-to-lan"
	uci set firewall.wg_lan_masq.src="wireguard"
	uci set firewall.wg_lan_masq.dest="lan"
	uci set firewall.wg_lan_masq.target="MASQUERADE"
	
	uci commit firewall

	# 写入防火墙自定义规则，作为老版本 fw3 (iptables) 的兼容后备方案
	grep -q "10.0.0.0/24" /etc/firewall.user 2>/dev/null || echo "iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o br-lan -j MASQUERADE" >> /etc/firewall.user
fi

exit 0
EOF
chmod +x "$uci_dir/99-custom-settings"

# 8. 预置 OpenVPN 服务端自动初始化脚本
# 原理：固件首次启动时自动生成 CA + 证书 + server.conf + client.ovpn
# 用 printf 逐行写入，避免嵌套 heredoc 在 bash 解析时引发歧义
OVPN_SCRIPT="$uci_dir/98-openvpn-setup"

printf '%s\n' '#!/bin/sh' > "$OVPN_SCRIPT"
printf '%s\n' '# OpenVPN 服务端首次启动自动初始化' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# 已初始化过则跳过' >> "$OVPN_SCRIPT"
printf '%s\n' '[ -f /etc/openvpn/keys/ca.crt ] && exit 0' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' 'logger "OpenVPN: 首次运行，开始自动生成证书（约需 30 秒）..."' >> "$OVPN_SCRIPT"
printf '%s\n' 'mkdir -p /etc/openvpn/keys' >> "$OVPN_SCRIPT"
printf '%s\n' 'chmod 700 /etc/openvpn/keys' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# --- 生成 CA ---' >> "$OVPN_SCRIPT"
printf '%s\n' 'openssl genrsa -out /etc/openvpn/keys/ca.key 2048 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' 'openssl req -new -x509 -days 3650 \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -key /etc/openvpn/keys/ca.key \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -out /etc/openvpn/keys/ca.crt \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -subj "/CN=MyRouter-CA" 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# --- 生成服务端证书 ---' >> "$OVPN_SCRIPT"
printf '%s\n' 'openssl genrsa -out /etc/openvpn/keys/server.key 2048 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' 'openssl req -new -key /etc/openvpn/keys/server.key \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -out /etc/openvpn/keys/server.csr -subj "/CN=MyRouter-Server" 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' 'openssl x509 -req -days 3650 \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -in /etc/openvpn/keys/server.csr \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -CA /etc/openvpn/keys/ca.crt \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -CAkey /etc/openvpn/keys/ca.key \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -CAcreateserial -out /etc/openvpn/keys/server.crt 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# --- 生成客户端证书 ---' >> "$OVPN_SCRIPT"
printf '%s\n' 'openssl genrsa -out /etc/openvpn/keys/client.key 2048 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' 'openssl req -new -key /etc/openvpn/keys/client.key \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -out /etc/openvpn/keys/client.csr -subj "/CN=MyPhone-Client" 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' 'openssl x509 -req -days 3650 \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -in /etc/openvpn/keys/client.csr \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -CA /etc/openvpn/keys/ca.crt \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -CAkey /etc/openvpn/keys/ca.key \' >> "$OVPN_SCRIPT"
printf '%s\n' '    -CAcreateserial -out /etc/openvpn/keys/client.crt 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# --- TLS-Auth key（防暴力破解攻击）---' >> "$OVPN_SCRIPT"
printf '%s\n' 'openvpn --genkey secret /etc/openvpn/keys/ta.key 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# --- 服务端配置文件 ---' >> "$OVPN_SCRIPT"
printf '%s\n' 'cat > /etc/openvpn/server.conf << CONEOF' >> "$OVPN_SCRIPT"
printf '%s\n' 'port 1194' >> "$OVPN_SCRIPT"
printf '%s\n' 'proto udp' >> "$OVPN_SCRIPT"
printf '%s\n' 'dev tun' >> "$OVPN_SCRIPT"
printf '%s\n' 'ca /etc/openvpn/keys/ca.crt' >> "$OVPN_SCRIPT"
printf '%s\n' 'cert /etc/openvpn/keys/server.crt' >> "$OVPN_SCRIPT"
printf '%s\n' 'key /etc/openvpn/keys/server.key' >> "$OVPN_SCRIPT"
printf '%s\n' 'dh none' >> "$OVPN_SCRIPT"
printf '%s\n' 'ecdh-curve prime256v1' >> "$OVPN_SCRIPT"
printf '%s\n' 'tls-auth /etc/openvpn/keys/ta.key 0' >> "$OVPN_SCRIPT"
printf '%s\n' 'cipher AES-256-GCM' >> "$OVPN_SCRIPT"
printf '%s\n' 'auth SHA256' >> "$OVPN_SCRIPT"
printf '%s\n' 'server 10.8.0.0 255.255.255.0' >> "$OVPN_SCRIPT"
printf '%s\n' 'push "redirect-gateway def1 bypass-dhcp"' >> "$OVPN_SCRIPT"
printf '%s\n' 'push "dhcp-option DNS 192.168.3.1"' >> "$OVPN_SCRIPT"
printf '%s\n' 'keepalive 10 120' >> "$OVPN_SCRIPT"
printf '%s\n' 'persist-key' >> "$OVPN_SCRIPT"
printf '%s\n' 'persist-tun' >> "$OVPN_SCRIPT"
printf '%s\n' 'status /tmp/openvpn-status.log' >> "$OVPN_SCRIPT"
printf '%s\n' 'verb 3' >> "$OVPN_SCRIPT"
printf '%s\n' 'CONEOF' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# --- 注册 UCI 服务实例 ---' >> "$OVPN_SCRIPT"
printf '%s\n' 'uci set openvpn.server=openvpn' >> "$OVPN_SCRIPT"
printf '%s\n' "uci set openvpn.server.enabled='1'" >> "$OVPN_SCRIPT"
printf '%s\n' "uci set openvpn.server.config='/etc/openvpn/server.conf'" >> "$OVPN_SCRIPT"
printf '%s\n' 'uci commit openvpn' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# --- 防火墙放行 1194/UDP ---' >> "$OVPN_SCRIPT"
printf '%s\n' 'uci set firewall.openvpn=rule' >> "$OVPN_SCRIPT"
printf '%s\n' "uci set firewall.openvpn.name='Allow-OpenVPN'" >> "$OVPN_SCRIPT"
printf '%s\n' "uci set firewall.openvpn.src='wan'" >> "$OVPN_SCRIPT"
printf '%s\n' "uci set firewall.openvpn.dest_port='1194'" >> "$OVPN_SCRIPT"
printf '%s\n' "uci set firewall.openvpn.proto='udp'" >> "$OVPN_SCRIPT"
printf '%s\n' "uci set firewall.openvpn.target='ACCEPT'" >> "$OVPN_SCRIPT"
printf '%s\n' 'uci commit firewall' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' '# --- 添加 OpenVPN 转发和伪装规则 ---' >> "$OVPN_SCRIPT"
printf '%s\n' '# 允许 tun 接口转发，并进行 SNAT 伪装，保证客户端能访问局域网设备' >> "$OVPN_SCRIPT"
printf '%s\n' 'grep -q "10.8.0.0/24" /etc/firewall.user 2>/dev/null || {' >> "$OVPN_SCRIPT"
printf '%s\n' '    echo "iptables -I FORWARD -i tun+ -j ACCEPT" >> /etc/firewall.user' >> "$OVPN_SCRIPT"
printf '%s\n' '    echo "iptables -I FORWARD -o tun+ -j ACCEPT" >> /etc/firewall.user' >> "$OVPN_SCRIPT"
printf '%s\n' '    echo "iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o br-lan -j MASQUERADE" >> /etc/firewall.user' >> "$OVPN_SCRIPT"
printf '%s\n' '    fw3 restart 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null' >> "$OVPN_SCRIPT"
printf '%s\n' '}' >> "$OVPN_SCRIPT"
printf '%s\n' '' >> "$OVPN_SCRIPT"
printf '%s\n' 'logger "OpenVPN: 初始化完毕！"' >> "$OVPN_SCRIPT"
printf '%s\n' 'logger "OpenVPN: 请在路由器 Web 界面【服务】->【OpenVPN 客户端配置下载】中直接获取配置文件。"' >> "$OVPN_SCRIPT"
chmod +x "$OVPN_SCRIPT"

# --- 提供 Web UI (LuCI) 一键下载 OpenVPN 配置文件的功能 ---
# 1. 核心生成脚本
mkdir -p package/base-files/files/bin
cat > package/base-files/files/bin/gen-ovpn-client << 'EOF'
#!/bin/sh
if [ ! -f /etc/openvpn/keys/ca.crt ]; then
    exit 1
fi

printf "client\ndev tun\nproto udp\n"
printf "remote YOUR-DDNS-DOMAIN.COM 1194\n"
printf "resolv-retry infinite\nnobind\n"
printf "persist-key\npersist-tun\n"
printf "cipher AES-256-GCM\nauth SHA256\n"
printf "key-direction 1\nverb 3\n\n"
printf "<ca>\n"; cat /etc/openvpn/keys/ca.crt; printf "</ca>\n\n"
printf "<cert>\n"; openssl x509 -in /etc/openvpn/keys/client.crt; printf "</cert>\n\n"
printf "<key>\n"; cat /etc/openvpn/keys/client.key; printf "</key>\n\n"
printf "<tls-auth>\n"; cat /etc/openvpn/keys/ta.key; printf "</tls-auth>\n"
EOF
chmod +x package/base-files/files/bin/gen-ovpn-client

# 2. LuCI Web 界面入口
mkdir -p package/base-files/files/usr/lib/lua/luci/controller
cat > package/base-files/files/usr/lib/lua/luci/controller/openvpn_dl.lua << 'EOF'
module("luci.controller.openvpn_dl", package.seeall)

function index()
    -- 挂载在 Web 后台“服务(Services)”菜单下
    entry({"admin", "services", "openvpn_dl"}, call("action_download"), "OpenVPN 客户端配置下载", 99).dependent = true
end

function action_download()
    local fp = io.popen("/bin/gen-ovpn-client 2>/dev/null")
    if not fp then
        luci.http.status(500, "Internal Server Error")
        return
    end
    local content = fp:read("*a")
    fp:close()
    
    if content == nil or content == "" then
        luci.http.prepare_content("text/plain; charset=utf-8")
        luci.http.write("证书尚未生成或发生错误，请等待系统首次开机初始化几分钟后再试。")
        return
    end

    luci.http.prepare_content("application/x-openvpn-profile")
    luci.http.header("Content-Disposition", "attachment; filename=\"client.ovpn\"")
    luci.http.write(content)
end
EOF

# 6. 预置 OpenClash 内核（避免首次安装系统后因无代理导致无法下载内核的死锁问题）
CORE_DIR="package/base-files/files/etc/openclash/core"
mkdir -p "$CORE_DIR"

echo "Downloading OpenClash cores..."
if curl -sL --connect-timeout 60 \
    https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz \
    | tar xzvC "$CORE_DIR"; then
    mv "$CORE_DIR/clash" "$CORE_DIR/clash_meta" 2>/dev/null || true
    chmod +x "$CORE_DIR/clash_meta"
    echo "OpenClash core downloaded successfully!"
else
    echo "WARNING: OpenClash core download failed, will be downloaded at first boot."
fi

# 7. 强制写入 qrencode 软件包，用于 WireGuard 的配置二维码显示
echo "CONFIG_PACKAGE_qrencode=y" >> .config

# 8. 强制写入 OpenAppFilter 软件包
echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config

# 9. 修复“保留配置”升级时 OpenVPN 证书丢失的问题
# 将 OpenVPN 的配置和证书目录加入系统升级的白名单中（保留配置升级时不会被清除）
KEEP_D_DIR="package/base-files/files/lib/upgrade/keep.d"
mkdir -p "$KEEP_D_DIR"
echo "/etc/openvpn/" > "$KEEP_D_DIR/openvpn-custom"


# 10. 注入固件版本号，供 luci-app-autoupdate 与 GitHub Release Tag 进行比对
# Release Tag 格式 (openwrt-builder.yml)：YYYY.MM.DD-HHMM
# 插件比对逻辑：云端 tag > 本地 tag 则提示更新
#
# 【修复说明】
# 不能直接写 package/base-files/files/etc/openwrt_release，
# 因为 OpenWrt 编译系统在打包时会根据 .config 中的 CONFIG_VERSION_* 变量
# 自动重新生成该文件，手写的内容会被覆盖。
# 正确做法：将版本号注入 .config 的 CONFIG_VERSION_NUMBER 字段，
# 编译系统会将其写入 DISTRIB_REVISION，从而让版本号正确生成到固件中。
BUILD_DATE="${BUILD_DATE:-$(date +"%Y.%m.%d-%H%M")}"

# 从 .config 中删除旧的版本号配置（避免重复），再写入新值
sed -i '/^CONFIG_VERSION_NUMBER=/d' .config
sed -i '/^CONFIG_VERSION_CODE=/d' .config

# CONFIG_VERSION_NUMBER → 生成到 /etc/openwrt_release 的 DISTRIB_REVISION 字段
# CONFIG_VERSION_CODE   → 生成到 /etc/openwrt_release 的 DISTRIB_CODENAME 字段（可选）
echo "CONFIG_VERSION_NUMBER=\"${BUILD_DATE}\"" >> .config

echo "固件版本号已注入 .config: ${BUILD_DATE}"