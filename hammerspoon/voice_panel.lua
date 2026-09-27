-- 语音输入的面板窗口：记录 / 统计 / 设置（页面是同目录的 panel.html）。
--
-- 数据流：这里读 history.jsonl、录音缓存、config.json，拼成一个表，
-- 用 app.render(json) 推给页面；页面的按钮通过 webkit messageHandler 发回
-- {cmd=...}，在 handle() 里处理。转写、测试 Key 这类慢操作都走 hs.task，异步回调。

local M = {}

local HOME = os.getenv("HOME")
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
local SCRIPT = HERE .. "/../bin/voice-input"
local PAGE = HERE .. "/panel.html"
local HISTORY = HOME .. "/.local/state/voice-input/history.jsonl"
local ARCHIVE = HOME .. "/.local/state/voice-input/recordings"
local CONFIG_DIR = HOME .. "/.config/voice-input"
local CONFIG = CONFIG_DIR .. "/config.json"
local CALLS = HOME .. "/.local/state/voice-input/calls.jsonl"
local QUOTA = HOME .. "/.local/state/voice-input/quota.json"
-- 可选：阿里云真实账单 {"at": "…", "days": {"YYYY-MM-DD": {模型: 元}}}，由外部脚本（比如定时拉 BSS 账单的）写入。
-- 有这个文件，面板的花费就用真实扣费；没有就只显示按标价的估算
local BILLING = HOME .. "/.local/state/voice-input/billing.json"
local COOLDOWN = (os.getenv("TMPDIR") or "/tmp") .. "/voice-input/cooldown"
local VOCAB = os.getenv("VOICE_VOCAB") or (CONFIG_DIR .. "/vocab.txt") -- 常用词表（可以软链到自己的 dotfiles）
local DEFAULT_MODELS = { "qwen3-asr-flash-2025-09-08", "qwen3-asr-flash-2026-02-10", "fun-asr-flash-2026-06-15", "qwen3-asr-flash", "gemini-3-flash-preview", "gemini-2.5-flash", "local-qwen3-asr-1.7b" }
-- 设置页"可选模型"：没启用的也列出来，勾一下就能用。note 显示在模型名旁边
local KNOWN_MODELS = {
  { name = "qwen3-asr-flash-2025-09-08", provider = "阿里云百炼", note = "qwen3-asr-flash 现在指向的版本，单独 10 小时免费额度" },
  { name = "qwen3-asr-flash-2026-02-10", provider = "阿里云百炼", note = "qwen3-asr-flash 的新快照，单独 10 小时免费额度" },
  { name = "fun-asr-flash-2026-06-15", provider = "阿里云百炼", note = "另一个听写模型，单独 10 小时免费额度；中英文间不加空格" },
  { name = "qwen3-asr-flash", provider = "阿里云百炼", note = "¥0.79/小时录音，国内直连，最快" },
  { name = "gemini-3-flash-preview", provider = "Gemini", note = "免费额度，要走代理" },
  { name = "gemini-2.5-flash", provider = "Gemini", note = "免费额度，要走代理" },
  { name = "gemini-2.5-flash-lite", provider = "Gemini", note = "免费额度，效果差，容易加词" },
  { name = "local-qwen3-asr-1.7b", provider = "本机", note = "免费、断网可用，准确度差一些，最后备用" },
}

local wv, hooks, playing = nil, {}, nil

------------------------------------------------------------------------------
-- 读数据
------------------------------------------------------------------------------
local function readConfig()
  local f = io.open(CONFIG, "r")
  if not f then return {} end
  local ok, t = pcall(hs.json.decode, f:read("a"))
  f:close()
  return (ok and type(t) == "table") and t or {}
end

local function writeConfig(t)
  hs.fs.mkdir(HOME .. "/.config")
  hs.fs.mkdir(CONFIG_DIR)
  local f = assert(io.open(CONFIG, "w"))
  f:write(hs.json.encode(t, true))
  f:close()
  os.execute("chmod 600 '" .. CONFIG .. "'") -- 里面有 API Key
