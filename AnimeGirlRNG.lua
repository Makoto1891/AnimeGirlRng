--[[
    Anime Girl RNG - Helper v3 (Delta compatible)

    PAGE 1 "Quests": auto-accept for ONE NPC picked in a dropdown.
    PAGE 2 "Robin" : Robin's Summer Bounties
        * Talks to Robin -> "View Bounties" -> presses every available "Accept"
        * Presses "Claim" on finished bounties
        * Replays YOUR recorded fishing / arcade steps (macro) to progress those bounties
        * Auto-runs the whole routine every 30 minutes
    The "-" button shrinks the panel into a draggable icon. Tap the icon to reopen.

    FISHING / ARCADE SETUP (the script can't know the game's fishing/arcade remotes):
      Robin page -> "Record Fishing" ON -> catch ONE fish by hand -> press it again to stop.
      Same for "Record Arcade" with ONE mini game. The steps are replayed each run.
]]

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)
local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

local CONFIG = {
    QuestKeywords     = { "quest", "accept", "talk", "mission", "task", "start" },
    GuiAcceptKeywords = { "accept", "start quest" },
    AcceptExclude     = { "accepted" },
    IgnoreRemoteKeywords = { "roll", "move", "walk", "position", "ping", "heartbeat", "camera", "input", "sprint", "jump" },
    IgnoreWhenMacro   = { "roll", "ping", "heartbeat", "camera", "position", "walk", "sprint" },
    IslandRadius   = 600,
    LoopDelay      = 3,
    TeleportOffset = Vector3.new(0, 3, 4),
    ReturnAfterAccept = true,
    VirtualClickFallback = true, -- tap the button on screen if no signal could be fired
    SaveFile = "AGRNG_Helper.json",
    Robin = {
        NpcName = "robin",
        OpenKeywords = { "view bounties" },
        ClaimKeywords = { "claim", "collect" },
        ClaimExclude = { "claimed" },
        IntervalSeconds = 1800,   -- 30 minutes
        DialogWait = 1.0,
        MacroDelay = 0.6,
    },
}

-- cleanup previous run
local env = (getgenv and getgenv()) or _G
if env.AGRNG_Stop then pcall(env.AGRNG_Stop) end
local guiParent = (gethui and gethui()) or game:GetService("CoreGui")

local alive, recording, autoQuest, robinAuto, busy = true, false, false, false, false
local recordGroup = nil          -- nil / "fish" / "arcade" / "robin"
local macroRepeats = 3
local nextRobinRun = 0
local marks, npcs, recorded = {}, {}, {}
local tab = "npc"
local selected = nil             -- { name=, pos= }
local render, updateRecButtons

-- ---------- helpers ----------
local function lower(s) return string.lower(tostring(s or "")) end
local function getRoot() local c = lp.Character return c and c:FindFirstChild("HumanoidRootPart") end

local function notify(text)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", { Title = "AG RNG Helper", Text = text, Duration = 4 })
    end)
end

local function teleportTo(pos, offset)
    local r = getRoot()
    if r then r.CFrame = CFrame.new(pos + (offset or CONFIG.TeleportOffset)) return true end
end

local function islandOf(pos)
    local best, bd
    for i, m in pairs(marks) do
        local d = (m - pos).Magnitude
        if d <= CONFIG.IslandRadius and (not bd or d < bd) then best, bd = i, d end
    end
    return best
end

local function matches(text, list)
    text = lower(text)
    for _, k in ipairs(list) do if string.find(text, k, 1, true) then return true end end
    return false
end

local function saveMarks()
    if not writefile then return end
    pcall(function()
        local t = {}
        for i, v in pairs(marks) do t[tostring(i)] = { v.X, v.Y, v.Z } end
        writefile(CONFIG.SaveFile, HttpService:JSONEncode(t))
    end)
