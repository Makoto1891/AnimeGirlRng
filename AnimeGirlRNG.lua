--[[
    Anime Girl RNG - Robin Bounty Helper (Delta compatible)

    ONE PANEL, focused on Robin's Summer Bounties.
    Every run, in this priority order:
      1. Talk to Robin -> View Bounties -> press every available "Accept"
      2. Read your active quests (quest icon on the left)
      3. ARCADE quest active?  -> replay your recorded arcade macro (N times)
      4. Claim completed quests
      5. FISHING quest active? -> teleport to your marked fishing spot (and stay there)
    Extras: 30-min auto-run (toggle button, red = OFF / green = ON), auto-claim loop, minimize ("-") into a draggable icon.

    FIRST-TIME SETUP
      a) "Pick Quest Icon" -> tap the quest/banner icon on the left side of the screen.
      b) "Mark Fishing Spot" while standing where you want to fish.
      c) "Record Arcade Macro" -> play ONE arcade mini game by hand -> press Stop.
         (Don't tap Roll/Auto Roll while recording.)
      d) Optional: "Mark Robin Spot" (fallback if Robin isn't loaded in).
      e) "Run Robin Now" to test, then turn on Auto Run / Auto Claim.
]]

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local PPS = game:GetService("ProximityPromptService")
local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)
local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

local CONFIG = {
    Robin = {
        NpcName = "robin",
        OpenKeywords = { "view bounties" },
        WindowKeywords = { "resets in", "summer bount" }, -- text that proves the bounty window is open
        AcceptKeywords = { "accept" },
        AcceptExclude = { "accepted" },
        IntervalSeconds = 1800,        -- 30 minutes between cycles
        AutoStart = false,             -- true = timer starts by itself on load; false = you toggle it
        FirstRunDelay = 30,            -- seconds after loading before the first cycle
        DialogWait = 1.0,
    },
    ClaimKeywords = { "claim", "collect" },
    ClaimExclude = { "claimed" },
    ClaimInterval = 20,                -- seconds between auto-claim sweeps
    FishKeywords = { "fish", "angler" },
    ArcadeKeywords = { "mini game", "minigame", "mini-game", "arcade" },
    QuestIconNames = { "quest", "bounty", "mission" }, -- only used if you didn't pick the icon
    Arcade = {
        IgnoreRemotes = { "roll", "ping", "heartbeat", "camera", "position", "walk", "sprint" },
        BetweenRuns = 1.5,
        DefaultRuns = 1,
        MaxSteps = 400,
    },
    TeleportOffset = Vector3.new(0, 3, 4),
    ReturnAfterRun = true,             -- go back after a run (not when a fishing quest sends you to the spot)
    VirtualClickFallback = true,       -- tap on screen if no button signal could be fired
    SaveFile = "AGRNG_Robin.json",
}

-- cleanup previous run
local env = (getgenv and getgenv()) or _G
if env.AGRNG_Stop then pcall(env.AGRNG_Stop) end
local guiParent = (gethui and gethui()) or game:GetService("CoreGui")

-- ---------- state ----------
local alive = true
local busy = false
local robinAuto, claimAuto = CONFIG.Robin.AutoStart, false
local nextRobinRun, nextClaim = os.time() + CONFIG.Robin.FirstRunDelay, 0
local fishSpot, robinSpot, arcadePos = nil, nil, nil
local arcadeRuns = CONFIG.Arcade.DefaultRuns
local questIcon, questIconInfo = nil, nil
local pickMode = false
local macro, macroRecording, lastStepT = {}, false, 0
local lastDetect = "Quests: not checked yet"
local conns = {}
local updateUI

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

local function pressButton(b)
    local fired = 0
    if getconnections then
        for _, sig in ipairs({ b.MouseButton1Click, b.Activated }) do
            pcall(function()
                for _, c in ipairs(getconnections(sig)) do c:Fire() fired = fired + 1 end
            end)
        end
    elseif firesignal then
        if pcall(firesignal, b.MouseButton1Click) then fired = fired + 1 end
        pcall(firesignal, b.Activated)
    end
    if fired == 0 and CONFIG.VirtualClickFallback and VIM then
        pcall(function()
            local pos = b.AbsolutePosition + b.AbsoluteSize / 2 + GuiService:GetGuiInset()
            VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
            task.wait(0.05)
            VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
            fired = 1
        end)
    end
    return fired