end

-- 按文件大小+修改时间缓存解析结果：每次打开/刷新面板都逐行解析几百行 JSON 要几十毫秒，
-- 期间 Hammerspoon 整个卡住。返回的表是共享的，调用方只读不改。
local jsonlCache = {}
local function readJsonl(path)
  local a = hs.fs.attributes(path)
  if not a then return {} end
  local c = jsonlCache[path]
  if c and c.size == a.size and c.mtime == a.modification then return c.rows end
  local out, f = {}, io.open(path, "r")
  if not f then return out end
  for line in f:lines() do
    local ok, e = pcall(hs.json.decode, line)
    if ok and type(e) == "table" then table.insert(out, e) end
  end
  f:close()
  jsonlCache[path] = { size = a.size, mtime = a.modification, rows = out }
  return out
end

local function readHistory()
  local out = {}
  for _, e in ipairs(readJsonl(HISTORY)) do
    if e.at and e.text then table.insert(out, e) end
  end
  return out
end

local function exists(p) return p and hs.fs.attributes(p) ~= nil end

local function chars(s) return utf8.len(s or "") or #(s or "") end

-- 早期记录没存时长：按每秒约 4 个字估算（中文正常语速）
local function durOf(e) return tonumber(e.dur) or chars(e.text) / 4 end

local function buildItems(history)
  local items, seen = {}, {}
  -- 同一段录音可能转写过好几次（重新转写），只保留最新那次
  for i = #history, 1, -1 do
    local e = history[i]
    local key = e.audio or ("text:" .. i)
    if not seen[key] then
      seen[key] = true
      table.insert(items, {
        at = e.at, text = e.text, model = e.model, dur = tonumber(e.dur),
        audio = exists(e.audio) and e.audio or nil,
      })
    end
    if #items >= 100 then break end
  end
  -- 缓存里还没转写成功的录音（转写失败、被取消）也列出来，能补转
  local files = {}
  if exists(ARCHIVE) then for file in hs.fs.dir(ARCHIVE) do table.insert(files, file) end end
  for _, file in ipairs(files) do
    local stamp = file:match("^(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)%.wav$")
    local path = ARCHIVE .. "/" .. file
    if stamp and not seen[path] then
      local attr = hs.fs.attributes(path)
      table.insert(items, {
        at = string.format("%s-%s-%s %s:%s:%s", stamp:sub(1, 4), stamp:sub(5, 6), stamp:sub(7, 8),
                           stamp:sub(10, 11), stamp:sub(12, 13), stamp:sub(14, 15)),
        text = "", audio = path, dur = attr and (attr.size / 32000) or nil,
      })
    end
  end
  table.sort(items, function(a, b) return a.at > b.at end)
  for i, it in ipairs(items) do it.id = i end
  return items
end

local UNKNOWN = "未记录模型" -- 早期转写没存模型

