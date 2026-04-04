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

# ==================== 注入你的个人网络架构 ====================
# 1. 恢复 LAN 的多物理网口桥接 (eth0 到 eth3全归属为内网口)
uci set network.@device[0].name='br-lan'
uci set network.@device[0].type='bridge'
uci -q delete network.@device[0].ports
uci add_list network.@device[0].ports='eth0'
uci add_list network.@device[0].ports='eth1'
uci add_list network.@device[0].ports='eth2'
uci add_list network.@device[0].ports='eth3'

# 2. 恢复 LAN 的多网段 IP 设定 (支持 192.168.3.1 和 192.168.2.1)
uci set network.lan.device='br-lan'
uci -q delete network.lan.ipaddr
uci -q delete network.lan.netmask
uci add_list network.lan.ipaddr='192.168.3.1/24'
uci add_list network.lan.ipaddr='192.168.2.1/24'

# 3. 恢复 WAN 物理网口位置 (强制绑定在外网线插入的 eth4 口)
# 并预设为 PPPoE 拨号模式 (账号密码留空，保证核心隐私安全)
uci set network.wan.device='eth4'
uci set network.wan.proto='pppoe'
uci -q delete network.wan.username
uci -q delete network.wan.password

uci commit network
# ============================================================

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
