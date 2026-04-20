#!/bin/bash
# 04-uci-defaults-custom.sh - 预置系统定制与插件初始化脚本

uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"

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
	# 1. 生成服务端密钥
	WG_SERVER_PRIV="$(wg genkey)"
	WG_SERVER_PUB="$(echo "$WG_SERVER_PRIV" | wg pubkey)"

	# 2. 建立 wg0 接口，注入服务端私钥
	uci set network.wg0="interface"
	uci set network.wg0.proto="wireguard"
	uci set network.wg0.private_key="$WG_SERVER_PRIV"
	uci set network.wg0.listen_port="51820"
	uci set network.wg0.mtu="1420"
	uci add_list network.wg0.addresses="10.0.0.1/24"

	mkdir -p /etc/wireguard

	# 3. 循环生成 6 部手机 + 6 台 PC 的密钥与 Peer（共 12 个节点）
	#    phone1-6 → 10.0.0.2-7，pc1-6 → 10.0.0.8-13，全部走全流量代理
	for _i in 1 2 3 4 5 6; do
		# phone$_i
		_PRIV="$(wg genkey)"
		_PUB="$(echo "$_PRIV" | wg pubkey)"
		_PSK="$(wg genpsk)"
		uci set network.wg_phone${_i}="wireguard_wg0"
		uci set network.wg_phone${_i}.description="Phone${_i}"
		uci set network.wg_phone${_i}.public_key="$_PUB"
		uci set network.wg_phone${_i}.preshared_key="$_PSK"
		uci set network.wg_phone${_i}.route_allowed_ips="1"
		uci add_list network.wg_phone${_i}.allowed_ips="10.0.0.$((1+_i))/32"
		printf 'PRIV_KEY="%s"\nPSK="%s"\n' "$_PRIV" "$_PSK" > /etc/wireguard/phone${_i}.info

		# pc$_i
		_PRIV="$(wg genkey)"
		_PUB="$(echo "$_PRIV" | wg pubkey)"
		_PSK="$(wg genpsk)"
		uci set network.wg_pc${_i}="wireguard_wg0"
		uci set network.wg_pc${_i}.description="PC${_i}"
		uci set network.wg_pc${_i}.public_key="$_PUB"
		uci set network.wg_pc${_i}.preshared_key="$_PSK"
		uci set network.wg_pc${_i}.route_allowed_ips="1"
		uci add_list network.wg_pc${_i}.allowed_ips="10.0.0.$((7+_i))/32"
		printf 'PRIV_KEY="%s"\nPSK="%s"\n' "$_PRIV" "$_PSK" > /etc/wireguard/pc${_i}.info
	done

	uci commit network

	chmod 600 /etc/wireguard/*.info
	# 服务端公钥：客户端配置中的 [Peer] PublicKey 字段需要用到它
	echo "$WG_SERVER_PUB" > /etc/wireguard/server_public.key
	chmod 644 /etc/wireguard/server_public.key
fi

if ! uci -q get firewall.wg > /dev/null; then
	# 5. 建立 WireGuard 防火墙区域（直接互通，依托 OpenWrt 原生路由回包，无需 MASQUERADE）
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
	
	# 允许 wg 节点访问外网 (WAN 口默认带有 Masquerade，所以外网访问会自动转换)
	uci set firewall.wg_wan_forward="forwarding"
	uci set firewall.wg_wan_forward.src="wireguard"
	uci set firewall.wg_wan_forward.dest="wan"

	uci commit firewall
fi

# 开启 UPnP 与 NAT-PMP 服务
if uci -q get upnpd.config > /dev/null; then
	uci set upnpd.config.enabled='1'
	uci set upnpd.config.enable_upnp='1'
	uci set upnpd.config.enable_natpmp='1'
	uci commit upnpd
fi

# --- 配置 SoftEther VPN 防火墙 ---
if ! uci -q get firewall.softether > /dev/null; then
	uci set firewall.softether="rule"
	uci set firewall.softether.name="Allow-SoftEther"
	uci set firewall.softether.src="wan"
	uci add_list firewall.softether.dest_port="443"
	uci add_list firewall.softether.dest_port="992"
	uci add_list firewall.softether.dest_port="5555"
	uci add_list firewall.softether.dest_port="500"
	uci add_list firewall.softether.dest_port="4500"
	uci set firewall.softether.proto="tcp udp"
	uci set firewall.softether.target="ACCEPT"
	uci commit firewall
fi


uci set system.@system[0].custom_inited='1'
uci commit system

exit 0
EOF
chmod +x "$uci_dir/99-custom-settings"
