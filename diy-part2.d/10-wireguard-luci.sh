#!/bin/bash
# 10-wireguard-luci.sh - WireGuard 客户端与 LuCI 相关配置

# ---------------------------------------------------------
# 0. 首次开机初始化脚本 (/etc/uci-defaults/98-wireguard-init)
#    服务端 wg0：单次初始化（幂等保护密钥）
#    Peer 节点：每个节点独立检查，升级后只补全缺失节点（解决扩容不生效问题）
#    防火墙规则：单次初始化（幂等）
# ---------------------------------------------------------
_wg_uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$_wg_uci_dir"

cat > "$_wg_uci_dir/98-wireguard-init" << 'WGINIT'
#!/bin/sh

# 1. 服务端（wg0）：全新安装时初始化，升级保留配置时跳过（保护服务端密钥不变）
if ! uci -q get network.wg0 > /dev/null; then
	WG_SERVER_PRIV="$(wg genkey)"
	WG_SERVER_PUB="$(echo "$WG_SERVER_PRIV" | wg pubkey)"

	uci set network.wg0="interface"
	uci set network.wg0.proto="wireguard"
	uci set network.wg0.private_key="$WG_SERVER_PRIV"
	uci set network.wg0.listen_port="51820"
	uci set network.wg0.mtu="1420"
	uci add_list network.wg0.addresses="10.0.0.1/24"
	uci commit network

	mkdir -p /etc/wireguard
	echo "$WG_SERVER_PUB" > /etc/wireguard/server_public.key
	chmod 644 /etc/wireguard/server_public.key
fi

# 2. 客户端 Peer：幂等补全——每个节点单独检查，只生成缺失的
#    phone1-6 → 10.0.0.2-7，pc1-6 → 10.0.0.8-13，全部走全流量代理
#    固件升级后若新增节点，下次开机时会自动补全，已有节点密钥不变
mkdir -p /etc/wireguard
_wg_changed=0
for _i in 1 2 3 4 5 6; do
	if ! uci -q get network.wg_phone${_i} > /dev/null; then
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
		_wg_changed=1
	fi
	if ! uci -q get network.wg_pc${_i} > /dev/null; then
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
		_wg_changed=1
	fi