end
local function loadMarks()
    if not (isfile and readfile) then return end
    pcall(function()
        if isfile(CONFIG.SaveFile) then
            for k, v in pairs(HttpService:JSONDecode(readfile(CONFIG.SaveFile))) do
                marks[tonumber(k)] = Vector3.new(v[1], v[2], v[3])
            end
        end
    end)
end
loadMarks()

-- ---------- NPC scanning ----------
local function scanNPCs()
    table.clear(npcs)
    local byModel = {}
    local function entryFor(holder)
        local model = holder:IsA("Model") and holder or holder:FindFirstAncestorOfClass("Model") or holder
        if model:IsA("Model") and Players:GetPlayerFromCharacter(model) then return nil end
        local e = byModel[model]
        if e then return e end
        local pos
        if model:IsA("Model") then
            local ok, p = pcall(function() return model:GetPivot().Position end)
            pos = ok and p or nil
        elseif model:IsA("BasePart") then
            pos = model.Position
        end
        if not pos then return nil end
        e = { name = model.Name, pos = pos, prompts = {}, clicks = {}, texts = {}, island = islandOf(pos) }
        byModel[model] = e
        table.insert(npcs, e)
        return e
    end
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Parent then
            local e = entryFor(d.Parent)
            if e then
                table.insert(e.prompts, d)
                table.insert(e.texts, d.ActionText)
                table.insert(e.texts, d.ObjectText)
            end
        elseif d:IsA("ClickDetector") and d.Parent then
            local e = entryFor(d.Parent)
            if e then table.insert(e.clicks, d) end
        elseif d:IsA("Humanoid") and d.Parent then
            entryFor(d.Parent)
        end
    end
    table.sort(npcs, function(a, b)
        local ia, ib = a.island or 9, b.island or 9
        if ia ~= ib then return ia < ib end
        return a.name < b.name
    end)
end

local function isSelected(e)
    return selected ~= nil and e.name == selected.name and (e.pos - selected.pos).Magnitude < 10
end

local function nearestNPC(pos)
    if not pos then return nil end
    if #npcs == 0 then scanNPCs() end
    local best, bd
    for _, e in ipairs(npcs) do
        local d = (e.pos - pos).Magnitude
        if d < 30 and (not bd or d < bd) then best, bd = e, d end
    end
    return best and best.name
end

-- ---------- GUI buttons ----------
local function isShown(obj)
    local cur = obj
    while cur and cur ~= pg do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("ScreenGui") and not cur.Enabled then return false end
        cur = cur.Parent
    end
    return true
end

