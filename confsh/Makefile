# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

PKG_NAME:=confsh
PKG_VERSION:=0.3.0
PKG_RELEASE:=1

PKG_MAINTAINER:=halcycon <adam@thecuckoocamp.co.uk>
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/confsh
  SECTION:=utils
  CATEGORY:=Utilities
  SUBMENU:=Shells
  TITLE:=EdgeOS/Vyatta-style configuration shell for UCI
  URL:=https://github.com/halcycon/confsh
  DEPENDS:=+bash +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus
  PKGARCH:=all
endef

define Package/confsh/description
  An optional EdgeOS/Vyatta-style front end for UCI: configure, set,
  delete, edit, show, compare, commit, commit-confirm, rollback and
  operational "show" commands with tab completion. UCI stays the single
  source of truth, so LuCI and uci keep working alongside it.
endef

define Package/confsh/conffiles
/etc/config/confsh
endef

define Build/Compile
endef

define Package/confsh/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,confsh))