end

local function pressTarget(o)
    if o:IsA("GuiButton") then return pressButton(o) end
    if VIM then
        pcall(function()
            local pos = o.AbsolutePosition + o.AbsoluteSize / 2 + GuiService:GetGuiInset()
            VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
            task.wait(0.05)
            VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
        end)
    end
    return 1
end

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
                if hit and isShown(d) then
                    local btn = d:IsA("TextButton") and d or d:FindFirstAncestorWhichIsA("GuiButton") or d
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

-- are fishing / arcade quest texts visible (optionally only inside scopeSet)?
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

-- ---------- tap methods (tried in order until something responds) ----------
local function vimTap(o, withInset)
    if not VIM then return 0 end
    pcall(function()
        local pos = o.AbsolutePosition + o.AbsoluteSize / 2
        if withInset then pos = pos + GuiService:GetGuiInset() end
        VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
        task.wait(0.06)
        VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
    end)
    return 1
end

local function fakeInput(o)
    if not getconnections then return 0 end
    local c = o.AbsolutePosition + o.AbsoluteSize / 2
    local function mk(state)
        return {
            UserInputType = Enum.UserInputType.MouseButton1,
            UserInputState = state,
            KeyCode = Enum.KeyCode.Unknown,
            Position = Vector3.new(c.X, c.Y, 0),
            Delta = Vector3.new(0, 0, 0),
        }
    end
    local cur, n = o, 0
    while cur and cur ~= pg and n < 3 do
        if cur:IsA("GuiObject") then
            pcall(function()
                for _, cn in ipairs(getconnections(cur.InputBegan)) do cn:Fire(mk(Enum.UserInputState.Begin), false) end
                for _, cn in ipairs(getconnections(cur.InputEnded)) do cn:Fire(mk(Enum.UserInputState.End), false) end
            end)
            if cur:IsA("GuiButton") then
                pcall(function()
                    for _, cn in ipairs(getconnections(cur.MouseButton1Click)) do cn:Fire() end
                    for _, cn in ipairs(getconnections(cur.Activated)) do cn:Fire() end
                end)
            end
        end
        cur = cur.Parent
        n = n + 1
    end
    return 1
end

-- method 1: button signals | 2: real tap (with top-bar inset) | 3: real tap (no inset) | 4: fake input events
local function tapMethod(b, m)
    if m == 1 then
        if b:IsA("GuiButton") then return pressButton(b) end
        return vimTap(b, true)
    elseif m == 2 then
        return vimTap(b, true)
    elseif m == 3 then
        return vimTap(b, false)
    end
    return fakeInput(b)
end

-- press every match; if the number of matches doesn't go down, switch to the next tap method
local function pressAll(keywords, exact, exclude, scopeSet, maxRounds)
    local method, total = 1, 0
    for _ = 1, maxRounds do
        local targets = findButtons(keywords, exact, exclude, scopeSet)
        if #targets == 0 then break end
        for _, b in ipairs(targets) do
            tapMethod(b, method)
            task.wait(0.25)
        end
        total = total + #targets
        task.wait(0.7)
        local after = findButtons(keywords, exact, exclude, scopeSet)
        if #after >= #targets then method = math.min(method + 1, 4) end
    end
    return total
end