local function buildStats(history, settingsModels)
  local byDay, estimated, seen = {}, false, {}
  local total = { count = 0, chars = 0, secs = 0 }
  for _, e in ipairs(history) do
    -- 日期快照（qwen3-asr-flash-2026-02-10）算进主模型：图上是同一个模型，只是额度分开
    local day, model = e.at:sub(1, 10), e.model and e.model:gsub("%-%d%d%d%d%-%d%d%-%d%d$", "") or UNKNOWN
    seen[model] = true
    local d = byDay[day] or { count = 0, chars = 0, secs = 0, byModel = {} }
    local c, s = chars(e.text), durOf(e)
    if not e.dur then estimated = true end
    d.count, d.chars, d.secs = d.count + 1, d.chars + c, d.secs + s
    local m = d.byModel[model] or { count = 0, chars = 0, secs = 0 }
    m.count, m.chars, m.secs = m.count + 1, m.chars + c, m.secs + s
    d.byModel[model] = m
    byDay[day] = d
    total.count, total.chars, total.secs = total.count + 1, total.chars + c, total.secs + s
  end
  local days = {}
  for i = 13, 0, -1 do
    local date = os.date("%Y-%m-%d", os.time() - i * 86400)
    local d = byDay[date] or { count = 0, chars = 0, secs = 0, byModel = {} }
    local bm = {}
    for k, v in pairs(d.byModel) do bm[k] = { count = v.count, chars = v.chars, secs = math.floor(v.secs + 0.5) } end
    table.insert(days, { date = date, count = d.count, chars = d.chars, secs = math.floor(d.secs + 0.5), byModel = bm })
  end

  -- 按模型：今天的调用情况（calls.jsonl，含失败）+ 已知上限（quota.json）+ 是否冷却中
  local today = os.date("%Y-%m-%d")
  local calls = {}
  -- 花费：脚本按阿里云标价在每次调用时算好写进 calls.jsonl（cost 字段，元）；Gemini 免费额度没有 cost
  local cost, costByDay = { today = 0, yesterday = 0, month = 0, total = 0 }, {}
  local yday, month = os.date("%Y-%m-%d", os.time() - 86400), os.date("%Y-%m")
  for _, c in ipairs(readJsonl(CALLS)) do
    local v = tonumber(c.cost) or 0
    if v > 0 and c.at then
      cost.total = cost.total + v
      costByDay[c.at:sub(1, 10)] = (costByDay[c.at:sub(1, 10)] or 0) + v
      if c.at:sub(1, 7) == month then cost.month = cost.month + v end
      if c.at:sub(1, 10) == today then cost.today = cost.today + v end
      if c.at:sub(1, 10) == yday then cost.yesterday = cost.yesterday + v end
    end
    if c.model and c.at and c.at:sub(1, 10) == today then
      seen[c.model] = true
      local t = calls[c.model] or { calls = 0, ok = 0, limited = 0, failed = 0, cost = 0 }
      t.calls = t.calls + 1
      t.cost = t.cost + (tonumber(c.cost) or 0)
      if c.code == 200 then t.ok = t.ok + 1
      elseif c.code == 429 then t.limited = t.limited + 1
      else t.failed = t.failed + 1 end
      calls[c.model] = t
    end
  end
  -- 真实扣费：只算语音输入自己调过的模型（calls.jsonl 里出现过的）
  local billing
  do
    local f = io.open(BILLING, "r")
    local ok, b = false, nil
    if f then ok, b = pcall(hs.json.decode, f:read("a")); f:close() end
    if ok and type(b) == "table" and type(b.days) == "table" then
      local mine = {}
      for _, c in ipairs(readJsonl(CALLS)) do if c.model then mine[c.model] = true end end
      billing = { at = b.at, today = 0, month = 0, total = 0, byDay = {}, byModel = {} }
      for day, ms in pairs(b.days) do
        for m, v in pairs(ms) do
          if mine[m] and tonumber(v) then
            billing.total = billing.total + v
            billing.byDay[day] = (billing.byDay[day] or 0) + v
            if day:sub(1, 7) == month then billing.month = billing.month + v end
            if day == today then billing.today = billing.today + v; billing.byModel[m] = (billing.byModel[m] or 0) + v end
          end
        end
      end
    end
  end
  local quota = {}
  do
    local f = io.open(QUOTA, "r")
    if f then local ok, t = pcall(hs.json.decode, f:read("a")); f:close(); if ok and type(t) == "table" then quota = t end end
  end
  -- 模型顺序：设置里的顺序在前，其余按名字；"未记录模型"放最后。颜色由页面按模型名固定分配
  local order, inOrder = {}, {}
  for _, m in ipairs(settingsModels) do table.insert(order, m); inOrder[m] = true end -- 设置里的模型没用过也列出来
  local rest = {}
  for m in pairs(seen) do if not inOrder[m] and m ~= UNKNOWN then table.insert(rest, m) end end
  table.sort(rest)
  for _, m in ipairs(rest) do table.insert(order, m) end
  if seen[UNKNOWN] then table.insert(order, UNKNOWN) end

  local models = {}
  for _, m in ipairs(order) do
    local c = calls[m] or { calls = 0, ok = 0, limited = 0, failed = 0, cost = 0 }
    local q = quota[m]
    local perDay = q and q.quotaId and q.quotaId:find("PerDay") ~= nil
    local coolAttr = hs.fs.attributes(COOLDOWN .. "/" .. m)
    local cooling = coolAttr and (os.time() - coolAttr.modification) < 600
    local todayOk = (byDay[today] and byDay[today].byModel[m] and byDay[today].byModel[m].count) or 0
    table.insert(models, {
      name = m, unknown = (m == UNKNOWN), todayOk = todayOk,
      calls = c.calls, limited = c.limited, failed = c.failed,
      limit = q and q.limit or nil, limitUnit = q and (perDay and "天" or (q.quotaId and q.quotaId:find("PerMinute") and "分钟") or "") or nil,
      -- 剩余是估算：上限减去今天记录到的非限额请求（Google 没有查询剩余额度的接口）
      remaining = (q and q.limit and perDay) and math.max(0, q.limit - (c.calls - c.limited)) or nil,
      cooling = cooling or false,
      cost = c.cost, paid = (m:find("^qwen") ~= nil or m:find("^fun%-asr") ~= nil),
      billed = billing and (billing.byModel[m] or 0) or nil,
    })
  end

  for _, d in ipairs(days) do d.cost = costByDay[d.date] or 0; d.billed = billing and (billing.byDay[d.date] or 0) or nil end

  local empty = { count = 0, chars = 0, secs = 0 }
  return {
    days = days, total = total, estimated = estimated, models = models, cost = cost, billing = billing,
    today = byDay[today] or empty,
    yesterday = byDay[os.date("%Y-%m-%d", os.time() - 86400)] or empty,
  }
