-- moseeri nexus: Farm + In stage for Anime Nexus RNG X. Own window in the moseeri hub (AA) style.
-- Remotes from the 11-14 recordings (data/watch_run2.txt, watch_run3.txt):
--   start   Remotes.StageEnd:FireServer("StartMatch", act, diff, "Go", map)
--   defend  Remotes.NWAction:FireServer({op="Start", type="FateDefend", diff=diff, mods={}}) then StartMatch(1, diff, "Go", "FateDefend")
--   replay  Remotes.StageEnd:FireServer("Replay")
--   place   <char>.CharacterHandler.Remotes.UnitAction:FireServer("Place", uuid, Vector3, 0)
--   upgrade UnitAction:FireServer("Upgrade", model) | skill UnitAction:FireServer("Active", model, 1)
--   events  Remotes.StageEnd <- ("ShowResults", {Result="Win"/"Failed", Act, StageName...}) ; RemoteEvents.ReplicaSet <- CurrentWave / EquippedUnits / LastStage
-- Lua 5.1 only. Every callback runs in pcall: the game reports client errors to its server (NWErrReport).

local G = (getgenv and getgenv()) or _G
if G.__nexus_farm_stop then pcall(G.__nexus_farm_stop) end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LP = Players.LocalPlayer
local Remotes = RS:WaitForChild("Remotes", 20)
local RepEvents = RS:FindFirstChild("RemoteEvents")
local FOLDER = "NexusFarm"

local F = {
    alive = true,
    conns = {},
    cfg = {
        autoJoin = false, mode = "Story", map = "HiddenGround", act = 1, diff = "Normal",
        afterWin = "Replay", afterLoss = "Retry", autoPlace = false, autoUpgrade = false,
        autoSkill = false, perUnit = 3, maxUnits = 12, radius = 7, waitResult = 8,
        stopRarities = { Legendary = true, Mythic = true, Divine = true, Ascendant = true, Nexus = true, Secret = true },
        stopShiny = true, stopNames = "", stopEarly = false, autoBoss = false, autoMine = false, mineTick = 0.5,
    },
    centers = {},       -- base index -> {x,y,z}: where the units go around
    learned = {},       -- base index -> list of {x,y,z} taken from the player's own placements
    equipped = {},      -- slot "1".."6" -> uuid
    mine = {},          -- list of {model=, uuid=, at=Vector3}
    perUuid = {},       -- uuid -> placed count this match
    failYen = {},       -- uuid -> yen at the last failed place
    inMatch = false, wave = 0, lastWaveAt = 0,
    wins = 0, losses = 0, lastResult = "", lastAction = "",
    resultAt = nil, resultWin = nil, startedAt = 0,
}

--------------------------------------------------------------------------------
-- files
--------------------------------------------------------------------------------
local canFiles = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local function ensureFolder()
    if canFiles and type(isfolder) == "function" and type(makefolder) == "function" then
        pcall(function() if not isfolder(FOLDER) then makefolder(FOLDER) end end)
    end
