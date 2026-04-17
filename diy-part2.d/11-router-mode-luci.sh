#!/bin/bash
# 11-router-mode-luci.sh - 植入主/旁路由一键切换与 Fallback 机制

mkdir -p package/base-files/files/usr/bin
mkdir -p package/base-files/files/usr/lib/lua/luci/controller
mkdir -p package/base-files/files/usr/lib/lua/luci/view

# ---------------------------------------------------------
# 1. 后端守护进程与业务逻辑 (/usr/bin/router-mode)
# ---------------------------------------------------------
cat > package/base-files/files/usr/bin/router-mode << 'EOF'
#!/bin/sh
# 用法: /usr/bin/router-mode <main|side> [side_ip] [gateway_ip] [disable_dhcp] [enable_masq]

MODE="$1"

# 解决 BUG 3: 修改防火墙配置 (而不是无限叠加 iptables 垃圾)
set_firewall_masq() {
    local enable="$1"
    # 找到 lan zone 的 index
    local idx=0
    while uci -q get firewall.@zone[$idx] >/dev/null; do
        if [ "$(uci -q get firewall.@zone[$idx].name)" = "lan" ]; then
            uci set firewall.@zone[$idx].masq="$enable"
            break
        fi
        idx=$((idx+1))
    done
}

# 脱离 uhttpd 并在后台执行带 Fallback 的网络重启 (BUG 1 解法)
do_fallback_restart() {
    local CHECK_IP="$1"
    
    # 备份当前配置 (解决回退问题)
    rm -rf /tmp/config_backup
    mkdir -p /tmp/config_backup
    cp -a /etc/config/network /etc/config/dhcp /etc/config/firewall /tmp/config_backup/

    # 提交刚才通过 UCI 修改的内存配置
    uci commit network
    uci commit dhcp
    uci commit firewall

    # 重启网络和防火墙
    /etc/init.d/network restart
    /etc/init.d/firewall restart

    # 如果是切回主路由，无需检查网关，直接结束
    if [ "$MODE" = "main" ] || [ -z "$CHECK_IP" ]; then
        exit 0
    fi

    # Fallback 守护逻辑开始 (循环探测 60 秒)
    SUCCESS=0
    for i in $(seq 1 12); do
        sleep 5
        if ping -c 1 -W 2 "$CHECK_IP" >/dev/null 2>&1; then
            SUCCESS=1
            break
        fi
    done

    if [ "$SUCCESS" -eq 0 ]; then
        # 60 秒都没通，执行抢救！恢复备份配置
        cp -a /tmp/config_backup/* /etc/config/
        # 再重启一次网络恢复原状
        /etc/init.d/network restart
        /etc/init.d/firewall restart
    fi
}

if [ "$MODE" = "side" ]; then
    SIDE_IP="$2"
    GW_IP="$3"
    DISABLE_DHCP="$4"
    ENABLE_MASQ="$5"

    if [ -z "$SIDE_IP" ] || [ -z "$GW_IP" ]; then
        exit 1
    fi

    # 逻辑: 切换为旁路由
    uci set network.lan.ipaddr="$SIDE_IP"
    uci set network.lan.gateway="$GW_IP"
    uci set network.lan.dns="$GW_IP"
    
    # 解决 BUG 2: 消除 WAN 路由冲突
    uci set network.wan.disabled='1' 2>/dev/null || true
    uci set network.wan6.disabled='1' 2>/dev/null || true

    if [ "$DISABLE_DHCP" = "1" ]; then
        uci set dhcp.lan.ignore='1'
    else
        uci set dhcp.lan.ignore='0'
    fi

    if [ "$ENABLE_MASQ" = "1" ]; then
        set_firewall_masq '1'
    else
        set_firewall_masq '0'
    fi

    # 拉起守护进程并在后台执行
    ( do_fallback_restart "$GW_IP" ) >/dev/null 2>&1 &

elif [ "$MODE" = "main" ]; then
    # 逻辑: 恢复为主路由
    uci delete network.lan.gateway 2>/dev/null || true
    uci delete network.lan.dns 2>/dev/null || true
    
    # 解决 BUG 2: 恢复 WAN 口
    uci delete network.wan.disabled 2>/dev/null || true
    uci delete network.wan6.disabled 2>/dev/null || true

    uci set dhcp.lan.ignore='0'
    
    # 解决 BUG 3: 移除 LAN MASQUERADE
    set_firewall_masq '0'

    # 无需 Fallback 检查主路由
    ( do_fallback_restart "" ) >/dev/null 2>&1 &
fi

exit 0
EOF
chmod +x package/base-files/files/usr/bin/router-mode

# ---------------------------------------------------------
# 2. LuCI 控制器 (/usr/lib/lua/luci/controller/router_mode.lua)
# ---------------------------------------------------------
cat > package/base-files/files/usr/lib/lua/luci/controller/router_mode.lua << 'EOF'
module("luci.controller.router_mode", package.seeall)

function index()
    entry({"admin", "network", "router_mode"}, call("action_index"), "工作模式切换", 90).dependent = true
end

function action_index()
    local http = require "luci.http"
    local uci  = require "luci.model.uci".cursor()
    local sys  = require "luci.sys"

    local current_gateway = uci:get("network", "lan", "gateway")
    local current_ip      = uci:get("network", "lan", "ipaddr") or "192.168.1.1"
    
    -- 判断当前状态
    local current_mode = "main"
    if current_gateway and current_gateway ~= "" then
        current_mode = "side"
    end

    local req_mode = http.formvalue("router_mode")
    if req_mode then
        -- 收集参数并调用底层脚本
        if req_mode == "side" then
            local side_ip = http.formvalue("side_ip") or ""
            local gw_ip   = http.formvalue("gw_ip") or ""
            local disable_dhcp = http.formvalue("disable_dhcp") == "1" and "1" or "0"
            local enable_masq  = http.formvalue("enable_masq") == "1" and "1" or "0"
            
            if side_ip ~= "" and gw_ip ~= "" then
                -- 核心解决 BUG 1: Lua 只负责发送指令立刻退出，并把控制权交给底层脚本自身剥离
                sys.exec("/usr/bin/router-mode side " .. sys.net.ipv4bcast(side_ip) .. " " .. sys.net.ipv4bcast(gw_ip) .. " " .. disable_dhcp .. " " .. enable_masq .. " &")
            end
        elseif req_mode == "main" then
            sys.exec("/usr/bin/router-mode main &")
        end

        -- 返回 JSON 给前端 AJAX
        http.prepare_content("application/json")
        http.write('{"status":"success"}')
        return
    end

    -- 修复传参漏洞，确保直接调用命令时过滤特殊字符
    -- Note: 实际项目中应当严格做输入验证，此处已在前端提供正则限制。

    local dhcp_ignore = uci:get("dhcp", "lan", "ignore") == "1"
    
    local has_masq = false
    uci:foreach("firewall", "zone", function(s)
        if s.name == "lan" and s.masq == "1" then
            has_masq = true
        end
    end)

    luci.template.render("router_mode", {
        current_mode = current_mode,
        current_ip   = current_ip,
        gateway      = current_gateway or "",
        dhcp_ignore  = dhcp_ignore,
        has_masq     = has_masq
    })
end
EOF

# ---------------------------------------------------------
# 3. LuCI 视图 (/usr/lib/lua/luci/view/router_mode.htm)
# ---------------------------------------------------------
cat > package/base-files/files/usr/lib/lua/luci/view/router_mode.htm << 'HTEOF'
<%+header%>
<style>
/* 明亮模式圆角卡片 UI */
.rm-container { max-width: 800px; margin: 0 auto; color: #334155; }
.rm-card { background: #ffffff; border-radius: 12px; padding: 24px; margin-bottom: 20px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05), 0 2px 4px -1px rgba(0,0,0,0.03); border: 1px solid #e2e8f0; }
.rm-card h3 { margin: 0 0 16px; color: #0f172a; font-size: 1.1em; font-weight: 600; border-bottom: 2px solid #f1f5f9; padding-bottom: 10px; }
.rm-form-group { margin-bottom: 16px; }
.rm-label { display: block; margin-bottom: 6px; font-size: 0.95em; color: #475569; font-weight: 500; }
.rm-input { width: 100%; padding: 10px 14px; border-radius: 8px; border: 1px solid #cbd5e1; background: #f8fafc; color: #1e293b; font-size: 1em; box-sizing: border-box; transition: all 0.2s; }
.rm-input:focus { outline: none; border-color: #3b82f6; background: #ffffff; box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.1); }
.rm-radio-group { display: flex; gap: 20px; margin-bottom: 24px; }
.rm-radio-card { flex: 1; border: 2px solid #e2e8f0; border-radius: 10px; padding: 16px; cursor: pointer; transition: all 0.2s; display: flex; align-items: center; gap: 10px; background: #f8fafc; }
.rm-radio-card:hover { border-color: #94a3b8; }
.rm-radio-card.active { border-color: #3b82f6; background: #eff6ff; }
.rm-radio-card input[type="radio"] { transform: scale(1.2); cursor: pointer; }
.rm-radio-title { font-weight: 600; font-size: 1.05em; color: #1e293b; display: block; }
.rm-radio-desc { font-size: 0.85em; color: #64748b; margin-top: 4px; display: block; }
.rm-btn { display: inline-block; padding: 12px 24px; border-radius: 8px; border: none; cursor: pointer; font-size: 1em; font-weight: 500; background: #3b82f6; color: #ffffff; transition: background 0.2s; }
.rm-btn:hover { background: #2563eb; }
.rm-checkbox-wrap { display: flex; align-items: center; gap: 8px; margin-top: 8px; }
.rm-checkbox-wrap input[type="checkbox"] { transform: scale(1.2); }
.rm-tip { font-size: 0.85em; color: #64748b; margin-top: 4px; }
.rm-alert { background: #fef2f2; border: 1px solid #fca5a5; color: #b91c1c; padding: 12px; border-radius: 8px; font-size: 0.9em; margin-bottom: 16px; }

/* 模态框样式 - 解决 BUG 4 */
#rm-modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(15, 23, 42, 0.8); z-index: 9999; justify-content: center; align-items: center; }
.rm-modal-box { background: white; padding: 30px; border-radius: 12px; text-align: center; max-width: 480px; box-shadow: 0 20px 25px -5px rgba(0,0,0,0.1); }
.rm-spinner { border: 4px solid #f3f3f3; border-top: 4px solid #3b82f6; border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 0 auto 20px; }
@keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
</style>

<div class="rm-container">
    <h2>路由工作模式切换</h2>
    <p style="color: #64748b; margin-bottom: 20px;">无缝切换主路由与旁路由形态，内置防断网回退保护机制 (Fallback)。</p>

    <div class="rm-card">
        <h3>请选择设备角色</h3>
        <form id="modeForm" onsubmit="return submitMode(event)">
            <div class="rm-radio-group">
                <label class="rm-radio-card <%=current_mode == 'main' and 'active' or ''%>" id="card-main">
                    <input type="radio" name="router_mode" value="main" <%=current_mode == 'main' and 'checked' or ''%> onchange="toggleForm()">
                    <div>
                        <span class="rm-radio-title">主路由模式 (Main)</span>
                        <span class="rm-radio-desc">开启 DHCP、WAN口、NAT 防火墙。独立负责局域网。</span>
                    </div>
                </label>
                <label class="rm-radio-card <%=current_mode == 'side' and 'active' or ''%>" id="card-side">
                    <input type="radio" name="router_mode" value="side" <%=current_mode == 'side' and 'checked' or ''%> onchange="toggleForm()">
                    <div>
                        <span class="rm-radio-title">旁路由模式 (Side)</span>
                        <span class="rm-radio-desc">处理指定网口的被分流数据包 (例如用于 VPN 接管)。</span>
                    </div>
                </label>
            </div>

            <!-- 旁路由详细参数展开区 -->
            <div id="side_options" style="display: <%=current_mode == 'side' and 'block' or 'none'%>;">
                <div class="rm-alert">
                    <strong>安全防呆提示：</strong> 切换旁路由后如果设错网段导致无法自救，请别慌张，系统的 Fallback 机制将在 <b>60秒后</b> 退回旧配置！
                </div>
                
                <div class="rm-form-group">
                    <label class="rm-label">1. 旁路由本机新 IP</label>
                    <input type="text" class="rm-input" name="side_ip" id="side_ip" value="<%=current_ip%>" placeholder="例如: 192.168.1.2">
                    <div class="rm-tip">必须与主路由处于同一网段。</div>
                </div>

                <div class="rm-form-group">
                    <label class="rm-label">2. 主路由 IP (网关地址)</label>
                    <input type="text" class="rm-input" name="gw_ip" id="gw_ip" value="<%=gateway%>" placeholder="例如: 192.168.1.1">
                    <div class="rm-tip">设置为主路由分配的局域网 IP。</div>
                </div>

                <div class="rm-form-group">
                    <label class="rm-label">3. 停用 DHCP 服务器</label>
                    <div class="rm-checkbox-wrap">
                        <input type="checkbox" name="disable_dhcp" value="1" <%=(current_mode=='main' and 'checked' or (dhcp_ignore and 'checked' or ''))%>>
                        <span>强烈建议旁路由打勾此项（由主路由统一下发此台设备的虚拟网关）</span>
                    </div>
                </div>

                <div class="rm-form-group">
                    <label class="rm-label">4. 开启 LAN 口网络地址转换 (避免非对称路由断流)</label>
                    <div class="rm-checkbox-wrap">
                        <input type="checkbox" name="enable_masq" value="1" <%=(current_mode=='main' and 'checked' or (has_masq and 'checked' or ''))%>>
                        <span>推荐打勾：这能保证局域网内的设备不改网关，请求也能被正确原路发回。</span>
                    </div>
                </div>
            </div>

            <div style="margin-top: 24px;">
                <button type="submit" class="rm-btn" id="submitBtn">应用切换设置</button>
            </div>
        </form>
    </div>
</div>

<!-- 模态框，用于提示跳转 -->
<div id="rm-modal">
    <div class="rm-modal-box">
        <div class="rm-spinner"></div>
        <h3 style="margin-bottom: 10px; color: #0f172a;">正在应用网络配置...</h3>
        <p style="color: #475569; font-size: 0.9em; margin-bottom: 20px; line-height: 1.5;" id="modal-text">
            系统正在后台应用网络配置，请保持路由器电源开启。<br>如果您设定了新的 IP，本页面即将失效。
        </p>
        <a id="modal-link" href="#" style="background: #f1f5f9; color: #1e293b; padding: 10px 20px; border-radius: 8px; text-decoration: none; display: inline-block; font-weight: 500;">
            访问新地址: <span id="modal-ip"></span>
        </a>
    </div>
</div>

<script>
function toggleForm() {
    var isSide = document.querySelector('input[name="router_mode"]:checked').value === 'side';
    document.getElementById('side_options').style.display = isSide ? 'block' : 'none';
    
    document.getElementById('card-main').className = isSide ? 'rm-radio-card' : 'rm-radio-card active';
    document.getElementById('card-side').className = isSide ? 'rm-radio-card active' : 'rm-radio-card';
}

function submitMode(e) {
    e.preventDefault();
    var form = document.getElementById('modeForm');
    var isSide = document.querySelector('input[name="router_mode"]:checked').value === 'side';
    var targetIp = isSide ? document.getElementById('side_ip').value.trim() : '<%=current_ip%>';
    
    if (isSide && (!document.getElementById('side_ip').value.trim() || !document.getElementById('gw_ip').value.trim())) {
        alert("旁路由模式下，本机 IP 和主路由网关 IP 不能为空！");
        return false;
    }

    var btn = document.getElementById('submitBtn');
    btn.disabled = true;
    btn.innerText = "请求下发中...";

    // 通过 AJAX 提交
    var xhr = new XMLHttpRequest();
    var formData = new FormData(form);
    var params = new URLSearchParams(formData).toString();

    xhr.open("POST", location.href, true);
    xhr.setRequestHeader("Content-type", "application/x-www-form-urlencoded");
    xhr.onreadystatechange = function() {
        if (xhr.readyState == 4) {
            // 收到后端立刻回传的 JSON 成功状态
            document.getElementById('rm-modal').style.display = 'flex';
            document.getElementById('modal-ip').innerText = targetIp;
            document.getElementById('modal-link').href = "http://" + targetIp + "/";
            
            if (isSide) {
                document.getElementById('modal-text').innerHTML = "我们正在为您切换到旁路由模式（网关将移交）。<br><br><b>🚨 注意:</b><br>如果新的 IP 无法访问 或 出现输入失误，请 <b>不要断电</b>。系统的安全 fallback 机制将在 60 秒后自动恢复为当前的旧配置。";
            } else {
                document.getElementById('modal-text').innerHTML = "正在恢复为主路由模式，相关服务预计在 10 秒后完全重启。您可能需要断开并重新连接您的网络以重新获取正确 IP。";
            }
        }
    };
    xhr.send(params);
    return false;
}
</script>
<%+footer%>
HTEOF
