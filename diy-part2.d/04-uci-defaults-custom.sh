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

# 允许 dnsmasq 响应来自 wg0（10.0.0.x）的 DNS 查询
# localservice=1 会拒绝非本地接口的查询，全流量代理模式下必须关闭
uci set dhcp.@dnsmasq[0].localservice='0'
uci commit dhcp


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
