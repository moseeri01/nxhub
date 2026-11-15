-- moseeri watch: remote recorder + game scanner for Anime Nexus RNG X (works in any game).
-- Same MacLib window as moseeri hub. Records only: it never fires a remote of its own.
-- Files go to the executor workspace folder "NexusWatch".
-- Lua 5.1 only (no +=, no continue, no goto).

local G = (getgenv and getgenv()) or _G
if G.__nexus_watch_stop then pcall(G.__nexus_watch_stop) end

local ok_maclib, MacLib = pcall(function()
    local why = {}
    for _, src in ipairs({ { "raw", "https://raw.githubusercontent.com/moseeri01/blueheater2/main/maclib.txt" },
        { "release", "https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt" } }) do
        local okG, body = pcall(function() return game:HttpGet(src[2]) end)
        local fn = okG and type(body) == "string" and #body > 100000 and loadstring(body) or nil
        local okC, lib = false, nil
        if type(fn) == "function" then okC, lib = pcall(fn) end
        if okC and type(lib) == "table" then return lib end
        why[#why + 1] = src[1] .. " failed"
    end
    error(table.concat(why, "; "))
end)
if not ok_maclib or not MacLib then
    warn("[moseeri watch] MacLib failed to load: " .. tostring(MacLib))
    return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local FOLDER = "NexusWatch"
local W = {
    watching = false,
    listening = false,
    log = {},          -- lines not written yet are flushed every few seconds
    count = 0,         -- outgoing calls seen this session
    inCount = 0,       -- incoming events seen this session
    dirty = false,
    last = "",
    conns = {},
    inLast = {},       -- remote -> os.clock() of the last logged incoming line
    inSkipped = {},    -- remote -> lines skipped by the rate cap
    noise = { "mouse", "camera", "heartbeat", "ping", "position", "input" },
    -- exact names the game calls on its own timer (seen 11-14: every 4 s / 30 s); Settings can turn this off
    poll = { NWPolicyPick = true, NWAfk = true, NWExploration = true, NWFpsDiag = true, NWHealth = true },
    skipPoll = true,
    -- incoming values that tick every second (ReplicaSet paths) - logged at most once a minute
    tickPaths = { GreaterLuckPotionRemaining = true, LuckPotionRemaining = true, PotionRemaining = true },
    inGap = 2,         -- seconds between two logged lines of the same incoming remote + same path
    alive = true,
}

local canFiles = type(writefile) == "function" and type(readfile) == "function"
    and type(isfolder) == "function" and type(makefolder) == "function"
local function ensureFolder()
    if canFiles then pcall(function() if not isfolder(FOLDER) then makefolder(FOLDER) end end) end
end
local function readSmall(path)
    local ok, s = pcall(function() return isfile(path) and readfile(path) or "" end)
    return ok and type(s) == "string" and s or ""
end
local function appendFile(path, text)
    if not canFiles then return false end
    ensureFolder()
    if type(appendfile) == "function" and pcall(function() return isfile(path) end) and isfile(path) then
        return pcall(appendfile, path, text)
    end
    return pcall(writefile, path, readSmall(path) .. text)
end
local function writeFile(path, text)
    if not canFiles then return false end
    ensureFolder()
    return pcall(writefile, path, text)
end

-- values -> readable text (tables 3 levels deep, Instances by full path)
local function describe(v, depth)
    local t = typeof(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    if t == "Instance" then
        local ok, p = pcall(function() return v:GetFullName() end)
        return "<" .. v.ClassName .. " " .. (ok and p or "?") .. ">"
    end
    if t == "table" then
        if depth >= 3 then return "{...}" end
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 40 then parts[#parts + 1] = "..." break end
            local key = type(k) == "string" and k or ("[" .. describe(k, depth + 1) .. "]")
            parts[#parts + 1] = key .. "=" .. describe(val, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return t .. "(" .. tostring(v) .. ")"
end
local function describeArgs(args)
    local parts = {}
    for i = 1, args.n or #args do parts[i] = describe(args[i], 0) end
    return table.concat(parts, ", ")
end
local function isNoise(name)
    if W.skipPoll and W.poll[name] then return true end
    local n = string.lower(name)
    for _, w in ipairs(W.noise) do if n:find(w, 1, true) then return true end end
    return false
end
local function addLine(line)
    W.log[#W.log + 1] = line
    W.last = line
    W.dirty = true
end

--------------------------------------------------------------------------------
-- Watch (outgoing): __namecall hook. Never make a method call inside the hook
-- itself (it replaces the game's namecall method) - the line is built later.
--------------------------------------------------------------------------------
-- (every callback runs inside pcall: the game sends client errors to its server through NWErrReport)
local function onOutgoing(remote, method, args)
    pcall(function()
        local name = remote.Name
        if isNoise(name) then return end
        local okP, path = pcall(function() return remote:GetFullName() end)
        W.count = W.count + 1
        addLine(string.format("%s -> %s %s(%s)", os.date("%H:%M:%S"), okP and path or name, method, describeArgs(args)))
    end)
end

local hookInstalled = false
local function installHook()
    if hookInstalled then return true end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return false
    end
    local wrap = type(newcclosure) == "function" and newcclosure or function(f) return f end
    local old
    old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        if W.watching and W.alive then
            local method = getnamecallmethod()
            if (method == "FireServer" or method == "InvokeServer")
                and not (type(checkcaller) == "function" and checkcaller()) then
                task.spawn(onOutgoing, self, method, table.pack(...))
                if type(setnamecallmethod) == "function" then setnamecallmethod(method) end
                -- (11-14: what the server answers to an InvokeServer - e.g. the Sorcerer King "state" with its open
                -- times. The answer is passed back unchanged; only a copy is written, later, on its own thread)
                if method == "InvokeServer" then
                    local res = table.pack(old(self, ...))
                    task.spawn(function()
                        pcall(function()
                            if isNoise(self.Name) then return end
                            addLine(string.format("%s <= %s answer(%s)", os.date("%H:%M:%S"), self.Name, describeArgs(res)))
                        end)
                    end)
                    return unpack(res, 1, res.n)
                end
            end
        end
        return old(self, ...)
    end))
    hookInstalled = true
    return true
end

--------------------------------------------------------------------------------
-- Listen (incoming): plain OnClientEvent connections, rate-capped per remote
--------------------------------------------------------------------------------
local function listenTo(remote)
    if not remote:IsA("RemoteEvent") then return end
    W.conns[#W.conns + 1] = remote.OnClientEvent:Connect(function(...)
        if not W.listening then return end
        local args = table.pack(...)
        pcall(function()
            if isNoise(remote.Name) then return end
            -- (11-14 fix: the cap was per remote, so one ticking ReplicaSet value hid StageData / NextWaveInfo.
            -- Now the cap key is remote + its first two args, e.g. ReplicaSet 1 {"StageData"})
            local key = remote.Name
            local gap = W.inGap
            if args.n >= 1 and type(args[1]) ~= "table" then key = key .. "|" .. tostring(args[1]) end
            if args.n >= 2 and type(args[2]) == "table" then
                local p = {}
                for i, v in ipairs(args[2]) do
                    p[i] = tostring(v)
                    if W.tickPaths[tostring(v)] then gap = 60 end
                end
                key = key .. "|" .. table.concat(p, ".")
            end
            local now = os.clock()
            local last = W.inLast[key]
            if last and now - last < gap then
                W.inSkipped[key] = (W.inSkipped[key] or 0) + 1
                return
            end
            W.inLast[key] = now
            local skipped = W.inSkipped[key] or 0
            W.inSkipped[key] = 0
            W.inCount = W.inCount + 1
            local okP, path = pcall(function() return remote:GetFullName() end)
            addLine(string.format("%s <- %s(%s)%s", os.date("%H:%M:%S"), okP and path or remote.Name,
                describeArgs(args), skipped > 0 and ("  (+" .. skipped .. " skipped)") or ""))
        end)
    end)
end
local function startListening()
    if W.listenReady then return end
    W.listenReady = true
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do listenTo(d) end
    W.conns[#W.conns + 1] = ReplicatedStorage.DescendantAdded:Connect(listenTo)
    -- (11-14: placing / upgrading go through Workspace.<player>.CharacterHandler.Remotes.UnitAction -
    -- the character's own remotes are listened too, again after every respawn)
    local function hookChar(char)
        if not char then return end
        for _, d in ipairs(char:GetDescendants()) do listenTo(d) end
        W.conns[#W.conns + 1] = char.DescendantAdded:Connect(listenTo)
    end
    hookChar(LocalPlayer.Character)
    W.conns[#W.conns + 1] = LocalPlayer.CharacterAdded:Connect(hookChar)
end

-- flush the log to NexusWatch/watch.txt every 3 s
task.spawn(function()
    while W.alive do
        task.wait(3)
        if W.dirty and #W.log > 0 then
            local chunk = table.concat(W.log, "\n") .. "\n"
            W.log = {}
            W.dirty = false
            appendFile(FOLDER .. "/watch.txt", chunk)
        end
    end
end)

--------------------------------------------------------------------------------
-- Scans (buttons only, never at start)
--------------------------------------------------------------------------------
local function tree(root, maxDepth, out, depth, cap)
    if #out >= cap then return end
    for _, c in ipairs(root:GetChildren()) do
        if #out >= cap then out[#out + 1] = "... (cut at " .. cap .. " lines)" return end
        local mark = ""
        if c:IsA("RemoteEvent") or c:IsA("RemoteFunction") or c:IsA("UnreliableRemoteEvent") then mark = "  <== REMOTE" end
        local kids = #c:GetChildren()
        out[#out + 1] = string.rep("  ", depth) .. c.Name .. " [" .. c.ClassName .. "]" .. (kids > 0 and (" (" .. kids .. ")") or "") .. mark
        if depth + 1 < maxDepth then tree(c, maxDepth, out, depth + 1, cap) end
    end
end

local function scanGame()
    local out = {}
    out[#out + 1] = "# scan " .. os.date("%Y-%m-%d %H:%M:%S")
    out[#out + 1] = "PlaceId " .. tostring(game.PlaceId) .. " | GameId " .. tostring(game.GameId) .. " | JobId " .. tostring(game.JobId)
    out[#out + 1] = ""
    out[#out + 1] = "## remotes (all of ReplicatedStorage)"
    local nRem = 0
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") then
            nRem = nRem + 1
            out[#out + 1] = d.ClassName .. "  " .. d:GetFullName()
        end
    end
    -- (11-14: the character carries remotes too - CharacterHandler.Remotes.UnitAction places / upgrades units)
    if LocalPlayer.Character then
        for _, d in ipairs(LocalPlayer.Character:GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") then
                nRem = nRem + 1
                out[#out + 1] = d.ClassName .. "  " .. d:GetFullName() .. "  (character)"
            end
        end
    end
    out[#out + 1] = "(" .. nRem .. " remotes)"
    out[#out + 1] = ""
    out[#out + 1] = "## ReplicatedStorage (5 levels)"
    tree(ReplicatedStorage, 5, out, 0, 3000)
    out[#out + 1] = ""
    out[#out + 1] = "## Workspace (3 levels)"
    tree(workspace, 3, out, 0, 1500)
    out[#out + 1] = ""
    out[#out + 1] = "## Player"
    for _, c in ipairs(LocalPlayer:GetChildren()) do
        out[#out + 1] = c.Name .. " [" .. c.ClassName .. "]"
        if c.Name == "leaderstats" then
            for _, s in ipairs(c:GetChildren()) do
                local ok, v = pcall(function() return s.Value end)
                out[#out + 1] = "  " .. s.Name .. " = " .. (ok and tostring(v) or "?")
            end
        end
    end
    local okA, attrs = pcall(function() return LocalPlayer:GetAttributes() end)
    if okA then
        for k, v in pairs(attrs) do out[#out + 1] = "  attr " .. k .. " = " .. describe(v, 0) end
    end
    out[#out + 1] = ""
    out[#out + 1] = "## PlayerGui screens"
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, g in ipairs(pg:GetChildren()) do
            local en = ""
            pcall(function() if g:IsA("ScreenGui") then en = g.Enabled and " (on)" or " (off)" end end)
            out[#out + 1] = g.Name .. " [" .. g.ClassName .. "]" .. en
        end
    end
    local name = FOLDER .. "/scan_" .. os.date("%m%d_%H%M%S") .. ".txt"
    writeFile(name, table.concat(out, "\n"))
    return name, nRem
end

-- the folder in Workspace that holds the most Models = probably the placed units / enemies
local function scanMap()
    local out = { "# map scan " .. os.date("%Y-%m-%d %H:%M:%S") }
    local rows = {}
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("Folder") or c:IsA("Model") then
            local models = 0
            for _, m in ipairs(c:GetChildren()) do if m:IsA("Model") then models = models + 1 end end
            if models > 0 then rows[#rows + 1] = { c, models } end
        end
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    for i, r in ipairs(rows) do
        if i > 12 then break end
        out[#out + 1] = ""
        out[#out + 1] = "## " .. r[1].Name .. " [" .. r[1].ClassName .. "] " .. r[2] .. " models"
        local shown = 0
        for _, m in ipairs(r[1]:GetChildren()) do
            if m:IsA("Model") and shown < 8 then
                shown = shown + 1
                local line = "  " .. m.Name
                local okA, attrs = pcall(function() return m:GetAttributes() end)
                if okA and next(attrs) then line = line .. " attrs " .. describe(attrs, 1) end
                out[#out + 1] = line
                for _, k in ipairs(m:GetChildren()) do
                    if k:IsA("ValueBase") or k:IsA("Folder") or k:IsA("Configuration") then
                        local okV, v = pcall(function() return k.Value end)
                        out[#out + 1] = "    " .. k.Name .. " [" .. k.ClassName .. "]" .. (okV and (" = " .. describe(v, 1)) or "")
                        if k:IsA("Folder") or k:IsA("Configuration") then
                            for _, s in ipairs(k:GetChildren()) do
                                local okS, sv = pcall(function() return s.Value end)
                                out[#out + 1] = "      " .. s.Name .. (okS and (" = " .. describe(sv, 1)) or (" [" .. s.ClassName .. "]"))
                            end
                        end
                    end
                end
            end
        end
    end
    local name = FOLDER .. "/map_" .. os.date("%m%d_%H%M%S") .. ".txt"
    writeFile(name, table.concat(out, "\n"))
    return name, #rows
end

-- require every ModuleScript under ReplicatedStorage (opt-in, 2 s limit each) and list its keys
local function scanModules(setStatus)
    local mods = {}
    -- (11-14: the game reported "Cmdr server module is somehow running on a client" through NWErrReport -
    -- Cmdr and anything named like server code is left out, so requiring it cannot raise that report)
    local skipped = 0
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d:IsA("ModuleScript") then
            local full = string.lower(d:GetFullName())
            if full:find("cmdr", 1, true) or full:find("server", 1, true) then
                skipped = skipped + 1
            else
                mods[#mods + 1] = d
            end
        end
    end
    local out = { "# modules " .. os.date("%Y-%m-%d %H:%M:%S") .. " | " .. #mods .. " ModuleScripts (" .. skipped .. " Cmdr/server ones left out)" }
    for i, m in ipairs(mods) do
        if not W.alive then break end
        if i % 20 == 0 then setStatus("Modules " .. i .. " / " .. #mods) end
        local done, okR, res = false, false, nil
        task.spawn(function()
            okR, res = pcall(require, m)
            done = true
        end)
        local t0 = os.clock()
        while not done and os.clock() - t0 < 2 do task.wait(0.05) end
        local line = m:GetFullName()
        if not done then
            line = line .. "  (no answer in 2 s)"
        elseif not okR then
            line = line .. "  (error " .. tostring(res):sub(1, 80) .. ")"
        elseif type(res) == "table" then
            local keys, n = {}, 0
            for k, v in pairs(res) do
                n = n + 1
                if n <= 25 then keys[#keys + 1] = tostring(k) .. ":" .. type(v) end
            end
            line = line .. "  {" .. n .. " keys} " .. table.concat(keys, ", ") .. (n > 25 and " ..." or "")
        else
            line = line .. "  = " .. type(res)
        end
        out[#out + 1] = line
    end
    local name = FOLDER .. "/modules_" .. os.date("%m%d_%H%M%S") .. ".txt"
    writeFile(name, table.concat(out, "\n"))
    return name, #mods
end

--------------------------------------------------------------------------------
-- UI (MacLib, as moseeri hub)
--------------------------------------------------------------------------------
local Window = MacLib:Window({
    Title = "moseeri watch",
    Subtitle = "Anime Nexus RNG X recorder",
    Size = UDim2.fromOffset(868, 650),
    DragStyle = 1,
    DisabledWindowControls = {},
    ShowUserInfo = false,
    Keybind = Enum.KeyCode.LeftControl,
    AcrylicBlur = false,
})
local function notify(msg)
    pcall(function() Window:Notify({ Title = "moseeri watch", Description = tostring(msg), Lifetime = 5 }) end)
end

local function fit()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    if vp.X < 1 or vp.Y < 1 then return end
    pcall(function() Window:SetScale(math.clamp(math.min(vp.X * 0.9 / 868, vp.Y * 0.9 / 650), 0.5, 1.5)) end)
end
fit()

local tabGroup = Window:TabGroup()
local watchTab = tabGroup:Tab({ Name = "Watch", Image = "rbxassetid://10734950309" })
local scanTab = tabGroup:Tab({ Name = "Scan", Image = "rbxassetid://10734950309" })
local setTab = tabGroup:Tab({ Name = "Settings", Image = "rbxassetid://10734950309" })

-- Watch tab
local wLeft = watchTab:Section({ Side = "Left" })
local wRight = watchTab:Section({ Side = "Right" })
local status = wLeft:Paragraph({ Header = "Status", Body = "Off" })
local function setStatus(text)
    pcall(function() status:UpdateBody(text) end)
end

-- (11-14: autoexecute starts the script again after every teleport - Watch / Listen / Skip timer calls are
-- saved in NexusWatch/settings.txt and come back on by themselves)
local SETTINGS = FOLDER .. "/settings.txt"
local saved = readSmall(SETTINGS)
local function savedOn(key, default)
    local v = saved:match(key .. "=(%d)")
    if v == nil then return default end
    return v == "1"
end
local function saveSettings()
    writeFile(SETTINGS, string.format("watch=%d\nlisten=%d\nskippoll=%d\n",
        W.watching and 1 or 0, W.listening and 1 or 0, W.skipPoll and 1 or 0))
end
local function setWatch(on)
    if on and not installHook() then
        notify("This executor has no hookmetamethod, so Watch cannot work.")
        return
    end
    if on and not W.watching then
        appendFile(FOLDER .. "/watch.txt", "\n# watch on " .. os.date("%Y-%m-%d %H:%M:%S") .. " | PlaceId " .. tostring(game.PlaceId) .. "\n")
    end
    W.watching = on
    saveSettings()
end
local function setListen(on)
    if on then startListening() end
    W.listening = on
    saveSettings()
end
local startWatch, startListen = savedOn("watch", false), savedOn("listen", false)
W.skipPoll = savedOn("skippoll", true)

wLeft:Toggle({
    Name = "Watch (what I send)",
    Default = startWatch,
    Callback = function(on) pcall(setWatch, on) end,
})
wLeft:Toggle({
    Name = "Listen (what the game sends)",
    Default = startListen,
    Callback = function(on) pcall(setListen, on) end,
})
wLeft:Button({
    Name = "Mark a moment",
    Callback = function()
        addLine("# ---- mark " .. os.date("%H:%M:%S") .. " ----")
        notify("Mark added to watch.txt")
    end,
})

wRight:Paragraph({
    Header = "How to use",
    Body = "1. Turn Watch + Listen on.\n2. Play by hand: roll, join a stage, place, upgrade, finish, press the result buttons.\n3. Press Mark a moment before each new thing.\n4. Files: Workspace/NexusWatch/watch.txt",
})
wRight:Button({
    Name = "Copy last 40 lines",
    Callback = function()
        if type(setclipboard) ~= "function" then notify("No setclipboard on this executor") return end
        local text = readSmall(FOLDER .. "/watch.txt") .. table.concat(W.log, "\n")
        local lines = {}
        for l in text:gmatch("[^\n]+") do lines[#lines + 1] = l end
        local from = math.max(1, #lines - 39)
        setclipboard(table.concat(lines, "\n", from))
        notify("Copied " .. (#lines - from + 1) .. " lines")
    end,
})
wRight:Button({
    Name = "Start a new watch file",
    Callback = function()
        local old = readSmall(FOLDER .. "/watch.txt")
        if old ~= "" then writeFile(FOLDER .. "/watch_" .. os.date("%m%d_%H%M%S") .. ".txt", old) end
        writeFile(FOLDER .. "/watch.txt", "")
        notify("Old file kept as watch_<time>.txt")
    end,
})

-- Scan tab
local sLeft = scanTab:Section({ Side = "Left" })
local sRight = scanTab:Section({ Side = "Right" })
sLeft:Button({
    Name = "Scan game (remotes, folders, player, screens)",
    Callback = function()
        local ok, name, n = pcall(scanGame)
        if ok then notify(n .. " remotes -> " .. name) else notify("Scan failed: " .. tostring(name)) end
    end,
})
sLeft:Button({
    Name = "Scan map (units / enemies on the map)",
    Callback = function()
        local ok, name, n = pcall(scanMap)
        if ok then notify(n .. " folders -> " .. name) else notify("Scan failed: " .. tostring(name)) end
    end,
})
-- (11-14: off. The 10:31 run sent two error reports to the game's server through NWErrReport - Cmdr and
-- Modules.GameData.EvolutionQuests fail when required on a client. Its result is already in data/modules_1114_103221.txt)
W.modulesLocked = true
sLeft:Button({
    Name = "Scan modules (locked - already done)",
    Callback = function()
        if W.modulesLocked then
            notify("Locked: it made the game send error reports. The module list is already saved.")
            return
        end
        task.spawn(function()
            local ok, name, n = pcall(scanModules, setStatus)
            if ok then notify(n .. " modules -> " .. name) else notify("Scan failed: " .. tostring(name)) end
        end)
    end,
})
-- (11-14: on MuMu many of the game's panels draw their buttons with no text. This writes every visible button in the
-- game's screens with its real text and its place on screen in pixels, so a blank box can be told apart. Reads only)
local function scanScreen()
    local out = { "# screen " .. os.date("%Y-%m-%d %H:%M:%S") .. " | x y w h (pixels) | path | text" }
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local function visible(o)
        local p = o
        while p and p ~= pg do
            if p:IsA("GuiObject") and not p.Visible then return false end
            if p:IsA("ScreenGui") and not p.Enabled then return false end
            p = p.Parent
        end
        return true
    end
    local n = 0
    for _, o in ipairs(pg and pg:GetDescendants() or {}) do
        if (o:IsA("TextButton") or o:IsA("ImageButton")) and visible(o) then
            local ap, as = o.AbsolutePosition, o.AbsoluteSize
            if as.X > 4 and as.Y > 4 then
                local text = o:IsA("TextButton") and o.Text or ""
                if text == "" then
                    -- (the label is often a TextLabel inside the button)
                    for _, d in ipairs(o:GetDescendants()) do
                        if d:IsA("TextLabel") and d.Text ~= "" then text = d.Text break end
                    end
                end
                n = n + 1
                out[#out + 1] = string.format("%d %d %d %d | %s | %s", ap.X, ap.Y, as.X, as.Y, o:GetFullName():gsub("^Players%.[^%.]+%.PlayerGui%.", ""), text:gsub("\n", " "))
            end
        end
    end
    local inset = game:GetService("GuiService"):GetGuiInset()
    out[2] = "(gui inset " .. tostring(inset) .. " | camera " .. tostring(workspace.CurrentCamera.ViewportSize) .. ")"
    local name = FOLDER .. "/screen_" .. os.date("%m%d_%H%M%S") .. ".txt"
    writeFile(name, table.concat(out, "\n"))
    return name, n
end
sLeft:Button({
    Name = "Scan screen buttons (what is open now)",
    Callback = function()
        local ok, name, n = pcall(scanScreen)
        if ok then notify(n .. " buttons -> " .. name) else notify("Scan failed: " .. tostring(name)) end
    end,
})
-- the same scan every 10 s while a game panel is open (no tap needed while the window is hidden)
task.spawn(function()
    local last = ""
    while W.alive do
        task.wait(10)
        if W.autoScreen then
            pcall(function()
                local name = scanScreen()
                local body = readSmall(name)
                local sig = body:gsub("^[^\n]*\n[^\n]*\n", "")
                if sig == last then pcall(delfile, name) else last = sig end
            end)
        end
    end
end)
W.autoScreen = true
sRight:Paragraph({
    Header = "When to scan",
    Body = "Scan game: once in the lobby, once inside a stage.\nScan map: inside a stage after placing 2-3 units, while enemies walk.\nScan modules: locked (done on 11-14).",
})

-- Settings tab
local cLeft = setTab:Section({ Side = "Left" })
cLeft:Input({
    Name = "Skip remotes with these words",
    Placeholder = "mouse,camera,ping",
    Default = table.concat(W.noise, ","),
    AcceptedCharacters = "All",
    Callback = function(text)
        local list = {}
        for w in tostring(text):gmatch("[^,%s]+") do list[#list + 1] = string.lower(w) end
        W.noise = list
    end,
})
cLeft:Toggle({
    Name = "Skip timer calls (NWPolicyPick, NWAfk ...)",
    Default = W.skipPoll,
    Callback = function(on) W.skipPoll = on pcall(saveSettings) end,
})
cLeft:Slider({
    Name = "Seconds between incoming lines (same remote)",
    Default = W.inGap,
    Minimum = 0,
    Maximum = 10,
    DisplayMethod = "Value",
    Precision = 0,
    Callback = function(v) W.inGap = tonumber(v) or 2 end,
})
cLeft:Button({
    Name = "Close watch",
    Callback = function() if G.__nexus_watch_stop then G.__nexus_watch_stop() end end,
})

-- (11-14: SelectTab does not exist - the window opened on an empty page; MacLib tabs have :Select())
pcall(function() watchTab:Select() end)

-- (11-14: on the phone there is no LeftControl - after minimize the window could not come back.
-- A small "MW" button brings it back / hides it)
pcall(function()
    local parent = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    local old = parent:FindFirstChild("NexusWatchToggle")
    if old then old:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "NexusWatchToggle"
    gui.IgnoreGuiInset = true -- (same row as the MN button)
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 999
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(52, 30)
    b.Position = UDim2.new(1, -200, 0, 120)
    b.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
    b.BackgroundTransparency = 0.15
    b.TextColor3 = Color3.fromRGB(230, 230, 230)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.Text = "MW"
    b.Parent = gui
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 8)
    c.Parent = b
    gui.Parent = parent
    W.toggleGui = gui
    b.MouseButton1Click:Connect(function()
        pcall(function()
            local okS, shown = pcall(function() return Window:GetState() end)
            if not okS then shown = W.shown ~= false end
            W.shown = not shown
            Window:SetState(W.shown)
        end)
    end)
end)

-- status line every second
task.spawn(function()
    while W.alive do
        setStatus(string.format("Watch %s | Listen %s\nSent %d | Received %d\nLast: %s",
            W.watching and "ON" or "off", W.listening and "ON" or "off", W.count, W.inCount, W.last:sub(1, 120)))
        task.wait(1)
    end
end)

G.__nexus_watch_stop = function()
    W.alive = false
    W.watching = false
    W.listening = false
    for _, c in ipairs(W.conns) do pcall(function() c:Disconnect() end) end
    W.conns = {}
    if #W.log > 0 then appendFile(FOLDER .. "/watch.txt", table.concat(W.log, "\n") .. "\n") W.log = {} end
    pcall(function() Window:Unload() end)
    pcall(function() if W.toggleGui then W.toggleGui:Destroy() end end)
end

ensureFolder()
-- turn back on what was on before the teleport (same functions as the toggles; a second call is harmless)
if startWatch then pcall(setWatch, true) end
if startListen then pcall(setListen, true) end
if not canFiles then notify("This executor cannot write files: use Copy last 40 lines.") end
-- (11-14: starts hidden so it does not cover the farm window; MW opens it)
W.shown = false
pcall(function() Window:SetState(false) end)
notify("Ready. MW shows the recorder window.")