local function bountyWindowOpen()
    for _, d in ipairs(pg:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and isShown(d) then
            local t = cleanText(d.Text)
            if #t < 60 then
                for _, k in ipairs(CONFIG.Robin.WindowKeywords) do
                    if string.find(t, k, 1, true) then return true end
                end
            end
        end
    end
    return false
end

-- click "View Bounties" and verify the bounty window really opened
local function openBounties()
    local method = 1
    for _ = 1, 6 do
        if bountyWindowOpen() then return true end
        local targets = findButtons(CONFIG.Robin.OpenKeywords)
        if #targets == 0 then return false end
        for _, b in ipairs(targets) do tapMethod(b, method) end
        task.wait(1.0)
        if bountyWindowOpen() then return true end
        method = math.min(method + 1, 4)
    end
    return bountyWindowOpen()
end

local function dumpUI()
    local lines = {}
    for _, d in ipairs(pg:GetDescendants()) do
        if isShown(d) then
            if (d:IsA("TextButton") or d:IsA("TextLabel")) and d.Text ~= "" then
                lines[#lines + 1] = ("%s | %q | %s"):format(d.ClassName, d.Text, d:GetFullName())
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
        if d:IsA("GuiButton") and matches(d.Name, CONFIG.QuestIconNames) and isShown(d) then
            questIcon = d
            return d
        end
    end
    return nil
end

-- open quest panel, claim finished quests, detect active fishing/arcade quests, close panel
-- returns ok, claimedCount, fishActive, arcadeActive
local function claimSweep()
    local icon = getQuestIcon()
    if not icon then return false, 0, false, false end
    local before = textSet()
    pressButton(icon)
    task.wait(0.9)
    local fresh, n = diffSince(before)
    local opened = n > 2
    local claimed = pressByText(CONFIG.ClaimKeywords, false, CONFIG.ClaimExclude, opened and fresh or nil)
    if claimed > 0 then task.wait(0.8) end
    local fresh2 = opened and (diffSince(before)) or nil
    local fish, arcade = detect(fresh2)
    if opened then
        pressButton(icon)
        task.wait(0.4)
    end
    lastDetect = ("Quests: fishing %s | arcade %s"):format(fish and "YES" or "no", arcade and "YES" or "no")
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

-- returns found, opened(1/0), accepted, fallbackFish, fallbackArcade
local function robinTalk()
    local r = findRobin()
    if not r and robinSpot then
        teleportTo(robinSpot, Vector3.new(0, 3, 0))
        task.wait(2)
        r = findRobin()
    end
    if not r then return false, 0, 0, false, false end
    teleportTo(r.pos)
    task.wait(0.6)

    -- 1) get Robin's dialog on screen (retry the prompt a few times)
    local dialogShown = false
    for _ = 1, 3 do
        if bountyWindowOpen() or #findButtons(CONFIG.Robin.OpenKeywords) > 0 then dialogShown = true break end
        fireObj(r.inst)
        for _ = 1, 12 do
            task.wait(0.4)
            if #findButtons(CONFIG.Robin.OpenKeywords) > 0 or bountyWindowOpen() then dialogShown = true break end
        end
        if dialogShown then break end
        teleportTo(r.pos, Vector3.new(0, 3, 2))
        task.wait(0.5)
    end
    if not dialogShown then
        notify("Robin's dialog didn't open (the Talk prompt didn't trigger)")
        return true, 0, 0, false, false
    end

    -- 2) press View Bounties, verified
    task.wait(CONFIG.Robin.DialogWait)
    if not openBounties() then
        notify("Couldn't open View Bounties. Open Robin's dialog by hand and press Copy UI Debug.")
        pressByText({ "bye" }, true)
        return true, 0, 0, false, false
    end

    -- 3) accept everything available
    task.wait(CONFIG.Robin.DialogWait)
    local accepted = pressAll(CONFIG.Robin.AcceptKeywords, false, CONFIG.Robin.AcceptExclude, nil, 6)
    local fbFish, fbArcade = detect(nil) -- fallback detection while the bounty window is open
    pressByText({ "x" }, true)
    pressByText({ "bye" }, true)
    return true, 1, accepted, fbFish, fbArcade
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

local function addRemoteStep(remote, method, args)
    if not macroRecording then return end
    if matches(remote.Name, CONFIG.Arcade.IgnoreRemotes) then return end
    pushStep({ kind = "remote", remote = remote, method = method, args = args })
end

-- one shared __namecall hook (survives re-execution without stacking)
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

local function runStep(s)
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
        local o = (s.obj and s.obj:IsDescendantOf(pg)) and s.obj or refind(s.info)
        if o then pressTarget(o) end
    end
end

local function playMacro(times)
    if #macro == 0 then return 0 end
    local steps = 0
    for _ = 1, times do
        if not alive then break end
        if arcadePos then teleportTo(arcadePos, Vector3.new(0, 3, 0)) task.wait(0.5) end
        for _, s in ipairs(macro) do
            if not alive then break end
            task.wait(math.clamp(s.dt, 0.05, 6))
            runStep(s)
            steps = steps + 1
        end
        task.wait(CONFIG.Arcade.BetweenRuns)
    end
    return steps
