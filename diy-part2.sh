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



# 修改默认 LAN IP 和主机名
sed -i 's/192.168.1.1/192.168.3.1/g' package/base-files/files/bin/config_generate
sed -i 's/OpenWrt/MyOpenWrt/g' package/base-files/files/bin/config_generate

# 启用 BBR TCP 拥塞控制与 FQ 队列调度，并全局禁用 IPv6
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
if [ "$(uci -q get network.globals.auto_inited)" = "1" ]; then
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

uci set network.globals='globals' 2>/dev/null || true
uci set network.globals.auto_inited='1'
uci commit network
EOF
chmod +x "$uci_dir/97-auto-network"

cat > "$uci_dir/99-custom-settings" << 'EOF'
#!/bin/sh

# 使用全局标识位防止升级还原用户配置
if [ "$(uci -q get system.@system[0].custom_inited)" = "1" ]; then
    exit 0
fi

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
	uci set firewall.wg.masq="1"
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
	
	uci set firewall.wg_wan_forward="forwarding"
	uci set firewall.wg_wan_forward.src="wireguard"
	uci set firewall.wg_wan_forward.dest="wan"

	uci set firewall.wg_lan_masq="nat"
	uci set firewall.wg_lan_masq.name="wg-to-lan"
	uci set firewall.wg_lan_masq.src="wireguard"
	uci set firewall.wg_lan_masq.dest="lan"
	uci set firewall.wg_lan_masq.target="MASQUERADE"
	uci commit firewall

	grep -q "10.0.0.0/24" /etc/firewall.user 2>/dev/null || echo "iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o br-lan -j MASQUERADE" >> /etc/firewall.user
fi

# 开启 UPnP 与 NAT-PMP 服务
if uci -q get upnpd.config > /dev/null; then
	uci set upnpd.config.enabled='1'
	uci set upnpd.config.enable_upnp='1'
	uci set upnpd.config.enable_natpmp='1'
	uci commit upnpd
fi

uci set system.@system[0].custom_inited='1'
uci commit system

exit 0
EOF
chmod +x "$uci_dir/99-custom-settings"

# 预置 OpenVPN 服务端自动初始化脚本
OVPN_SCRIPT="$uci_dir/98-openvpn-setup"

cat > "$OVPN_SCRIPT" << 'EOF'
#!/bin/sh
[ -f /etc/openvpn/keys/ca.crt ] && exit 0

mkdir -p /etc/openvpn/keys
chmod 700 /etc/openvpn/keys

# ── 生成 CA ──────────────────────────────────────────────
openssl genrsa -out /etc/openvpn/keys/ca.key 2048 2>/dev/null
openssl req -new -x509 -days 3650 \
    -key /etc/openvpn/keys/ca.key \
    -out /etc/openvpn/keys/ca.crt \
    -subj "/CN=MyRouter-CA" 2>/dev/null

# ── 生成服务端证书 ────────────────────────────────────────
openssl genrsa -out /etc/openvpn/keys/server.key 2048 2>/dev/null
openssl req -new -key /etc/openvpn/keys/server.key \
    -out /etc/openvpn/keys/server.csr \
    -subj "/CN=MyRouter-Server" 2>/dev/null
openssl x509 -req -days 3650 \
    -in /etc/openvpn/keys/server.csr \
    -CA /etc/openvpn/keys/ca.crt \
    -CAkey /etc/openvpn/keys/ca.key \
    -CAcreateserial \
    -extfile <(printf 'extendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment') \
    -out /etc/openvpn/keys/server.crt 2>/dev/null

# ── 生成客户端证书 ────────────────────────────────────────
openssl genrsa -out /etc/openvpn/keys/client.key 2048 2>/dev/null
openssl req -new -key /etc/openvpn/keys/client.key \
    -out /etc/openvpn/keys/client.csr \
    -subj "/CN=MyPhone-Client" 2>/dev/null
openssl x509 -req -days 3650 \
    -in /etc/openvpn/keys/client.csr \
    -CA /etc/openvpn/keys/ca.crt \
    -CAkey /etc/openvpn/keys/ca.key \
    -CAcreateserial \
    -extfile <(printf 'extendedKeyUsage=clientAuth') \
    -out /etc/openvpn/keys/client.crt 2>/dev/null

# ── 生成 TLS-Crypt 预共享密钥（替代 tls-auth，更安全且无方向歧义）────
# openvpn --genkey tls-crypt-v2-server 在旧版本中不兼容
# 使用 secret 关键字生成，tls-crypt 与 tls-auth 均可使用 secret 格式密钥
openvpn --genkey --type tls-auth /etc/openvpn/keys/ta.key 2>/dev/null || \
    openvpn --genkey secret /etc/openvpn/keys/ta.key 2>/dev/null
