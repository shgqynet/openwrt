#
# luci-app-autoupdate - OpenWrt 固件云端自动更新插件
# 自主编写，无需依赖第三方仓库
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-autoupdate
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-autoupdate
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI - 固件云端自动更新
  DEPENDS:=+curl +ca-bundle +jsonfilter
  PKGARCH:=all
endef

define Package/luci-app-autoupdate/description
  通过 GitHub Releases 对比版本号，一键下载、校验并 sysupgrade 升级固件。
  支持保留配置、SHA256 校验、ghproxy 镜像加速。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/luci-app-autoupdate/install
	# LuCI 控制器
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/autoupdate.lua \
		$(1)/usr/lib/lua/luci/controller/

	# LuCI 视图模板
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/autoupdate
	$(INSTALL_DATA) ./luasrc/view/autoupdate/index.htm \
		$(1)/usr/lib/lua/luci/view/autoupdate/

	# 核心更新脚本
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/autoupdate $(1)/usr/bin/

	# 默认 UCI 配置
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/autoupdate $(1)/etc/config/
endef

$(eval $(call BuildPackage,luci-app-autoupdate))