end

-- ---------- full run ----------
local function robinRun()
    if busy then notify("Busy - try again in a moment") return end
    busy = true
    local root = getRoot()
    local origin = root and root.CFrame
    local stayAtFishing = false
    local ok, err = pcall(function()
        local found, opened, accepted, fbFish, fbArcade = robinTalk()
        if not found then
            notify("Robin not found. Stand near her / use Mark Robin Spot.")
            return
        end

        local okS, _, fish, arcade = claimSweep()
        if not okS then
            fish, arcade = fbFish, fbArcade
            lastDetect = ("Quests (fallback): fishing %s | arcade %s"):format(fish and "YES" or "no", arcade and "YES" or "no")
        end

        local steps = 0
        -- PRIORITY 1: arcade macro
        if arcade then
            if #macro > 0 then
                steps = playMacro(arcadeRuns)
                task.wait(1)
                local ok2, _, f2 = claimSweep()
                if ok2 then fish = f2 end
            else
                notify("Arcade quest active but no macro recorded")
            end
        end

        -- PRIORITY 2: fishing spot
        if fish then
            if fishSpot then
                teleportTo(fishSpot, Vector3.new(0, 3, 0))
                stayAtFishing = true
            else
                notify("Fishing quest active - mark a fishing spot first")
            end
        end

        notify(("Run done. Accepted %d | macro steps %d | %s"):format(accepted, steps, stayAtFishing and "at fishing spot" or "back home"))
    end)
    if not ok then notify("Run error: " .. tostring(err)) end
    if (not stayAtFishing) and CONFIG.ReturnAfterRun and origin and getRoot() then getRoot().CFrame = origin end
    busy = false
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

-- title bar
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

-- minimized icon
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

-- scrolling content
local content = Instance.new("ScrollingFrame")
content.Size = UDim2.fromOffset(300, PANEL_H - 34)
content.Position = UDim2.fromOffset(0, 34)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.ScrollBarThickness = 4
content.CanvasSize = UDim2.fromOffset(0, 590)
content.Parent = main
curParent = content

local GREEN, GREEN_ON = Color3.fromRGB(60, 120, 70), Color3.fromRGB(40, 170, 70)
local OFFCOL = Color3.fromRGB(150, 60, 60)
local ORANGE, RED = Color3.fromRGB(140, 80, 50), Color3.fromRGB(190, 60, 60)

local statusLbl = makeLabel("Ready", 10, 4, 280, 34, true)

makeButton("Run Robin Now", 10, 42, 280, Color3.fromRGB(50, 90, 140), function()
    if robinAuto then nextRobinRun = os.time() + CONFIG.Robin.IntervalSeconds end -- restart the 30 min timer
    task.spawn(robinRun)
end)

makeButton(("Auto Run every %d min: %s"):format(CONFIG.Robin.IntervalSeconds / 60, robinAuto and "ON" or "OFF"), 10, 74, 280, robinAuto and GREEN_ON or OFFCOL, function(b)
    robinAuto = not robinAuto
    if robinAuto then nextRobinRun = os.time() notify("Auto Run ON: cycle starts now, then every 30 min") else notify("Auto Run OFF") end
    b.Text = ("Auto Run every %d min: %s"):format(CONFIG.Robin.IntervalSeconds / 60, robinAuto and "ON" or "OFF")
    b.BackgroundColor3 = robinAuto and GREEN_ON or OFFCOL
end)

makeButton("Auto Claim Completed Quests: OFF", 10, 106, 280, OFFCOL, function(b)
    claimAuto = not claimAuto
    if claimAuto then nextClaim = os.time() end
    b.Text = "Auto Claim Completed Quests: " .. (claimAuto and "ON" or "OFF")
    b.BackgroundColor3 = claimAuto and GREEN_ON or OFFCOL
end)

