-- voice-input 的 Hammerspoon 部分：全局按键说话，云端转写，文字直接粘贴到光标处。
-- 在 ~/.hammerspoon/init.lua 里加载（install.sh 会自动加）：
--   package.path = "<仓库路径>/hammerspoon/?.lua;" .. package.path
--   require("voice")
--
-- 默认触发键是"右 Command"（键码 54）。单独点一下右 Command 在 macOS 里本来没有任何作用，
-- 占用它不冲突；按住它再按别的键（⌘C 之类）会被识别成组合键，自动取消录音，不影响快捷键。
-- Windows 键盘接 Mac 时，空格右边的 Alt 通常就是右 Command。
--
--   按住触发键说话，松开 → 转写并粘贴（对讲机模式，适合短句）
--   轻点触发键 → 开始录音；再点一下 → 转写并粘贴（适合长段落，不用一直按着）
--   录音中按 Esc → 取消
--   Ctrl+Option+V → 最近的转写列表，选一条粘贴
--
-- 录音和转写都在 bin/voice-input 里，这里只管按键、状态和粘贴。

require("hs.ipc") -- 让终端里的 `hs` 命令能连进来调试
-- 仓库根目录：从这个文件自己的路径推出来，装在哪都行
local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/hammerspoon/[^/]+$") or "."
package.path = ROOT .. "/hammerspoon/?.lua;" .. package.path
local panel = require("voice_panel")
-- 可选：隐藏 Hammerspoon 自己的锤子图标，菜单栏只留麦克风（Hammerspoon 只用来跑这个工具时）。
-- 开启：在 Hammerspoon 控制台执行 hs.settings.set("voice.hideHammerspoonIcon", true)，再重载。
-- 隐藏后要打开控制台：点菜单栏麦克风 →「Hammerspoon 控制台」。
if hs.settings.get("voice.hideHammerspoonIcon") then hs.menuIcon(false) end

local SCRIPT = ROOT .. "/bin/voice-input"
local HISTORY = os.getenv("HOME") .. "/.local/state/voice-input/history.jsonl"
-- 触发键可以在菜单栏麦克风 →「设置触发键…」里自己改，存在 hs.settings 里，重启也记得。
-- 只支持单独的修饰键（Command/Option/Control/Shift/Fn），因为它们单独按下不会打出字符。
local masks = hs.eventtap.event.rawFlagMasks
local MODIFIER_KEYS = {
  [54] = { "右 Command", masks.deviceRightCommand },
  [55] = { "左 Command", masks.deviceLeftCommand },
  [61] = { "右 Option", masks.deviceRightAlternate },
  [58] = { "左 Option", masks.deviceLeftAlternate },
  [62] = { "右 Control", masks.deviceRightControl },
  [59] = { "左 Control", masks.deviceLeftControl },
  [60] = { "右 Shift", masks.deviceRightShift },
  [56] = { "左 Shift", masks.deviceLeftShift },
  [63] = { "Fn", masks.secondaryFn },
}
local TRIGGER_KEY = hs.settings.get("voice.triggerKey") or 54
if not MODIFIER_KEYS[TRIGGER_KEY] then TRIGGER_KEY = 54 end
local capturing = false -- 正在等你按下新的触发键
local ESC = 53
local HOLD_SECONDS = 0.35 -- 按住超过这个时间算"对讲机"，否则算"轻点切换"

-- idle → starting → recording → transcribing → idle
local state = "idle"
local stopWhenStarted = false -- 录音还没真正起来就松手了：起来后立刻停
local cancelWhenStarted = false
local pressAt = nil         -- 这次触发键按下的时间
local pressStarted = false  -- 这次按下是不是开启了录音
local comboUsed = false     -- 按住触发键期间按了别的键（比如 ⌘C）
local pressSource = "key"   -- 这次是键盘触发键还是鼠标侧键按下的