end
local logLines = {}
local function log(msg)
    F.lastAction = os.date("%H:%M:%S ") .. tostring(msg)
    logLines[#logLines + 1] = F.lastAction
end
local function saveAll()
    if not canFiles then return end
    ensureFolder()
    pcall(function()
        writefile(FOLDER .. "/config.json", HttpService:JSONEncode({ cfg = F.cfg, centers = F.centers, learned = F.learned }))
    end)
end
local function loadAll()
    if not canFiles then return end
    pcall(function()
        if not isfile(FOLDER .. "/config.json") then return end
        local d = HttpService:JSONDecode(readfile(FOLDER .. "/config.json"))
        if type(d.cfg) == "table" then for k, v in pairs(d.cfg) do if F.cfg[k] ~= nil then F.cfg[k] = v end end end
        if type(d.centers) == "table" then F.centers = d.centers end
        if type(d.learned) == "table" then F.learned = d.learned end
    end)
end
loadAll()
task.spawn(function()
    while F.alive do
        task.wait(5)
        if #logLines > 0 and canFiles then
            ensureFolder()
            local chunk = table.concat(logLines, "\n") .. "\n"
            logLines = {}
            pcall(function()
                local old = isfile(FOLDER .. "/log.txt") and readfile(FOLDER .. "/log.txt") or ""
                writefile(FOLDER .. "/log.txt", old:sub(-60000) .. chunk)
            end)
        end
    end
end)

--------------------------------------------------------------------------------
-- game reads
--------------------------------------------------------------------------------
local function yen()
    local v = LP:GetAttribute("Yen")
    return tonumber(v) or 0
end
local function baseKey()
    return tostring(LP:GetAttribute("NWBaseIndex") or "0")
end
local function root()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function unitAction()
    local c = LP.Character
    local h = c and c:FindFirstChild("CharacterHandler")
    local r = h and h:FindFirstChild("Remotes")
    return r and r:FindFirstChild("UnitAction")
end
local function entities()
    return workspace:FindFirstChild("Entities")
end
local function modelPos(m)
    local ok, p = pcall(function() return m:GetPivot().Position end)
    return ok and p or nil
end

-- the team: replica data holds EquippedUnits {"1"=uuid ...}. Read once from memory, then kept
-- up to date by ReplicaSet events (nothing is required, nothing is called)
local function readTeamFromMemory()
    if type(getgc) ~= "function" then return false end
    local found = false
    pcall(function()
        for _, t in ipairs(getgc(true)) do
            if type(t) == "table" then
                local eq = rawget(t, "EquippedUnits")
                if type(eq) == "table" and rawget(t, "Inventory") ~= nil then
                    local n = 0
                    for k, v in pairs(eq) do
                        if type(v) == "string" and #v > 20 then F.equipped[tostring(k)] = v n = n + 1 end
                    end
                    if n > 0 then found = true break end
                end
            end
        end
    end)
    return found
end
local function teamList()
    local list = {}
    for i = 1, 6 do
        local u = F.equipped[tostring(i)]
        if type(u) == "string" and #u > 20 then list[#list + 1] = u end
    end
    return list
end

--------------------------------------------------------------------------------
-- spots: learned from the player's own placements on this base, else a ring around the base center
--------------------------------------------------------------------------------
local function groundAt(x, y, z)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    if LP.Character then ignore[#ignore + 1] = LP.Character end
    if entities() then ignore[#ignore + 1] = entities() end
    params.FilterDescendantsInstances = ignore
    local hit = workspace:Raycast(Vector3.new(x, y + 25, z), Vector3.new(0, -80, 0), params)
    if hit then return hit.Position end
    return Vector3.new(x, y, z)
end
local function setCenterHere()
    local r = root()
    if not r then return false end
    local g = groundAt(r.Position.X, r.Position.Y, r.Position.Z)
    F.centers[baseKey()] = { g.X, g.Y, g.Z }
    saveAll()
    log(string.format("base center set %.1f %.1f %.1f (base %s)", g.X, g.Y, g.Z, baseKey()))
    return true
end
local function spots()
    local out = {}
    local learned = F.learned[baseKey()]
    if type(learned) == "table" then
        for _, p in ipairs(learned) do out[#out + 1] = Vector3.new(p[1], p[2], p[3]) end
    end
    local c = F.centers[baseKey()]
    if not c then
        local r = root()
        if r then c = { r.Position.X, r.Position.Y, r.Position.Z } end
    end
    if c then
        local rad = tonumber(F.cfg.radius) or 7
        for ring = 1, 2 do
            local rr = rad * (ring == 1 and 0.7 or 1.2)
            for i = 0, 7 do
                local a = math.rad(i * 45 + (ring == 2 and 22.5 or 0))
                out[#out + 1] = groundAt(c[1] + math.cos(a) * rr, c[2], c[3] + math.sin(a) * rr)
            end
        end
    end
    return out
end
local function spotFree(p)
    for _, m in ipairs(F.mine) do
        if m.at and (m.at - p).Magnitude < 2.5 then return false end
    end
    return true
end

--------------------------------------------------------------------------------
-- actions
--------------------------------------------------------------------------------
local function fire(remote, ...)
    if not remote then return false end
    local args = { ... }
    local n = select("#", ...)
    return pcall(function() remote:FireServer(unpack(args, 1, n)) end)
end
local function resetMatch()
    F.mine = {}
    F.perUuid = {}
    F.failYen = {}
end
local function startStage(act)
    local c = F.cfg
    resetMatch()
    F.resultAt = nil
    F.startedAt = os.clock()
    local se = Remotes and Remotes:FindFirstChild("StageEnd")
    if c.mode == "Defend" then
        fire(Remotes:FindFirstChild("NWAction"), { op = "Start", type = "FateDefend", diff = c.diff, mods = {} })
        task.wait(1)
        fire(se, "StartMatch", 1, c.diff, "Go", "FateDefend")
        log("start Defend " .. c.diff)
    else
        fire(se, "StartMatch", act or tonumber(c.act) or 1, c.diff, "Go", c.map)
        log("start " .. c.map .. " act " .. tostring(act or c.act) .. " " .. c.diff)
    end
end
local function replay()
    resetMatch()
    F.resultAt = nil
    F.startedAt = os.clock()
    fire(Remotes and Remotes:FindFirstChild("StageEnd"), "Replay")
    log("replay")
end

-- place one unit: the new model that shows up in Entities near the spot within 2 s is ours
local placing = false
local function tryPlace()
    if placing or os.clock() < (F.arenaPauseUntil or 0) then return end
    local ua = unitAction()
    local team = teamList()
    if not ua or #team == 0 then return end
    if #F.mine >= (tonumber(F.cfg.maxUnits) or 12) then return end
    local y = yen()
    for _, uuid in ipairs(team) do
        local count = F.perUuid[uuid] or 0
        local failed = F.failYen[uuid]
        if count < (tonumber(F.cfg.perUnit) or 3) and (not failed or y > failed.yen + 100 or os.clock() - failed.at > 6) then
            local spot
            for _, p in ipairs(spots()) do
                if spotFree(p) then spot = p break end
            end
            if not spot then return end
            placing = true
            local ents = entities()
            local before = {}
            if ents then for _, m in ipairs(ents:GetChildren()) do before[m] = true end end
            fire(ua, "Place", uuid, spot, 0)
            local got
            local t0 = os.clock()
            while not got and os.clock() - t0 < 2 do
                task.wait(0.15)
                if ents then
                    for _, m in ipairs(ents:GetChildren()) do
                        if not before[m] then
                            local p = modelPos(m)
                            if p and (Vector3.new(p.X, spot.Y, p.Z) - spot).Magnitude < 4 then got = m break end
                        end
                    end
                end
            end
            placing = false
            if got then
                F.mine[#F.mine + 1] = { model = got, uuid = uuid, at = spot }
                F.perUuid[uuid] = count + 1
                F.failYen[uuid] = nil
                log("placed " .. got.Name)
            else
                F.failYen[uuid] = { yen = y, at = os.clock() }
            end
            return
        end
    end
end

-- (11-14 test: a refused upgrade shows "Not enough Yen : upgrade costs $N" on screen (NWNotify). That price is kept
-- on the unit and it is not tried again until the yen reaches it - no more red text every 1.5 s)
local lastUpgrade, upIndex, lastUpUnit, lastUpAt = 0, 0, nil, 0
local function tryUpgrade()
    if os.clock() - lastUpgrade < 1.2 then return end
    local ua = unitAction()
    if not ua or #F.mine == 0 then return end
    local y = yen()
    for _ = 1, #F.mine do
        upIndex = upIndex % #F.mine + 1
        local m = F.mine[upIndex]
        if m and m.model and m.model.Parent and (not m.need or y >= m.need) then
            lastUpgrade = os.clock()
            m.need = nil
            lastUpUnit, lastUpAt = m, os.clock()
            fire(ua, "Upgrade", m.model)
            return
        end
    end
end
pcall(function()
    local nn = Remotes:FindFirstChild("NWNotify")
    if nn and nn:IsA("RemoteEvent") then
        F.conns[#F.conns + 1] = nn.OnClientEvent:Connect(function(msg)
            pcall(function()
                local text = type(msg) == "table" and tostring(msg.text) or tostring(msg)
                if text:find("own arena", 1, true) then
                    -- (11-14: the player went to the lobby while the stage ran on - 148 refused places. Wait 20 s)
                    F.arenaPauseUntil = os.clock() + 20
                end
                local cost = text:match("upgrade costs %$(%d+)")
                if cost and lastUpUnit and os.clock() - lastUpAt < 2 then
                    -- (copies of the same unit at the same level cost the same: they wait too, one red line not three)
                    local base = tostring(lastUpUnit.uuid)
                    for _, m in ipairs(F.mine) do
                        if m.uuid == base and not m.need then m.need = tonumber(cost) end
                    end
                    lastUpUnit.need = tonumber(cost)
                end
            end)
        end)
    end
end)

local lastSkill = 0
local function trySkill()
    -- (11-15: slots 2-3 taken back until the game's skill data is read - owner: find the method first)
    if os.clock() - lastSkill < 5 then return end
    local ua = unitAction()
    if not ua then return end
    lastSkill = os.clock()
    for _, m in ipairs(F.mine) do
        if m.model and m.model.Parent then fire(ua, "Active", m.model, 1) end
    end
end

--------------------------------------------------------------------------------
-- game events (plain connections: nothing is hooked for these)
--------------------------------------------------------------------------------
local function onResult(info)
    if type(info) ~= "table" then return end
    local win = info.Result == "Win"
    if win then F.wins = F.wins + 1 else F.losses = F.losses + 1 end
    F.lastResult = string.format("%s %s act %s wave %s", tostring(info.Result), tostring(info.StageName), tostring(info.Act), tostring(info.Wave))
    F.inMatch = false
    F.resultAt = os.clock()
    F.resultWin = win
    F.resultAct = tonumber(info.Act)
    log("result " .. F.lastResult)
end
pcall(function()
    local se = Remotes:FindFirstChild("StageEnd")
    if se and se:IsA("RemoteEvent") then
        F.conns[#F.conns + 1] = se.OnClientEvent:Connect(function(kind, info)
            pcall(function()
                if kind == "ShowResults" then onResult(info)
                elseif kind == "Close" then
                    -- (the game closes the result screen after 6 s and starts the next stage itself: Auto Next
                    -- on = next act, off = the same act again. New match: our unit list starts empty)
                    F.closedAt = os.clock()
                    resetMatch()
                end
            end)
        end)
    end
end)
pcall(function()
    local rs = RepEvents and RepEvents:FindFirstChild("ReplicaSet")
    if rs then
        F.conns[#F.conns + 1] = rs.OnClientEvent:Connect(function(_, path, value)
            pcall(function()
                if type(path) ~= "table" then return end
                -- (11-14: replica 1 also carries other players' stages - TrainingGrounds act 4, GemRush - so it only
                -- feeds the wave shown; "in a stage" comes from StageStats, which the game sends to this player only)
                if path[1] == "CurrentWave" then
                    F.wave = tonumber(value) or F.wave
                elseif path[1] == "EquippedUnits" and path[2] then
                    F.equipped[tostring(path[2])] = value
                end
            end)
        end)
    end
end)

pcall(function()
    local st = Remotes:FindFirstChild("StageStats")
    if st and st:IsA("RemoteEvent") then
        F.conns[#F.conns + 1] = st.OnClientEvent:Connect(function()
            F.lastWaveAt = os.clock()
            F.inMatch = true
        end)
    end
end)

-- After win / After loss are the game's own Auto Next / Auto Retry (the game starts the stage 6 s after a result);
-- sent once when they change. The macro only starts a stage itself when nothing started (Act 1, Picked stage, fallback)
local sentSettings = {}
local function syncGameSettings()
    if not F.cfg.autoJoin then return end
    local want = { AutoNext = F.cfg.afterWin == "Next act", AutoRetry = F.cfg.afterLoss == "Retry" }
    local cs = Remotes and Remotes:FindFirstChild("ChangeSetting")
    for k, v in pairs(want) do
        if sentSettings[k] ~= v then
            sentSettings[k] = v
            fire(cs, k, v)
            log("game setting " .. k .. " = " .. tostring(v))
        end
    end
end

-- learn spots from the player's own hand placements (hook only reads; the game's call goes out unchanged)
pcall(function()
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then return end
    local wrap = type(newcclosure) == "function" and newcclosure or function(f) return f end
    local old
    old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        if F.alive and F.learnSpots then
            local method = getnamecallmethod()
            if method == "FireServer" and not (type(checkcaller) == "function" and checkcaller()) then
                local a1, _, a3 = ...
                if a1 == "Place" and typeof(a3) == "Vector3" then
                    task.spawn(function()
                        pcall(function()
                            local k = baseKey()
                            F.learned[k] = F.learned[k] or {}
                            table.insert(F.learned[k], { a3.X, a3.Y, a3.Z })
                            log(string.format("learned spot %.1f %.1f %.1f", a3.X, a3.Y, a3.Z))
                            saveAll()
                        end)
                    end)
                end
                if type(setnamecallmethod) == "function" then setnamecallmethod(method) end
            end
        end
        return old(self, ...)
    end))
end)

--------------------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------------------
task.spawn(function()
    -- (11-14 test: autoexecute runs during the loading screen - a start sent then was lost and the team read 0.
    -- Wait for the game, the character and a few seconds; the team is read again every 5 s until found)
    pcall(function() if not game:IsLoaded() then game.Loaded:Wait() end end)
    local t0 = os.clock()
    while F.alive and not (LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")) and os.clock() - t0 < 60 do task.wait(0.5) end
    task.wait(8)
    F.ready = true
    local lastTeamTry = 0
    while F.alive do
        if #teamList() == 0 and os.clock() - lastTeamTry > 5 then
            lastTeamTry = os.clock()
            if readTeamFromMemory() then log("team " .. #teamList()) end
        end
        pcall(function()
            -- drop units that left the map (sold, match over)
            for i = #F.mine, 1, -1 do
                local m = F.mine[i]
                if not (m.model and m.model.Parent) then table.remove(F.mine, i) end
            end
            if F.inMatch and os.clock() - F.lastWaveAt > 25 then F.inMatch = false end
            syncGameSettings()
            -- the game started the next stage itself after the result screen closed: nothing to do
            if F.resultAt and F.closedAt and F.closedAt > F.resultAt and F.lastWaveAt > F.closedAt then
                F.resultAt = nil
                F.startedAt = os.clock()
            end
            if F.inMatch or os.clock() - F.startedAt < 20 or os.clock() - (F.closedAt or -99) < 20 then
                if F.cfg.autoPlace then tryPlace() end
                if F.cfg.autoUpgrade then tryUpgrade() end
                if F.cfg.autoSkill then trySkill() end
            end
            -- after a result: the game closes it after 6 s and may start the next stage itself; when nothing
            -- started within the wait after that, the macro starts it
            local since = F.closedAt and F.resultAt and F.closedAt > F.resultAt and F.closedAt or (F.resultAt and F.resultAt + 6)
            if F.cfg.autoJoin and F.resultAt and not F.inMatch and since and os.clock() - since > (tonumber(F.cfg.waitResult) or 8) then
                local what = F.resultWin and F.cfg.afterWin or F.cfg.afterLoss
                F.resultAt = nil
                if what == "Replay" or what == "Retry" then
                    replay()
                elseif what == "Next act" then
                    local nextAct = math.min((F.resultAct or tonumber(F.cfg.act) or 1) + 1, 6)
                    F.cfg.act = nextAct
                    startStage(nextAct)
                elseif what == "Act 1" then
                    startStage(1)
                else
                    startStage()
                end
            end
            -- nothing running at all: start the picked stage
            if F.cfg.autoJoin and not F.inMatch and not F.resultAt and os.clock() - F.startedAt > 25 and os.clock() - F.lastWaveAt > 30 then
                startStage()
            end
        end)
        task.wait(0.5)
    end
end)

--------------------------------------------------------------------------------
-- Sorcerer King world boss (seen 11-14 13:04): Remotes.NWSorcererKing:InvokeServer("join") answers {ok=true} and puts the
-- player in the queue ("Finding players..."); a full queue teleports to the boss place 79484052673102 as a co-op run.
-- It opens every hour; while closed the panel says "Closed". The macro asks to join once a minute from the main place,
-- waits 4 minutes after an accepted join (queue / fight), and never asks inside the boss place.
--------------------------------------------------------------------------------
local BOSS_PLACE = 79484052673102
F.boss = { lastTry = 0, waitUntil = 0, last = "-" }
task.spawn(function()
    while F.alive do
        task.wait(5)
        if F.cfg.autoBoss and F.ready and game.PlaceId ~= BOSS_PLACE
            and os.clock() > F.boss.waitUntil and os.clock() - F.boss.lastTry > 60 then
            F.boss.lastTry = os.clock()
            pcall(function()
                local r = Remotes:FindFirstChild("NWSorcererKing")
                if not r then return end
                local ok, res = pcall(function() return r:InvokeServer("join") end)
                if ok and type(res) == "table" and res.ok then
                    F.boss.waitUntil = os.clock() + 240
                    F.boss.last = os.date("%H:%M") .. " joined the queue"
                    log("boss: joined the Sorcerer King queue")
                else
                    local msg = type(res) == "table" and tostring(res.msg or res.err or "closed") or tostring(res)
                    F.boss.last = os.date("%H:%M") .. " " .. msg:sub(1, 40)
                end
            end)
        end
    end
end)
if game.PlaceId == BOSS_PLACE then log("boss: in the Sorcerer King place") end

--------------------------------------------------------------------------------
-- Gurren mine (seen 11-15): Remotes.NWGMine:InvokeServer("Enter") answers {ok, rocks={{id, type, pos, crystal}...}};
-- RemoteEvent NWGMineEv <- ("s", id, type, pos, crystal) a rock appears, ("b", id, amount, ...) a rock breaks;
-- a hit is NWGMineEv:FireServer("h", id). The owner's account has the pass that mines every rock at once, so each
-- round hits every known rock once. One round every mineTick seconds (0.5 s = 2 hits a second per rock).
--------------------------------------------------------------------------------
F.gmine = { rocks = {}, count = 0, broken = 0, entered = 0, last = "-" }
local function mineRemotes()
    return Remotes:FindFirstChild("NWGMine"), Remotes:FindFirstChild("NWGMineEv")
end
local function rockCount()
    local n = 0
    for _ in pairs(F.gmine.rocks) do n = n + 1 end
    return n
end
local function mineEnter()
    local rf = mineRemotes()
    if not rf then return false end
    local ok, res = pcall(function() return rf:InvokeServer("Enter", nil) end)
    F.gmine.entered = os.clock()
    if ok and type(res) == "table" and res.ok and type(res.rocks) == "table" then
        F.gmine.rocks = {}
        for _, r in ipairs(res.rocks) do
            if type(r) == "table" and r[1] then F.gmine.rocks[r[1]] = { type = r[2], pos = r[3] } end
        end
        F.gmine.last = os.date("%H:%M") .. " entered, " .. rockCount() .. " rocks"
        log("mine: entered, " .. rockCount() .. " rocks")
        return true
    end
    F.gmine.last = os.date("%H:%M") .. " enter refused: " .. (type(res) == "table" and tostring(res.msg or res.err) or tostring(res)):sub(1, 40)
    return false
end
pcall(function()
    local _, ev = mineRemotes()
    if not (ev and ev:IsA("RemoteEvent")) then return end
    F.conns[#F.conns + 1] = ev.OnClientEvent:Connect(function(kind, id, a3, a4)
        pcall(function()
            if kind == "s" and id then
                F.gmine.rocks[id] = { type = a3, pos = a4 }
            elseif kind == "b" and id then
                F.gmine.rocks[id] = nil
                F.gmine.broken = F.gmine.broken + 1
            end
        end)
    end)
end)
task.spawn(function()
    while F.alive do
        local tick = math.clamp(tonumber(F.cfg.mineTick) or 0.5, 0.2, 3)
        task.wait(tick)
        if F.cfg.autoMine and F.ready then
            pcall(function()
                -- (11-15 bug: "Enter" teleports the character into the mine. The list ran empty every ~20 s and the
                -- re-enter pulled the player back 10 times in 3.5 min - the owner could not walk to the Event.
                -- Now it only mines and re-enters while the character is IN the mine (within 200 studs of it);
                -- walk or teleport away and it stops on its own. Switching Auto mine on enters once.)
                local r = root()
                local near = r and (Vector3.new(r.Position.X, 0, r.Position.Z) - Vector3.new(-14000, 0, 14010)).Magnitude < 200
                if not near then return end
                if rockCount() == 0 and os.clock() - F.gmine.entered > 20 then mineEnter() end
                local _, ev = mineRemotes()
                if not ev then return end
                for id in pairs(F.gmine.rocks) do
                    ev:FireServer("h", id)
                    F.gmine.count = F.gmine.count + 1
                end
            end)
        end
    end
end)

--------------------------------------------------------------------------------
-- Roll: uses the game's own auto roll (ChangeSetting "AutoRoll", seen 11-14) and stops it when a roll matches.
-- RollResult <- {rolls={{name, rarity, shiny, uuid}}, next={name, shiny}, total} : next = what the NEXT roll gives
--------------------------------------------------------------------------------
local R = { log = {}, count = 0, next = nil, nextShiny = false, rarityOf = {} }
R.on = false -- (always off at start: it only rolls after the switch is pressed)
-- (11-14 test: switching the game's AutoRoll setting on did not roll at all in 40 s - the game's loop starts from its
-- own button. So the macro sends the rolls itself, the same call the game sends: RequestRoll({auto, reqId, count, fast}).
-- Its reqId counter starts at 1000 so its results are told apart from the game's)
R.reqId, R.cooldown, R.lastAt = 1000, 1.2, 0
local function setGameAutoRoll(on)
    R.on = on and true or false
    log("auto roll " .. (on and "on" or "off"))
end
task.spawn(function()
    while F.alive do
        if R.on and os.clock() - R.lastAt > R.cooldown + 0.4 then
            R.lastAt = os.clock()
            R.reqId = R.reqId + 1
            fire(Remotes and Remotes:FindFirstChild("RequestRoll"), { auto = true, reqId = R.reqId, count = 1, fast = false })
        end
        task.wait(0.2)
    end
end)
-- a unit's rarity from its data module (UnitData.<name>.Rarity); only needed for "stop one roll early"
local function rarityOf(name)
    if R.rarityOf[name] ~= nil then return R.rarityOf[name] end
    local rar = false
    pcall(function()
        local folder = RS.Modules.Shared.Data.UnitData
        local m = folder:FindFirstChild(name, true)
        if m and m:IsA("ModuleScript") then
            local d = require(m)
            if type(d) == "table" and type(d.Rarity) == "string" then rar = d.Rarity end
        end
    end)
    R.rarityOf[name] = rar
    return rar
end
local function wanted(name, rarity, shiny)
    if shiny and F.cfg.stopShiny then return "shiny " .. tostring(name) end
    if rarity and F.cfg.stopRarities[rarity] then return tostring(rarity) .. " " .. tostring(name) end
    for w in tostring(F.cfg.stopNames):gmatch("[^,]+") do
        w = w:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if #w > 1 and tostring(name):lower():find(w, 1, true) then return tostring(name) end
    end
    return nil
end
pcall(function()
    local rr = Remotes:FindFirstChild("RollResult")
    if rr and rr:IsA("RemoteEvent") then
        F.conns[#F.conns + 1] = rr.OnClientEvent:Connect(function(res)
            pcall(function()
                if type(res) ~= "table" then return end
                if tonumber(res.cooldown) then R.cooldown = math.clamp(tonumber(res.cooldown), 0.3, 5) end
                local hit
                for _, r in ipairs(type(res.rolls) == "table" and res.rolls or {}) do
                    R.count = R.count + 1
                    table.insert(R.log, 1, string.format("%s %s%s", tostring(r.name), tostring(r.rarity), r.shiny and " shiny" or ""))
                    if #R.log > 8 then table.remove(R.log) end
                    if r.rarity then R.rarityOf[tostring(r.name)] = r.rarity end
                    hit = hit or wanted(r.name, r.rarity, r.shiny)
                end
                if type(res.next) == "table" then
                    R.next, R.nextShiny = res.next.name, res.next.shiny and true or false
                    if not hit and F.cfg.stopEarly then
                        local nh = wanted(R.next, rarityOf(tostring(R.next)), R.nextShiny)
                        if nh then hit = "next is " .. nh end
                    end
                end
                if hit and R.on then
                    setGameAutoRoll(false)
                    R.stopped = hit
                    log("roll stop: " .. hit)
                    pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", { Title = "moseeri nexus", Text = "Auto roll stopped: " .. hit, Duration = 8 }) end)
                end
            end)
        end)
    end
end)

--------------------------------------------------------------------------------
-- UI: own window in the moseeri hub (AA) style - wide, tabs across the top, two columns of cards.
-- Same theme values as AA (UIRef.Theme). No MacLib.
--------------------------------------------------------------------------------
local UIS = game:GetService("UserInputService")
local T = {
    bg = Color3.fromRGB(11, 11, 13), headBg = Color3.fromRGB(4, 4, 5), card = Color3.fromRGB(17, 17, 21),
    line = Color3.fromRGB(30, 30, 37), text = Color3.fromRGB(212, 212, 218), value = Color3.fromRGB(180, 180, 190),
    mute = Color3.fromRGB(138, 138, 148), faint = Color3.fromRGB(88, 88, 98), accent = Color3.fromRGB(138, 180, 255),
    onAccent = Color3.fromRGB(11, 11, 13), off = Color3.fromRGB(44, 44, 52), good = Color3.fromRGB(143, 209, 158),
    bad = Color3.fromRGB(232, 104, 104), white = Color3.fromRGB(236, 236, 242),
}
local UI = { pages = {}, tabs = {}, refreshers = {} }

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end
local function stroke(o, c) new("UIStroke", { Color = c or T.line, Thickness = 1 }, o) end
local function label(parent, text, size, color, font, props)
    local l = new("TextLabel", {
        BackgroundTransparency = 1, Text = text, TextSize = size or 13, TextColor3 = color or T.text,
        Font = font or Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
    }, parent)
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end

local guiParent = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
pcall(function() local o = guiParent:FindFirstChild("MoseeriNexus") if o then o:Destroy() end end)
pcall(function() local o = guiParent:FindFirstChild("NexusFarmToggle") if o then o:Destroy() end end)
local gui = new("ScreenGui", { Name = "MoseeriNexus", ResetOnSpawn = false, DisplayOrder = 998, IgnoreGuiInset = true })
local WIN_W, HEAD_H, TAB_H = 780, 92, 40
local win = new("Frame", { Size = UDim2.fromOffset(WIN_W, 300), Position = UDim2.new(0.5, -WIN_W / 2, 0, 150),
    BackgroundColor3 = T.bg, BorderSizePixel = 0, Active = true }, gui)
corner(win, 12)
stroke(win)
-- (11-14 test: a tap on an empty part of the window went through to the game and opened its Events page.
-- An invisible button under everything takes those taps)
new("TextButton", { Name = "Sink", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 0 }, win)
local scale = new("UIScale", { Scale = 1 }, win)
pcall(function()
    local vp = workspace.CurrentCamera.ViewportSize
    scale.Scale = math.clamp(math.min(vp.X * 0.62 / WIN_W, vp.Y * 0.8 / 460), 0.55, 1.2)
end)

-- header: spaced title, subtitle, a few stars, the ··· button hides the window
local head = new("Frame", { Size = UDim2.new(1, 0, 0, HEAD_H), BackgroundColor3 = T.headBg, BorderSizePixel = 0 }, win)
corner(head, 12)
new("Frame", { Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 1, -12), BackgroundColor3 = T.headBg, BorderSizePixel = 0 }, head)
label(head, "M O S E E R I   N E X U S", 26, T.white, Enum.Font.GothamMedium, { Position = UDim2.fromOffset(28, 22), Size = UDim2.new(1, -120, 0, 32) })
label(head, "Anime Nexus RNG X · auto farm", 12, T.mute, Enum.Font.Gotham, { Position = UDim2.fromOffset(28, 56), Size = UDim2.new(1, -120, 0, 16) })
local rng = Random.new(7)
for _ = 1, 26 do
    local s = rng:NextInteger(1, 2)
    new("Frame", { Size = UDim2.fromOffset(s, s), Position = UDim2.new(rng:NextNumber(0.35, 0.98), 0, rng:NextNumber(0.1, 0.9), 0),
        BackgroundColor3 = T.white, BackgroundTransparency = rng:NextNumber(0.3, 0.8), BorderSizePixel = 0 }, head)
end
local dots = new("TextButton", { Size = UDim2.fromOffset(40, 28), Position = UDim2.new(1, -56, 0, 18), BackgroundTransparency = 1,
    Text = "···", TextSize = 20, TextColor3 = T.mute, Font = Enum.Font.GothamBold }, head)

-- drag by the header (mouse and touch)
do
    local dragging, start, startPos
    -- (11-14 test: the window slid on later taps - the drag only ends when THIS touch ends, and only the same
    -- touch moves it)
    local dragInput
    head.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, start, startPos, dragInput = true, input.Position, win.Position, input
            local c
            c = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false dragInput = nil c:Disconnect() end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        local same = (input == dragInput) or (input.UserInputType == Enum.UserInputType.MouseMovement and dragInput and dragInput.UserInputType == Enum.UserInputType.MouseButton1)
        if same then
            local d = (input.Position - start) / scale.Scale
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false dragInput = nil end
    end)
end

-- tabs
local tabBar = new("Frame", { Size = UDim2.new(1, -40, 0, TAB_H), Position = UDim2.fromOffset(20, HEAD_H), BackgroundTransparency = 1 }, win)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 26), SortOrder = Enum.SortOrder.LayoutOrder }, tabBar)
new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, HEAD_H + TAB_H), BackgroundColor3 = T.line, BorderSizePixel = 0 }, win)
local body = new("Frame", { Size = UDim2.new(1, -36, 0, 10), Position = UDim2.fromOffset(18, HEAD_H + TAB_H + 10), BackgroundTransparency = 1 }, win)

