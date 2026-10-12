--[[
    Anime Girl RNG - Robin Bounty Helper (Delta compatible) - FIXED click system + FIXED config macro save/load

    Every run, in this priority order:
      1. Talk to Robin -> View Bounties -> press every available "Accept"
      2. Read your active quests (quest icon on the left)
      3. ARCADE quest active?  -> replay your recorded arcade macro (N times)
      4. Claim completed quests
      5. FISHING quest active? -> teleport to your marked fishing spot (and stay there)

    CONFIG FIXES in this version:
      * Macro steps are no longer silently thrown away when an object can't be found at load time.
        They are kept and resolved again when the macro is played (objects may load in late).
      * Instance paths now handle several objects with the same name (stores the sibling index).
      * More value types are saved (EnumItem, UDim, UDim2, BrickColor) and bigger/deeper tables.
      * Writes are verified by reading the file back; falls back to memory if the executor can't write.
      * Saving while still recording now stops the recording first (so the macro is complete).
      * Save/load tell you exactly how many steps couldn't be saved or are pending.
]]

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local PPS = game:GetService("ProximityPromptService")
local TeleportService = game:GetService("TeleportService")
local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)
local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

local CONFIG = {
    Robin = {
        NpcName = "robin",
        IntervalSeconds = 1800,
        AutoStart = false,
        FirstRunDelay = 30,
        KnownBountyIds = {             -- used only if the bounty board can't be read
            "robin_biome_1", "robin_biome_4", "robin_fish_1", "robin_fish_10", "robin_fish_25", "robin_fish_50",
            "robin_mini_1", "robin_mini_5", "robin_mini_10", "robin_mini_20",
            "robin_roll_100m", "robin_roll_10k", "robin_roll_100k",
        },
    },
    ClaimKeywords = { "claim", "collect" },
    ClaimExclude = { "claimed" },
    ClaimInterval = 300,               -- Auto Claim toggle: check for claimable quests every 5 minutes
    FishKeywords = { "fish", "angler" },
    ArcadeKeywords = { "mini game", "minigame", "mini-game", "arcade" },
    QuestIconNames = { "quest", "bounty", "mission" },
    Arcade = {
        IgnoreRemotes = { "roll", "ping", "heartbeat", "camera", "position", "walk", "sprint" },
        BetweenRuns = 1.5,
        DefaultRuns = 1,
        MaxSteps = 400,
    },
    AntiAfkJumpSeconds = 600,          -- Anti-AFK: jump every this many seconds (saved in configs too)
    TeleportOffset = Vector3.new(0, 3, 4),
    ReturnAfterRun = true,
    VirtualClickFallback = true,
    SaveFile = "AGRNG_Robin.json",
    FilePrefix = "AGRNG_Robin_",
    ScriptUrl = "https://raw.githubusercontent.com/Makoto1891/AnimeGirlRng/refs/heads/main/AnimeGirlRNG.lua",
}

-- cleanup previous run
local env = (getgenv and getgenv()) or _G
if env.AGRNG_Stop then pcall(env.AGRNG_Stop) end
local guiParent = (gethui and gethui()) or game:GetService("CoreGui")

-- ---------- state ----------
local alive = true
local busy = false
local robinAuto, claimAuto = CONFIG.Robin.AutoStart, false
local antiAfk, autoReconnect = true, false
local afkInterval = CONFIG.AntiAfkJumpSeconds
local nextRobinRun, nextClaim = os.time() + CONFIG.Robin.FirstRunDelay, 0
local fishSpot, robinSpot, arcadePos = nil, nil, nil
local arcadeRuns = CONFIG.Arcade.DefaultRuns
local questIcon, questIconInfo = nil, nil
local pickMode = false
local macro, macroRecording, lastStepT = {}, false, 0
local lastDetect = "Quests: not checked yet"
local conns = {}
local updateUI
local abortFlag = false  -- set by the STOP button: makes a running run / macro quit as soon as possible

-- sleep that wakes up early when STOP is pressed
local function sleep(t)
    local t0 = os.clock()
    while os.clock() - t0 < t and not abortFlag and alive do task.wait(0.1) end
end

-- ---------- helpers ----------
local function lower(s) return string.lower(tostring(s or "")) end
local function getRoot() local c = lp.Character return c and c:FindFirstChild("HumanoidRootPart") end

local function notify(text)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", { Title = "Robin Helper", Text = text, Duration = 4 })
    end)
end

local function teleportTo(pos, offset)
    local r = getRoot()
    if r then r.CFrame = CFrame.new(pos + (offset or CONFIG.TeleportOffset)) return true end
    return false
end

local function matches(text, list)
    text = lower(text)
    for _, k in ipairs(list) do if string.find(text, k, 1, true) then return true end end
    return false
end

