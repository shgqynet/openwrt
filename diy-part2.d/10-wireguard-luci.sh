#!/bin/bash
# 10-wireguard-luci.sh - WireGuard 客户端与 LuCI 相关配置

# --- WireGuard 客户端配置下载功能 ---
# 用户在 LuCI 页面输入 DDNS 域名，即可获得完整的客户端 .conf 文件和二维码
# 服务端公钥、客户端预共享密钥均在首次启动时自动生成并保存

# 1. 核心生成脚本：/bin/gen-wg-client <phone|pc> <domain>
mkdir -p package/base-files/files/bin
cat > package/base-files/files/bin/gen-wg-client << 'EOF'
#!/bin/sh
# 用法: gen-wg-client <phone|pc> <domain>
DEVICE="${1:-phone}"
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

. "$INFO_FILE"
SERVER_PUB="$(cat /etc/wireguard/server_public.key)"
PORT="$(uci -q get network.wg0.listen_port 2>/dev/null || echo 51820)"
DNS="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.3.1)"

if [ "$DEVICE" = "phone" ]; then
    CLIENT_IP="10.0.0.2/32"
    ALLOWED_IPS="0.0.0.0/0"
else
    CLIENT_IP="10.0.0.3/32"
    # 电脑节点：提取网关所在 C 段自适应下发路由表
    ROUTER_SUBNET="$(echo $DNS | cut -d'.' -f1,2,3).0/24"
    ALLOWED_IPS="${ROUTER_SUBNET}, 10.0.0.0/24"
fi

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

    local device = http.formvalue("device") or "phone"
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
.wg-card{background:#1e293b;border-radius:12px;padding:24px;margin-bottom:20px;color:#e2e8f0}
.wg-card h3{margin:0 0 16px;color:#7dd3fc;font-size:1.1em}
.wg-form label{display:block;margin-bottom:6px;font-size:.9em;color:#94a3b8}
.wg-form input,.wg-form select{width:100%;padding:10px 14px;border-radius:8px;
  border:1px solid #334155;background:#0f172a;color:#e2e8f0;font-size:.95em;box-sizing:border-box}
.wg-form input:focus,.wg-form select:focus{outline:none;border-color:#38bdf8}
.wg-btn{display:inline-block;padding:10px 22px;border-radius:8px;border:none;
  cursor:pointer;font-size:.95em;margin-right:10px;margin-top:12px}
.wg-btn-preview{background:#0ea5e9;color:#fff}
.wg-btn-dl{background:#10b981;color:#fff}
.wg-pre{background:#0f172a;border-radius:8px;padding:16px;font-family:monospace;
  font-size:.85em;white-space:pre;overflow-x:auto;color:#86efac;border:1px solid #1e3a4a}
.wg-qr{text-align:center;margin-top:16px}
.wg-qr svg{max-width:220px;height:auto;background:#fff;padding:10px;border-radius:8px}
.wg-tip{font-size:.83em;color:#64748b;margin-top:8px}
</style>
<h2><%-translate("WireGuard 客户端配置")%></h2>
<div class="wg-card">
  <h3>生成客户端配置</h3>
  <form method="post" class="wg-form">
    <div style="margin-bottom:14px">
      <label>设备类型</label>
      <select name="device">
        <option value="phone" <%=(device=="phone" and "selected" or "")%>>📱 手机（MyPhone - 10.0.0.2）</option>
        <option value="pc"    <%=(device=="pc"    and "selected" or "")%>>💻 电脑（MyPC - 10.0.0.3）</option>
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
  <p class="wg-tip">所有密钥均在首次开机时自动生成。您只需填写您的域名即可获得完整客户端配置。</p>
</div>
<% if conf_text and conf_text ~= "" then %>
<div class="wg-card">
  <h3>配置内容预览</h3>
  <div class="wg-pre"><%=conf_text%></div>
  <% if qr_svg and qr_svg ~= "" then %>
  <div class="wg-qr">
    <p style="color:#94a3b8;margin-bottom:8px">手机端扫码导入</p>
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