end

local function mask(k)
  if not k or #k < 12 then return nil end
  return k:sub(1, 4) .. "…" .. k:sub(-4)
end

-- 直接读 ~/.secrets.zsh 里的 export NAME=value，不起 zsh：hs.execute 是同步的，
-- 每起一个进程 Hammerspoon 就整个卡一下（打开面板原来要卡 150ms 以上）
local function readSecret(...)
  local f = io.open(os.getenv("HOME") .. "/.secrets.zsh", "r"); if not f then return nil end
  local vals = {}
  for line in f:lines() do
    local k, v = line:match("^%s*export%s+([%w_]+)=(.-)%s*$")
    if k then vals[k] = v:gsub("^([\"'])(.*)%1$", "%2") end
  end
  f:close()
  for _, name in ipairs({ ... }) do if vals[name] and vals[name] ~= "" then return vals[name] end end
end

-- 麦克风列表要跑 ffmpeg，很慢：先用上次的结果，后台重新列一遍，列完有变化再刷新页面
local devices = {}
local function refreshDevices()
  hs.task.new(SCRIPT, function(_, out)
    local list = {}
    for line in (out or ""):gmatch("[^\n]+") do table.insert(list, line) end
    if table.concat(list, "\n") ~= table.concat(devices, "\n") then
      devices = list
      if M.isOpen() then M.refresh() end
    end
  end, { "devices" }):start()
end