local function fitHeight(page)
    local h = 0
    for _, col in ipairs(page.cols) do
        local ch = 0
        for _, c in ipairs(col:GetChildren()) do
            if c:IsA("Frame") then ch = ch + c.AbsoluteSize.Y / scale.Scale + 10 end
        end
        if ch > h then h = ch end
    end
    win.Size = UDim2.fromOffset(WIN_W, HEAD_H + TAB_H + 20 + h)
end
function UI.show(name)
    for n, p in pairs(UI.pages) do p.frame.Visible = (n == name) end
    for n, t in pairs(UI.tabs) do
        t.btn.TextColor3 = (n == name) and T.white or T.mute
        t.bar.Visible = (n == name)
    end
    UI.current = name
    task.delay(0.15, function() pcall(fitHeight, UI.pages[name]) end)
end
function UI.page(name, order)
    local btn = new("TextButton", { AutoButtonColor = false, BackgroundTransparency = 1, Text = name, TextSize = 14,
        Font = Enum.Font.GothamMedium, TextColor3 = T.mute, LayoutOrder = order, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X }, tabBar)
    local bar = new("Frame", { Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2), BackgroundColor3 = T.accent, BorderSizePixel = 0, Visible = false }, btn)
    UI.tabs[name] = { btn = btn, bar = bar }
    local frame = new("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Visible = false }, body)
    local cols = {}
    for i = 1, 2 do
        local col = new("Frame", { Size = UDim2.new(0.5, -6, 1, 0), Position = UDim2.new((i - 1) * 0.5, (i - 1) * 6, 0, 0), BackgroundTransparency = 1 }, frame)
        new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, col)
        cols[i] = col
    end
    local page = { frame = frame, cols = cols }
    UI.pages[name] = page
    btn.MouseButton1Click:Connect(function() UI.show(name) end)
    return page
