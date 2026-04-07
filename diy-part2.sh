#!/bin/bash
#
# diy-part2.sh - 在 install feeds 之后执行
# 用途：修改默认配置，预置自定义设置
#

# 1. 修改默认 LAN IP 为你习惯的网段 (3.1)
sed -i 's/192.168.1.1/192.168.3.1/g' package/base-files/files/bin/config_generate

# 2. 修改默认主机名
sed -i 's/OpenWrt/MyOpenWrt/g' package/base-files/files/bin/config_generate

# 3. 启用 BBR TCP 拥塞控制 + FQ 队列调度（x86 内核 >= 4.9 均支持）
mkdir -p package/base-files/files/etc/sysctl.d
cat > package/base-files/files/etc/sysctl.d/10-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

# 4. 提高系统连接数上限（适合高负载 x86 路由场景）
cat > package/base-files/files/etc/sysctl.d/11-conntrack.conf << 'EOF'
net.netfilter.nf_conntrack_max=131072
net.nf_conntrack_max=131072
EOF

# 5. 预置开机 uci-defaults 脚本（首次启动自动执行，执行后自动删除）
uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"

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

# --- 自动配置 WireGuard 基础环境接口与防火墙 ---
# 判断 wg0 接口是否存在，防止系统升级保留配置时覆盖原有密钥等数据
if ! uci -q get network.wg0 > /dev/null; then
	# 1. 自动生成服务端和客户端专属密钥
	WG_SERVER_PRIV="$(wg genkey)"
	WG_CLIENT_PRIV="$(wg genkey)"
	WG_CLIENT_PUB="$(echo $WG_CLIENT_PRIV | wg pubkey)"
	WG_PC_PRIV="$(wg genkey)"
	WG_PC_PUB="$(echo $WG_PC_PRIV | wg pubkey)"

	# 2. 建立 wg0 接口，自动注入服务端私钥
	uci set network.wg0="interface"
	uci set network.wg0.proto="wireguard"
	uci set network.wg0.private_key="$WG_SERVER_PRIV"
	uci set network.wg0.listen_port="51820"
	uci add_list network.wg0.addresses="10.0.0.1/24"

	# 3. 自动建立名为 MyPhone 的预设手机节点（分配 10.0.0.2 IP）
	uci set network.wg_client_phone="wireguard_wg0"
	uci set network.wg_client_phone.description="MyPhone"
	uci set network.wg_client_phone.public_key="$WG_CLIENT_PUB"
	uci set network.wg_client_phone.private_key="$WG_CLIENT_PRIV"
	uci set network.wg_client_phone.route_allowed_ips="1"
	uci set network.wg_client_phone.endpoint_port="51820"
	uci set network.wg_client_phone.persistent_keepalive="25"
	uci add_list network.wg_client_phone.allowed_ips="10.0.0.2/32"

	# 4. 自动建立名为 MyPC 的预设电脑节点（分配 10.0.0.3 IP）
	uci set network.wg_client_pc="wireguard_wg0"
	uci set network.wg_client_pc.description="MyPC"
	uci set network.wg_client_pc.public_key="$WG_PC_PUB"
	uci set network.wg_client_pc.private_key="$WG_PC_PRIV"
	uci set network.wg_client_pc.route_allowed_ips="1"
	uci set network.wg_client_pc.endpoint_port="51820"
	uci set network.wg_client_pc.persistent_keepalive="25"
	uci add_list network.wg_client_pc.allowed_ips="10.0.0.3/32"
	uci commit network
fi

if ! uci -q get firewall.wg > /dev/null; then
	# 5. 建立 WireGuard 防火墙区域并放行端口
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
	uci commit firewall
fi

exit 0
EOF
chmod +x "$uci_dir/99-custom-settings"

# 6. 预置 OpenClash 内核（极致优化体验）
# 避免首次安装系统后因无代理导致无法从 GitHub 下载内核的死锁问题（鸡和蛋的问题）
CORE_DIR="package/base-files/files/etc/openclash/core"
mkdir -p "$CORE_DIR"

echo "Downloading OpenClash cores..."

# 下载 Meta 内核 (目前只用 Meta 内核即可，Dev 内核仓库路径已失效)
curl -sL https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz | tar xzvC "$CORE_DIR"
mv "$CORE_DIR/clash" "$CORE_DIR/clash_meta"
chmod +x "$CORE_DIR/clash_meta"
echo "OpenClash cores downloaded successfully!"

# 7. 强制写入 qrencode 软件包，用于 WireGuard 的配置二维码显示
echo "CONFIG_PACKAGE_qrencode=y" >> .config