done
[ "$_wg_changed" = "1" ] && uci commit network
chmod 600 /etc/wireguard/*.info 2>/dev/null || true

# 3. 防火墙：只在未配置时初始化（幂等）
if ! uci -q get firewall.wg > /dev/null; then
	uci set firewall.wg="zone"
	uci set firewall.wg.name="wireguard"
	uci set firewall.wg.input="ACCEPT"
	uci set firewall.wg.output="ACCEPT"
	uci set firewall.wg.forward="ACCEPT"
	uci add_list firewall.wg.network="wg0"

	# 放行 51820 UDP 端口（不限来源 zone，主路由从 wan 进、旁路由从 lan 进均可握手）
	uci set firewall.wg_rule="rule"
	uci set firewall.wg_rule.name="Allow-WireGuard"
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

	# 允许 wg 节点访问外网（wan zone 自带 masq='1'，转发到此即自动 SNAT，无需额外规则）
	uci set firewall.wg_wan_forward="forwarding"
	uci set firewall.wg_wan_forward.src="wireguard"
	uci set firewall.wg_wan_forward.dest="wan"

	uci commit firewall
fi

exit 0
WGINIT
chmod +x "$_wg_uci_dir/98-wireguard-init"

# --- WireGuard 客户端配置下载功能 ---
# 用户在 LuCI 页面输入 DDNS 域名，即可获得完整的客户端 .conf 文件和二维码
# 服务端公钥、客户端预共享密钥均在首次启动时自动生成并保存

# 1. 核心生成脚本：/bin/gen-wg-client <phone|pc> <domain>
mkdir -p package/base-files/files/bin
cat > package/base-files/files/bin/gen-wg-client << 'EOF'
#!/bin/sh
# 用法: gen-wg-client <phone1-6|pc1-6> <domain>
# IP 分配: phone1-6 → 10.0.0.2-7，pc1-6 → 10.0.0.8-13，全部走全流量代理
DEVICE="${1:-phone1}"
DOMAIN="${2:-your-domain.example.com}"

INFO_FILE="/etc/wireguard/${DEVICE}.info"

if [ ! -f "$INFO_FILE" ]; then
    echo "Error: device info not found: $INFO_FILE" >&2
    echo "System may not have completed first-boot initialization yet." >&2
    exit 1
fi
if [ ! -f "/etc/wireguard/server_public.key" ]; then
    echo "Error: server public key not found." >&2
    exit 1
fi

# IP 映射表（与首次开机初始化脚本保持一致）
case "$DEVICE" in
    phone1) CLIENT_IP="10.0.0.2/32" ;;
    phone2) CLIENT_IP="10.0.0.3/32" ;;
    phone3) CLIENT_IP="10.0.0.4/32" ;;
    phone4) CLIENT_IP="10.0.0.5/32" ;;
    phone5) CLIENT_IP="10.0.0.6/32" ;;
    phone6) CLIENT_IP="10.0.0.7/32" ;;
    pc1)    CLIENT_IP="10.0.0.8/32" ;;
    pc2)    CLIENT_IP="10.0.0.9/32" ;;
    pc3)    CLIENT_IP="10.0.0.10/32" ;;
    pc4)    CLIENT_IP="10.0.0.11/32" ;;
    pc5)    CLIENT_IP="10.0.0.12/32" ;;
    pc6)    CLIENT_IP="10.0.0.13/32" ;;
    *)      echo "Error: unknown device '$DEVICE'" >&2; exit 1 ;;
esac

. "$INFO_FILE"
SERVER_PUB="$(cat /etc/wireguard/server_public.key)"
PORT="$(uci -q get network.wg0.listen_port 2>/dev/null || echo 51820)"
DNS="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.3.1)"

# 所有设备统一走全流量代理（手机与 PC 行为一致）
ALLOWED_IPS="0.0.0.0/0, ::/0"

printf '[Interface]\n'
printf 'PrivateKey = %s\n' "$PRIV_KEY"
printf 'Address = %s\n' "$CLIENT_IP"
printf 'DNS = %s\n' "$DNS"
printf '\n'
printf '[Peer]\n'
printf 'PublicKey = %s\n' "$SERVER_PUB"
printf 'PresharedKey = %s\n' "$PSK"
printf 'AllowedIPs = %s\n' "$ALLOWED_IPS"
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

    local device = http.formvalue("device") or "phone1"
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
            -- 生成 SVG 二维码（qrencode -o - 直接输出到 stdout，避免写磁盘开销）
            local safe_cmd2 = "/bin/gen-wg-client " .. util.shellquote(device) .. " " .. util.shellquote(domain) .. " 2>/dev/null | qrencode -t SVG -o -"
            local f = io.popen(safe_cmd2, "r")
            if f then
                qr_b64 = f:read("*a")
                f:close()
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
.wg-card{background:#ffffff;border-radius:12px;padding:24px;margin-bottom:20px;color:#1e293b;box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05), 0 2px 4px -1px rgba(0,0,0,0.03);border:1px solid #e2e8f0}
.wg-card h3{margin:0 0 16px;color:#0f172a;font-size:1.1em;border-bottom:2px solid #f1f5f9;padding-bottom:10px;font-weight:600}
.wg-form label{display:block;margin-bottom:6px;font-size:.95em;color:#475569;font-weight:500}
.wg-form input,.wg-form select{width:100%;padding:10px 14px;border-radius:8px;
  border:1px solid #cbd5e1;background:#f8fafc;color:#1e293b;font-size:.95em;box-sizing:border-box;transition:all 0.2s}
.wg-form input:focus,.wg-form select:focus{outline:none;border-color:#3b82f6;background:#ffffff;box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.1)}
.wg-btn{display:inline-block;padding:12px 22px;border-radius:8px;border:none;
  cursor:pointer;font-size:.95em;font-weight:500;margin-right:10px;margin-top:12px;transition:background 0.2s}
.wg-btn-preview{background:#3b82f6;color:#fff}
.wg-btn-dl{background:#10b981;color:#fff}
.wg-btn-preview:hover{background:#2563eb}
.wg-btn-dl:hover{background:#059669}
.wg-pre{background:#f8fafc;border-radius:8px;padding:16px;font-family:monospace;
  font-size:.85em;white-space:pre;overflow-x:auto;color:#1e293b;border:1px solid #e2e8f0}
.wg-qr{text-align:center;margin-top:16px}
.wg-qr svg{max-width:220px;height:auto;background:#fff;padding:10px;border-radius:8px;border:1px solid #e2e8f0}
.wg-tip{font-size:.85em;color:#64748b;margin-top:8px}
</style>
<h2><%-translate("WireGuard 客户端配置")%></h2>
<div class="wg-card">
  <h3>生成客户端配置</h3>
  <form method="post" class="wg-form">
    <div style="margin-bottom:14px">
      <label>设备类型</label>
      <select name="device">
        <optgroup label="📱 手机（全流量代理）">
          <option value="phone1" <%=(device=="phone1" and "selected" or "")%>>Phone 1 · 10.0.0.2</option>
          <option value="phone2" <%=(device=="phone2" and "selected" or "")%>>Phone 2 · 10.0.0.3</option>
          <option value="phone3" <%=(device=="phone3" and "selected" or "")%>>Phone 3 · 10.0.0.4</option>
          <option value="phone4" <%=(device=="phone4" and "selected" or "")%>>Phone 4 · 10.0.0.5</option>
          <option value="phone5" <%=(device=="phone5" and "selected" or "")%>>Phone 5 · 10.0.0.6</option>
          <option value="phone6" <%=(device=="phone6" and "selected" or "")%>>Phone 6 · 10.0.0.7</option>
        </optgroup>
        <optgroup label="💻 电脑（全流量代理）">
          <option value="pc1" <%=(device=="pc1" and "selected" or "")%>>PC 1 · 10.0.0.8</option>
          <option value="pc2" <%=(device=="pc2" and "selected" or "")%>>PC 2 · 10.0.0.9</option>
          <option value="pc3" <%=(device=="pc3" and "selected" or "")%>>PC 3 · 10.0.0.10</option>
          <option value="pc4" <%=(device=="pc4" and "selected" or "")%>>PC 4 · 10.0.0.11</option>
          <option value="pc5" <%=(device=="pc5" and "selected" or "")%>>PC 5 · 10.0.0.12</option>
          <option value="pc6" <%=(device=="pc6" and "selected" or "")%>>PC 6 · 10.0.0.13</option>
        </optgroup>
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
  <p class="wg-tip">共 12 个节点（Phone 1-6 · PC 1-6），密钥在首次开机时自动生成，手机与 PC 均走全流量代理（AllowedIPs = 0.0.0.0/0）。</p>
</div>
<% if conf_text and conf_text ~= "" then %>
<div class="wg-card">
  <h3>配置内容预览</h3>
  <div class="wg-pre"><%=conf_text%></div>
  <% if qr_svg and qr_svg ~= "" then %>
  <div class="wg-qr">
    <p style="color:#94a3b8;margin-bottom:8px">扫码导入配置</p>
    <%=qr_svg%>
  </div>
  <% end %>
</div>
<% end %>
<%+footer%>
HTEOF

# 9. 修复“保留配置”升级时保留证书目录的问题
# 将 WireGuard 的配置和证书目录加入系统升级的白名单中（保留配置升级时不会被清除）
KEEP_D_DIR="package/base-files/files/lib/upgrade/keep.d"
mkdir -p "$KEEP_D_DIR"
echo "/etc/wireguard/" > "$KEEP_D_DIR/vpn-custom"
