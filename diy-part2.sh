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

# 2b. 从 config_generate 源头删除 wan6 接口的创建逻辑
# 这是 wan6 被持续生成的根本原因：config_generate 在每次首次启动时都会重建 wan6
# 用 awk 删除包含 "wan6" 的整个 set_interface 调用块（从 set_interface wan6 直到下一个空行）
awk '/set_interface.*wan6/{skip=1} skip && /^\s*$/{skip=0; next} !skip' \
    package/base-files/files/bin/config_generate > /tmp/config_generate.tmp && \
    mv /tmp/config_generate.tmp package/base-files/files/bin/config_generate
chmod +x package/base-files/files/bin/config_generate

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

	# 保存所有密钥文件（客户端私钥 + 服务端公钥），供配置下载页面使用
	mkdir -p /etc/wireguard
	printf '%s\n' "$WG_CLIENT_PRIV" > /etc/wireguard/phone_client.key
	printf '%s\n' "$WG_PC_PRIV"     > /etc/wireguard/pc_client.key
	# 服务端公钥：客户端配置中的 [Peer] PublicKey 字段需要用到它
	printf '%s\n' "$(echo "$WG_SERVER_PRIV" | wg pubkey)" > /etc/wireguard/server_public.key
	chmod 600 /etc/wireguard/phone_client.key /etc/wireguard/pc_client.key
	chmod 644 /etc/wireguard/server_public.key
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

# --- WireGuard 客户端配置下载功能 ---
# 用户在 LuCI 页面输入 DDNS 域名，即可获得完整的客户端 .conf 文件和二维码
# 服务端公钥、客户端私钥均在首次启动时自动生成并保存

# 1. 核心生成脚本：/bin/gen-wg-client <phone|pc> <domain>
mkdir -p package/base-files/files/bin
cat > package/base-files/files/bin/gen-wg-client << 'EOF'
#!/bin/sh
# 用法: gen-wg-client <phone|pc> <domain>
DEVICE="${1:-phone}"
DOMAIN="${2:-your-domain.example.com}"

case "$DEVICE" in
    phone)
        KEY_FILE="/etc/wireguard/phone_client.key"
        CLIENT_IP="10.0.0.2/32"
        ;;
    pc)
        KEY_FILE="/etc/wireguard/pc_client.key"
        CLIENT_IP="10.0.0.3/32"
        ;;
    *)
        echo "Error: unknown device type '$DEVICE'" >&2
        exit 1
        ;;
esac

if [ ! -f "$KEY_FILE" ]; then
    echo "Error: key file not found: $KEY_FILE" >&2
    echo "System may not have completed first-boot initialization yet." >&2
    exit 1
fi
if [ ! -f "/etc/wireguard/server_public.key" ]; then
    echo "Error: server public key not found." >&2
    exit 1
fi

PRIV_KEY="$(cat $KEY_FILE)"
SERVER_PUB="$(cat /etc/wireguard/server_public.key)"
PORT="$(uci -q get network.wg0.listen_port 2>/dev/null || echo 51820)"
DNS="192.168.3.1"

printf '[Interface]\n'
printf 'PrivateKey = %s\n' "$PRIV_KEY"
printf 'Address = %s\n' "$CLIENT_IP"
printf 'DNS = %s\n' "$DNS"
printf '\n'
printf '[Peer]\n'
printf 'PublicKey = %s\n' "$SERVER_PUB"
printf 'AllowedIPs = 0.0.0.0/0\n'
printf 'Endpoint = %s:%s\n' "$DOMAIN" "$PORT"
printf 'PersistentKeepalive = 25\n'
EOF
chmod +x package/base-files/files/bin/gen-wg-client

# 2. LuCI 控制器
mkdir -p package/base-files/files/usr/lib/lua/luci/controller
cat > package/base-files/files/usr/lib/lua/luci/controller/wg_client_dl.lua << 'EOF'
module("luci.controller.wg_client_dl", package.seeall)

function index()
    entry({"admin", "services", "wg_client_dl"}, call("action_index"), "WireGuard 客户端配置", 98).dependent = true
end

function action_index()
    local http  = require "luci.http"
    local sys   = require "luci.sys"
    local uci   = require "luci.model.uci".cursor()

    local saved_domain = uci:get("network", "wg0", "endpoint_domain") or ""
    local domain = http.formvalue("domain")
    
    -- 如果用户提交了新域名，保存到 uci
    if domain and domain ~= "" and domain ~= saved_domain then
        uci:set("network", "wg0", "endpoint_domain", domain)
        uci:commit("network")
        saved_domain = domain
    end
    
    -- 页面上最终使用的域名（优先使用表单的值，如果没提交就是空的时候，使用保存的值）
    domain = (domain and domain ~= "") and domain or saved_domain

    local device = http.formvalue("device") or "phone"
    local action = http.formvalue("action") or ""

    -- 下载 .conf 文件
    if action == "download" and domain ~= "" then
        local conf = sys.exec("/bin/gen-wg-client " .. device .. " " .. domain .. " 2>/dev/null")
        if conf and conf ~= "" then
            http.prepare_content("text/plain")
            http.header("Content-Disposition", "attachment; filename=\"wg-" .. device .. ".conf\"")
            http.write(conf)
        else
            http.status(500, "Internal Server Error")
            http.prepare_content("text/plain; charset=utf-8")
            http.write("密钥尚未生成，请等待首次开机初始化完成后再试。")
        end
        return
    end

    -- 渲染页面（含配置预览和二维码）
    local conf_text = ""
    local qr_b64   = ""
    if action == "preview" and domain ~= "" then
        conf_text = sys.exec("/bin/gen-wg-client " .. device .. " " .. domain .. " 2>/dev/null")
        if conf_text and conf_text ~= "" then
            -- 生成 SVG 二维码（qrencode 已内置）
            local tmp = "/tmp/wg_qr_" .. device .. ".svg"
            os.execute("/bin/gen-wg-client " .. device .. " " .. domain .. " 2>/dev/null | qrencode -t SVG -o " .. tmp)
            local f = io.open(tmp, "r")
            if f then
                qr_b64 = f:read("*a")
                f:close()
                os.remove(tmp)
            end
        end
    end

    luci.template.render("wg_client_dl", {
        domain    = domain,
        device    = device,
        conf_text = conf_text,
        qr_svg    = qr_b64,
    })