local menu = hs.menubar.new()
-- 日志同时写一份到文件：hs 命令行读控制台容易触发 ipc 递归刷屏，排查问题直接看这个文件
local LOGFILE = os.getenv("HOME") .. "/.local/state/voice-input/hammerspoon.log"
local log = { i = function(msg)
  local f = io.open(LOGFILE, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n"); f:close() end
end }
local watchdog = nil -- 转写超时保护：无论哪一步卡住，都不会永远停在"转写中"

------------------------------------------------------------------------------
-- 外观：目标是"像系统自带的"，不要花哨。
--   菜单栏：系统麦克风图标（template，自动适配深浅色菜单栏），录音时右下角红点，转写时黄点
--   浮窗：底部居中的深色胶囊，淡入淡出、柔和阴影、极细描边
--     录音   ● 0:05  ▁▃▅▇▅▃▁   红点呼吸；波形跟着当前音量起伏（不滚动）
--     提示   ● 已取消            一行字，几秒后自己淡出（替代 hs.alert 那个大方框）
--   转写：主浮窗右边并排一个小胶囊「◌ 转写中 ②」，黄色转圈 + 后台条数；
--     和录音/提示同时显示，录下一段时也看得到前面几段还在转写
--   提示音：Apple 系统的录音开始/结束音；出错用系统听写的"无法开始"音
-- 不能只靠提示音：蓝牙耳机空闲会休眠，醒来要半秒，短提示音经常被吞掉。
------------------------------------------------------------------------------
local RED   = { red = 1.00, green = 0.27, blue = 0.23 }
local AMBER = { red = 1.00, green = 0.72, blue = 0.20 }
local GRAY  = { white = 0.62 }

-- 菜单栏图标：系统麦克风 + 状态小圆点，画成一张图
local MIC = hs.image.imageFromName("NSTouchBarAudioInputTemplate")
local function menuImage(dotColor)
  if not dotColor then return MIC end
  local c = hs.canvas.new({ x = 0, y = 0, w = 22, h = 22 })
  c[1] = { type = "image", image = MIC, frame = { x = 1, y = 2, w = 18, h = 18 } }
  c[2] = { type = "circle", action = "fill", fillColor = dotColor, center = { x = 17, y = 16 }, radius = 3.6 }
  local img = c:imageFromCanvas()
  c:delete()
  return img
end
local MENU_IMG = { idle = menuImage(nil), starting = menuImage(RED), recording = menuImage(RED),
                   transcribing = menuImage(AMBER) }

-- 音量数据来自 voice-input 里 ffmpeg 每 50ms 算一次的音量，写在 LEVELS 文件里。
local LEVELS = (os.getenv("TMPDIR") or "/tmp") .. "/voice-input/ffmpeg.log"
local HUD_H = 44
local BARS, BAR_W, BAR_GAP, BAR_MAX_H = 11, 3, 3.5, 22
local WAVE_W = BARS * BAR_W + (BARS - 1) * BAR_GAP
local PAD, DOT_R = 18, 4.5

local hud = hs.canvas.new({ x = 0, y = 0, w = 200, h = HUD_H }):level(hs.canvas.windowLevels.overlay)
hud:behavior({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
-- 底色：从上到下很淡的深色渐变 + 顶部一条极细高光（像玻璃反光），不是一块死黑
hud[1] = { type = "rectangle", action = "strokeAndFill",
           fillGradient = "linear", fillGradientAngle = 90,
           fillGradientColors = { { red = 0.10, green = 0.10, blue = 0.12, alpha = 0.96 },
                                  { red = 0.20, green = 0.20, blue = 0.24, alpha = 0.96 } },
           strokeColor = { white = 1, alpha = 0.09 }, strokeWidth = 1,
           roundedRectRadii = { xRadius = HUD_H / 2, yRadius = HUD_H / 2 },
           withShadow = true, shadow = { blurRadius = 18, color = { alpha = 0.4 }, offset = { h = -5, w = 0 } },
           frame = { x = 8, y = 6, w = 184, h = HUD_H - 12 } }
local GLOW = 2 -- 画在最底下的光晕；红点在最上层（DOT，见下）
hud[GLOW] = { type = "circle", action = "fill", fillColor = { red = 1, green = 0.3, blue = 0.25, alpha = 0.18 },
              center = { x = 0, y = HUD_H / 2 }, radius = DOT_R + 4 }
hud[3] = { type = "text", text = "", textSize = 14, textColor = { white = 0.95 },
           frame = { x = 0, y = HUD_H / 2 - 9, w = 10, h = 20 } }
for i = 1, BARS do
  hud[3 + i] = { type = "rectangle", action = "fill",
                 fillGradient = "linear", fillGradientAngle = 90,
                 fillGradientColors = { { red = 0.72, green = 0.80, blue = 0.95, alpha = 0.85 }, { white = 1, alpha = 0.95 } },
                 roundedRectRadii = { xRadius = BAR_W / 2, yRadius = BAR_W / 2 },
                 frame = { x = 0, y = 0, w = BAR_W, h = BAR_W } }
end
local N = 3 + BARS
hud[N + 1] = { type = "rectangle", action = "fill", fillColor = { white = 1, alpha = 0.10 },   -- 顶部高光
               frame = { x = 0, y = 7, w = 10, h = 1 } }
local DOT = N + 2
hud[DOT] = { type = "circle", action = "fill", fillColor = RED, center = { x = 0, y = HUD_H / 2 }, radius = DOT_R } -- 红点

-- 按内容排版：有波形时 [点][文字][波形]，纯提示时 [点][文字]；胶囊宽度随内容变
local layout = { textW = 0, showWave = false, waveX = 0 }
local function hudLayout(text, showWave)
  local tw = math.ceil(hs.drawing.getTextDrawingSize(text, { size = 14 }).w) + 2
  if showWave then tw = math.max(tw, 44) end -- 计时 0:05 → 10:05 宽度会变，给个下限不跳
  local w = PAD + DOT_R * 2 + 10 + tw + (showWave and (14 + WAVE_W) or 0) + PAD
  hud:size({ w = w + 16, h = HUD_H }) -- 位置由 arrange() 统一摆（和转写胶囊并排居中）
  hud[1].frame = { x = 8, y = 6, w = w, h = HUD_H - 12 }
  hud[1].roundedRectRadii = { xRadius = (HUD_H - 12) / 2, yRadius = (HUD_H - 12) / 2 }
  -- 两个元素各给一份新表：canvas 的属性读出来是代理对象，不能直接互相赋值
  hud[DOT].center = { x = 8 + PAD + DOT_R, y = HUD_H / 2 }
  hud[GLOW].center = { x = 8 + PAD + DOT_R, y = HUD_H / 2 }
  local r = (HUD_H - 12) / 2
  hud[N + 1].frame = { x = 8 + r, y = 7, w = w - 2 * r, h = 1 }
  hud[3].frame = { x = 8 + PAD + DOT_R * 2 + 10, y = HUD_H / 2 - 9.5, w = tw, h = 20 }
  hud[3].text = text
  layout.textW, layout.showWave = tw, showWave
  layout.waveX = 8 + PAD + DOT_R * 2 + 10 + tw + 14
  -- 纯提示时不画波形条（action = "skip"）。之前是把渐变色设成透明，但 canvas 不认那种写法，
  -- 条还留在原位，压在提示文字上面。
  for i = 1, BARS do hud[3 + i].action = showWave and "fill" or "skip" end
end

local hudTimer, recordStart, messageTimer, hideTimer = nil, nil, nil, nil
local toggleMode = false -- 轻点开启的录音（要再点一下才结束）
local level = 0          -- 当前音量（0~1），涨得快、落得慢
-- 波形不滚动：所有条跟着"当前音量"一起起伏，中间高两边低；每根条再叠一点
-- 自己节奏的轻微律动，看起来是活的；高度逐帧缓动，才丝滑。
local SHAPE, PHASE, heights = {}, {}, {}
for i = 1, BARS do
  local d = math.abs(i - (BARS + 1) / 2) / ((BARS - 1) / 2) -- 0（中间）~ 1（两端）
  SHAPE[i] = 0.35 + 0.65 * math.cos(d * math.pi / 2)
  PHASE[i] = i * 1.7
  heights[i] = 0
end

local function readLevel()
  local f = io.open(LEVELS, "r")
  if not f then return 0 end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - 400)) -- 只读结尾一小段，文件再长也不慢
  local tail = f:read("a") or ""
  f:close()
  local last
  for v in tail:gmatch("RMS_level=([%-%w%.]+)") do last = v end
  local db = tonumber(last) or -100 -- "-inf"（完全静音）解析不了，按 -100 算
  -- 按大疆麦克风实测校准：底噪约 -65 dB，平常说话约 -48 dB，大声 -39~-29 dB。
  return math.max(0, math.min(1, (db + 62) / 30))
end

local function drawBars(targetFn)
  for i = 1, BARS do
    heights[i] = heights[i] + (targetFn(i) - heights[i]) * 0.3 -- 缓动
    local h = BAR_W + heights[i] * (BAR_MAX_H - BAR_W)
    hud[3 + i].frame = { x = layout.waveX + (i - 1) * (BAR_W + BAR_GAP), y = (HUD_H - h) / 2, w = BAR_W, h = h }
  end
end

local function tickRecording()
  local t = hs.timer.secondsSinceEpoch()
  local now = readLevel()
  level = (now > level) and now or (level * 0.82 + now * 0.18)
  drawBars(function(i) return level * SHAPE[i] * (0.78 + 0.22 * math.sin(t * 8 + PHASE[i])) end)
  local secs = math.floor(t - recordStart)
  hud[3].text = string.format("%d:%02d", secs // 60, secs % 60)
  -- 红点呼吸：1.6 秒一个周期，在 55%~100% 之间
  local breath = 0.775 + 0.225 * math.cos(t * 3.9)
  hud[DOT].fillColor = { red = RED.red, green = RED.green, blue = RED.blue, alpha = breath }
  hud[GLOW].fillColor = { red = RED.red, green = RED.green, blue = RED.blue, alpha = 0.22 * breath }
end

-- 转写胶囊：独立的小浮窗，和主浮窗并排。◌ 转圈表示在处理，右边圆形角标是后台条数
local chip = hs.canvas.new({ x = 0, y = 0, w = 120, h = HUD_H }):level(hs.canvas.windowLevels.overlay)
chip:behavior({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
chip[1] = { type = "rectangle", action = "strokeAndFill",
            fillGradient = "linear", fillGradientAngle = 90,
            fillGradientColors = { { red = 0.10, green = 0.10, blue = 0.12, alpha = 0.96 },
                                   { red = 0.20, green = 0.20, blue = 0.24, alpha = 0.96 } },
            strokeColor = { white = 1, alpha = 0.09 }, strokeWidth = 1,
            withShadow = true, shadow = { blurRadius = 18, color = { alpha = 0.4 }, offset = { h = -5, w = 0 } },
            frame = { x = 8, y = 6, w = 104, h = HUD_H - 12 } }
local SPIN_R = 5.5
chip[2] = { type = "circle", action = "stroke", strokeWidth = 2,               -- 转圈的底圈
            strokeColor = { red = AMBER.red, green = AMBER.green, blue = AMBER.blue, alpha = 0.22 },
            center = { x = 0, y = HUD_H / 2 }, radius = SPIN_R }
chip[3] = { type = "arc", action = "stroke", arcRadii = false, strokeWidth = 2, strokeCapStyle = "round",
            strokeColor = AMBER, center = { x = 0, y = HUD_H / 2 }, radius = SPIN_R,
            startAngle = 0, endAngle = 110 }
chip[4] = { type = "text", text = "转写中", textSize = 13, textColor = { white = 0.88 },
            frame = { x = 0, y = HUD_H / 2 - 9, w = 50, h = 20 } }
chip[5] = { type = "circle", action = "fill", fillColor = AMBER, center = { x = 0, y = HUD_H / 2 }, radius = 9 }
chip[6] = { type = "text", text = "1", textSize = 11.5, textColor = { red = 0.16, green = 0.12, blue = 0.04 },
            textFont = ".AppleSystemUIFontBold", textAlignment = "center",
            frame = { x = 0, y = HUD_H / 2 - 8, w = 18, h = 16 } }
chip[7] = { type = "rectangle", action = "fill", fillColor = { white = 1, alpha = 0.10 },  -- 顶部高光
            frame = { x = 0, y = 7, w = 10, h = 1 } }

local mainOn, chipCount, chipTimer = false, 0, nil
local CHIP_GAP = 8

-- 主浮窗和转写胶囊作为一组，在屏幕底部居中；只有一个时它自己居中
local function arrange()
  local f = hs.screen.mainScreen():frame()
  local mw = mainOn and (hud:frame().w - 16) or 0
  local cw = chipCount > 0 and (chip:frame().w - 16) or 0
  local total = mw + cw + ((mw > 0 and cw > 0) and CHIP_GAP or 0)
  local left, y = f.x + (f.w - total) / 2, f.y + f.h - 96
  if mainOn then hud:topLeft({ x = left - 8, y = y }) end -- 正在淡出的主浮窗留在原地，别跳
  chip:topLeft({ x = left + (mw > 0 and mw + CHIP_GAP or 0) - 8, y = y })
end

local function tickChip()
  local a = (hs.timer.secondsSinceEpoch() * 400) % 360 -- 约 1 秒转一圈
  chip[3].startAngle, chip[3].endAngle = a, a + 110
end

-- n = 后台正在转写的条数；0 时收起
local function updateChip(n)
  if n == chipCount then return end
  chipCount = n
  if n <= 0 then
    if chipTimer then chipTimer:stop(); chipTimer = nil end
    if chip:isShowing() then chip:hide(0.2) end
    arrange()
    return
  end
  local tw = math.ceil(hs.drawing.getTextDrawingSize("转写中", { size = 13 }).w) + 2
  local P = 14
  local sx = 8 + P + SPIN_R
  local tx = sx + SPIN_R + 9
  local bx = tx + tw + 6 + 9
  local w = (bx + 9 + 7) - 8 -- 角标右边留得比左边内边距小一点，角标本身是圆的
  chip:size({ w = w + 16, h = HUD_H })
  chip[1].frame = { x = 8, y = 6, w = w, h = HUD_H - 12 }
  chip[1].roundedRectRadii = { xRadius = (HUD_H - 12) / 2, yRadius = (HUD_H - 12) / 2 }
  chip[2].center = { x = sx, y = HUD_H / 2 }
  chip[3].center = { x = sx, y = HUD_H / 2 }
  chip[4].frame = { x = tx, y = HUD_H / 2 - 9, w = tw, h = 20 }
  chip[5].center = { x = bx, y = HUD_H / 2 }
  chip[6].frame = { x = bx - 9, y = HUD_H / 2 - 8, w = 18, h = 16 }
  chip[6].text = tostring(n)
  local r = (HUD_H - 12) / 2
  chip[7].frame = { x = 8 + r, y = 7, w = w - 2 * r, h = 1 }
  arrange()
  if not chip:isShowing() then chip:show(0.12) end
  if not chipTimer then tickChip(); chipTimer = hs.timer.doEvery(1 / 30, tickChip) end
end

local function stopTimers()
  if hudTimer then hudTimer:stop(); hudTimer = nil end
  if messageTimer then messageTimer:stop(); messageTimer = nil end
end

local function hudShow()
  mainOn = true
  arrange()
  if not hud:isShowing() then hud:show(0.12) end
end
local function hudHide()
  stopTimers()
  mainOn = false
  if hud:isShowing() then hud:hide(0.2) end
  arrange()
end

-- 一行提示，几秒后自己淡出（替代 hs.alert）
local function hudMessage(text, color, seconds)
  stopTimers()
  hudLayout(text, false)
  hud[DOT].fillColor = color or GRAY
  local c = color or GRAY
  hud[GLOW].fillColor = { red = c.red or c.white, green = c.green or c.white, blue = c.blue or c.white, alpha = 0.16 }
  hudShow()
  messageTimer = hs.timer.doAfter(seconds or 2.2, hudHide)
end

local function hudRecording() end -- 保留给按键逻辑调用（轻点模式切换），新样式不需要额外刷新

local jobs = {}            -- 后台转写队列（按录音先后顺序），见下方「后台转写」
local function pendingCount()
  local n = 0
  for _, j in ipairs(jobs) do if j.status == "running" then n = n + 1 end end
  return n
end

local hudMode = "none" -- rec / none：避免每次刷新都重排浮窗
local function setIcon()
  local recording = (state == "starting" or state == "recording")
  -- 刚松开、还在收尾（finish）的那一段也算"转写中"，免得胶囊晚半拍才出现
  local pending = pendingCount() + (state == "stopping" and 1 or 0)
  updateChip(pending)
  local icon = recording and "recording" or (pending > 0 and "transcribing" or "idle")
  menu:setIcon(MENU_IMG[icon], icon == "idle")
  log.i(string.format("state -> %s, pending=%d", state, pending))
  if recording then
    if hudMode ~= "rec" then
      stopTimers()
      hudMode = "rec"
      recordStart, level = hs.timer.secondsSinceEpoch(), 0
      for i = 1, BARS do heights[i] = 0 end
      hudLayout("0:00", true)
      tickRecording()
      hudShow()
      hudTimer = hs.timer.doEvery(1 / 30, tickRecording) -- 30 帧，波形才顺
    end
  else
    hudMode, recordStart = "none", nil
    -- 稍等一下再收起：取消/出错时紧跟着会弹一行提示，别先淡出再淡入闪一下。
    -- 定时器必须存进变量：hs.timer 没人引用会被垃圾回收、根本不触发，
    -- 之前"转写中"一直不消失就是这个原因。
    if hudTimer then hudTimer:stop(); hudTimer = nil end -- 先停掉录音波形动画
    if hideTimer then hideTimer:stop() end
    hideTimer = hs.timer.doAfter(0.05, function()
      hideTimer = nil
      if hudMode == "none" and not messageTimer then hudHide() end
    end)
  end
end

-- 提示音：Apple 系统自带的录音开始/结束音（Siri/听写同一套），出错用听写的"无法开始"。
-- 直接引用系统文件，不拷进仓库；万一某个版本的 macOS 没有，就不响，不影响功能。
local SYS = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
local sounds = {
  start = hs.sound.getByFile(SYS .. "begin_record.caf"),
  stop  = hs.sound.getByFile(SYS .. "end_record.caf"),
  error = hs.sound.getByFile("/System/Library/Input Methods/DictationIM.app/Contents/Resources/UnableToStartDictationSound.caf"),
}
local function sound(name)
  local s = sounds[name]
  if s then s:stop(); s:volume(0.8):play() end
end

local pasteTimers = {} -- 同上：定时器要有人引用，否则可能被回收、粘贴或还原剪贴板不发生
-- 转写结果两条路都走：一定放进剪贴板（随时 ⌘V 再贴一次、贴到别处），
-- 光标还在原来的输入框里时再自动粘贴。
-- 转写里的换行（模型自己分的段）粘贴前去掉：Claude Code 收到带 3 行以上的粘贴会折叠成
-- [Pasted text #1 +N lines]，看不到转写得对不对。超过 800 字也会折叠，那种再按一次 ⌘V 就能展开。
local function oneLine(text)
  return (text:gsub("[ \t]*\n%s*", "\n"):gsub("(%w)\n(%w)", "%1 %2"):gsub("\n", ""))
end

local function paste(text)
  text = oneLine(text)
  hs.pasteboard.setContents(text)
  pasteTimers.press = hs.timer.doAfter(0.05, function() hs.eventtap.keyStroke({ "cmd" }, "v", 0) end)
end

-- 现在能不能直接粘贴：窗口还是松手时那个，且焦点不在明显不是输入框的控件上。
-- 用黑名单而不是"必须是文本框"：终端、网页编辑器、Electron 报的角色五花八门，
-- 认不出来的一律照常粘贴，只拦确定不能输入的（按钮、列表、侧边栏……）。
local NON_TEXT = { AXButton = true, AXList = true, AXOutline = true, AXRow = true, AXCell = true,
                   AXTable = true, AXStaticText = true, AXImage = true, AXMenuItem = true, AXMenuBar = true,
                   AXCheckBox = true, AXRadioButton = true, AXPopUpButton = true, AXTabGroup = true,
                   AXToolbar = true, AXScrollBar = true, AXLink = true, AXSlider = true }
-- 当前前台窗口。前台是 Hammerspoon 自己（比如面板）时直接返回 nil：用辅助功能接口查
-- 自己的窗口会卡在自己的主线程上，约 1 秒超时后返回 nil（实测）。
local function frontWindow()
  local app = hs.application.frontmostApplication()
  if not app or app:bundleID() == hs.processInfo.bundleID then return nil end
  return hs.window.focusedWindow()
end

local function pasteTarget(winId)
  local win = frontWindow()
  if not (win and winId and win:id() == winId) then return false, "窗口切换了" end
  local ok, role = pcall(function()
    local el = hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
    return el and el:attributeValue("AXRole")
  end)
  if ok and role and NON_TEXT[role] then return false, "光标不在输入框里" end
  return true
end

local function run(args, callback)
  local t = hs.task.new(SCRIPT, function(code, out, err)
    if callback then callback(code, out, err) end
  end, args)
  t:start()
  return t
end

------------------------------------------------------------------------------
-- 后台转写
--
-- 松手后只做"停止录音 + 存进缓存"（voice-input finish，零点几秒），转写另起后台
-- 任务，所以可以马上录下一段，好几条同时在转写。结果按录音的先后顺序交付：
--   * 还停在录音结束时的那个窗口 → 直接粘贴进去
--   * 已经切到别的窗口 → 不往新窗口乱贴，复制到剪贴板并提示"按 ⌘V 粘贴"
-- 每条都进历史，面板「记录」里随时能复制。
------------------------------------------------------------------------------
local jobSeq = 0
local delivering, deliverTimer = false, nil
local noticeLater = nil -- 录音时不弹提示（会盖住录音浮窗），等录音结束再弹

local function notice(text, color, seconds)
  if state == "starting" or state == "recording" then
    noticeLater = { text, color, seconds }
  else
    hudMessage(text, color, seconds)
  end
end

local function flushJobs()
  if delivering then return end
  local j = jobs[1]
  if not j or j.status == "running" then
    setIcon()
    return
  end
  table.remove(jobs, 1)
  if j.status == "done" and j.text ~= "" then
    local ok, why = pasteTarget(j.winId)
    if ok then
      paste(j.text)
    else
      hs.pasteboard.setContents(oneLine(j.text))
      notice("已复制 · " .. why .. "，按 ⌘V 粘贴", GRAY, 3.5)
    end
  elseif j.status == "done" then
    notice("没有识别到内容")
  elseif j.status == "failed" then
    sound("error")
    notice(j.err .. " · 录音已保存，面板里可重新转写", RED, 4.5)
  end
  -- 两次粘贴之间留出时间：paste() 借用剪贴板，0.8 秒后才还原
  delivering = true
  deliverTimer = hs.timer.doAfter(1.0, function()
    delivering, deliverTimer = false, nil
    flushJobs()
  end)
  setIcon()
end

local function startJob(args, winId)
  jobSeq = jobSeq + 1
  local j = { id = jobSeq, status = "running", winId = winId }
  table.insert(jobs, j)
  -- 超时保护：脚本自己有网络超时，这里再兜一层，任何情况下都不会一直"转写中"
  j.watchdog = hs.timer.doAfter(240, function()
    if j.task and j.task:isRunning() then j.task:terminate() end
    if j.status == "running" then j.status, j.err = "failed", "转写超时" end
    flushJobs()
  end)
  j.task = run(args, function(code, out, err)
    if j.watchdog then j.watchdog:stop(); j.watchdog = nil end
    if j.status ~= "running" then return end
    log.i(string.format("job %d %s exit=%d out=%q err=%q", j.id, args[1], code, out or "", err or ""))
    if code == 0 then
      j.status, j.text = "done", out or ""
    else
      j.status, j.err = "failed", ((err or ""):gsub("voice%-input: [^\n]*换下一个模型\n", ""):gsub("^voice%-input: ", ""):gsub("%s+$", ""))
      if j.err == "" then j.err = "转写失败" end
    end
    if panel.isOpen() then panel.refresh() end
    flushJobs()
  end)
  setIcon()
end

local function transcribeWith(cmd, file) -- 面板重新转写 / 菜单重新转写：同样走后台队列
  local win = frontWindow()
  startJob(file and { cmd, file } or { cmd }, win and win:id())
end

local startAfterStop = false -- 上一段还在收尾（finish）时又按下了：收尾完立刻开始新录音
local startRecording

local function stopRecording()
  if state == "starting" then
    stopWhenStarted = true
  elseif state == "recording" then
    sound("stop")
    state = "stopping"
    local win = frontWindow()
    local winId = win and win:id()
    run({ "finish" }, function(code, out, err)
      state = "idle"
      if code == 0 and out ~= "" then
        startJob({ "file", out }, winId)
      else
        sound("error")
        notice(((err or ""):gsub("^voice%-input: ", ""):gsub("%s+$", "")), RED, 3)
      end
      setIcon()
      if noticeLater then hudMessage(table.unpack(noticeLater)); noticeLater = nil end
      if startAfterStop then startAfterStop = false; startRecording() end
    end)
    setIcon()
  elseif state == "stopping" and startAfterStop then
    stopWhenStarted = true -- 排队中的新录音一开始就结束（按得太短）
  end
end

local function cancelRecording()
  if state == "starting" then
    cancelWhenStarted = true
  elseif state == "stopping" then
    startAfterStop = false
  elseif state == "recording" then
    state = "idle"
    setIcon()
    run({ "cancel" })
    hudMessage("已取消 · 录音已保存在面板里")
  end
end

-- 触发键按下 / 松开（键盘触发键和鼠标侧键共用）
local function triggerDown(source)
  pressAt, comboUsed, pressSource = hs.timer.secondsSinceEpoch(), false, source or "key"
  if state == "idle" or state == "stopping" then
    pressStarted = true
    startRecording() -- 上一段还在后台转写也没关系，直接录下一段
  else
    -- 轻点模式下的第二下：结束录音
    pressStarted = false
    stopRecording()
  end
end
local function triggerUp()
  if not pressAt then return end
  local held = hs.timer.secondsSinceEpoch() - pressAt
  pressAt = nil
  if pressStarted and comboUsed then
    cancelRecording() -- 其实是 ⌘C 这类组合键，不是想说话
  elseif pressStarted and held >= HOLD_SECONDS then
    stopRecording() -- 对讲机模式：松手即结束
  elseif pressStarted then
    toggleMode = true -- 轻点：继续录，等下一次按下；浮窗提示改成"再点一下结束"
    if state == "recording" or state == "starting" then hudRecording() end
  end
end

startRecording = function()
  if state == "stopping" then startAfterStop = true; stopWhenStarted, cancelWhenStarted = false, false; return end
  if state ~= "idle" then return end
  state = "starting"
  stopWhenStarted, cancelWhenStarted, toggleMode = false, false, false
  setIcon()
  sound("start")
  run({ "start" }, function(code, _, err)
    if code ~= 0 then
      state = "idle"
      setIcon()
      sound("error")
      hudMessage(((err or ""):gsub("^voice%-input: ", ""):gsub("%s+$", "")), RED, 4)
      return
    end
    state = "recording"
    setIcon()
    if cancelWhenStarted then cancelRecording()
    elseif stopWhenStarted then stopRecording() end
  end)
end


local tap = hs.eventtap.new(
  { hs.eventtap.event.types.flagsChanged, hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.scrollWheel },
  function(e)
    local t = e:getType()
    if t == hs.eventtap.event.types.scrollWheel then
      -- 按住触发键（右 Command）时滚轮会变成 ⌘+滚轮（缩放/切换），把 ⌘ 去掉，滚动照常
      if pressAt and (TRIGGER_KEY == 54 or TRIGGER_KEY == 55) then
        local f = e:getFlags(); f.cmd = nil; e:setFlags(f)
      end
      return false
    end
    if t == hs.eventtap.event.types.keyDown then
      if capturing and e:getKeyCode() == ESC then
        capturing = false
        hudMessage("已取消设置")
        return true
      end
      -- 按住触发键后 0.8 秒内按了别的键，才算组合键（⌘C 这种都是一按下就按）。
      -- 说了一会儿之后再有按键事件（鼠标驱动、误碰），不能把整段录音丢掉。
      -- 鼠标侧键触发时不算组合键：它不会和 ⌘C 这类混在一起
      -- 自己发出去的按键不算：paste() 贴上一段用的 ⌘V（keycode 9）和鼠标前键的回车也是 keyDown 事件。
      -- 连着说两段时，上一段的转写常常正好在下一段刚开始录的 0.8 秒里落地，那一下 ⌘V 会被当成
      -- 用户按的组合键，松手就"已取消"，只能去面板重新转写。2026-09-29 复现两次，
      -- hammerspoon.log 里 "combo key 9 -> will cancel" 都和上一条 "job N file exit=0" 同一秒。
      -- 判据是事件源进程号：我们 post 的事件带 Hammerspoon 自己的 pid，真手按的键不会。
      local selfSent = e:getProperty(hs.eventtap.event.properties.eventSourceUnixProcessID)
                         == hs.processInfo.processID
      if pressAt and pressSource == "key" and not selfSent
         and hs.timer.secondsSinceEpoch() - pressAt < 0.8 then
        comboUsed = true
        log.i("combo key " .. e:getKeyCode() .. " -> will cancel")
      end
      if e:getKeyCode() == ESC and (state == "recording" or state == "starting") then
        log.i("Esc -> cancel")
        cancelRecording()
        return true -- 吞掉这个 Esc，免得同时把前台 app 的东西也取消了
      end
      -- 后台转写时不拦 Esc：你可能正在别的 App 里干活，Esc 是给它们用的
      return false
    end

    local code = e:getKeyCode()
    if capturing then
      if MODIFIER_KEYS[code] and (e:rawFlags() & MODIFIER_KEYS[code][2]) ~= 0 then
        capturing = false
        TRIGGER_KEY = code
        hs.settings.set("voice.triggerKey", code)
        hudMessage("触发键已设为「" .. MODIFIER_KEYS[code][1] .. "」", RED, 2.5)
        panel.refresh()
      end
      return false
    end
    if code ~= TRIGGER_KEY then return false end
    if (e:rawFlags() & MODIFIER_KEYS[TRIGGER_KEY][2]) ~= 0 then triggerDown() else triggerUp() end
    return false
  end
)
tap:start()

-- 鼠标侧键：后键（靠近拇指那个）= 触发键，按住说话 / 轻点开始再点结束；前键 = 回车（看过转写没问题再发）。
-- 中键（按滚轮）= 粘贴（⌘V）：选中文字大多已经自动复制了，只差粘贴这一步不用再右键找菜单。
-- 三个键的原始动作（浏览器后退/前进、中键在新标签页打开链接）都吞掉。菜单里可以关。
local MOUSE_PASTE, MOUSE_TALK, MOUSE_ENTER = 2, 3, 4 -- buttonNumber：2 = 中键，3 = 后退键，4 = 前进键

-- 前键就是回车，哪里都一样。以前在 tmux 里的 Claude Code 上会先发 End（绑成 scroll:bottom）
-- 兼作「跳到底」，结果只想回车时也被拽到底部，两件事抢一个键，去掉了。
local function mouseEnter()
  hs.eventtap.keyStroke({}, "return", 0)
end
local mouseOn = hs.settings.get("voice.mouseButtons") == true -- 默认关：侧键本来是后退/前进，要用自己在菜单里开
local BTN = hs.eventtap.event.properties.mouseEventButtonNumber
local mouseTap = hs.eventtap.new(
  { hs.eventtap.event.types.otherMouseDown, hs.eventtap.event.types.otherMouseUp },
  function(e)
    if not mouseOn then return false end
    local b = e:getProperty(BTN)
    if e:getType() == hs.eventtap.event.types.otherMouseDown then log.i("mouse button " .. b) end
    if b ~= MOUSE_TALK and b ~= MOUSE_ENTER and b ~= MOUSE_PASTE then return false end
    local down = e:getType() == hs.eventtap.event.types.otherMouseDown
    if b == MOUSE_PASTE then
      if down then hs.eventtap.keyStroke({ "cmd" }, "v", 0) end
    elseif b == MOUSE_TALK then
      if down then triggerDown("mouse") else triggerUp() end
    elseif down then
      mouseEnter()
    end
    return true
  end
)
mouseTap:start()
-- 必须挂到全局上：只存在 local 里、没人再引用的话，几分钟后会被垃圾回收，侧键就悄悄失灵了
-- （2026-09-26 实测：重启后能用，19:54 之后再按就没有任何事件进来）
_G.voiceMouseTap = mouseTap
local function toggleMouse()
  mouseOn = not mouseOn
  hs.settings.set("voice.mouseButtons", mouseOn)
  hudMessage(mouseOn and "鼠标按键已开启 · 后键说话，前键回车，中键粘贴" or "鼠标按键已关闭，恢复后退/前进/中键")
end
-- 启动时清掉上次可能残留的录音进程（录到一半重载配置/重启 Hammerspoon 会留下）。
run({ "cancel" })

-- macOS 在事件回调太慢时会悄悄关掉 eventtap，定时检查并拉起来。
-- 定时器本身也存全局，同样防回收
_G.voiceTapWatchdog = hs.timer.doEvery(5, function()
  if not tap:isEnabled() then tap:start() end
  if _G.voiceMouseTap and not _G.voiceMouseTap:isEnabled() then _G.voiceMouseTap:start() end
end)

local function retry()
  transcribeWith("retry")
end

-- 菜单里的「最近的录音」：每段录音都缓存着（voice-input 保留最近 10 段），点一下重新转写并粘贴
local function recentMenu()
  local out = hs.execute("'" .. SCRIPT .. "' list") or ""
  local items = {}
  for line in out:gmatch("[^\n]+") do
    local path, dur, text = line:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
    if path then
      local stamp = path:match("(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)%.wav$") or "?"
      local when = stamp:sub(5, 6) .. "-" .. stamp:sub(7, 8) .. " " .. stamp:sub(10, 11) .. ":" .. stamp:sub(12, 13)
      local preview = (text ~= "" and text or "（未转写）")
      if utf8.len(preview) and utf8.len(preview) > 28 then
        preview = preview:sub(1, utf8.offset(preview, 29) - 1) .. "…"
      end
      table.insert(items, { title = string.format("%s  %ss  %s", when, dur, preview),
                            fn = function() transcribeWith("file", path) end })
    end
  end
  if #items == 0 then items = { { title = "还没有录音", disabled = true } } end
  table.insert(items, { title = "-" })
  table.insert(items, { title = "打开录音文件夹", fn = function()
    hs.execute("mkdir -p ~/.local/state/voice-input/recordings && open ~/.local/state/voice-input/recordings")
  end })
  return items
end
-- ⌃⌥V：最近的转写，打字筛选，回车贴到当前光标（同时进剪贴板）；⌘1~9 直接选。
-- 不用打开面板、点复制、再切回来粘贴。
local function recentTexts(limit)
  local lines, f = {}, io.open(HISTORY, "r")
  if not f then return {} end
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  local out, seen = {}, {}
  for i = #lines, 1, -1 do
    local ok, e = pcall(hs.json.decode, lines[i])
    if ok and type(e) == "table" and e.text and e.text ~= "" and not seen[e.audio or e.text] then
      seen[e.audio or e.text] = true
      out[#out + 1] = e
      if #out >= limit then break end
    end
  end
  return out
end
local picker = hs.chooser.new(function(choice)
  if not choice then return end
  hs.pasteboard.setContents(oneLine(choice.full))
  pasteTimers.press = hs.timer.doAfter(0.15, function() hs.eventtap.keyStroke({ "cmd" }, "v", 0) end)
end)
picker:placeholderText("最近的转写 · 输入筛选 · 回车粘贴（也会放进剪贴板）"):searchSubText(false):rows(9):width(40)
local function showPicker()
  local choices = {}
  for _, e in ipairs(recentTexts(40)) do
    local oneLine = e.text:gsub("%s+", " ")
    choices[#choices + 1] = { text = oneLine, full = e.text,
                              subText = (e.at or ""):sub(6, 16) .. (e.dur and string.format(" · %d 秒", math.floor(e.dur + 0.5)) or "") }
  end
  picker:choices(choices)
  picker:query("")
  picker:show()
end
hs.hotkey.bind({ "ctrl", "alt" }, "v", showPicker)

-- 给终端调试用：hs -c 'return voice.state()'
_G.voice = { state = function() return state end, trigger = function() return TRIGGER_KEY end,
             tapEnabled = function() return tap:isEnabled() end,
             -- 只显示浮窗、不录音，用来看样子：hs -c 'voice.demoHud(true)'
             demoHud = function(on) state = on and "recording" or "idle"; setIcon() end,
             demoState = function(st) state = st; setIcon() end,
             jobs = function() return #jobs, pendingCount() end,
             demoChip = function(n) updateChip(n) end, -- 只看转写胶囊的样子：voice.demoChip(2)
             picker = function(hide) if hide then picker:hide() else showPicker() end end,
             demoMessage = function(text) hudMessage(text, RED, 3) end }

local function startCapture()
  if state ~= "idle" then return end
  capturing = true
  hudMessage("按一下想用的键（⌘ ⌥ ⌃ ⇧ Fn）· Esc 取消", GRAY, 8)
end
panel.setup({ triggerName = function() return MODIFIER_KEYS[TRIGGER_KEY][1] end, startCapture = startCapture })
-- 启动几秒后在后台把面板窗口建好（不显示），第一次打开就不用等 WebKit 冷启动
_G.voicePanelPrewarm = hs.timer.doAfter(3, function() panel.prewarm() end)

menu:setMenu(function()
  return {
    { title = "按住「" .. MODIFIER_KEYS[TRIGGER_KEY][1] .. "」说话 / 轻点开始、再点结束", disabled = true },
    { title = "打开面板（记录 · 统计 · 设置）", fn = panel.open },
    { title = "-" },
    { title = "设置触发键…", fn = startCapture },
    { title = "鼠标按键：后键说话、前键回车、中键粘贴", checked = mouseOn, fn = function() toggleMouse() end },
    { title = "最近的转写（粘贴）  ⌃⌥V", fn = showPicker },
    { title = "重新转写最近一段", fn = retry },
    { title = "最近的录音", menu = recentMenu() },
    { title = "打开转写历史", fn = function() hs.execute("open -t '" .. HISTORY .. "'") end },
    { title = "-" },
    { title = "重新加载配置", fn = hs.reload },
    { title = "Hammerspoon 控制台", fn = hs.openConsole },
  }
end)
setIcon()
hudMessage("语音输入已就绪 · 按住「" .. MODIFIER_KEYS[TRIGGER_KEY][1] .. "」说话")
