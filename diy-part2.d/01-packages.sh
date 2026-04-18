#!/bin/bash
# 01-packages.sh - 处理本地依赖与第三方包配置

# 集成本地源码插件
echo "[Packages] Preparing custom local packages..."
for pkg in luci-app-autoupdate luci-app-aliddns luci-app-argon-config; do
    if [ -d "$GITHUB_WORKSPACE/packages/$pkg" ]; then
        cp -r "$GITHUB_WORKSPACE/packages/$pkg" "package/$pkg"
        echo "  -> Copied local package: $pkg"
    else
        echo "  -> Warning: Local package directory not found: packages/$pkg"
    fi
done

# 预置 OpenClash 内核（避免首次安装系统后因无代理导致无法下载内核的死锁问题）
echo "[Packages] Pre-downloading OpenClash core..."
CORE_DIR="package/base-files/files/etc/openclash/core"
mkdir -p "$CORE_DIR"

if curl -sL --connect-timeout 60 \
    https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz \
    | tar xzvC "$CORE_DIR" -f -; then
    mv "$CORE_DIR/clash" "$CORE_DIR/clash_meta" 2>/dev/null || true
    chmod +x "$CORE_DIR/clash_meta"
    echo "  -> OpenClash core downloaded and extracted successfully."
else
    echo "  -> Warning: Failed to download OpenClash core. It will be downloaded on first run."
fi

# 强制写入 qrencode 软件包，用于 WireGuard 的配置二维码显示
echo "CONFIG_PACKAGE_qrencode=y" >> .config

# 强制写入核心加密组件与第三方依赖包
echo "CONFIG_PACKAGE_openssl-util=y" >> .config
echo "CONFIG_PACKAGE_wireguard-tools=y" >> .config
echo "CONFIG_PACKAGE_kmod-wireguard=y" >> .config
echo "CONFIG_PACKAGE_luci-proto-wireguard=y" >> .config
echo "CONFIG_PACKAGE_luci-app-wireguard=y" >> .config
echo "CONFIG_PACKAGE_luci-app-upnp=y" >> .config
echo "CONFIG_PACKAGE_kmod-tun=y" >> .config
echo "CONFIG_PACKAGE_zerotier=y" >> .config
echo "CONFIG_PACKAGE_luci-app-zerotier=y" >> .config
echo "CONFIG_PACKAGE_softethervpn5-server=y" >> .config
echo "CONFIG_PACKAGE_softethervpn5-bridge=y" >> .config
echo "CONFIG_PACKAGE_softethervpn5-client=y" >> .config
echo "CONFIG_PACKAGE_luci-app-softethervpn=y" >> .config