local pickBtn = makeButton("Pick Quest Icon", 10, 138, 190, nil, function()
    pickMode = not pickMode
    if pickMode then notify("Now tap the quest icon on the left side of the screen") end
    updateUI()
end)
makeButton("Claim Now", 206, 138, 84, Color3.fromRGB(50, 90, 140), function()
    if busy then notify("Busy") return end
    task.spawn(function()
        busy = true
        local ok, n = pcall(claimSweep)
        busy = false
        if not ok then notify("Claim error") end
        if ok and n == false then notify("Pick the quest icon first") end
    end)
end)
local iconLbl = makeLabel("", 10, 170, 280, 18, false)

makeButton("Mark Fishing Spot", 10, 196, 190, nil, function()
    local r = getRoot()
    if r then fishSpot = r.Position saveData() updateUI() notify("Fishing spot marked") end
end)
makeButton("Go", 206, 196, 84, nil, function()
    if fishSpot then teleportTo(fishSpot, Vector3.new(0, 3, 0)) else notify("Mark a fishing spot first") end
end)
local fishLbl = makeLabel("", 10, 228, 280, 18, false)

local recBtn = makeButton("Record Arcade Macro", 10, 252, 190, ORANGE, function()
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
makeButton("Clear", 206, 252, 84, nil, function()
    if macroRecording then return end
    table.clear(macro)
    updateUI()
end)
local macroLbl = makeLabel("", 10, 284, 280, 18, false)

local runsLbl = makeLabel("", 10, 312, 120, 18, false)
makeButton("-", 136, 306, 70, nil, function()
    arcadeRuns = math.max(1, arcadeRuns - 1) saveData() updateUI()
end)
makeButton("+", 212, 306, 78, nil, function()
    arcadeRuns = math.min(50, arcadeRuns + 1) saveData() updateUI()
end)

makeButton("Test Arcade Macro (1x)", 10, 340, 280, Color3.fromRGB(50, 90, 140), function()
    if busy then notify("Busy") return end
    if #macro == 0 then notify("Record a macro first") return end
    task.spawn(function()
        busy = true
        pcall(playMacro, 1)
        busy = false
    end)
end)

makeButton("Mark Robin Spot (optional)", 10, 372, 280, nil, function()
    local r = getRoot()
    if r then robinSpot = r.Position saveData() updateUI() notify("Robin spot marked") end
end)

makeButton("Copy UI Debug (visible buttons/text)", 10, 404, 280, nil, function()
    task.spawn(dumpUI)
end)

makeLabel("Run order: Robin accepts -> arcade macro -> claim -> fishing spot.\n"
    .. "Keep the quest panel closed; the script opens/closes it to claim and to read active quests. "
    .. "The arcade macro must be re-recorded after you re-execute the script.",
    10, 440, 280, 110, true)

updateUI = function()
    local counts = { remote = 0, prompt = 0, gui = 0 }
    for _, s in ipairs(macro) do counts[s.kind] = (counts[s.kind] or 0) + 1 end
    recBtn.Text = macroRecording and "Stop Recording" or "Record Arcade Macro"
    recBtn.BackgroundColor3 = macroRecording and RED or ORANGE
    macroLbl.Text = ("Macro: %d steps (%d remote, %d prompt, %d tap)"):format(#macro, counts.remote, counts.prompt, counts.gui)
    runsLbl.Text = "Arcade runs: " .. arcadeRuns
    fishLbl.Text = "Fishing spot: " .. fmtVec(fishSpot)
    iconLbl.Text = "Quest icon: " .. (questIconInfo and questIconInfo.name or "not set")
    pickBtn.Text = pickMode and "Tap the icon now... (cancel)" or "Pick Quest Icon"
    pickBtn.BackgroundColor3 = pickMode and RED or Color3.fromRGB(60, 60, 80)
end

-- taps: quest-icon picking + macro recording
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

updateUI()

-- timers: auto run, auto claim, status text
task.spawn(function()
    while alive do
        task.wait(1)
        local now = os.time()
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
        if macroRecording then
            line1 = "RECORDING macro..."
        elseif busy then
            line1 = "Running..."
        elseif robinAuto then
            local left = math.max(0, nextRobinRun - now)
            line1 = ("Next auto run in %02d:%02d"):format(math.floor(left / 60), left % 60)
        else
            line1 = "Auto run is OFF"
        end
        statusLbl.Text = line1 .. "\n" .. lastDetect
    end
end)

notify("Loaded. Use '-' to minimize into an icon.")