chmod 600 /etc/openvpn/keys/ta.key
chmod 600 /etc/openvpn/keys/ca.key /etc/openvpn/keys/server.key /etc/openvpn/keys/client.key

# ── 禁用 tun 接口的反向路径过滤（rp_filter），否则返回包会被丢弃 ────
for f in /proc/sys/net/ipv4/conf/all/rp_filter \
          /proc/sys/net/ipv4/conf/default/rp_filter; do
    echo 0 > "$f" 2>/dev/null || true
done

# ── 加载 tun 内核模块 ────────────────────────────────────
modprobe tun 2>/dev/null || true

LAN_IP=$(uci -q get network.lan.ipaddr || echo "192.168.3.1")

# ── 写入服务端配置 ────────────────────────────────────────
cat > /etc/openvpn/server.conf << CONEOF
port 1194
proto udp
dev tun
ca /etc/openvpn/keys/ca.crt
cert /etc/openvpn/keys/server.crt
key /etc/openvpn/keys/server.key
dh none
ecdh-curve prime256v1
tls-crypt /etc/openvpn/keys/ta.key
tls-version-min 1.2
remote-cert-tls client
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 114.114.114.114"
push "dhcp-option DNS 8.8.8.8"
push "route-metric 512"
keepalive 10 120
persist-key
persist-tun
explicit-exit-notify 1
status /tmp/openvpn-status.log
log-append /tmp/openvpn.log
verb 3
CONEOF

# ── 注册 OpenVPN UCI ─────────────────────────────────────
uci set openvpn.server=openvpn
uci set openvpn.server.enabled='1'
uci set openvpn.server.config='/etc/openvpn/server.conf'
uci commit openvpn

# ── 在 /etc/sysctl.conf 追加 rp_filter 禁用（持久化）────
grep -q 'net.ipv4.conf.all.rp_filter' /etc/sysctl.conf 2>/dev/null || \
    echo 'net.ipv4.conf.all.rp_filter=0' >> /etc/sysctl.conf
grep -q 'net.ipv4.conf.default.rp_filter' /etc/sysctl.conf 2>/dev/null || \
    echo 'net.ipv4.conf.default.rp_filter=0' >> /etc/sysctl.conf
grep -q 'net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null || \
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# ── 注册 ovpn 网络接口 (unmanaged，让 OpenVPN 自行管理 tun0) ────
uci set network.ovpn='interface'
uci set network.ovpn.proto='unmanaged'
uci set network.ovpn.device='tun0'
uci commit network

# ── 独立的 OpenVPN 防火墙区域（关键：与 LAN zone 分开，配 masq）────
# 不能把 tun+ 加入 LAN zone，那样无法 NAT 出去到 WAN
uci set firewall.ovpn_zone='zone'
uci set firewall.ovpn_zone.name='openvpn'
uci set firewall.ovpn_zone.input='ACCEPT'
uci set firewall.ovpn_zone.output='ACCEPT'
uci set firewall.ovpn_zone.forward='ACCEPT'
uci set firewall.ovpn_zone.masq='1'
uci add_list firewall.ovpn_zone.network='ovpn'
uci add_list firewall.ovpn_zone.device='tun+'

# ovpn → wan 转发（客户端流量走 WAN 出去上网）
uci set firewall.ovpn_wan='forwarding'
uci set firewall.ovpn_wan.src='openvpn'
uci set firewall.ovpn_wan.dest='wan'

# ovpn → lan 转发（客户端可访问路由器内网）
uci set firewall.ovpn_lan='forwarding'
uci set firewall.ovpn_lan.src='openvpn'
uci set firewall.ovpn_lan.dest='lan'

# lan → ovpn 转发（内网主机可主动访问 VPN 客户端）
uci set firewall.lan_ovpn='forwarding'
uci set firewall.lan_ovpn.src='lan'
uci set firewall.lan_ovpn.dest='openvpn'

# WAN 放行 1194 UDP
uci set firewall.openvpn_rule='rule'
uci set firewall.openvpn_rule.name='Allow-OpenVPN'
uci set firewall.openvpn_rule.src='wan'
uci set firewall.openvpn_rule.dest_port='1194'
uci set firewall.openvpn_rule.proto='udp'
uci set firewall.openvpn_rule.target='ACCEPT'

uci commit firewall
EOF
chmod +x "$OVPN_SCRIPT"

# --- 提供 Web UI (LuCI) 一键下载 OpenVPN 配置文件的功能 ---
# 1. 核心生成脚本
mkdir -p package/base-files/files/bin
cat > package/base-files/files/bin/gen-ovpn-client << 'EOF'
#!/bin/sh
if [ ! -f /etc/openvpn/keys/ca.crt ]; then
    echo "# 证书尚未生成，请等待首次开机初始化完成后重试" >&2
    exit 1
