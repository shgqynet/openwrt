module("luci.controller.autoupdate", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/autoupdate") then
        return
    end

    -- 挂载到"系统"菜单下
    local e = entry(
        {"admin", "system", "autoupdate"},
        call("action_index"),
        _("固件自动更新"), 80
    )
    e.dependent = false

    -- Ajax 接口（leaf = true 表示不再展示子菜单）
    entry({"admin", "system", "autoupdate", "check"},
          call("action_check"), nil).leaf = true

    entry({"admin", "system", "autoupdate", "download"},
          call("action_download"), nil).leaf = true

    entry({"admin", "system", "autoupdate", "verify"},
          call("action_verify"), nil).leaf = true

    entry({"admin", "system", "autoupdate", "upgrade"},
          call("action_upgrade"), nil).leaf = true

    entry({"admin", "system", "autoupdate", "save"},
          call("action_save"), nil).leaf = true
end

-- 主页面
function action_index()
    local uci = require "luci.model.uci".cursor()
    luci.template.render("autoupdate/index", {
        repo      = uci:get("autoupdate", "config", "github_repo") or "",
        tag       = uci:get("autoupdate", "config", "firmware_tag") or "sysupgrade",
        keep      = uci:get("autoupdate", "config", "keep_config") or "1",
        proxy_url = uci:get("autoupdate", "config", "proxy_url") or "",
    })
end

-- 检查更新（Ajax）
function action_check()
    luci.http.prepare_content("application/json; charset=utf-8")
    local result = luci.util.exec("autoupdate check 2>/dev/null")
    luci.http.write(result ~= "" and result or '{"error":"脚本无输出，请检查 autoupdate 命令是否存在"}')
end

-- 下载固件（Ajax）
function action_download()
    luci.http.prepare_content("application/json; charset=utf-8")
    local url = luci.http.formvalue("url")
    if not url or url == "" then
        luci.http.write('{"error":"缺少 url 参数"}')
        return
    end
    -- 安全过滤：只允许 http/https URL
    if not url:match("^https?://") then
        luci.http.write('{"error":"非法 URL"}')
        return
    end
    local result = luci.util.exec(
        string.format("autoupdate download '%s' 2>/dev/null",
            url:gsub("'", ""))
    )
    luci.http.write(result ~= "" and result or '{"error":"下载命令无响应"}')
end

-- 校验固件（Ajax）
function action_verify()
    luci.http.prepare_content("application/json; charset=utf-8")
    local sha_url = luci.http.formvalue("sha256_url") or ""
    local sha_content = ""

    -- 若提供了 sha256sums URL，先抓取其内容
    if sha_url:match("^https?://") then
        local uci = require "luci.model.uci".cursor()
        local proxy = uci:get("autoupdate", "config", "proxy_url") or ""
        proxy = proxy:gsub("/$", "")
        local req_url = (proxy ~= "") and (proxy .. "/" .. sha_url) or sha_url
        sha_content = luci.util.exec(
            string.format("curl -sf --connect-timeout 10 '%s' 2>/dev/null",
                req_url:gsub("'", ""))
        )
    end

    local result = luci.util.exec(
        string.format("autoupdate verify '%s' 2>/dev/null",
            sha_content:gsub("'", ""):gsub("\n", " "))
    )
    luci.http.write(result ~= "" and result or '{"error":"校验命令无响应"}')
end

-- 执行升级（Ajax，后台运行）
function action_upgrade()
    luci.http.prepare_content("application/json; charset=utf-8")
    local keep = luci.http.formvalue("keep") or "1"
    -- 写入保留配置选项
    luci.util.exec(string.format(
        "uci set autoupdate.config.keep_config='%s'; uci commit autoupdate",
        keep == "1" and "1" or "0"
    ))
    -- 延迟 2 秒后在后台执行，给客户端时间接收本次响应
    luci.util.exec("( sleep 2; autoupdate upgrade ) >/tmp/autoupdate_upgrade.log 2>&1 &")
    luci.http.write('{"success":1,"message":"升级指令已发送，设备将在数秒后自动重启，请等待..."}')
end

-- 保存设置（Ajax）
function action_save()
    luci.http.prepare_content("application/json; charset=utf-8")
    local uci    = require "luci.model.uci".cursor()
    local repo   = luci.http.formvalue("github_repo") or ""
    local tag    = luci.http.formvalue("firmware_tag") or "sysupgrade"
    local proxy  = luci.http.formvalue("proxy_url")   or ""
    local keep   = luci.http.formvalue("keep_config") or "1"

    uci:set("autoupdate", "config", "github_repo",  repo)
    uci:set("autoupdate", "config", "firmware_tag", tag)
    uci:set("autoupdate", "config", "proxy_url",    proxy)
    uci:set("autoupdate", "config", "keep_config",  keep)
    uci:commit("autoupdate")

    luci.http.write('{"success":1}')
end
