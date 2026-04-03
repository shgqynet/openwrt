#!/bin/bash
#
# diy-part2.sh - 在 install feeds 之后执行
# 用途：修改默认配置，预置自定义设置
#

# 1. 修改默认 LAN IP（避免与常见家用路由器冲突）
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

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

exit 0
EOF
chmod +x "$uci_dir/99-custom-settings"

# 6. 预置 OpenClash 内核（极致优化体验）
# 避免首次安装系统后因无代理导致无法从 GitHub 下载内核的死锁问题（鸡和蛋的问题）
CORE_DIR="package/base-files/files/etc/openclash/core"
mkdir -p "$CORE_DIR"

echo "Downloading OpenClash cores..."
# 下载 Dev 内核
curl -sL https://raw.githubusercontent.com/vernesong/OpenClash/core/master/dev/clash-linux-amd64.tar.gz | tar xzvC "$CORE_DIR"
chmod +x "$CORE_DIR/clash"

# 下载 Meta 内核
curl -sL https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz | tar xzvC "$CORE_DIR"
mv "$CORE_DIR/clash" "$CORE_DIR/clash_meta"
chmod +x "$CORE_DIR/clash_meta"
echo "OpenClash cores downloaded successfully!"