fi

# 获取 DDNS 域名参数（可选，不传则留占位符）
REMOTE="${1:-YOUR-DDNS-DOMAIN.COM}"

# 提取只含 BEGIN/END CERTIFICATE 的 PEM 块（去除链式证书中的中间证书）
CA_CERT=$(openssl x509 -in /etc/openvpn/keys/ca.crt 2>/dev/null)
CLIENT_CERT=$(openssl x509 -in /etc/openvpn/keys/client.crt 2>/dev/null)

printf 'client\n'
printf 'dev tun\n'
printf 'proto udp\n'
printf 'remote %s 1194\n' "$REMOTE"
printf 'resolv-retry infinite\n'
printf 'nobind\n'
printf 'persist-key\n'
printf 'persist-tun\n'
printf 'remote-cert-tls server\n'
printf 'tls-version-min 1.2\n'
printf 'cipher AES-256-GCM\n'
printf 'ncp-ciphers AES-256-GCM:AES-128-GCM\n'
printf 'auth SHA256\n'
printf 'key-direction 1\n'
printf 'verb 3\n'
printf 'mute 20\n'
printf 'keepalive 10 60\n'
printf '\n'
printf '<ca>\n'; printf '%s\n' "$CA_CERT"; printf '</ca>\n'
printf '\n'
printf '<cert>\n'; printf '%s\n' "$CLIENT_CERT"; printf '</cert>\n'
printf '\n'
printf '<key>\n'; cat /etc/openvpn/keys/client.key; printf '</key>\n'
printf '\n'
printf '<tls-crypt>\n'; cat /etc/openvpn/keys/ta.key; printf '</tls-crypt>\n'
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
DNS="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.3.1)"

printf '[Interface]\n'
printf 'PrivateKey = %s\n' "$PRIV_KEY"
printf 'Address = %s\n' "$CLIENT_IP"
printf 'DNS = %s\n' "$DNS"
printf '\n'
printf '[Peer]\n'
printf 'PublicKey = %s\n' "$SERVER_PUB"
if [ "$DEVICE" = "phone" ]; then
    printf 'AllowedIPs = 0.0.0.0/0\n'
else
    # 电脑节点：提取网关所在 C 段自适应下发路由表
    ROUTER_SUBNET="$(echo $DNS | cut -d'.' -f1,2,3).0/24"
    printf 'AllowedIPs = %s, 10.0.0.0/24\n' "$ROUTER_SUBNET"
fi
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
    local util  = require "luci.util"

    local domain_file = "/etc/wireguard/domain.txt"
    local saved_domain = ""
    local f = io.open(domain_file, "r")
    if f then
        saved_domain = f:read("*l") or ""
        f:close()
    end
    
    local domain = http.formvalue("domain")
    
    -- 从 UCI 迁移至文本直存：避免缺少 ACL 写入权限，或被网络设置页面的“保存应用”清洗掉未知字段
    if domain and domain ~= "" and domain ~= saved_domain then
        local w = io.open(domain_file, "w")
        if w then
            w:write(domain)
            w:close()
            saved_domain = domain
        end
    end
    
    -- 页面上最终使用的域名（优先使用表单的值，如果没提交就是空的时候，使用保存的值）
    domain = (domain and domain ~= "") and domain or saved_domain

    local device = http.formvalue("device") or "phone"
    local action = http.formvalue("action") or ""

    -- 下载 .conf 文件
    if action == "download" and domain ~= "" then
        -- 修复重大隐患：Lua 的 %q 转义出的双引号依然会被 Shell 解析 $(...) 和反引号。必须用 shellquote (单引号)
        local safe_cmd = "/bin/gen-wg-client " .. util.shellquote(device) .. " " .. util.shellquote(domain) .. " 2>/dev/null"
        local conf = sys.exec(safe_cmd)
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
        local safe_cmd1 = "/bin/gen-wg-client " .. util.shellquote(device) .. " " .. util.shellquote(domain) .. " 2>/dev/null"
        conf_text = sys.exec(safe_cmd1)
        if conf_text and conf_text ~= "" then
            -- 生成 SVG 二维码（qrencode 已内置）
            local tmp = "/tmp/wg_qr_" .. device .. ".svg"
            local safe_cmd2 = "/bin/gen-wg-client " .. util.shellquote(device) .. " " .. util.shellquote(domain) .. " 2>/dev/null | qrencode -t SVG -o " .. util.shellquote(tmp)
            os.execute(safe_cmd2)
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

