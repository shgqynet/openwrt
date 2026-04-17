#!/bin/bash
# 01-packages.sh - 处理本地依赖与第三方包配置

# 集成本地源码插件（源码已放入仓库 packages/ 目录，无需依赖第三方且防止访问失败）
# 直接从本工作区复制到 OpenWrt 的 package 编译目录
cp -r "$GITHUB_WORKSPACE/packages/luci-app-autoupdate" package/luci-app-autoupdate
cp -r "$GITHUB_WORKSPACE/packages/luci-app-aliddns" package/luci-app-aliddns
cp -r "$GITHUB_WORKSPACE/packages/luci-app-argon-config" package/luci-app-argon-config

# 预置 OpenClash 内核（避免首次安装系统后因无代理导致无法下载内核的死锁问题）
CORE_DIR="package/base-files/files/etc/openclash/core"
mkdir -p "$CORE_DIR"

if curl -sL --connect-timeout 60 \
    https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz \
    | tar xzvC "$CORE_DIR" -f -; then
    mv "$CORE_DIR/clash" "$CORE_DIR/clash_meta" 2>/dev/null || true
    chmod +x "$CORE_DIR/clash_meta"
fi

# 强制写入 qrencode 软件包，用于 WireGuard 的配置二维码显示
echo "CONFIG_PACKAGE_qrencode=y" >> .config

# 强制写入核心加密组件与第三方依赖包
echo "CONFIG_PACKAGE_openssl-util=y" >> .config
echo "CONFIG_PACKAGE_wireguard-tools=y" >> .config
echo "CONFIG_PACKAGE_kmod-wireguard=y" >> .config
echo "CONFIG_PACKAGE_luci-proto-wireguard=y" >> .config
echo "CONFIG_PACKAGE_luci-app-wireguard=y" >> .config
echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config
echo "CONFIG_PACKAGE_luci-app-upnp=y" >> .config
echo "CONFIG_PACKAGE_kmod-tun=y" >> .config
echo "CONFIG_PACKAGE_zerotier=y" >> .config
echo "CONFIG_PACKAGE_luci-app-zerotier=y" >> .config
echo "CONFIG_PACKAGE_softethervpn5-server=y" >> .config
echo "CONFIG_PACKAGE_softethervpn5-bridge=y" >> .config
echo "CONFIG_PACKAGE_softethervpn5-client=y" >> .config
echo "CONFIG_PACKAGE_luci-app-softethervpn=y" >> .config