local function buildSettings()
  local cfg = readConfig()
  local key, source = cfg.api_key, "面板设置"
  if not key or key == "" then
    key = readSecret("GEMINI_API_KEY", "GOOGLE_API_KEY")
    source = "来自 ~/.secrets.zsh"
  end
  local ds, dsSource = cfg.dashscope_key, "面板设置"
  if not ds or ds == "" then
    ds = readSecret("DASHSCOPE_API_KEY")
    dsSource = "来自 ~/.secrets.zsh"
  end
  return {
    keyMasked = mask(key), keySource = source,
    dsMasked = mask(ds), dsSource = dsSource, knownModels = KNOWN_MODELS,
    models = (type(cfg.models) == "table" and #cfg.models > 0) and cfg.models or DEFAULT_MODELS,
    mic = cfg.mic or "", keep = tonumber(cfg.keep) or 10,
    devices = devices, trigger = hooks.triggerName and hooks.triggerName() or "",
    vocab = (function()
      local f = io.open(VOCAB, "r"); if not f then return "" end
      local t = f:read("a"); f:close(); return t
    end)(),
  }
end

------------------------------------------------------------------------------
-- 和页面通信
------------------------------------------------------------------------------
local function js(code) if wv then wv:evaluateJavaScript(code) end end
local function call(fn, ...)
  local args = {}
  for i, v in ipairs({ ... }) do args[i] = hs.json.encode({ v }):sub(2, -2) end -- 编码单个值
  js(string.format("window.app && app.%s(%s)", fn, table.concat(args, ",")))
end

function M.refresh()
  if not wv then return end
  local history = readHistory()
  local settings = buildSettings()
  call("render", { items = buildItems(history), stats = buildStats(history, settings.models), settings = settings })
end

local function runScript(args, env, cb)
  local t = hs.task.new(SCRIPT, cb, args)
  if env then
    local e = t:environment()
    for k, v in pairs(env) do e[k] = v end
    t:setEnvironment(e)
  end
  t:start()
end

local function clean(err) return ((err or ""):gsub("^voice%-input: ", ""):gsub("%s+$", "")) end

local handlers = {
  ready = function() M.refresh() end,
  refresh = function() M.refresh() end,
  copy = function(m)
    hs.pasteboard.setContents(m.text or "")
    call("onCopied", m.id)
  end,
  play = function(m)
    if playing then playing:stop() end
    playing = hs.sound.getByFile(m.path)
    if playing then playing:play() end
  end,
  reveal = function(m) hs.execute("open -R '" .. m.path:gsub("'", "'\\''") .. "'") end,
  openFolder = function() hs.execute("mkdir -p '" .. ARCHIVE .. "' && open '" .. ARCHIVE .. "'") end,
  retranscribe = function(m)
    local args = { "file", m.path }
    if m.model and m.model ~= "" then table.insert(args, m.model) end
    runScript(args, nil, function(code, out, err)
      if code == 0 and out ~= "" then
        call("onRetranscribed", m.id, { ok = true, text = out, model = m.model ~= "" and m.model or nil })
      else
        call("onRetranscribed", m.id, { ok = false, err = code == 0 and "没有识别到内容" or clean(err) })
      end
    end)
  end,
  testKey = function(m)
    -- 测试输入框里的新 Key（还没保存）时，通过环境变量传给脚本，不写进命令行参数
    local provider = m.provider == "qwen" and "qwen" or "gemini"
    local env = nil
    if m.key and m.key ~= "" then
      env = provider == "qwen" and { VOICE_DASHSCOPE_KEY = m.key } or { VOICE_API_KEY = m.key }
    end
    runScript({ "test", provider }, env, function(code, out, err)
      call("onTest", provider, { ok = code == 0, msg = code == 0 and clean(out) or clean(err) })
    end)
  end,
  saveSettings = function(m)
    local s, cfg = m.settings or {}, readConfig()
    if s.api_key and s.api_key ~= "" then cfg.api_key = s.api_key end
    if s.dashscope_key and s.dashscope_key ~= "" then cfg.dashscope_key = s.dashscope_key end
    if type(s.models) == "table" and #s.models > 0 then cfg.models = s.models end
    if s.mic and s.mic ~= "" then cfg.mic = s.mic end
    if tonumber(s.keep) then cfg.keep = math.floor(tonumber(s.keep)) end
    writeConfig(cfg)
    if type(s.vocab) == "string" and s.vocab ~= "" then
      local f = io.open(VOCAB, "w")
      if f then f:write((s.vocab:gsub("\r\n", "\n"))); f:close() end
    end
    M.refresh()
    call("onSaved", "已保存")
  end,
  setTrigger = function()
    if hooks.startCapture then hooks.startCapture() end
  end,
}

local function handle(msg)
  local m = msg.body
  if type(m) ~= "table" then return end
  local h = handlers[m.cmd]
  if h then
    local ok, e = pcall(h, m)
    if not ok then hs.printf("voice panel: %s failed: %s", tostring(m.cmd), tostring(e)) end
  end
end

------------------------------------------------------------------------------
-- 窗口
------------------------------------------------------------------------------
function M.setup(h) hooks = h or {} end

-- 建窗口但不显示。Hammerspoon 启动后第一次建 webview 要起 WebKit，实测阻塞 1.3 秒；
-- 所以启动后先在后台建好藏着（M.prewarm），点"打开面板"时只是显示出来。
local function create()
  local uc = hs.webview.usercontent.new("voice")
  uc:setCallback(handle)
  local f = hs.screen.mainScreen():frame()
  local w, hgt = 720, 640
  wv = hs.webview.new({ x = f.x + (f.w - w) / 2, y = f.y + (f.h - hgt) / 2, w = w, h = hgt },
                      { developerExtrasEnabled = true }, uc)
  wv:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    :windowTitle("语音输入")
    :allowTextEntry(true)       -- 设置页要能输入 Key
    :allowNewWindows(false)
    -- 关窗只是藏起来，不销毁：下次打开不用重新建 WebKit、加载页面，直接出来
    :deleteOnClose(false)
    :url("file://" .. PAGE)
    :level(hs.drawing.windowLevels.normal)
    -- 普通窗口行为：只待在打开它的那个桌面。webview 默认"在所有桌面都显示"，
    -- 切到全屏的 iTerm 时它也跟过去盖在上面。
    :behavior(hs.drawing.windowBehaviors.default)
end

function M.prewarm() if not wv then create() end end

function M.open()
  refreshDevices()
  local fresh = not wv
  if fresh then create() end
  -- 不用 bringToFront()：它会把窗口层级改成 floating（不带参数也会），切到别的窗口它还盖在上面。
  -- bringToFront 会顺带把层级改成 floating（不带参数也会），切走后它还盖在别的窗口上面，
  -- 所以拉到前面后马上改回普通层级。
  -- 别用 wv:hswindow() / hs.window.focusedWindow() 去查面板自己：用辅助功能接口查
  -- Hammerspoon 自己的窗口会卡在自己的主线程上，约 1 秒超时后返回 nil（实测 1.0~1.5 秒）。
  wv:show():bringToFront():level(hs.drawing.windowLevels.normal)
  hs.focus()
  if not fresh then M.refresh() end -- 新建的等页面加载完发 ready 再刷新
end

-- 全屏应用的桌面里，别的应用的窗口总是浮在全屏窗口上面，调层级没用（点全屏的 iTerm 面板也不会沉下去）。
-- 所以切到全屏窗口时直接把面板藏起来；再从菜单打开会原样出来。
M.appWatcher = hs.application.watcher.new(function(_, event, app)
  if event ~= hs.application.watcher.activated or not wv or not wv:isVisible() then return end
  -- 激活的是 Hammerspoon 自己（比如刚打开面板）就别查：查自己的窗口会卡 1 秒，见 M.open
  if not app or app:bundleID() == hs.processInfo.bundleID then return end
  local fw = hs.window.focusedWindow()
  if fw and fw:isFullScreen() then
    hs.printf("voice panel: hidden, %s is fullscreen", fw:application():name())
    wv:hide()
  end
end)
M.appWatcher:start()

function M.isOpen() return wv ~= nil and wv:isVisible() end
function M.js(code) js(code) end -- 调试用：在面板里执行一段 JS

return M