if curl -sL --connect-timeout 60 \
    https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz \
    | tar xzvC "$CORE_DIR" -f -; then
    mv "$CORE_DIR/clash" "$CORE_DIR/clash_meta" 2>/dev/null || true
    chmod +x "$CORE_DIR/clash_meta"
fi

# 7. 强制写入 qrencode 软件包，用于 WireGuard 的配置二维码显示
echo "CONFIG_PACKAGE_qrencode=y" >> .config

# 8. 强制写入核心加密组件与第三方依赖包
echo "CONFIG_PACKAGE_openssl-util=y" >> .config
echo "CONFIG_PACKAGE_wireguard-tools=y" >> .config
echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config
echo "CONFIG_PACKAGE_luci-app-upnp=y" >> .config
echo "CONFIG_PACKAGE_kmod-tun=y" >> .config
echo "CONFIG_PACKAGE_openvpn-openssl=y" >> .config
echo "CONFIG_PACKAGE_luci-app-openvpn=y" >> .config

# 9. 修复“保留配置”升级时 OpenVPN 证书丢失的问题
# 将 OpenVPN 的配置和证书目录加入系统升级的白名单中（保留配置升级时不会被清除）
KEEP_D_DIR="package/base-files/files/lib/upgrade/keep.d"
mkdir -p "$KEEP_D_DIR"
echo "/etc/openvpn/" > "$KEEP_D_DIR/vpn-custom"
echo "/etc/wireguard/" >> "$KEEP_D_DIR/vpn-custom"


# 10. 注入固件版本号，供 luci-app-autoupdate 与 GitHub Release Tag 进行比对
# Release Tag 格式 (openwrt-builder.yml)：YYYY.MM.DD-HHMM
BUILD_DATE=$(TZ=UTC-8 date +"%Y.%m.%d-%H%M")

sed -i '/^CONFIG_VERSION_NUMBER=/d' .config
sed -i '/^CONFIG_VERSION_CODE=/d' .config

echo "CONFIG_VERSION_NUMBER=\"${BUILD_DATE}\"" >> .config
sed -i "s/R[0-9]\+\.[0-9]\+\.[0-9]\+/${BUILD_DATE}/g" package/lean/default-settings/files/zzz-default-settings

# 11. 写入 SSH 登录欢迎 Banner（含 ASCII Art + 作者/项目/构建时间）
mkdir -p package/base-files/files/etc
cat > package/base-files/files/etc/banner << EOF
  _______                     ________        __
 |       |.-----.-----.-----.|  |  |  |.----.|  |_
 |   -   ||  _  |  -__|     ||  |  |  ||   _||   _|
 |_______||   __|_____|__|__||________||__|  |____|
          |__| W I R E L E S S   F R E E D O M
 -----------------------------------------------------
  作者：夏昸
  项目：https://github.com/suifeng009/openwrt
  构建：${BUILD_DATE}
 -----------------------------------------------------
EOF

# 12. 写入 LuCI 概览页厂商/项目信息（官方 CONFIG_VERSION_* 字段）
sed -i '/^CONFIG_VERSION_MANUFACTURER=/d' .config
sed -i '/^CONFIG_VERSION_BUG_URL=/d' .config
echo 'CONFIG_VERSION_MANUFACTURER="夏昸 OpenWrt"' >> .config
echo 'CONFIG_VERSION_BUG_URL="https://github.com/suifeng009/openwrt"' >> .config

# 13. 在固件元信息文件追加自定义作者字段（供脚本/插件读取）
mkdir -p package/base-files/files/etc
# 若文件不存在则创建，避免追加到空路径
touch package/base-files/files/etc/openwrt_release
grep -q "DISTRIB_AUTHOR" package/base-files/files/etc/openwrt_release \
  || cat >> package/base-files/files/etc/openwrt_release << 'REOF'
DISTRIB_AUTHOR="夏昸"
DISTRIB_PROJECT="https://github.com/suifeng009/openwrt"
REOF

# 14. 自定义 Argon 登录页底部 Footer（直接覆写主题源码，避免与 base-files 文件冲突）
# argon 主题由 feeds 提供，其源码路径为 feeds/luci/themes/luci-theme-argon
# 直接写入该路径，文件归属仍属于 argon 包，不会触发 check_data_file_clashes
ARGON_FOOTER="feeds/luci/themes/luci-theme-argon/luasrc/view/themes/argon/footer_login.htm"
if [ -f "$ARGON_FOOTER" ]; then
  cat > "$ARGON_FOOTER" << 'EOF'
<%
local ver = require "luci.version"
%>
<div class="login-footer">
  <span><a href="https://github.com/suifeng009/openwrt" target="_blank">夏昸 OpenWrt</a></span>
  <span> <%= ver.distversion %></span>
</div>
EOF
fi