end

-- a card: title + rows with a hairline between them
local cardN = 0
function UI.card(page, side, title)
    cardN = cardN + 1
    local c = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = T.card,
        BorderSizePixel = 0, LayoutOrder = cardN }, page.cols[side])
    corner(c, 10)
    new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 8) }, c)
    new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, c)
    label(c, title, 14, T.white, Enum.Font.GothamMedium, { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 0 })
    return { frame = c, n = 0 }
end
local function row(card, text, h)
    card.n = card.n + 1
    local r = new("Frame", { Size = UDim2.new(1, 0, 0, h or 38), BackgroundTransparency = 1, LayoutOrder = card.n }, card.frame)
    if card.n > 1 then new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = T.line, BorderSizePixel = 0 }, r) end
    label(r, text, 13, T.text, Enum.Font.Gotham, { Size = UDim2.new(0.55, 0, 1, 0) })
    return r
end

-- switch
function UI.toggle(card, text, get, setv)
    local r = row(card, text)
    local sw = new("TextButton", { AutoButtonColor = false, Text = "", Size = UDim2.fromOffset(42, 22), Position = UDim2.new(1, -42, 0.5, -11),
        BackgroundColor3 = T.off, BorderSizePixel = 0 }, r)
    corner(sw, 11)
    local knob = new("Frame", { Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = T.white, BorderSizePixel = 0 }, sw)
    corner(knob, 8)
    local function paint()
        local on = get() and true or false
        sw.BackgroundColor3 = on and T.accent or T.off
        knob.Position = on and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3)
    end
    sw.MouseButton1Click:Connect(function() pcall(setv, not get()) paint() end)
    paint()
    UI.refreshers[#UI.refreshers + 1] = paint
end
-- choice: the value on the right, a tap goes to the next option
function UI.choice(card, text, options, get, setv)
    local r = row(card, text)
    local b = new("TextButton", { AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(0.45, 0, 1, 0), Position = UDim2.new(0.55, 0, 0, 0),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = T.value, TextXAlignment = Enum.TextXAlignment.Right }, r)
    local function paint() b.Text = tostring(get()) .. "  ›" end
    b.MouseButton1Click:Connect(function()
        local cur, i = tostring(get()), 0
        for k, o in ipairs(options) do if tostring(o) == cur then i = k end end
        pcall(setv, options[i % #options + 1])
        paint()
    end)
    paint()
    UI.refreshers[#UI.refreshers + 1] = paint
end
-- number with - and +
function UI.stepper(card, text, lo, hi, get, setv)
    local r = row(card, text)
    local box = new("Frame", { Size = UDim2.fromOffset(104, 26), Position = UDim2.new(1, -104, 0.5, -13), BackgroundTransparency = 1 }, r)
    local v = label(box, "", 13, T.value, Enum.Font.GothamMedium, { Size = UDim2.new(1, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Center })
    local function btn(txt, x, d)
        local b = new("TextButton", { AutoButtonColor = false, Text = txt, TextSize = 15, Font = Enum.Font.GothamMedium, TextColor3 = T.text,
            BackgroundColor3 = T.off, Size = UDim2.fromOffset(26, 26), Position = UDim2.new(x, x == 0 and 0 or -26, 0, 0), BorderSizePixel = 0 }, box)
        corner(b, 6)
        b.MouseButton1Click:Connect(function() pcall(setv, math.clamp((tonumber(get()) or lo) + d, lo, hi)) v.Text = tostring(get()) end)
    end
    btn("−", 0, -1)
    btn("+", 1, 1)
    v.Text = tostring(get())
    UI.refreshers[#UI.refreshers + 1] = function() v.Text = tostring(get()) end
end
-- outlined accent button, like AA "Setup ›"
function UI.button(card, text, btnText, fn)
    local r = row(card, text)
    local b = new("TextButton", { AutoButtonColor = false, Text = btnText .. "  ›", TextSize = 13, Font = Enum.Font.Gotham, TextColor3 = T.accent,
        BackgroundTransparency = 1, Size = UDim2.fromOffset(110, 28), Position = UDim2.new(1, -110, 0.5, -14) }, r)
    corner(b, 7)
    stroke(b, T.accent)
    b.MouseButton1Click:Connect(function() task.spawn(function() pcall(fn) end) end)
end
-- label + live value
function UI.info(card, text, getText)
    local r = row(card, text)
    local v = label(r, "", 13, T.value, Enum.Font.Gotham, { Size = UDim2.new(0.6, 0, 1, 0), Position = UDim2.new(0.4, 0, 0, 0),
        TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd })
    UI.refreshers[#UI.refreshers + 1] = function() local ok, s = pcall(getText) v.Text = ok and tostring(s) or "-" end
end
function UI.note(card, text)
    card.n = card.n + 1
    label(card.frame, text, 12, T.mute, Enum.Font.Gotham, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true, LayoutOrder = card.n, TextYAlignment = Enum.TextYAlignment.Top })
end

-- pills: several on/off choices in one row (wraps)
function UI.pills(card, options, isOn, toggleOne)
    card.n = card.n + 1
    local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = card.n }, card.frame)
    new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8) }, holder)
    new("UIGridLayout", { CellSize = UDim2.fromOffset(84, 26), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
    local paints = {}
    for i, o in ipairs(options) do
        local b = new("TextButton", { AutoButtonColor = false, Text = o, TextSize = 12, Font = Enum.Font.GothamMedium, LayoutOrder = i, BorderSizePixel = 0 }, holder)
        corner(b, 13)
        local function paint()
            local on = isOn(o)
            b.BackgroundColor3 = on and T.accent or T.off
            b.TextColor3 = on and T.onAccent or T.mute
        end
        b.MouseButton1Click:Connect(function() pcall(toggleOne, o) paint() end)
        paint()
        paints[#paints + 1] = paint
    end
    UI.refreshers[#UI.refreshers + 1] = function() for _, p in ipairs(paints) do p() end end
end
-- text box on the right of a row
function UI.input(card, text, placeholder, get, setv)
    local r = row(card, text)
    local box = new("TextBox", { Size = UDim2.new(0.5, 0, 0, 26), Position = UDim2.new(0.5, 0, 0.5, -13), BackgroundColor3 = T.off, BorderSizePixel = 0,
        Text = tostring(get() or ""), PlaceholderText = placeholder, PlaceholderColor3 = T.faint, TextColor3 = T.text, Font = Enum.Font.Gotham,
        TextSize = 12, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left }, r)
    corner(box, 6)
    new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, box)
    box.FocusLost:Connect(function() pcall(setv, box.Text) end)
end

local function notify(msg)
    log(msg)
    pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", { Title = "moseeri nexus", Text = tostring(msg), Duration = 4 }) end)
end
local function cfgSet(key) return function(v) F.cfg[key] = v saveAll() end end
local function cfgGet(key) return function() return F.cfg[key] end end

-- Home
local home = UI.page("Home", 1)
local run = UI.card(home, 1, "Run")
UI.info(run, "Where", function() return F.inMatch and ("In stage · wave " .. F.wave) or "Lobby" end)
UI.info(run, "Stage", function() return F.cfg.mode == "Defend" and ("Defend · " .. F.cfg.diff) or (F.cfg.map .. " · Act " .. F.cfg.act .. " · " .. F.cfg.diff) end)
UI.toggle(run, "Auto join", cfgGet("autoJoin"), function(v) F.cfg.autoJoin = v F.startedAt = 0 saveAll() end)
UI.toggle(run, "Auto place", cfgGet("autoPlace"), cfgSet("autoPlace"))
UI.toggle(run, "Auto upgrade", cfgGet("autoUpgrade"), cfgSet("autoUpgrade"))
UI.button(run, "Start the stage now", "Start", function() startStage() end)
local res = UI.card(home, 2, "Results")
UI.info(res, "Wins · Losses", function() return F.wins .. " · " .. F.losses end)
UI.info(res, "Last result", function() return F.lastResult ~= "" and F.lastResult or "None yet" end)
UI.info(res, "Yen", function() return tostring(yen()) end)
UI.info(res, "My units · Team", function() return #F.mine .. " · " .. #teamList() end)
UI.info(res, "Last action", function() return F.lastAction ~= "" and F.lastAction or "-" end)

-- Farm
local farm = UI.page("Farm", 2)
local stage = UI.card(farm, 1, "Stage")
UI.choice(stage, "Mode", { "Story", "Defend" }, cfgGet("mode"), cfgSet("mode"))
UI.choice(stage, "Map", { "HiddenGround", "ChuninExams", "TrainingGrounds", "FinalValley", "GoteiBarracks", "Invasion", "RoswaalMansion", "FuyukiCity" }, cfgGet("map"), cfgSet("map"))
UI.input(stage, "Other map id", "HiddenGround", cfgGet("map"), function(t) if type(t) == "string" and #t > 2 then F.cfg.map = t saveAll() end end)
UI.choice(stage, "Act", { 1, 2, 3, 4, 5, 6 }, cfgGet("act"), function(v) F.cfg.act = tonumber(v) or 1 saveAll() end)
UI.choice(stage, "Difficulty", { "Normal", "Nightmare" }, cfgGet("diff"), cfgSet("diff"))
local after = UI.card(farm, 2, "After the stage")
UI.toggle(after, "Auto join", cfgGet("autoJoin"), function(v) F.cfg.autoJoin = v F.startedAt = 0 saveAll() end)
UI.choice(after, "After win", { "Replay", "Next act" }, cfgGet("afterWin"), cfgSet("afterWin"))
UI.choice(after, "After loss", { "Retry", "Act 1", "Picked stage" }, cfgGet("afterLoss"), cfgSet("afterLoss"))
UI.stepper(after, "Wait before acting (s)", 3, 20, cfgGet("waitResult"), cfgSet("waitResult"))
UI.note(after, "Turn the game's own Auto Next and Auto Retry off, or they start a stage before this does.")

-- In stage
local ins = UI.page("In stage", 3)
local units = UI.card(ins, 1, "Units")
UI.toggle(units, "Auto place", cfgGet("autoPlace"), cfgSet("autoPlace"))
UI.toggle(units, "Auto upgrade", cfgGet("autoUpgrade"), cfgSet("autoUpgrade"))
UI.toggle(units, "Auto skill", cfgGet("autoSkill"), cfgSet("autoSkill"))
UI.stepper(units, "Copies per unit", 1, 6, cfgGet("perUnit"), cfgSet("perUnit"))
UI.stepper(units, "Max units", 1, 30, cfgGet("maxUnits"), cfgSet("maxUnits"))
local sp = UI.card(ins, 2, "Spots")
UI.stepper(sp, "Distance from base", 3, 20, cfgGet("radius"), cfgSet("radius"))
UI.button(sp, "Base center", "Set here", function() notify(setCenterHere() and "Base center saved" or "No character") end)
UI.toggle(sp, "Learn spots from my placements", function() return F.learnSpots end, function(v) F.learnSpots = v end)
UI.button(sp, "Learned spots", "Forget", function() F.learned[baseKey()] = nil saveAll() notify("Learned spots cleared") end)
UI.button(sp, "Team", "Read again", function()
    notify(readTeamFromMemory() and (#teamList() .. " units in the team") or "Team not found: press Equip Best once")
end)

-- Roll
-- Boss (own tab, owner 11-14: joining the Sorcerer King queue is enough)
local bossPage = UI.page("Boss", 5)
local boss = UI.card(bossPage, 1, "Sorcerer King")
UI.toggle(boss, "Auto join queue", cfgGet("autoBoss"), function(v) F.cfg.autoBoss = v F.boss.lastTry = 0 F.boss.waitUntil = 0 saveAll() end)
UI.info(boss, "Last try", function() return F.boss.last end)
UI.note(boss, "Opens every hour. Tries once a minute from the lobby; after joining it waits 4 minutes.")
-- Mine (own tab)
local minePage = UI.page("Mine", 6)
local mc = UI.card(minePage, 1, "Gurren mine")
UI.toggle(mc, "Auto mine all rocks", cfgGet("autoMine"), function(v)
    F.cfg.autoMine = v
    saveAll()
    if v then task.spawn(mineEnter) end
end)
UI.info(mc, "Rocks now", function() return tostring(rockCount()) end)
UI.info(mc, "Hits · Broken", function() return F.gmine.count .. " · " .. F.gmine.broken end)
UI.info(mc, "Last", function() return F.gmine.last end)
UI.choice(mc, "Seconds between rounds", { 0.3, 0.5, 1, 2 }, cfgGet("mineTick"), function(v) F.cfg.mineTick = tonumber(v) or 0.5 saveAll() end)
UI.button(mc, "Rock list", "Enter again", function() mineEnter() end)
local rollPage = UI.page("Roll", 4)
local ar = UI.card(rollPage, 1, "Auto roll")
UI.toggle(ar, "Auto roll", function() return R.on end, function(v) R.stopped = nil setGameAutoRoll(v) end)
UI.info(ar, "Rolls this session", function() return tostring(R.count) end)
UI.info(ar, "Next roll gives", function() return R.next and (tostring(R.next) .. (R.nextShiny and " (shiny)" or "")) or "Roll once to see" end)
UI.info(ar, "Stopped because", function() return R.stopped or "-" end)
UI.toggle(ar, "Stop one roll early", cfgGet("stopEarly"), cfgSet("stopEarly"))
UI.note(ar, "Early: stops before a wanted unit, for a luck potion.")
local sw = UI.card(rollPage, 2, "Stop when I get")
local RARS = { "Legendary", "Mythic", "Divine", "Ascendant", "Nexus", "Secret", "Exclusive", "Eternal" }
UI.pills(sw, RARS, function(o) return F.cfg.stopRarities[o] and true or false end, function(o)
    F.cfg.stopRarities[o] = not F.cfg.stopRarities[o] or nil
    saveAll()
end)
UI.toggle(sw, "Any shiny", cfgGet("stopShiny"), cfgSet("stopShiny"))
UI.input(sw, "Unit names", "Gigglemesh, Sabar", cfgGet("stopNames"), cfgSet("stopNames"))
local rl = UI.card(rollPage, 2, "Last rolls")
for i = 1, 5 do
    UI.info(rl, tostring(i), function() return R.log[i] or "-" end)
end

-- small toggle button (the window's ··· hides it, this brings it back)
local tb = new("TextButton", { Name = "Toggle", Size = UDim2.fromOffset(52, 30), Position = UDim2.new(1, -260, 0, 120),
    BackgroundColor3 = T.headBg, BackgroundTransparency = 0.1, TextColor3 = T.accent, Font = Enum.Font.GothamBold, TextSize = 14, Text = "MN" }, gui)
corner(tb, 8)
stroke(tb, T.accent)
local function setShown(v) win.Visible = v end
tb.MouseButton1Click:Connect(function() setShown(not win.Visible) end)
dots.MouseButton1Click:Connect(function() setShown(false) end)
UIS.InputBegan:Connect(function(input, gp)
    -- (11-15 owner: Ctrl did nothing - AA uses LeftControl. Either Ctrl key shows / hides the window)
    if input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then setShown(not win.Visible) end
end)

gui.Parent = guiParent
UI.show("Home")

task.spawn(function()
    while F.alive do
        if win.Visible then
            for _, f in ipairs(UI.refreshers) do pcall(f) end
        end
        task.wait(1)
    end
end)

G.__nexus_farm_stop = function()
    F.alive = false
    for _, c in ipairs(F.conns) do pcall(function() c:Disconnect() end) end
    pcall(function() gui:Destroy() end)
end
G.__nexus_farm = F -- (for checking from the watch / console)

ensureFolder()
log("loaded")
notify("Ready. Ctrl or the MN button shows / hides the window.")