local function cleanText(s)
    s = lower(s)
    s = string.gsub(s, "<[^>]->", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function fmtVec(v) return v and string.format("%.0f, %.0f, %.0f", v.X, v.Y, v.Z) or "not set" end

-- ---------- persistence ----------
local function saveData()
    if not writefile then return end
    pcall(function()
        local t = { runs = arcadeRuns, icon = questIconInfo }
        if fishSpot then t.fish = { fishSpot.X, fishSpot.Y, fishSpot.Z } end
        if robinSpot then t.robin = { robinSpot.X, robinSpot.Y, robinSpot.Z } end
        writefile(CONFIG.SaveFile, HttpService:JSONEncode(t))
    end)
end
pcall(function()
    if isfile and readfile and isfile(CONFIG.SaveFile) then
        local t = HttpService:JSONDecode(readfile(CONFIG.SaveFile))
        if t.fish then fishSpot = Vector3.new(t.fish[1], t.fish[2], t.fish[3]) end
        if t.robin then robinSpot = Vector3.new(t.robin[1], t.robin[2], t.robin[3]) end
        if t.icon then questIconInfo = t.icon end
        if t.runs then arcadeRuns = math.clamp(tonumber(t.runs) or 1, 1, 50) end
    end
end)

-- ---------- GUI helpers ----------
local function isShown(obj)
    local cur = obj
    while cur and cur ~= pg do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("ScreenGui") and not cur.Enabled then return false end
        cur = cur.Parent
    end
    return true
end

-- stricter than isShown: ignores hidden/transparent/zero-size/off-screen leftovers
local function reallyShown(o)
    if not isShown(o) then return false end
    local sz = o.AbsoluteSize
    if sz.X < 2 or sz.Y < 2 then return false end
    local cam = workspace.CurrentCamera
    if cam then
        local vp = cam.ViewportSize
        local c = o.AbsolutePosition + sz / 2
        if c.X < 0 or c.Y < -60 or c.X > vp.X or c.Y > vp.Y + 60 then return false end
    end
    local cur = o
    while cur and cur ~= pg do
        if (cur:IsA("TextLabel") or cur:IsA("TextButton")) and cur.TextTransparency >= 0.95 then return false end
        if cur:IsA("CanvasGroup") and cur.GroupTransparency >= 0.95 then return false end
        cur = cur.Parent
    end
    return true
end

local function describe(o)
    local p1 = o.Parent
    local p2 = p1 and p1.Parent
    return { name = o.Name, class = o.ClassName, p1 = p1 and p1.Name or "", p2 = p2 and p2.Name or "" }
end

local function refind(info)
    local best
    for _, d in ipairs(pg:GetDescendants()) do
        if d.Name == info.name and d.ClassName == info.class then
            local p1 = d.Parent
            local p2 = p1 and p1.Parent
            if (p1 and p1.Name or "") == info.p1 and (p2 and p2.Name or "") == info.p2 then
                if isShown(d) then return d end
                best = best or d
            end
        end
    end
    return best
end

local function centerOf(o) return o.AbsolutePosition + o.AbsoluteSize / 2 end

local function rectHas(g, p)
    local a, s = g.AbsolutePosition, g.AbsoluteSize
    return p.X >= a.X and p.X <= a.X + s.X and p.Y >= a.Y and p.Y <= a.Y + s.Y
end

-- find the object that actually receives the click for a piece of text
local function resolveClickable(o)
    if o:IsA("GuiButton") then return o end
    local a = o:FindFirstAncestorWhichIsA("GuiButton")
    if a then return a end
    -- a separate (often transparent) button laid over the label: smallest visible button containing the label center
    local c = centerOf(o)
    local best, bestArea
    local cur, n = o.Parent, 0
    while cur and cur ~= pg and n < 3 do
        for _, d in ipairs(cur:GetDescendants()) do
            if d:IsA("GuiButton") and rectHas(d, c) and isShown(d) then
                local area = d.AbsoluteSize.X * d.AbsoluteSize.Y
                if not bestArea or area < bestArea then best, bestArea = d, area end
            end
        end
        if best then return best end
        cur = cur.Parent
        n = n + 1
    end
    return o
end

-- ---------- clicking (quest panel only - bounties are accepted through remotes) ----------
local function fireSignals(b)
    local fired = 0
    if not b:IsA("GuiButton") then return 0 end
    for _, name in ipairs({ "MouseButton1Down", "MouseButton1Click", "MouseButton1Up", "Activated" }) do
        pcall(function()
            local sig = b[name]
            if getconnections then
                for _, c in ipairs(getconnections(sig)) do
                    pcall(function() c:Fire() end)
                    fired = fired + 1
                end
            elseif firesignal then
                firesignal(sig)
                fired = fired + 1
            end
        end)
    end
    return fired
end

local function vimTap(o, withInset)
    if not VIM then return 0 end
    pcall(function()
        local pos = centerOf(o)
        if withInset then pos = pos + GuiService:GetGuiInset() end
        VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
        task.wait(0.07)
        VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
    end)
    return 1
end

local function pressButton(b)
    b = resolveClickable(b)
    local n = fireSignals(b)
    if n == 0 and CONFIG.VirtualClickFallback then vimTap(b, true) end
    return 1
end

local function pressTarget(o)
    if o:IsA("GuiButton") then return pressButton(o) end
    vimTap(o, true)
    return 1
end

-- ---------- finding buttons ----------
-- visible buttons whose own text / inner label text matches. scopeSet (optional) limits to given labels.
local function findButtons(keywords, exact, exclude, scopeSet)
    local out, seen = {}, {}
    for _, d in ipairs(pg:GetDescendants()) do
        if (d:IsA("TextButton") or d:IsA("TextLabel")) and ((not scopeSet) or scopeSet[d]) then
            local t = cleanText(d.Text)
            if t ~= "" and #t < 40 then
                local hit = false
                for _, k in ipairs(keywords) do
                    if (exact and t == k) or ((not exact) and string.find(t, k, 1, true)) then hit = true break end
                end
                if hit and exclude then
                    for _, x in ipairs(exclude) do
                        if string.find(t, x, 1, true) then hit = false break end
                    end
                end
                if hit and reallyShown(d) then
                    local btn = resolveClickable(d)
                    if btn and not seen[btn] and isShown(btn) then
                        seen[btn] = true
                        out[#out + 1] = btn
                    end
                end
            end
        end
    end
    return out
end

local function pressByText(keywords, exact, exclude, scopeSet)
    local btns = findButtons(keywords, exact, exclude, scopeSet)
    for _, b in ipairs(btns) do
        pressButton(b)
        task.wait(0.2)
    end
    return #btns
end

local function textSet()
    local s = {}
    for _, d in ipairs(pg:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and isShown(d) then s[d] = true end
    end
    return s
end

local function diffSince(before)
    local out, n = {}, 0
    for d in pairs(textSet()) do
        if not before[d] then out[d] = true n = n + 1 end
    end
    return out, n
end

local function detect(scopeSet)
    local fish, arcade = false, false
    for _, d in ipairs(pg:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and ((not scopeSet) or scopeSet[d]) and isShown(d) then
            local t = cleanText(d.Text)
            if t ~= "" and #t < 80 then
                if matches(t, CONFIG.FishKeywords) then fish = true end
                if matches(t, CONFIG.ArcadeKeywords) then arcade = true end
            end
        end
    end
    return fish, arcade
end

local function topButtonAt(pos)
    local ok, hits = pcall(function() return pg:GetGuiObjectsAtPosition(pos.X, pos.Y) end)
    if not ok then return nil end
    for _, h in ipairs(hits) do
        if h:IsA("GuiButton") then return h end
        local a = h:FindFirstAncestorWhichIsA("GuiButton")
        if a then return a end
    end
    return nil
end

local function topInteractiveAt(pos)
    local b = topButtonAt(pos)
    if b then return b end
    local ok, hits = pcall(function() return pg:GetGuiObjectsAtPosition(pos.X, pos.Y) end)
    if not ok then return nil end
    for _, h in ipairs(hits) do
        local root = h:FindFirstAncestorOfClass("ScreenGui")
        if not (root and root.Name == "TouchGui") then return h end
    end
    return nil
end

local function dumpUI()
    local lines = {}
    for _, d in ipairs(pg:GetDescendants()) do
        if isShown(d) then
            if (d:IsA("TextButton") or d:IsA("TextLabel")) and d.Text ~= "" then
                lines[#lines + 1] = ("%s | %q | %s | size %dx%d | txtT %.2f"):format(d.ClassName, d.Text, d:GetFullName(), d.AbsoluteSize.X, d.AbsoluteSize.Y, d.TextTransparency)
            elseif d:IsA("ImageButton") then
                lines[#lines + 1] = ("ImageButton | %s | %s"):format(d.Name, d:GetFullName())
            end
        end
        if #lines >= 250 then break end
    end
    local out = table.concat(lines, "\n")
    if setclipboard then
        pcall(setclipboard, out)
        notify(("UI dump copied to clipboard (%d lines)"):format(#lines))
    else
        print(out)
        notify(("UI dump printed to console (%d lines)"):format(#lines))
    end
end

local function emit(out, label)
    if setclipboard then
        pcall(setclipboard, out)
        notify(label .. " copied to clipboard")
    else
        print(out)
        notify(label .. " printed to console")
    end
end

-- ---------- quest icon ----------
local function setQuestIcon(btn)
    questIcon = btn
    questIconInfo = describe(btn)
    saveData()
end

local function getQuestIcon()
    if questIcon and questIcon:IsDescendantOf(pg) then return questIcon end
    if questIconInfo then
        local o = refind(questIconInfo)
        if o then questIcon = o return o end
    end
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("GuiButton") and (matches(d.Name, CONFIG.QuestIconNames) or (d.Parent and matches(d.Parent.Name, CONFIG.QuestIconNames))) and isShown(d) then
            questIcon = d
            return d
        end
    end
    return nil
end

-- the quest window: the smallest container that holds the "QUESTS" title and a Claim button
local function isClaimText(t)
    return string.sub(t, 1, 5) == "claim" and not string.find(t, "claimed", 1, true)
end

local function findQuestPanel()
    local title
    for _, d in ipairs(pg:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and cleanText(d.Text) == "quests" and reallyShown(d) then
            title = d
            break
        end
    end
    if not title then return nil end
    local cur = title.Parent
    while cur and cur ~= pg do
        for _, d in ipairs(cur:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and reallyShown(d) then
                local t = cleanText(d.Text)
                if t ~= "" and #t < 30 and isClaimText(t) then return cur end
            end
        end
        cur = cur.Parent
    end
    return title:FindFirstAncestorOfClass("ScreenGui") or title.Parent
end

local function panelScope(root)
    local sc = {}
    if not (root and root.Parent) then return sc end
    for _, d in ipairs(root:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and isShown(d) then sc[d] = true end
    end
    return sc
end

local function panelSig(root)
    local t = {}
    for d in pairs(panelScope(root)) do t[#t + 1] = d.Text end
    table.sort(t)
    return table.concat(t, "|")
end

-- ---- only press Claim buttons that are really ready ----
local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }
local function parseNum(n, suf)
    n = string.gsub(n, ",", "")
    local v = tonumber(n)
    if not v then return nil end
    return v * (SUFFIX[suf] or 1)
end

-- "3/10", "1,200 / 5k", "50m/100m" -> current, max (nil if the text has no progress)
local function progressOf(t)
    if #t > 40 then return nil end
    local a, sa, b, sb = string.match(t, "([%d%.,]+)%s*([kmbt]?)%s*/%s*([%d%.,]+)%s*([kmbt]?)")
    if not a then return nil end
    local cur, max = parseNum(a, sa), parseNum(b, sb)
    if cur and max and max > 0 then return cur, max end
    return nil
end

-- the label must really BE a claim button text (not a quest description like "Collect 10 coins")
local function isClaimLabel(t)
    if #t > 20 then return false end
    return isClaimText(t) or t == "collect" or t == "collect!" or t == "collect reward"
end

local function looksDisabled(btn, label)
    if btn:IsA("GuiButton") then
        if btn.Active == false then return true end
        local ok, inter = pcall(function() return btn.Interactable end)
        if ok and inter == false then return true end
    end
    if label and label.TextTransparency >= 0.4 then return true end -- greyed-out text
    return false
end

-- progress (cur, max) of the quest row this button belongs to, or nil if it can't be told
local function rowProgress(btn, root)
    local cur, levels = btn.Parent, 0
    local bestCur, bestMax
    while cur and cur ~= root and cur ~= pg and levels < 5 do
        local n, otherClaims, fc, fm = 0, 0, nil, nil
        for _, d in ipairs(cur:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and isShown(d) then
                local t = cleanText(d.Text)
                if isClaimLabel(t) and resolveClickable(d) ~= btn then otherClaims = otherClaims + 1 end
                local c, m = progressOf(t)
                if c then n = n + 1 fc, fm = c, m end
            end
        end
        -- stop growing once the container covers more than one quest row
        if n > 1 or otherClaims > 0 then break end
        if n == 1 then bestCur, bestMax = fc, fm end
        cur = cur.Parent
        levels = levels + 1
    end
    return bestCur, bestMax
end

local function findClaimButtons(root)
    local out, seen = {}, {}
    for d in pairs(panelScope(root)) do
        local t = cleanText(d.Text)
        if isClaimLabel(t) and reallyShown(d) then
            local btn = resolveClickable(d)
            if btn and btn:IsA("GuiButton") and not seen[btn] and isShown(btn) then
                seen[btn] = true
                local ready = not looksDisabled(btn, d)
                if ready then
                    local c, m = rowProgress(btn, root)
                    if c and c < m then ready = false end -- e.g. 3/10: not finished yet
                end
                if ready then out[#out + 1] = btn end
            end
        end
    end
    return out
end

-- open the quest page, claim everything claimable, read which quests are active, close the page again
-- returns ok, claimRounds, fishActive, arcadeActive
local function claimSweep()
    local icon = getQuestIcon()
    if not icon then
        lastDetect = "Quests: quest icon not found (use Pick Quest Icon)"
        return false, 0, false, false
    end

    -- open the page (or reuse it if it's already open)
    local root = findQuestPanel()
    local openedByUs = false
    if not root then
        for _ = 1, 2 do
            pressButton(icon)
            local t0 = os.clock()
            while os.clock() - t0 < 3 do
                task.wait(0.25)
                root = findQuestPanel()
                if root then break end
            end
            if root then openedByUs = true break end
        end
    end
    if not root then
        lastDetect = "Quests: page did not open"
        return false, 0, false, false
    end
    task.wait(0.6) -- let the quest list finish loading

    -- claim: press Claim, and keep going for as long as pressing it changes the page
    local claimed, pressedTotal = 0, 0
    local lastSig = panelSig(root)
    for _ = 1, 5 do
        local btns = findClaimButtons(root)
        if #btns == 0 then break end
        pressedTotal = pressedTotal + #btns
        for _, b in ipairs(btns) do
            pressButton(b)
            task.wait(0.3)
        end
        task.wait(0.9)
        root = findQuestPanel() or root
        local sig = panelSig(root)
        if sig == lastSig then break end -- nothing changed: nothing (more) to claim
        claimed = claimed + 1
        lastSig = sig
    end

    -- which quests are still active?
    local fish, arcade = detect(panelScope(root))

    -- close the page again (only if we opened it)
    if openedByUs then
        local x = findButtons({ "x" }, true, nil, panelScope(root))
        if #x > 0 then pressButton(x[1]) else pressButton(icon) end
        task.wait(0.5)
        if findQuestPanel() then
            pressButton(icon)
            task.wait(0.4)
        end
    end

    lastDetect = ("Quests: fishing %s | arcade %s | claimed %d"):format(fish and "YES" or "no", arcade and "YES" or "no", pressedTotal)
    return true, claimed, fish, arcade
end

-- ---------- Robin ----------
local function promptPos(inst)
    local cur = inst
    while cur and cur ~= workspace do
        if cur:IsA("Attachment") then return cur.WorldPosition end
        if cur:IsA("BasePart") then return cur.Position end
        if cur:IsA("Model") then
            local ok, p = pcall(function() return cur:GetPivot().Position end)
            if ok then return p end
        end
        cur = cur.Parent
    end
    return nil
end

local function fireObj(inst)
    if inst:IsA("ProximityPrompt") then
        pcall(function()
            inst.HoldDuration = 0
            inst.RequiresLineOfSight = false
            inst.MaxActivationDistance = math.max(inst.MaxActivationDistance, 20)
        end)
        if fireproximityprompt then
            pcall(fireproximityprompt, inst)
        else
            pcall(function() inst:InputHoldBegin() task.wait(0.1) inst:InputHoldEnd() end)
        end
    elseif inst:IsA("ClickDetector") then
        if fireclickdetector then pcall(fireclickdetector, inst) end
    end
end

local function findRobin()
    local needle = CONFIG.Robin.NpcName
    local best
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") or d:IsA("ClickDetector") then
            local holder = d.Parent
            if holder then
                local model = holder:IsA("Model") and holder or holder:FindFirstAncestorOfClass("Model")
                local hit = string.find(lower(model and model.Name or holder.Name), needle, 1, true) ~= nil
                if not hit and d:IsA("ProximityPrompt") then
                    hit = string.find(lower(d.ObjectText), needle, 1, true) ~= nil
                end
                if hit then
                    local pos = promptPos(d)
                    if pos then
                        local cand = { inst = d, pos = pos }
                        if d:IsA("ProximityPrompt") and string.find(lower(d.ActionText), "talk", 1, true) then
                            return cand
                        end
                        best = best or cand
                    end
                end
            end
        end
    end
    return best
end

-- ---- direct remote method (found with Remote Spy): board = RobinQuest:GetBountyBoard, accept = RobinQuest:Accept ----
local function getRemote(name)
    local rs = game:GetService("ReplicatedStorage")
    local folder = rs:FindFirstChild("Remotes")
    local r = folder and folder:FindFirstChild(name)
    if r then return r end
    for _, d in ipairs(rs:GetDescendants()) do
        if d.Name == name and (d:IsA("RemoteEvent") or d:IsA("RemoteFunction")) then return d end
    end
    return nil
end

local function invokeTimeout(rf, timeout)
    local done, ok, res = false, false, nil
    task.spawn(function()
        ok, res = pcall(function() return rf:InvokeServer() end)
        done = true
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < timeout do task.wait(0.1) end
    if not done then return false, nil end
    return ok, res
end

local function sigOf(v, d)
    d = d or 0
    if type(v) ~= "table" then return tostring(v) end
    if d > 5 then return "{..}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. sigOf(v[k], d + 1) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local BLOCKED_STATUS = { active = true, accepted = true, inprogress = true, ["in_progress"] = true, ["in progress"] = true,
    completed = true, complete = true, claimed = true, done = true, finished = true }

local function entryBlocked(t)
    if type(t) ~= "table" then return false end
    for k, v in pairs(t) do
        local key = lower(k)
        if type(v) == "boolean" and v and (key == "accepted" or key == "active" or key == "claimed"
            or key == "completed" or key == "complete" or key == "done") then
            return true
        end
        if type(v) == "string" and (key == "status" or key == "state") and BLOCKED_STATUS[lower(v)] then
            return true
        end
    end
    return false
end

-- collect bounty ids ("robin_...") from whatever structure the board has
local function collectBounties(node, out, seen, depth, ignoreBlocked)
    if depth > 6 or type(node) ~= "table" then return end
    local idKeys = { id = true, Id = true, ID = true, questId = true, QuestId = true, bountyId = true, BountyId = true }
    for k, v in pairs(node) do
        if type(k) == "string" and string.sub(k, 1, 6) == "robin_" then
            if not seen[k] and (ignoreBlocked or not entryBlocked(v)) then seen[k] = true out[#out + 1] = k end
        end
        if type(v) == "string" and string.sub(v, 1, 6) == "robin_" and (type(k) == "number" or idKeys[k]) then
            if not seen[v] and (ignoreBlocked or not entryBlocked(node)) then seen[v] = true out[#out + 1] = v end
        elseif type(v) == "table" then
            collectBounties(v, out, seen, depth + 1, ignoreBlocked)
        end
    end
end

-- returns ok, acceptedCount. ok=false means "use the dialog instead"
local function acceptViaRemotes()
    local interact = getRemote("Quest:NPCInteracted")
    local board = getRemote("RobinQuest:GetBountyBoard")
    local accept = getRemote("RobinQuest:Accept")
    if not (board and accept and board:IsA("RemoteFunction") and accept:IsA("RemoteEvent")) then
        notify("Bounty remotes not found (game update?)")
        return false, 0
    end
    if interact and interact:IsA("RemoteEvent") then
        pcall(function() interact:FireServer() end)
        task.wait(0.4)
    end
    local ok1, b1 = invokeTimeout(board, 6)
    if not ok1 then
        notify("Couldn't read the bounty board")
        return false, 0
    end
    local all, avail = {}, {}
    collectBounties(b1, all, {}, 0, true)
    collectBounties(b1, avail, {}, 0, false)
    local understood = #all > 0
    local ids = understood and avail or CONFIG.Robin.KnownBountyIds
    for _, id in ipairs(ids) do
        pcall(function() accept:FireServer(id) end)
        task.wait(0.35)
    end
    task.wait(0.6)
    local accepted = 0
    local ok2, b2 = invokeTimeout(board, 6)
    if ok2 then
        if understood then
            local rem = {}
            collectBounties(b2, rem, {}, 0, false)
            accepted = math.max(0, #avail - #rem)
        else
            accepted = (sigOf(b1) ~= sigOf(b2)) and #ids or 0
        end
    end
    notify(("Bounties: sent %d accept(s), %d accepted"):format(#ids, accepted))
    return true, accepted
end

local function dumpBoard()
    local board = getRemote("RobinQuest:GetBountyBoard")
    if not (board and board:IsA("RemoteFunction")) then notify("Board remote not found") return end
    local ok, res = invokeTimeout(board, 6)
    if not ok then notify("Couldn't read the board") return end
    local out = sigOf(res)
    emit(out, "Bounty board")
end

-- go to Robin (if she is loaded in) and accept every available bounty through the game's remotes
local function robinTalk()
    local r = findRobin()
    if not r and robinSpot then
        teleportTo(robinSpot, Vector3.new(0, 3, 0))
        task.wait(2)
        r = findRobin()
    end
    if r then
        teleportTo(r.pos)
        task.wait(0.6)
    else
        notify("Robin isn't loaded in - trying the bounty remotes anyway")
    end
    return acceptViaRemotes()
end

-- ---------- arcade macro ----------
local function pushStep(step)
    if not macroRecording then return end
    local now = os.clock()
    step.dt = (#macro == 0) and 0.5 or (now - lastStepT)
    lastStepT = now
    macro[#macro + 1] = step
    if #macro > CONFIG.Arcade.MaxSteps then table.remove(macro, 1) end
    if updateUI then updateUI() end
end

local spyOn, spyLog = false, {}
local function ser(v, d)
    d = d or 0
    local t = typeof(v)
    if t == "string" then return string.format("%q", v) end
    if t == "Instance" then return "Instance(" .. v:GetFullName() .. ")" end
    if t == "table" then
        if d > 2 then return "{...}" end
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 12 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = "[" .. ser(k, d + 1) .. "]=" .. ser(val, d + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function addRemoteStep(remote, method, args)
    if spyOn and #spyLog < 150 and not matches(remote.Name, { "ping", "heartbeat", "camera", "position", "walk", "sprint", "roll" }) then
        local parts = {}
        for i = 1, args.n do parts[i] = ser(args[i]) end
        local line = ("%s %s(%s)"):format(remote:GetFullName(), method, table.concat(parts, ", "))
        if spyLog[#spyLog] ~= line then spyLog[#spyLog + 1] = line end
    end
    if not macroRecording then return end
    if matches(remote.Name, CONFIG.Arcade.IgnoreRemotes) then return end
    pushStep({ kind = "remote", remote = remote, method = method, args = args })
end

if not env.AGRNG_HookInstalled then
    pcall(function()
        if hookmetamethod and getnamecallmethod then
            local ncc = newcclosure or function(f) return f end
            local old
            old = hookmetamethod(game, "__namecall", ncc(function(self, ...)
                local cb = env.AGRNG_RemoteCb
                if cb then
                    local m = getnamecallmethod()
                    if (m == "FireServer" or m == "InvokeServer") and typeof(self) == "Instance"
                        and not (checkcaller and checkcaller()) then
                        task.defer(cb, self, m, table.pack(...))
                    end
                end
                return old(self, ...)
            end))
            env.AGRNG_HookInstalled = true
        end
    end)
end
env.AGRNG_RemoteCb = addRemoteStep
local hookOk = env.AGRNG_HookInstalled == true

table.insert(conns, PPS.PromptTriggered:Connect(function(prompt, plr)
    if macroRecording and plr == lp then pushStep({ kind = "prompt", prompt = prompt }) end
end))

-- forward declaration: steps loaded from a config keep their raw data (s.enc) until the objects they point to exist.
-- resolveStep(s, wait) is defined further down (it needs the path/decode helpers).
local resolveStep

local function runStep(s)
    if s.enc then
        -- not resolved yet (object wasn't loaded when the config was loaded): try again now, wait a few seconds
        if not (resolveStep and resolveStep(s, 3)) then return end
    end
    if s.kind == "remote" then
        if not (s.remote and s.remote.Parent) then return end
        if s.method == "FireServer" then
            pcall(function() s.remote:FireServer(table.unpack(s.args, 1, s.args.n)) end)
        else
            task.spawn(function() pcall(function() s.remote:InvokeServer(table.unpack(s.args, 1, s.args.n)) end) end)
        end
    elseif s.kind == "prompt" then
        if s.prompt and s.prompt.Parent then
            local pos = promptPos(s.prompt)
            if pos then teleportTo(pos) task.wait(0.2) end
            fireObj(s.prompt)
        end
    elseif s.kind == "gui" then
        local o = (s.obj and s.obj:IsDescendantOf(pg)) and s.obj or (s.info and refind(s.info))
        if o then pressTarget(o) end
    end
end

local function playMacro(times)
    if #macro == 0 then return 0 end
    local steps = 0
    for _ = 1, times do
        if not alive or abortFlag then break end
        if arcadePos then teleportTo(arcadePos, Vector3.new(0, 3, 0)) sleep(0.5) end
        for _, s in ipairs(macro) do
            if not alive or abortFlag then break end
            sleep(math.clamp(s.dt, 0.05, 6))
            if abortFlag then break end
            runStep(s)
            steps = steps + 1
        end
        sleep(CONFIG.Arcade.BetweenRuns)
    end
    return steps
end

-- ---------- full run ----------
local function robinRun()
    if busy then notify("Busy - try again in a moment") return end
    busy = true
    abortFlag = false
    local root = getRoot()
    local origin = root and root.CFrame
    local stayAtFishing = false
    local ok, err = pcall(function()
        local _, accepted = robinTalk()
        if abortFlag then return end

        -- read the quest page, claim whatever is finished
        local _, _, fish, arcade = claimSweep()
        if abortFlag then return end

        local steps = 0
        if arcade then
            if #macro > 0 then
                steps = playMacro(arcadeRuns)
                if abortFlag then return end
                task.wait(1)
                local ok2, _, f2 = claimSweep()
                if abortFlag then return end
                if ok2 then fish = f2 end
            else
                notify("Arcade quest active but no macro recorded")
            end
        end

        if fish then
            if fishSpot then
                teleportTo(fishSpot, Vector3.new(0, 3, 0))
                stayAtFishing = true
            else
                notify("Fishing quest active - mark a fishing spot first")
            end
        end

        notify(("Run done. Accepted %d | macro steps %d | %s"):format(
            accepted or 0, steps, stayAtFishing and "at fishing spot" or "back home"))
    end)
    if not ok then notify("Run error: " .. tostring(err)) end
    if abortFlag then notify("Run stopped") end
    if (not stayAtFishing) and (not abortFlag) and CONFIG.ReturnAfterRun and origin and getRoot() then getRoot().CFrame = origin end
    busy = false
end

-- ---------- anti-AFK (jump) ----------
-- makes your character jump every `afkInterval` seconds (set CONFIG.AntiAfkJumpSeconds at the top, saved in configs)
local function afkJump()
    local c = lp.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health > 0 then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
end

-- ---------- auto reconnect ----------
local reconnecting = false

local function queueReload()
    local q = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
    if q and CONFIG.ScriptUrl ~= "" then
        pcall(q, ('task.wait(3) loadstring(game:HttpGet("%s"))()'):format(CONFIG.ScriptUrl))
        return true
    end
    return false
end

local function disconnected()
    local ok, res = pcall(function()
        local prompt = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
        local overlay = prompt and prompt:FindFirstChild("promptOverlay")
        return overlay ~= nil and overlay:FindFirstChild("ErrorPrompt") ~= nil
    end)
    if ok and res then return true end
    local ok2, msg = pcall(function() return GuiService:GetErrorMessage() end)
    return ok2 and type(msg) == "string" and msg ~= ""
end

local function rejoin()
    if reconnecting then return end
    reconnecting = true
    task.spawn(function()
        notify("Disconnected - rejoining in 5s...")
        task.wait(5)
        queueReload()
        for _ = 1, 10 do
            if not alive then break end
            pcall(function() TeleportService:Teleport(game.PlaceId, lp) end)
            task.wait(12)
        end
        reconnecting = false
    end)
end

pcall(function()
    table.insert(conns, GuiService.ErrorMessageChanged:Connect(function()
        if autoReconnect and alive and disconnected() then rejoin() end
    end))
end)

-- ---------- config storage ----------
local MEM = env.AGRNG_Mem or {}
env.AGRNG_Mem = MEM
local hasFS = (writefile ~= nil) and (readfile ~= nil) and (isfile ~= nil)

local function fileOf(key) return CONFIG.FilePrefix .. key .. ".json" end

-- returns true if the data really is on disk. If the executor can't write (or the write didn't stick),
-- the data is kept in memory for this session instead and false is returned.
local function sWrite(key, str)
    if hasFS then
        local ok = pcall(writefile, fileOf(key), str)
        if ok then
            local rok, back = pcall(readfile, fileOf(key))
            if rok and back == str then
                MEM[key] = nil
                return true
            end
        end
    end
    MEM[key] = str
    return false
end

local function sRead(key)
    if MEM[key] then return MEM[key] end -- only set when the disk write failed / no file access
    if hasFS then
        local ok, r = pcall(function()
            if isfile(fileOf(key)) then return readfile(fileOf(key)) end
            return nil
        end)
        if ok and r and r ~= "" then return r end
    end
    return nil
end

local function sDelete(key)
    MEM[key] = nil
    if hasFS then
        if delfile then pcall(delfile, fileOf(key)) else pcall(writefile, fileOf(key), "") end
    end
end

local function cleanName(n)
    n = tostring(n or "")
    n = string.gsub(n, "[^%w _%-]", "")
    n = string.gsub(n, "^%s+", "")
    n = string.gsub(n, "%s+$", "")
    return string.sub(n, 1, 24)
end

local function loadIndex()
    local raw = sRead("index")
    if not raw then return {} end
    local ok, t = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok and type(t) == "table" then return t end
    return {}
end
local function saveIndex(t) sWrite("index", HttpService:JSONEncode(t)) end
local function getAutoload() return sRead("autoload") end
local function setAutoload(name)
    if name then sWrite("autoload", name) else sDelete("autoload") end
end

-- ---------- config (de)serialization ----------
-- A path is a list of segments. A segment is the object's name, or {name, n} when several siblings share that
-- name (n = which one). Old saves that only contain plain names still load.
local function pathOf(inst)
    local t, cur = {}, inst
    while cur and cur ~= game do
        local parent = cur.Parent
        local seg = cur.Name
        if parent then
            local count, idx = 0, 0
            for _, c in ipairs(parent:GetChildren()) do
                if c.Name == cur.Name then
                    count = count + 1
                    if c == cur then idx = count end
                end
            end
            if count > 1 then seg = { cur.Name, idx } end
        end
        table.insert(t, 1, seg)
        cur = parent
    end
    if cur ~= game then return nil end
    return t
end

local function findChildSeg(parent, seg)
    if type(seg) == "table" then
        local count = 0
        for _, c in ipairs(parent:GetChildren()) do
            if c.Name == seg[1] then
                count = count + 1
                if count == seg[2] then return c end
            end
        end
        -- the exact sibling index may differ between servers: fall back to the first one with that name
        return parent:FindFirstChild(seg[1])
    end
    return parent:FindFirstChild(seg)
end

-- wait (seconds, optional) lets objects that haven't replicated/spawned yet show up
local function resolvePath(path, wait)
    if type(path) ~= "table" then return nil end
    local cur = game
    for _, seg in ipairs(path) do
        local o = findChildSeg(cur, seg)
        if not o and wait and wait > 0 then
            local t0 = os.clock()
            while not o and os.clock() - t0 < wait do
                task.wait(0.2)
                o = findChildSeg(cur, seg)
            end
        end
        if not o then return nil end
        cur = o
    end
    return cur
end

local MAX_DEPTH, MAX_ENTRIES = 8, 500

local function encodeValue(v, depth)
    local t = typeof(v)
    if t == "nil" then return { t = "z" } end
    if t == "boolean" then return { t = "b", v = v } end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        return { t = "n", v = v }
    end
    if t == "string" then return { t = "s", v = v } end
    if t == "Instance" then
        local p = pathOf(v)
        if p then return { t = "i", p = p } end
        return nil
    end
    if t == "Vector3" then return { t = "v3", x = v.X, y = v.Y, z = v.Z } end
    if t == "Vector2" then return { t = "v2", x = v.X, y = v.Y } end
    if t == "Color3" then return { t = "c3", r = v.R, g = v.G, b = v.B } end
    if t == "CFrame" then return { t = "cf", c = { v:GetComponents() } } end
    if t == "UDim2" then return { t = "u2", a = v.X.Scale, b = v.X.Offset, c = v.Y.Scale, d = v.Y.Offset } end
    if t == "UDim" then return { t = "u1", s = v.Scale, o = v.Offset } end
    if t == "BrickColor" then return { t = "bc", n = v.Name } end
    if t == "EnumItem" then return { t = "en", et = tostring(v.EnumType), n = v.Name } end
    if t == "table" and depth < MAX_DEPTH then
        local entries, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > MAX_ENTRIES then return nil end
            local ek, ev = encodeValue(k, depth + 1), encodeValue(val, depth + 1)
            if not ek or not ev then return nil end
            entries[#entries + 1] = { k = ek, v = ev }
        end
        return { t = "t", e = entries }
    end
    return nil
end

local function decodeValue(e, wait)
    if type(e) ~= "table" then return nil, false end
    local t = e.t
    if t == "z" then return nil, true end
    if t == "b" or t == "n" or t == "s" then return e.v, true end
    if t == "i" then
        local o = resolvePath(e.p, wait)
        return o, o ~= nil
    end
    if t == "v3" then return Vector3.new(e.x, e.y, e.z), true end
    if t == "v2" then return Vector2.new(e.x, e.y), true end
    if t == "c3" then return Color3.new(e.r, e.g, e.b), true end
    if t == "cf" then return CFrame.new(table.unpack(e.c)), true end
    if t == "u2" then return UDim2.new(e.a, e.b, e.c, e.d), true end
    if t == "u1" then return UDim.new(e.s, e.o), true end
    if t == "bc" then
        local ok, r = pcall(BrickColor.new, e.n)
        return r, ok
    end
    if t == "en" then
        local ok, r = pcall(function() return Enum[e.et][e.n] end)
        return r, ok and r ~= nil
    end
    if t == "t" then
        local out = {}
        for _, ent in ipairs(e.e) do
            local k, okk = decodeValue(ent.k, wait)
            local v, okv = decodeValue(ent.v, wait)
            if not (okk and okv) or k == nil then return nil, false end
            out[k] = v
        end
        return out, true
    end
    return nil, false
end

-- encodes the macro. returns list, skippedCount
local function encodeMacro()
    local out, skipped = {}, 0
    for _, s in ipairs(macro) do
        if s.enc then
            -- loaded from a config but not resolved yet: keep the original data so nothing is lost on re-save
            out[#out + 1] = s.enc
        else
            local e = { kind = s.kind, dt = s.dt }
            local ok = true
            if s.kind == "remote" then
                local p = s.remote and pathOf(s.remote)
                if not p then
                    ok = false
                else
                    e.path, e.method, e.n, e.args = p, s.method, s.args.n, {}
                    for i = 1, s.args.n do
                        local ev = encodeValue(s.args[i], 0)
                        if not ev then ok = false break end
                        e.args[i] = ev
                    end
                end
            elseif s.kind == "prompt" then
                local p = s.prompt and pathOf(s.prompt)
                if p then e.path = p else ok = false end
            elseif s.kind == "gui" then
                e.info = s.info
            else
                ok = false
            end
            if ok then out[#out + 1] = e else skipped = skipped + 1 end
        end
    end
    return out, skipped
end

-- turns a raw saved step into a live one. returns true when everything it points to exists
resolveStep = function(s, wait)
    local e = s.enc
    if not e then return true end
    if s.kind == "remote" then
        local r = resolvePath(e.path, wait)
        if not (r and type(e.args) == "table") then return false end
        local args = { n = e.n or #e.args }
        for i = 1, args.n do
            local v, okv = decodeValue(e.args[i], wait)
            if not okv then return false end
            args[i] = v
        end
        s.remote, s.method, s.args = r, e.method, args
    elseif s.kind == "prompt" then
        local pr = resolvePath(e.path, wait)
        if not pr then return false end
        s.prompt = pr
    elseif s.kind == "gui" then
        s.info = e.info
    end
    s.enc = nil
    return true
end

-- returns malformedCount, pendingCount (pending = kept, will resolve when played)
local function decodeMacro(list)
    table.clear(macro)
    local bad, pending = 0, 0
    for _, e in ipairs(list or {}) do
        local valid = type(e) == "table"
            and ((e.kind == "remote" and type(e.path) == "table" and type(e.args) == "table")
              or (e.kind == "prompt" and type(e.path) == "table")
              or (e.kind == "gui" and type(e.info) == "table"))
        if valid then
            local s = { kind = e.kind, dt = tonumber(e.dt) or 0.3, enc = e }
            if not resolveStep(s, 0) then pending = pending + 1 end
            macro[#macro + 1] = s
        else
            bad = bad + 1
        end
    end
    return bad, pending
end

local function v3t(v) return v and { v.X, v.Y, v.Z } or nil end
local function t3(a) return (type(a) == "table" and #a == 3) and Vector3.new(a[1], a[2], a[3]) or nil end

local currentConfig = nil

local function buildConfig()
    local m, skipped = encodeMacro()
    return {
        v = 2,
        settings = {
            runs = arcadeRuns, robinAuto = robinAuto, claimAuto = claimAuto,
            antiAfk = antiAfk, jumpEvery = afkInterval, autoReconnect = autoReconnect,
            fish = v3t(fishSpot), robin = v3t(robinSpot), arcade = v3t(arcadePos), icon = questIconInfo,
        },
        macro = m,
    }, skipped
end

local function applyConfig(t)
    local st = t.settings or {}
    macroRecording = false
    arcadeRuns = math.clamp(tonumber(st.runs) or 1, 1, 50)
    fishSpot, robinSpot, arcadePos = t3(st.fish), t3(st.robin), t3(st.arcade)
    questIconInfo = (type(st.icon) == "table") and st.icon or nil
    questIcon = nil
    robinAuto = st.robinAuto == true
    claimAuto = st.claimAuto == true
    if robinAuto then nextRobinRun = os.time() + CONFIG.Robin.FirstRunDelay end
    if claimAuto then nextClaim = os.time() + 10 end
    antiAfk = st.antiAfk ~= false
    afkInterval = math.clamp(tonumber(st.jumpEvery) or CONFIG.AntiAfkJumpSeconds, 5, 3600)
    autoReconnect = st.autoReconnect == true
    if autoReconnect then queueReload() end
    local bad, pending = decodeMacro(t.macro)
    saveData()
    if updateUI then updateUI() end
    return bad, pending
end

local function saveConfig(name)
    name = cleanName(name)
    if name == "" then return false, "Type a config name first" end
    if macroRecording then
        macroRecording = false
        notify("Recording stopped so the macro could be saved")
    end
    local cfg, skipped = buildConfig()
    local ok, json = pcall(function() return HttpService:JSONEncode(cfg) end)
    if not ok then return false, "Couldn't encode the macro (unsupported data)" end
    local onDisk = sWrite("cfg_" .. name, json)
    local idx, found = loadIndex(), false
    for _, n in ipairs(idx) do if n == name then found = true end end
    if not found then
        idx[#idx + 1] = name
        saveIndex(idx)
    end
    currentConfig = name
    local notes = {}
    notes[#notes + 1] = ("%d macro step(s) saved"):format(#cfg.macro)
    if skipped > 0 then notes[#notes + 1] = skipped .. " couldn't be saved (objects without a path / unsupported data)" end
    if not onDisk then notes[#notes + 1] = "WARNING: couldn't write the file, kept in memory only" end
    return true, table.concat(notes, ", "), name
end

local function loadConfig(name)
    local raw = sRead("cfg_" .. tostring(name))
    if not raw then return false, "Config not found" end
    local ok, t = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(t) ~= "table" then return false, "Config file is corrupt" end
    local bad, pending = applyConfig(t)
    currentConfig = name
    local notes = { ("%d macro step(s)"):format(#macro) }
    if pending > 0 then notes[#notes + 1] = pending .. " will be resolved when the macro plays (objects not loaded yet)" end
    if bad > 0 then notes[#notes + 1] = bad .. " invalid step(s) skipped" end
    return true, table.concat(notes, ", ")
end

local function deleteConfig(name)
    sDelete("cfg_" .. name)
    local idx = loadIndex()
    for i = #idx, 1, -1 do
        if idx[i] == name then table.remove(idx, i) end
    end
    saveIndex(idx)
    if getAutoload() == name then setAutoload(nil) end
    if currentConfig == name then currentConfig = nil end
end

-- ---------- UI ----------
local gui = Instance.new("ScreenGui")
gui.Name = "AGRNG_Helper"
gui.ResetOnSpawn = false
gui.Parent = guiParent

env.AGRNG_Stop = function()
    alive, macroRecording, robinAuto, claimAuto, pickMode = false, false, false, false, false
    env.AGRNG_RemoteCb = nil
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(function() gui:Destroy() end)
end

local PANEL_H = 380
local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(300, PANEL_H)
main.Position = UDim2.new(0, 70, 0, 10)
main.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
main.BorderSizePixel = 0
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

local ui = Instance.new("UIScale", main)
local function fitScale()
    local cam = workspace.CurrentCamera
    if cam then ui.Scale = math.clamp((cam.ViewportSize.Y - 20) / PANEL_H, 0.5, 1) end
end
fitScale()
pcall(function() table.insert(conns, workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale)) end)

local function makeDraggable(handle, target, scaleInst, onTap)
    local dragging, moved, ds, sp = false, false, nil, nil
    table.insert(conns, handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, moved, ds, sp = true, false, i.Position, target.Position
        end
    end))
    table.insert(conns, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - ds
            if d.Magnitude > 6 then moved = true end
            if moved then
                local k = scaleInst and scaleInst.Scale or 1
                target.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X / k, sp.Y.Scale, sp.Y.Offset + d.Y / k)
            end
        end
    end))
    table.insert(conns, UIS.InputEnded:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            if not moved and onTap then onTap() end
        end
    end))
end

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.fromOffset(300, 30)
titleBar.BackgroundTransparency = 1
titleBar.Active = true
titleBar.Parent = main
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text = "Robin Bounty Helper"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar
makeDraggable(titleBar, main, ui, nil)

local icon = Instance.new("TextButton")
icon.Size = UDim2.fromOffset(46, 46)
icon.Position = main.Position
icon.BackgroundColor3 = Color3.fromRGB(90, 60, 130)
icon.Text = "RB"
icon.TextColor3 = Color3.new(1, 1, 1)
icon.Font = Enum.Font.GothamBold
icon.TextSize = 16
icon.AutoButtonColor = false
icon.Visible = false
icon.Parent = gui
Instance.new("UICorner", icon).CornerRadius = UDim.new(1, 0)
local iconStroke = Instance.new("UIStroke", icon)
iconStroke.Color = Color3.fromRGB(190, 160, 255)
iconStroke.Thickness = 2
makeDraggable(icon, icon, nil, function()
    icon.Visible = false
    main.Visible = true
end)

local curParent = main
local function makeButton(text, x, y, w, color, cb)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(w, 28)
    b.Position = UDim2.fromOffset(x, y)
    b.BackgroundColor3 = color or Color3.fromRGB(60, 60, 80)
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.Gotham
    b.TextSize = 12
    b.Parent = curParent
    Instance.new("UICorner", b)
    b.MouseButton1Click:Connect(function() cb(b) end)
    return b
end

local function makeLabel(text, x, y, w, h, wrap)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromOffset(w, h)
    l.Position = UDim2.fromOffset(x, y)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = Color3.fromRGB(220, 220, 230)
    l.Font = Enum.Font.Gotham
    l.TextSize = 12
    l.TextWrapped = wrap or false
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Top
    l.Parent = curParent
    return l
end

makeButton("-", 236, 3, 26, Color3.fromRGB(80, 80, 110), function()
    icon.Position = main.Position
    main.Visible = false
    icon.Visible = true
end)
makeButton("X", 266, 3, 26, Color3.fromRGB(170, 60, 60), function() env.AGRNG_Stop() end)

local content = Instance.new("ScrollingFrame")
content.Size = UDim2.fromOffset(300, PANEL_H - 34)
content.Position = UDim2.fromOffset(0, 34)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.ScrollBarThickness = 4
content.CanvasSize = UDim2.fromOffset(0, 900)
content.Parent = main
curParent = content

local GREEN_ON, OFFCOL = Color3.fromRGB(40, 170, 70), Color3.fromRGB(150, 60, 60)
local ORANGE, RED, BLUE = Color3.fromRGB(140, 80, 50), Color3.fromRGB(190, 60, 60), Color3.fromRGB(50, 90, 140)
local cy = 4
local function row(h) local y = cy cy = cy + h return y end
local function setToggle(btn, label, on)
    btn.Text = label .. ": " .. (on and "ON" or "OFF")
    btn.BackgroundColor3 = on and GREEN_ON or OFFCOL
end

local statusLbl = makeLabel("Ready", 10, row(52), 280, 48, true)

makeButton("STOP (auto run + macro)", 10, row(32), 280, RED, function()
    abortFlag = true
    robinAuto, claimAuto = false, false
    macroRecording = false
    notify("Stopped: auto run/claim OFF, running macro/run cancelled")
    updateUI()
end)

makeButton("Run Robin Now", 10, row(32), 280, BLUE, function()
    if robinAuto then nextRobinRun = os.time() + CONFIG.Robin.IntervalSeconds end
    task.spawn(robinRun)
end)

local autoBtn = makeButton("", 10, row(32), 280, OFFCOL, function()
    robinAuto = not robinAuto
    if robinAuto then
        nextRobinRun = os.time()
        notify("Auto Run ON: cycle starts now, then every 30 min")
    else
        notify("Auto Run OFF")
    end
    updateUI()
end)

local claimBtn = makeButton("", 10, row(32), 280, OFFCOL, function()
    claimAuto = not claimAuto
    if claimAuto then nextClaim = os.time() end
    updateUI()
end)

local y = row(32)
local pickBtn = makeButton("Pick Quest Icon", 10, y, 190, nil, function()
    pickMode = not pickMode
    if pickMode then notify("Now tap the quest icon on the left side of the screen") end
    updateUI()
end)
makeButton("Claim Now", 206, y, 84, BLUE, function()
    if busy then notify("Busy") return end
    task.spawn(function()
        busy = true
        local ok, n = pcall(claimSweep)
        busy = false
        if not ok then notify("Claim error") end
        if ok and n == false then notify("Couldn't open the quest page (use Pick Quest Icon)") end
    end)
end)
local iconLbl = makeLabel("", 10, row(22), 280, 18, false)

y = row(32)
makeButton("Mark Fishing Spot", 10, y, 190, nil, function()
    local r = getRoot()
    if r then fishSpot = r.Position saveData() updateUI() notify("Fishing spot marked") end
end)
makeButton("Go", 206, y, 84, nil, function()
    if fishSpot then teleportTo(fishSpot, Vector3.new(0, 3, 0)) else notify("Mark a fishing spot first") end
end)
local fishLbl = makeLabel("", 10, row(24), 280, 18, false)

y = row(32)
local recBtn = makeButton("Record Arcade Macro", 10, y, 190, ORANGE, function()
    if macroRecording then
        macroRecording = false
        notify(("Macro saved: %d steps"):format(#macro))
    else
        if not hookOk then notify("Remote hook unavailable: only clicks/prompts will be recorded") end
        table.clear(macro)
        local r = getRoot()
        arcadePos = r and r.Position or nil
        lastStepT = os.clock()
        macroRecording = true
        notify("Recording. Play ONE arcade mini game, then press Stop.")
    end
    updateUI()
end)
makeButton("Clear", 206, y, 84, nil, function()
    if macroRecording then return end
    table.clear(macro)
    updateUI()
end)
local macroLbl = makeLabel("", 10, row(28), 280, 18, false)

y = row(34)
local runsLbl = makeLabel("", 10, y + 6, 120, 18, false)
makeButton("-", 136, y, 70, nil, function()
    arcadeRuns = math.max(1, arcadeRuns - 1) saveData() updateUI()
end)
makeButton("+", 212, y, 78, nil, function()
    arcadeRuns = math.min(50, arcadeRuns + 1) saveData() updateUI()
end)

makeButton("Test Arcade Macro (1x)", 10, row(32), 280, BLUE, function()
    if busy then notify("Busy") return end
    if #macro == 0 then notify("Record a macro first") return end
    task.spawn(function()
        busy = true
        abortFlag = false
        pcall(playMacro, 1)
        busy = false
    end)
end)

makeButton("Mark Robin Spot (optional)", 10, row(32), 280, nil, function()
    local r = getRoot()
    if r then robinSpot = r.Position saveData() updateUI() notify("Robin spot marked") end
end)

makeButton("Teleport to Robin", 10, row(32), 280, BLUE, function()
    task.spawn(function()
        local r = findRobin()
        if not r and robinSpot then
            -- Robin may be streamed out: go to the marked spot first so she loads in
            teleportTo(robinSpot, Vector3.new(0, 3, 0))
            for _ = 1, 8 do
                task.wait(0.5)
                r = findRobin()
                if r then break end
            end
        end
        if r then
            teleportTo(r.pos)
            notify("Teleported to Robin")
        else
            notify("Robin not found - stand near her and use 'Mark Robin Spot' first")
        end
    end)
end)

local afkBtn = makeButton("", 10, row(32), 280, GREEN_ON, function()
    antiAfk = not antiAfk
    updateUI()
end)
local reconBtn = makeButton("", 10, row(32), 280, OFFCOL, function()
    autoReconnect = not autoReconnect
    if autoReconnect then
        local q = queueReload()
        notify(q and "Auto Reconnect ON (script reloads after rejoin)" or "Auto Reconnect ON (executor can't auto-reload the script)")
    end
    updateUI()
end)

-- ===== configs =====
makeLabel("Configs (macro + settings)", 10, row(22), 280, 18, false)

local selectedCfg = nil
local nameBox = Instance.new("TextBox")
nameBox.Size = UDim2.fromOffset(190, 28)
nameBox.Position = UDim2.fromOffset(10, cy)
nameBox.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
nameBox.TextColor3 = Color3.new(1, 1, 1)
nameBox.PlaceholderText = "config name"
nameBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 145)
nameBox.Text = ""
nameBox.ClearTextOnFocus = false
nameBox.Font = Enum.Font.Gotham
nameBox.TextSize = 12
nameBox.Parent = content
Instance.new("UICorner", nameBox)

local cfgList = Instance.new("ScrollingFrame")
local cfgLayout = Instance.new("UIListLayout")
local autoloadBtn
local refreshConfigList

makeButton("Create / Save", 206, row(32), 84, BLUE, function()
    local typed = cleanName(nameBox.Text)
    local target = (typed ~= "") and typed or selectedCfg
    if not target then notify("Type a config name first") return end
    local ok, msg, saved = saveConfig(target)
    if ok then
        selectedCfg = saved
        nameBox.Text = ""
        notify("Saved config: " .. saved .. (msg and (" (" .. msg .. ")") or ""))
        lastDetect = "Config '" .. saved .. "': " .. (msg or "saved")
    else
        notify(msg or "Save failed")
    end
    refreshConfigList()
    updateUI()
end)

cfgList.Size = UDim2.fromOffset(280, 88)
cfgList.Position = UDim2.fromOffset(10, row(94))
cfgList.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
cfgList.BorderSizePixel = 0
cfgList.ScrollBarThickness = 4
cfgList.CanvasSize = UDim2.new()
cfgList.Parent = content
cfgLayout.Padding = UDim.new(0, 3)
cfgLayout.Parent = cfgList

refreshConfigList = function()
    for _, c in ipairs(cfgList:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    local al = getAutoload()
    for _, n in ipairs(loadIndex()) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 24)
        b.BackgroundColor3 = (n == selectedCfg) and Color3.fromRGB(40, 120, 60) or Color3.fromRGB(45, 45, 62)
        b.Text = (n == al and "[A] " or "") .. n .. (n == currentConfig and "  (loaded)" or "")
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.Gotham
        b.TextSize = 12
        b.TextTruncate = Enum.TextTruncate.AtEnd
        b.Parent = cfgList
        b.MouseButton1Click:Connect(function()
            selectedCfg = n
            refreshConfigList()
            updateUI()
        end)
    end
    cfgList.CanvasSize = UDim2.fromOffset(0, cfgLayout.AbsoluteContentSize.Y + 4)
end

y = row(32)
makeButton("Load", 10, y, 137, BLUE, function()
    if not selectedCfg then notify("Select a config in the list first") return end
    local ok, msg = loadConfig(selectedCfg)
    notify(ok and ("Loaded: " .. selectedCfg .. (msg and (" (" .. msg .. ")") or "")) or (msg or "Load failed"))
    if ok then lastDetect = "Config '" .. selectedCfg .. "': " .. (msg or "loaded") end
    refreshConfigList()
end)
local delArmed = 0
makeButton("Delete", 153, y, 137, RED, function()
    if not selectedCfg then notify("Select a config in the list first") return end
    if os.clock() - delArmed < 3 then
        deleteConfig(selectedCfg)
        notify("Deleted: " .. selectedCfg)
        selectedCfg = nil
        delArmed = 0
        refreshConfigList()
        updateUI()
    else
        delArmed = os.clock()
        notify("Tap Delete again within 3s to confirm")
    end
end)

local ovwArmed = 0
makeButton("Overwrite Selected (use current settings)", 10, row(32), 280, ORANGE, function()
    if not selectedCfg then notify("Select a config in the list first") return end
    if os.clock() - ovwArmed < 3 then
        ovwArmed = 0
        local ok, msg, saved = saveConfig(selectedCfg)
        if ok then
            notify("Overwrote config: " .. saved .. (msg and (" (" .. msg .. ")") or ""))
            lastDetect = "Config '" .. saved .. "': " .. (msg or "saved")
        else
            notify(msg or "Overwrite failed")
        end
        refreshConfigList()
        updateUI()
    else
        ovwArmed = os.clock()
        notify("Tap again within 3s to overwrite '" .. selectedCfg .. "'")
    end
end)

autoloadBtn = makeButton("", 10, row(32), 280, nil, function()
    local al = getAutoload()
    if selectedCfg and al ~= selectedCfg then
        setAutoload(selectedCfg)
        notify("Autoload set: " .. selectedCfg)
    elseif al then
        setAutoload(nil)
        notify("Autoload cleared")
    else
        notify("Select a config first, then tap to set it as autoload")
    end
    refreshConfigList()
    updateUI()
end)

makeButton("Copy Bounty Board (debug)", 10, row(32), 280, nil, function()
    task.spawn(dumpBoard)
end)
local spyBtn = makeButton("", 10, row(32), 280, OFFCOL, function()
    spyOn = not spyOn
    if spyOn then
        table.clear(spyLog)
        notify(hookOk and "Remote Spy ON: now do Talk > View Bounties > Accept BY HAND" or "Remote Spy ON but the executor has no remote hook")
    else
        notify(("Remote Spy OFF (%d calls logged)"):format(#spyLog))
    end
    updateUI()
end)
makeButton("Copy Remote Log", 10, row(32), 280, nil, function()
    if #spyLog == 0 then notify("Log is empty") return end
    emit(table.concat(spyLog, "\n"), "Remote log")
end)
makeButton("Copy UI Debug (visible buttons/text)", 10, row(32), 280, nil, function()
    task.spawn(dumpUI)
end)

makeLabel("Run order: Robin accepts -> arcade macro -> claim -> fishing spot.\n"
    .. "Configs store your macro, spots, quest icon and toggles. Mark an Autoload config and it loads every time the script runs. "
    .. "Auto Reconnect rejoins after a disconnect and reloads the script; pair it with an Autoload config to resume automatically. "
    .. (hasFS and "" or "\nNOTE: this executor has no file access, so configs only last until you close Roblox."),
    10, row(150), 280, 146, true)

content.CanvasSize = UDim2.fromOffset(0, cy + 10)

updateUI = function()
    local counts = { remote = 0, prompt = 0, gui = 0 }
    local pendingN = 0
    for _, s in ipairs(macro) do
        counts[s.kind] = (counts[s.kind] or 0) + 1
        if s.enc then pendingN = pendingN + 1 end
    end
    recBtn.Text = macroRecording and "Stop Recording" or "Record Arcade Macro"
    recBtn.BackgroundColor3 = macroRecording and RED or ORANGE
    macroLbl.Text = ("Macro: %d steps (%d remote, %d prompt, %d tap)%s"):format(#macro, counts.remote, counts.prompt, counts.gui,
        pendingN > 0 and (" [" .. pendingN .. " pending]") or "")
    runsLbl.Text = "Arcade runs: " .. arcadeRuns
    fishLbl.Text = "Fishing spot: " .. fmtVec(fishSpot)
    iconLbl.Text = "Quest icon: " .. (questIconInfo and questIconInfo.name or "not set")
    pickBtn.Text = pickMode and "Tap the icon now... (cancel)" or "Pick Quest Icon"
    pickBtn.BackgroundColor3 = pickMode and RED or Color3.fromRGB(60, 60, 80)
    setToggle(autoBtn, ("Auto Run every %d min"):format(CONFIG.Robin.IntervalSeconds / 60), robinAuto)
    setToggle(claimBtn, ("Auto Claim Quests (every %d min)"):format(CONFIG.ClaimInterval / 60), claimAuto)
    setToggle(afkBtn, ("Anti-AFK Jump (every %ds)"):format(afkInterval), antiAfk)
    setToggle(reconBtn, "Auto Reconnect (+reload script)", autoReconnect)
    setToggle(spyBtn, "Remote Spy", spyOn)
    local al = getAutoload()
    autoloadBtn.Text = "Autoload: " .. (al or "OFF") .. (selectedCfg and (al ~= selectedCfg) and "  (tap = use selected)" or (al and "  (tap = clear)" or ""))
    autoloadBtn.BackgroundColor3 = al and Color3.fromRGB(40, 120, 60) or Color3.fromRGB(60, 60, 80)
end

local function inRect(g, pos)
    if not g.Visible then return false end
    local p, s = g.AbsolutePosition, g.AbsoluteSize
    return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y - 40 and pos.Y <= p.Y + s.Y + 40
end
table.insert(conns, UIS.InputBegan:Connect(function(input)
    if not (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then return end
    local pos = input.Position
    if inRect(main, pos) or inRect(icon, pos) then return end
    if pickMode then
        local btn = topButtonAt(pos)
        if btn then
            setQuestIcon(btn)
            pickMode = false
            updateUI()
            notify("Quest icon set: " .. btn.Name)
        end
        return
    end
    if macroRecording then
        local o = topInteractiveAt(pos)
        if o then pushStep({ kind = "gui", obj = o, info = describe(o) }) end
    end
end))

refreshConfigList()

do
    local al = getAutoload()
    if al and sRead("cfg_" .. al) then
        selectedCfg = al
        local ok, msg = loadConfig(al)
        notify(ok and ("Autoloaded config: " .. al .. (msg and (" (" .. msg .. ")") or "")) or ("Autoload failed: " .. tostring(msg)))
        refreshConfigList()
    end
end
updateUI()

task.spawn(function()
    local lastNudge = os.time()
    while alive do
        task.wait(1)
        local now = os.time()

        if antiAfk and now - lastNudge >= afkInterval then
            lastNudge = now
            afkJump()
        end
        if autoReconnect and not reconnecting and disconnected() then rejoin() end

        if robinAuto and not busy and not macroRecording and now >= nextRobinRun then
            nextRobinRun = now + CONFIG.Robin.IntervalSeconds
            task.spawn(robinRun)
        elseif claimAuto and not busy and not macroRecording and not pickMode and now >= nextClaim then
            nextClaim = now + CONFIG.ClaimInterval
            task.spawn(function()
                busy = true
                pcall(claimSweep)
                busy = false
            end)
        end

        local line1
        if reconnecting then
            line1 = "Disconnected - rejoining..."
        elseif macroRecording then
            line1 = "RECORDING macro..."
        elseif busy then
            line1 = "Running..."
        elseif robinAuto then
            local left = math.max(0, nextRobinRun - now)
            line1 = ("Next auto run in %02d:%02d"):format(math.floor(left / 60), left % 60)
        else
            line1 = "Auto run is OFF"
        end
        if claimAuto and not reconnecting and not macroRecording then
            local lf = math.max(0, nextClaim - now)
            line1 = line1 .. (" | claim in %02d:%02d"):format(math.floor(lf / 60), lf % 60)
        end
        statusLbl.Text = line1 .. "\n" .. lastDetect .. "\n"
            .. ("Config: %s | AFK %s | Reconnect %s"):format(currentConfig or "none", antiAfk and "ON" or "OFF", autoReconnect and "ON" or "OFF")
    end
end)

notify("Loaded. Use '-' to minimize into an icon.")