end
EOF

# 3. LuCI 视图模板
mkdir -p package/base-files/files/usr/lib/lua/luci/view
cat > package/base-files/files/usr/lib/lua/luci/view/wg_client_dl.htm << 'HTEOF'
<%+header%>
<style>
.wg-card{background:#1e293b;border-radius:12px;padding:24px;margin-bottom:20px;color:#e2e8f0}
.wg-card h3{margin:0 0 16px;color:#7dd3fc;font-size:1.1em}
.wg-form label{display:block;margin-bottom:6px;font-size:.9em;color:#94a3b8}
.wg-form input,.wg-form select{width:100%;padding:10px 14px;border-radius:8px;
  border:1px solid #334155;background:#0f172a;color:#e2e8f0;font-size:.95em;box-sizing:border-box}
.wg-form input:focus,.wg-form select:focus{outline:none;border-color:#38bdf8}
.wg-btn{display:inline-block;padding:10px 22px;border-radius:8px;border:none;
  cursor:pointer;font-size:.95em;margin-right:10px;margin-top:12px}
.wg-btn-preview{background:#0ea5e9;color:#fff}
.wg-btn-dl{background:#10b981;color:#fff}
.wg-pre{background:#0f172a;border-radius:8px;padding:16px;font-family:monospace;
  font-size:.85em;white-space:pre;overflow-x:auto;color:#86efac;border:1px solid #1e3a4a}
.wg-qr{text-align:center;margin-top:16px}
.wg-qr svg{max-width:220px;height:auto;background:#fff;padding:10px;border-radius:8px}
.wg-tip{font-size:.83em;color:#64748b;margin-top:8px}
</style>
<h2><%-translate("WireGuard 客户端配置")%></h2>
<div class="wg-card">
  <h3>生成客户端配置</h3>
  <form method="post" class="wg-form">
    <div style="margin-bottom:14px">
      <label>设备类型</label>
      <select name="device">
        <option value="phone" <%=(device=="phone" and "selected" or "")%>>📱 手机（MyPhone - 10.0.0.2）</option>
        <option value="pc"    <%=(device=="pc"    and "selected" or "")%>>💻 电脑（MyPC - 10.0.0.3）</option>
      </select>
    </div>
    <div style="margin-bottom:14px">
      <label>您的 DDNS 域名（或公网 IP）</label>
      <input type="text" name="domain" value="<%=domain%>" placeholder="your-ddns.example.com" required />
    </div>
    <div>
      <button class="wg-btn wg-btn-preview" type="submit" name="action" value="preview">👁 预览 &amp; 二维码</button>
      <button class="wg-btn wg-btn-dl"      type="submit" name="action" value="download">⬇ 下载 .conf 文件</button>
    </div>
  </form>
  <p class="wg-tip">所有密钥均在首次开机时自动生成。您只需填写您的域名即可获得完整客户端配置。</p>
</div>
<% if conf_text and conf_text ~= "" then %>
<div class="wg-card">
  <h3>配置内容预览</h3>
  <div class="wg-pre"><%=conf_text%></div>
  <% if qr_svg and qr_svg ~= "" then %>
  <div class="wg-qr">
    <p style="color:#94a3b8;margin-bottom:8px">手机端扫码导入</p>
    <%=qr_svg%>
  </div>
  <% end %>
</div>
<% end %>
<%+footer%>
HTEOF

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
# 【重要说明】
# 此处写入 .config 的版本号会被随后执行的 `make defconfig` 覆盖！
# 真正生效的二次注入位于 workflow 的「Download package」步骤中，
# 在 `make defconfig` 执行完毕后立即重写 CONFIG_VERSION_NUMBER。
# 此处保留是为了方便本地调试参考。
BUILD_DATE="${BUILD_DATE:-$(date +"%Y.%m.%d-%H%M")}"

# 从 .config 中删除旧的版本号配置（避免重复），再写入新值
sed -i '/^CONFIG_VERSION_NUMBER=/d' .config
sed -i '/^CONFIG_VERSION_CODE=/d' .config

# CONFIG_VERSION_NUMBER → 生成到 /etc/openwrt_release 的 DISTRIB_REVISION 字段
# CONFIG_VERSION_CODE   → 生成到 /etc/openwrt_release 的 DISTRIB_CODENAME 字段（可选）
echo "CONFIG_VERSION_NUMBER=\"${BUILD_DATE}\"" >> .config

echo "固件版本号已写入 .config（预注入，实际生效在 defconfig 之后）: ${BUILD_DATE}"