local function cleanText(s)
    s = lower(s)
    s = string.gsub(s, "<[^>]->", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
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

-- finds visible buttons whose text (or inner label text) matches
local function findButtons(keywords, exact, exclude)
    local out, seen = {}, {}
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("TextButton") or d:IsA("TextLabel") then
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
                    local btn = d:IsA("TextButton") and d or d:FindFirstAncestorWhichIsA("GuiButton")
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

local function pressByText(keywords, exact, exclude)
    local btns = findButtons(keywords, exact, exclude)
    for _, b in ipairs(btns) do
        pressButton(b)
        task.wait(0.2)
    end
    return #btns
end

local function clickAcceptButtons()
    return pressByText(CONFIG.GuiAcceptKeywords, false, CONFIG.AcceptExclude)
end

-- ---------- remote recorder ----------
local function argSummary(args)
    local out = {}
    for i = 1, args.n do
        local v = args[i]
        local t = typeof(v)
        local s = (t == "string" or t == "number" or t == "boolean" or t == "Instance") and tostring(v) or t
        out[#out + 1] = string.sub(s, 1, 24)
    end
    return table.concat(out, ", ")
end

local function addRecord(remote, method, args)
    if not recording then return end
    local ignore = recordGroup and CONFIG.IgnoreWhenMacro or CONFIG.IgnoreRemoteKeywords
    if matches(remote.Name, ignore) then return end
    local key = (recordGroup or "-") .. remote:GetFullName() .. method .. argSummary(args)
    for _, r in ipairs(recorded) do if r.key == key then return end end
    local root = getRoot()
    local npc = (not recordGroup) and nearestNPC(root and root.Position) or nil
    table.insert(recorded, {
        remote = remote, method = method, args = args, key = key, npc = npc, group = recordGroup,
        pos = root and root.Position, selected = recordGroup ~= nil,
        label = (recordGroup and ("[" .. recordGroup .. "] ") or "") .. remote.Name
            .. "(" .. argSummary(args) .. ")" .. (npc and (" @" .. npc) or ""),
    })
    if #recorded > 80 then table.remove(recorded, 1) end
    if tab == "rec" and render then render() end
    if updateRecButtons then updateRecButtons() end
end

local hookOk = false
pcall(function()
    if hookmetamethod and getnamecallmethod then
        local ncc = newcclosure or function(f) return f end
        local old
        old = hookmetamethod(game, "__namecall", ncc(function(self, ...)
            local m = getnamecallmethod()
            if recording and (m == "FireServer" or m == "InvokeServer")
                and typeof(self) == "Instance" and not (checkcaller and checkcaller()) then
                task.defer(addRecord, self, m, table.pack(...))
            end
            return old(self, ...)
        end))
        hookOk = true
    end
end)

local function replay(rec)
    if not (rec.remote and rec.remote.Parent) then return end
    if rec.pos then teleportTo(rec.pos, Vector3.new()) task.wait(0.3) end
    if rec.method == "FireServer" then
        pcall(function() rec.remote:FireServer(table.unpack(rec.args, 1, rec.args.n)) end)
    else
        task.spawn(function() pcall(function() rec.remote:InvokeServer(table.unpack(rec.args, 1, rec.args.n)) end) end)
    end
end

local function countGroup(g)
    local n = 0
    for _, r in ipairs(recorded) do if r.group == g then n = n + 1 end end
    return n
end

local function runMacro(group, repeats)
    local n = 0
    for _ = 1, repeats do
        for _, rec in ipairs(recorded) do
            if rec.group == group and rec.selected then
                replay(rec)
                n = n + 1
                task.wait(CONFIG.Robin.MacroDelay)
            end
        end
    end
    return n
end

-- ---------- selected-NPC auto accept (Quests page) ----------
local function questCycle(cycle)
    local root = getRoot()
    if not root or not selected then return end
    local origin = root.CFrame

    for _, rec in ipairs(recorded) do
        if not autoQuest then break end
        if rec.selected and not rec.group and (rec.npc == nil or rec.npc == selected.name) then
            replay(rec) task.wait(0.4)
        end
    end

    if cycle % 5 == 1 or #npcs == 0 then scanNPCs() end
    for _, e in ipairs(npcs) do
        if not autoQuest then break end
        if isSelected(e) and (#e.prompts > 0 or #e.clicks > 0) then
            teleportTo(e.pos)
            task.wait(0.4)
            for _, p in ipairs(e.prompts) do
                if p.Parent then
                    pcall(function() p.HoldDuration = 0 end)
                    if fireproximityprompt then pcall(fireproximityprompt, p) end
                end
            end
            for _, c in ipairs(e.clicks) do
                if c.Parent and fireclickdetector then pcall(fireclickdetector, c) end
            end
            task.wait(0.4)
            clickAcceptButtons()
            task.wait(0.2)
        end
    end

    if CONFIG.ReturnAfterAccept and getRoot() then getRoot().CFrame = origin end
end

task.spawn(function()
    local cycle = 0
    while alive and task.wait(CONFIG.LoopDelay) do
        if autoQuest and not busy then
            if not selected then
                autoQuest = false
                notify("Pick an NPC in the dropdown first!")
            else
                cycle = cycle + 1
                busy = true
                pcall(questCycle, cycle)
                busy = false
            end
        end
    end
end)

-- ---------- Robin ----------
local function findRobin()
    local needle = CONFIG.Robin.NpcName
    local function look()
        for _, e in ipairs(npcs) do
            if #e.prompts + #e.clicks > 0 then
                if string.find(lower(e.name), needle, 1, true) then return e end
                for _, t in ipairs(e.texts) do
                    if string.find(lower(t), needle, 1, true) then return e end
                end
            end
        end
        return nil
    end
    if #npcs == 0 then scanNPCs() end
    local e = look()
    if not e then scanNPCs() e = look() end
    return e
end

-- talk to Robin, open bounties, accept + claim. returns found, opened, accepted, claimed
local function robinTalk()
    local e = findRobin()
    if not e then return false, 0, 0, 0 end
    teleportTo(e.pos)
    task.wait(0.6)
    for _, p in ipairs(e.prompts) do
        if p.Parent then
            pcall(function() p.HoldDuration = 0 end)
            if fireproximityprompt then pcall(fireproximityprompt, p) end
        end
    end
    for _, c in ipairs(e.clicks) do
        if c.Parent and fireclickdetector then pcall(fireclickdetector, c) end
    end
    task.wait(CONFIG.Robin.DialogWait)
    local opened = pressByText(CONFIG.Robin.OpenKeywords)
    task.wait(CONFIG.Robin.DialogWait)
    local accepted = 0
    for _ = 1, 2 do
        accepted = accepted + clickAcceptButtons()
        task.wait(0.5)
    end
    local claimed = pressByText(CONFIG.Robin.ClaimKeywords, false, CONFIG.Robin.ClaimExclude)
    task.wait(0.4)
    runMacro("robin", 1) -- optional recorded accept remotes (backup if buttons can't be pressed)
    pressByText({ "bye" }, true)
    pressByText({ "x" }, true)
    return true, opened, accepted, claimed
end

local function robinRun()
    if busy then notify("Busy, try again in a moment") return end
    busy = true
    local root = getRoot()
    local origin = root and root.CFrame
    pcall(function()
        local found, opened, accepted, claimed = robinTalk()
        if not found then
            notify("Robin not found. Go near her and press Rescan on the Quests page.")
            return
        end
        local f = runMacro("fish", macroRepeats)
        local a = runMacro("arcade", macroRepeats)
        if f + a > 0 then
            local _, _, acc2, cl2 = robinTalk()
            accepted, claimed = accepted + (acc2 or 0), claimed + (cl2 or 0)
        end
        notify(("Robin: opened %d, accepted %d, claimed %d, macro steps %d"):format(opened, accepted, claimed, f + a))
    end)
    if CONFIG.ReturnAfterAccept and origin and getRoot() then getRoot().CFrame = origin end
    busy = false
end

-- ---------- UI ----------
local gui = Instance.new("ScreenGui")
gui.Name = "AGRNG_Helper"
gui.ResetOnSpawn = false
gui.Parent = guiParent

env.AGRNG_Stop = function()
    alive, recording, autoQuest, robinAuto = false, false, false, false
    pcall(function() gui:Destroy() end)
end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(300, 474)
main.Position = UDim2.new(0, 70, 0, 10)
main.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
main.BorderSizePixel = 0
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

-- shrink to fit small phone screens
local ui = Instance.new("UIScale", main)
local function fitScale()
    local cam = workspace.CurrentCamera
    if cam then ui.Scale = math.clamp((cam.ViewportSize.Y - 20) / 474, 0.5, 1) end
end
fitScale()
pcall(function() workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale) end)

local function makeDraggable(handle, target, scaleInst, onTap)
    local dragging, moved, ds, sp = false, false, nil, nil
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, moved, ds, sp = true, false, i.Position, target.Position
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - ds
            if d.Magnitude > 6 then moved = true end
            if moved then
                local k = scaleInst and scaleInst.Scale or 1
                target.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X / k, sp.Y.Scale, sp.Y.Offset + d.Y / k)
            end
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            if not moved and onTap then onTap() end
        end
    end)
end

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

-- title bar (drag handle)
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.fromOffset(300, 30)
titleBar.BackgroundTransparency = 1
titleBar.Active = true
titleBar.Parent = main
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text = "Anime Girl RNG Helper v3"
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
icon.Text = "AG"
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

local function minimize()
    icon.Position = main.Position
    main.Visible = false
    icon.Visible = true
end
local function restore()
    icon.Visible = false
    main.Visible = true
end
makeDraggable(icon, icon, nil, restore)

curParent = main
makeButton("-", 236, 3, 26, Color3.fromRGB(80, 80, 110), function() minimize() end)
makeButton("X", 266, 3, 26, Color3.fromRGB(170, 60, 60), function() env.AGRNG_Stop() end)

-- pages
local function newPage()
    local f = Instance.new("Frame")
    f.Size = UDim2.fromOffset(300, 410)
    f.Position = UDim2.fromOffset(0, 62)
    f.BackgroundTransparency = 1
    f.Parent = main
    return f
end
local pageQ, pageR = newPage(), newPage()
pageR.Visible = false

local tabQBtn, tabRBtn
local function showPage(name)
    pageQ.Visible = (name == "q")
    pageR.Visible = (name == "r")
    tabQBtn.BackgroundColor3 = name == "q" and Color3.fromRGB(90, 60, 130) or Color3.fromRGB(60, 60, 80)
    tabRBtn.BackgroundColor3 = name == "r" and Color3.fromRGB(90, 60, 130) or Color3.fromRGB(60, 60, 80)
end
curParent = main
tabQBtn = makeButton("Quests", 10, 32, 137, nil, function() showPage("q") end)
tabRBtn = makeButton("Robin", 153, 32, 137, nil, function() showPage("r") end)

-- record button helpers
local recBtn, fishBtn, arcBtn, robBtn
local function toggleRecord(group)
    if not hookOk then notify("Executor can't hook remotes - recording unavailable") return end
    if recording and recordGroup == group then
        recording, recordGroup = false, nil
    else
        recording, recordGroup = true, group
    end
    updateRecButtons()
end
local function clearGroup(g)
    for i = #recorded, 1, -1 do
        if recorded[i].group == g then table.remove(recorded, i) end
    end
    updateRecButtons()
    if render then render() end
end
updateRecButtons = function()
    local function set(btn, group, label)
        if not btn then return end
        local on = recording and recordGroup == group
        local n = countGroup(group)
        btn.Text = label .. (group and (" (" .. n .. ")") or "") .. ": " .. (on and "ON" or "OFF")
        btn.BackgroundColor3 = on and Color3.fromRGB(190, 60, 60) or Color3.fromRGB(140, 80, 50)
    end
    set(recBtn, nil, "Record Remotes")
    set(fishBtn, "fish", "Record Fishing")
    set(arcBtn, "arcade", "Record Arcade")
    set(robBtn, "robin", "Record Robin Accept")
end

-- ===== QUESTS PAGE =====
curParent = pageQ
local list = Instance.new("ScrollingFrame")
list.Size = UDim2.fromOffset(280, 158)
list.Position = UDim2.fromOffset(10, 242)
list.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.CanvasSize = UDim2.new()
list.Parent = pageQ
local layout = Instance.new("UIListLayout", list)
layout.Padding = UDim.new(0, 3)

render = function()
    for _, c in ipairs(list:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
    local function row(text, color, cb)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 24)
        b.BackgroundColor3 = color
        b.Text = text
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.Gotham
        b.TextSize = 12
        b.TextTruncate = Enum.TextTruncate.AtEnd
        b.Parent = list
        b.MouseButton1Click:Connect(function() cb(b) end)
    end
    if tab == "npc" then
        for _, e in ipairs(npcs) do
            local tag = (#e.prompts + #e.clicks > 0) and " *" or ""
            row(("[I%s] %s%s"):format(e.island or "?", e.name, tag), Color3.fromRGB(45, 45, 62), function() teleportTo(e.pos) end)
        end
    else
        for _, r in ipairs(recorded) do
            local function col() return r.selected and Color3.fromRGB(40, 120, 60) or Color3.fromRGB(70, 50, 50) end
            row((r.selected and "[ON] " or "[OFF] ") .. r.label, col(), function(b)
                r.selected = not r.selected
                b.Text = (r.selected and "[ON] " or "[OFF] ") .. r.label
                b.BackgroundColor3 = col()
            end)
        end
    end
    list.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 4)
end

-- NPC dropdown
local ddBtn
local dd = Instance.new("ScrollingFrame")
dd.Size = UDim2.fromOffset(280, 150)
dd.Position = UDim2.fromOffset(10, 128)
dd.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
dd.BorderSizePixel = 0
dd.ScrollBarThickness = 4
dd.ZIndex = 10
dd.Visible = false
dd.CanvasSize = UDim2.new()
dd.Parent = pageQ
local ddLayout = Instance.new("UIListLayout", dd)
ddLayout.Padding = UDim.new(0, 2)

local function buildDropdown()
    for _, c in ipairs(dd:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
    for _, e in ipairs(npcs) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 24)
        b.BackgroundColor3 = Color3.fromRGB(45, 45, 62)
        b.Text = ("[I%s] %s%s"):format(e.island or "?", e.name, (#e.prompts + #e.clicks > 0) and " *" or "")
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.Gotham
        b.TextSize = 12
        b.TextTruncate = Enum.TextTruncate.AtEnd
        b.ZIndex = 11
        b.Parent = dd
        b.MouseButton1Click:Connect(function()
            selected = { name = e.name, pos = e.pos }
            ddBtn.Text = "NPC: " .. e.name .. "  v"
            dd.Visible = false
            notify("Selected: " .. e.name)
        end)
    end
    dd.CanvasSize = UDim2.fromOffset(0, ddLayout.AbsoluteContentSize.Y + 4)
end

makeButton("Mark I1", 10, 4, 137, nil, function()
    local r = getRoot() if r then marks[1] = r.Position saveMarks() notify("Island 1 marked") end
end)
makeButton("Mark I2", 153, 4, 137, nil, function()
    local r = getRoot() if r then marks[2] = r.Position saveMarks() notify("Island 2 marked") end
end)
makeButton("TP Island 1", 10, 36, 137, nil, function()
    if marks[1] then teleportTo(marks[1], Vector3.new(0, 3, 0)) else notify("Mark Island 1 first") end
end)
makeButton("TP Island 2", 153, 36, 137, nil, function()
    if marks[2] then teleportTo(marks[2], Vector3.new(0, 3, 0)) else notify("Mark Island 2 first") end
end)
makeButton("Rescan NPCs", 10, 68, 280, Color3.fromRGB(50, 90, 140), function()
    scanNPCs() tab = "npc" render() buildDropdown()
    notify(#npcs .. " NPCs/objects found")
end)
ddBtn = makeButton("NPC: (tap to choose)  v", 10, 100, 280, Color3.fromRGB(90, 60, 130), function()
    if not dd.Visible then
        if #npcs == 0 then scanNPCs() render() end
        buildDropdown()
    end
    dd.Visible = not dd.Visible
end)
makeButton("Auto Accept (selected NPC): OFF", 10, 132, 280, Color3.fromRGB(60, 120, 70), function(b)
    if not selected then notify("Pick an NPC from the dropdown first!") return end
    autoQuest = not autoQuest
    b.Text = "Auto Accept (selected NPC): " .. (autoQuest and "ON" or "OFF")
    b.BackgroundColor3 = autoQuest and Color3.fromRGB(40, 170, 70) or Color3.fromRGB(60, 120, 70)
end)
recBtn = makeButton("Record Remotes: OFF", 10, 164, 190, Color3.fromRGB(140, 80, 50), function() toggleRecord(nil) end)
makeButton("Clear", 206, 164, 84, nil, function() clearGroup(nil) end)
makeButton("NPCs", 10, 204, 137, nil, function() tab = "npc" render() end)
makeButton("Recorded", 153, 204, 137, nil, function() tab = "rec" render() end)

-- ===== ROBIN PAGE =====
curParent = pageR
local statusLbl = makeLabel("Auto run is OFF", 10, 4, 280, 20, false)
makeButton("Run Robin Now", 10, 28, 280, Color3.fromRGB(50, 90, 140), function()
    task.spawn(robinRun)
end)
makeButton(("Auto Run every %d min: OFF"):format(CONFIG.Robin.IntervalSeconds / 60), 10, 60, 280, Color3.fromRGB(60, 120, 70), function(b)
    robinAuto = not robinAuto
    if robinAuto then nextRobinRun = os.time() end
    b.Text = ("Auto Run every %d min: %s"):format(CONFIG.Robin.IntervalSeconds / 60, robinAuto and "ON" or "OFF")
    b.BackgroundColor3 = robinAuto and Color3.fromRGB(40, 170, 70) or Color3.fromRGB(60, 120, 70)
end)
fishBtn = makeButton("Record Fishing: OFF", 10, 92, 190, Color3.fromRGB(140, 80, 50), function() toggleRecord("fish") end)
makeButton("Clear", 206, 92, 84, nil, function() clearGroup("fish") end)
arcBtn = makeButton("Record Arcade: OFF", 10, 124, 190, Color3.fromRGB(140, 80, 50), function() toggleRecord("arcade") end)
makeButton("Clear", 206, 124, 84, nil, function() clearGroup("arcade") end)
robBtn = makeButton("Record Robin Accept: OFF", 10, 156, 190, Color3.fromRGB(140, 80, 50), function() toggleRecord("robin") end)
makeButton("Clear", 206, 156, 84, nil, function() clearGroup("robin") end)
local repLbl = makeLabel("Macro repeats: " .. macroRepeats, 10, 194, 130, 20, false)
makeButton("-", 146, 188, 66, nil, function()
    macroRepeats = math.max(1, macroRepeats - 1) repLbl.Text = "Macro repeats: " .. macroRepeats
end)
makeButton("+", 218, 188, 72, nil, function()
    macroRepeats = math.min(30, macroRepeats + 1) repLbl.Text = "Macro repeats: " .. macroRepeats
end)
makeLabel("1) Stand near Robin and press Run Robin Now to test accepting.\n"
    .. "2) Fishing/Arcade: press Record, do ONE catch / ONE mini game by hand, press Record again. "
    .. "Steps replay each run (see Quests > Recorded to switch steps off).\n"
    .. "3) Turn Auto Run ON. 'Record Robin Accept' is a backup if the Accept buttons don't respond.",
    10, 226, 280, 150, true)

showPage("q")
render()
updateRecButtons()

-- auto-run timer + status
task.spawn(function()
    while alive do
        task.wait(1)
        if robinAuto and not busy and os.time() >= nextRobinRun then
            nextRobinRun = os.time() + CONFIG.Robin.IntervalSeconds
            task.spawn(robinRun)
        end
        if busy then
            statusLbl.Text = "Status: running..."
        elseif robinAuto then
            local left = math.max(0, nextRobinRun - os.time())
            statusLbl.Text = ("Next auto run in %02d:%02d"):format(math.floor(left / 60), left % 60)
        else
            statusLbl.Text = "Auto run is OFF"
        end
    end
end)

notify("Loaded. Use '-' to minimize into an icon.")
