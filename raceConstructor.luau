--!strict
--!native

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local ServerStorage = game:GetService("ServerStorage")

local VehicleNet        = ReplicatedStorage:WaitForChild("VehicleNet")
local RaceBroadcast     = VehicleNet:WaitForChild("RaceBroadcast") :: RemoteEvent
local RaceCountdown     = VehicleNet:WaitForChild("RaceCountdown") :: RemoteEvent
local LapUpdate         = VehicleNet:WaitForChild("LapUpdate") :: RemoteEvent
local ReadyUp           = VehicleNet:WaitForChild("ReadyUp") :: RemoteEvent
local RaceEnd           = VehicleNet:WaitForChild("RaceEnd") :: RemoteEvent
local RaceStateRequest  = VehicleNet:WaitForChild("RaceStateRequest") :: RemoteFunction

local CarRequest        = VehicleNet:WaitForChild("CarRequest") :: RemoteEvent
local NextCPUpdate      = VehicleNet:FindFirstChild("NextCPUpdate") :: RemoteEvent?
local RaceTimerUpdate   = VehicleNet:FindFirstChild("RaceTimerUpdate") :: RemoteEvent?
local CheckpointArrow   = VehicleNet:FindFirstChild("CheckpointArrow") :: RemoteEvent?
local RaceActiveFlag    = VehicleNet:FindFirstChild("RaceActiveFlag") :: BoolValue?
local RaceStart         = VehicleNet:FindFirstChild("RaceStart") :: RemoteEvent?

local VoteMap           = Instance.new("RemoteEvent")
VoteMap.Name = "VoteMap"
VoteMap.Parent = VehicleNet

local GetMapList        = Instance.new("RemoteFunction")
GetMapList.Name = "GetMapList"
GetMapList.Parent = VehicleNet

local INFLATION = Vector3.new(1.5, 1.5, 1.5)

local isIntermission = true
local readyPlayers: {[Player]: boolean} = {}
local mapVotes: {[Player]: string} = {}

export type Checkpoint = {
    index: number,
    bboxCFrame: CFrame,
    bboxSize: Vector3
}

export type Lap = {
    index: number,
    startTime: number,
    checkpointsHit: { [number]: boolean },
    valid: boolean,
    lastCheckpoint: number,
    endTime: number?,
    duration: number?
}

export type Round = {
    index: number,
    startTime: number,
    laps: {Lap},
    currentLap: number,
    totalLaps: number,
    player: Player,
    finished: boolean,
    totalTime: number?,
    DNF: boolean
}

export type RaceObject = {
    name: string, 
    totalLaps: number, 
    roundTime: number, 

    raceFolder: Folder,
    countdownTime: number,
    roundActive: boolean,
    roundIndex: number,
    roundStartTime: number?,

    rounds: { [Player]: Round },
    spectators: { [Player]: boolean },

    activeVehicles: { [Player]: Model },
    activeSpawns: { [BasePart]: Player },
    padByModel: { [Model]: BasePart },
    finishers: { [Player]: number },

    checkpoints: {Checkpoint},
    checkpointsWorldFolder: Folder?,
    checkpointsTemplateFolder: Folder?,
    spawnPads: {BasePart},

    storedVehicles: Folder,
    carStorageAnchor: BasePart,

    _ended: boolean,
    start: boolean,
    state: string,

    _timerAccum: number,
    _hbConn: RBXScriptConnection?,
    _timerConn: RBXScriptConnection?,
    deathConns: { [Player]: RBXScriptConnection }
}

export type RaceConfig = {
    name: string?,
    raceFolder: Folder?,
    laps: number?,
    countdownTime: number?,
    roundTime: number?,
}

export type RaceStateResponse = {
    Active: boolean,
    Spectator: boolean?,
    CurrentLap: number,
    TotalLaps: number,
    Remaining: number
}

local globalStore = DataStoreService:GetDataStore("GlobalBestLap")
local globalBestTime = math.huge
local globalBestPlayer = "—"

task.spawn(function()
    local ok, data = pcall(function()
        return globalStore:GetAsync("Best")
    end)
    if ok and data and typeof(data) == "table" then
        globalBestTime = data.Time or math.huge
        globalBestPlayer = data.Name or "—"
    end
end)

local Race = {}
Race.__index = Race

local raceTracks = ServerStorage:WaitForChild("raceTracks")

local function getAllRaceNames(): {{Name: string, ImageId: string?}}
    local list = {}
    for _, folder in ipairs(raceTracks:GetChildren()) do
        if folder:IsA("Folder") and folder.Name ~= "car_storage" then
            table.insert(list, {
                Name = folder.Name,
                ImageId = folder:GetAttribute("ImageId")
            })
        end
    end
    table.sort(list, function(a,b) return a.Name < b.Name end)
    return list
end

local currentRace: RaceObject? = nil

local function broadcast(msg: string)
    RaceBroadcast:FireAllClients(msg)
end

local function ensureBestLapAttr(p: Player)
    if p:GetAttribute("BestLapTime") == nil then
        p:SetAttribute("BestLapTime", math.huge)
    end
end

local function parseColor(hex: string?): Color3
    if not hex then
        return Color3.new(1, 1, 1)
    end
    hex = hex:gsub("#", "")
    if #hex == 6 then
        local r = tonumber(hex:sub(1, 2), 16)
        local g = tonumber(hex:sub(3, 4), 16)
        local b = tonumber(hex:sub(5, 6), 16)
        if r and g and b then
            return Color3.fromRGB(r, g, b)
        end
    end
    return Color3.new(1, 1, 1)
end

local function getHRP(p: Player): BasePart?
    local c = p.Character
    if not c then
        return nil
    end
    return c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function pointInsideOBB(point: Vector3, cf: CFrame, size: Vector3): boolean
    local lp = cf:PointToObjectSpace(point)
    local half = (size * INFLATION) * 0.5
    return math.abs(lp.X) <= half.X
        and math.abs(lp.Y) <= half.Y
        and math.abs(lp.Z) <= half.Z
end

local function playerNearCheckpoint(p: Player, cp: Checkpoint): boolean
    local hrp = getHRP(p)
    if not hrp then return false end
    return pointInsideOBB(hrp.Position, cp.bboxCFrame, cp.bboxSize)
end

local function allHit(hit: {[number]: boolean}, total: number): boolean
    for i = 1, total do
        if not hit[i] then
            return false
        end
    end
    return true
end

local function sendToLobby(p: Player)
    local lobby = Workspace:FindFirstChild("Lobby")
    if not lobby then
        return
    end
    local spawnPart = lobby:FindFirstChild("lobby_spawn") :: BasePart?
    if not spawnPart then
        return
    end
    task.defer(function()
        local char = p.Character or p.CharacterAdded:Wait()
        local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
        if hrp and spawnPart then
            char:PivotTo(spawnPart.CFrame + Vector3.new(0, 3, 0))
        end
    end)
end

local function isMidRaceJoiner(p: Player): boolean
    if not currentRace then
        return false
    end
    if not currentRace.roundActive or not currentRace.roundStartTime then
        return false
    end
    return currentRace.rounds[p] == nil
end

function Race:rebuildCheckpoints(fromFolder: Folder)
    local self = self :: RaceObject
    table.clear(self.checkpoints)
    local children = fromFolder:GetChildren()
    table.sort(children, function(a, b)
        local numA = tonumber(a.Name:match("%d+")) or 0
        local numB = tonumber(b.Name:match("%d+")) or 0
        return numA < numB
    end)

    for i, inst in ipairs(children) do
        local cf: CFrame? = nil
        local sz: Vector3? = nil

        if inst:IsA("Model") then
            local ccf, cs = inst:GetBoundingBox()
            cf = ccf
            sz = cs
        elseif inst:IsA("BasePart") then
            cf = inst.CFrame
            sz = inst.Size
        end

        if cf and sz then
            table.insert(self.checkpoints, {
                index = i,
                bboxCFrame = cf,
                bboxSize = sz,
            })
        end
    end
end

function Race:getFreeSpawn(): BasePart?
    local self = self :: RaceObject
    for _, pad in ipairs(self.spawnPads) do
        if not self.activeSpawns[pad] then
            return pad
        end
    end
    return nil
end

function Race:freeSpawn(model: Model)
    local self = self :: RaceObject
    local pad = self.padByModel[model]
    if pad then
        self.activeSpawns[pad] = nil
        self.padByModel[model] = nil
        pad:SetAttribute("Occupied", false)
    end
end

function Race:recycleVehicle(model: Model)
    local self = self :: RaceObject
    if not model or not model.Parent then
        return
    end
    self:freeSpawn(model)
    if self.carStorageAnchor then
        model:PivotTo(self.carStorageAnchor.CFrame)
    end
    model.Parent = self.storedVehicles
end

function Race:spawnVehicle(p: Player, make: string, color: string?)
    local self = self :: RaceObject
    local pad = self:getFreeSpawn()
    if not pad then
        return
    end

    local template = ReplicatedStorage:FindFirstChild(make, true)
    if not template or not template:IsA("Model") then
        return
    end

    local model = template:Clone()
    model.Name = make .. "_" .. p.Name
    model.Parent = Workspace

    if not model.PrimaryPart then
        local base = model:FindFirstChildWhichIsA("BasePart")
        if base then
            model.PrimaryPart = base
        else
            model:Destroy()
            return
        end
    end

    model:PivotTo(pad.CFrame + Vector3.new(0, 3, 0))

    self.activeSpawns[pad] = p
    self.padByModel[model] = pad
    pad:SetAttribute("Occupied", true)
    self.activeVehicles[p] = model

    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") and d.Name:lower():find("body") then
            d.Color = parseColor(color)
        end
    end

    task.defer(function()
        local char = p.Character or p.CharacterAdded:Wait()
        local hrp = char:WaitForChild("HumanoidRootPart") :: BasePart
        local seat = model:FindFirstChildWhichIsA("VehicleSeat", true)
        if seat then
            hrp.CFrame = seat.CFrame * CFrame.new(0, 2.5, 0)
        else
            hrp.CFrame = pad.CFrame + Vector3.new(0, 5, -5)
        end
    end)
end

function Race:updateLapDisplay(p: Player, lap: number, total: number)
    LapUpdate:FireClient(p, lap, total)
end

function Race:updateArrowForPlayer(p: Player, nextIndex: number?)
    local self = self :: RaceObject
    if not CheckpointArrow then
        return
    end
    if not nextIndex or not self.checkpoints[nextIndex] then
        CheckpointArrow:FireClient(p, { visible = false })
        return
    end
    local cp = self.checkpoints[nextIndex]
    CheckpointArrow:FireClient(p, {
        visible = true,
        target = cp.bboxCFrame.Position,
        text = string.format("CHECKPOINT %d/%d", nextIndex, #self.checkpoints),
        color = Color3.fromRGB(255, 220, 0),
    })
end

function Race:_markDNF(p: Player)
    local self = self :: RaceObject
    local round = self.rounds[p]
    if not round or round.finished then
        return
    end

    round.finished = true
    round.DNF = true
    round.totalTime = nil

    if CheckpointArrow then
        CheckpointArrow:FireClient(p, { visible = false })
    end

    local car = self.activeVehicles[p]
    if car then
        self:recycleVehicle(car)
        self.activeVehicles[p] = nil 
    end

    local char = p.Character
    local lobby = Workspace:FindFirstChild("Lobby")
    local spawnPart = lobby and lobby:FindFirstChild("lobby_spawn") :: BasePart?

    if char and spawnPart then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then
            char:PivotTo(spawnPart.CFrame + Vector3.new(0, 3, 0))
        end
    end
    self.spectators[p] = true
end

function Race:_bindDeathForPlayer(p: Player)
    local self = self :: RaceObject
    self.deathConns = self.deathConns or {}
    local old = self.deathConns[p]
    if old then
        old:Disconnect()
    end

    local function attach(char: Model)
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum then
            return
        end
        if self.deathConns[p] then
            self.deathConns[p]:Disconnect()
        end
        self.deathConns[p] = hum.Died:Connect(function()
            if currentRace == self and self.roundActive then
                self:_markDNF(p)
            end
        end)
    end

    local char = p.Character
    if char then
        attach(char)
    end

    p.CharacterAdded:Connect(function(newChar)
        if currentRace == self and self.roundActive and self.rounds[p] and not self.rounds[p].finished then
            attach(newChar)
        end
    end)
end

function Race:createRoundFor(p: Player, start: number)
    local self = self :: RaceObject
    local lap: Lap = {
        index = 1,
        startTime = start,
        checkpointsHit = {}, 
        valid = true,
        lastCheckpoint = 0, 
    }
    self.rounds[p] = {
        index = self.roundIndex,
        startTime = start,
        laps = { lap },
        currentLap = 1,
        totalLaps = self.totalLaps,
        player = p,
        finished = false,
        totalTime = nil,
        DNF = false,
    }
    self:updateLapDisplay(p, 1, self.totalLaps)
    self:updateArrowForPlayer(p, 1)
    self:_bindDeathForPlayer(p)
end

function Race:startRound()
    local self = self :: RaceObject
    if self.roundActive then
        return
    end

    self.roundActive = true
    self.roundIndex += 1
    self.roundStartTime = tick()
    self._ended = false

    broadcast("Race starting!")

    local players = Players:GetPlayers()

    for _, p in ipairs(players) do
        ensureBestLapAttr(p)
        local char = p.Character or p.CharacterAdded:Wait()
        char:WaitForChild("HumanoidRootPart")

        local carMake = p:GetAttribute("SelectedCar") or "RWD"
        local carColor = p:GetAttribute("SelectedColor")

        self:spawnVehicle(p, carMake, carColor)
    end

    for _, pad in ipairs(self.spawnPads) do
        pad:Destroy()
    end

    local rStart = self.roundStartTime :: number

    for _, p in ipairs(players) do
        self:createRoundFor(p, rStart)
    end

    RaceCountdown:FireAllClients(self.countdownTime)
    task.wait(self.countdownTime)
    RaceCountdown:FireAllClients("GO!")

    if RaceStart then RaceStart:FireAllClients() end
    self.start = true
    if RaceActiveFlag then RaceActiveFlag.Value = true end
end

function Race:handlePlayerRemoving(p: Player)
    local self = self :: RaceObject

    if self.roundActive and self.rounds[p] and not self.rounds[p].finished then
        self:_markDNF(p)
    end

    if self.rounds[p] then
        self.rounds[p] = nil 
    end
    if self.activeVehicles[p] then
        self:recycleVehicle(self.activeVehicles[p])
        self.activeVehicles[p] = nil
    end

    if self.deathConns and self.deathConns[p] then
        self.deathConns[p]:Disconnect()
    end

    if self.roundActive then
        for _, other in ipairs(Players:GetPlayers()) do
            RaceCountdown:FireClient(other, "SYNC")
        end
    end
end

function Race:getStateForPlayer(player: Player): RaceStateResponse
    local self = self :: RaceObject
    local r = self.rounds[player]
    local currentLap = r and r.currentLap or 0
    local remaining = 0
    if self.roundActive and self.roundStartTime then
        local elapsed = tick() - self.roundStartTime
        remaining = math.max(0, self.roundTime - elapsed)
    else
        remaining = self.roundTime
    end

    if self.spectators[player] or isMidRaceJoiner(player) then
        return {
            Active = true,
            Spectator = true,
            CurrentLap = 0,
            TotalLaps = self.totalLaps,
            Remaining = remaining,
        }
    end

    return {
        Active = currentRace.roundActive,
        Spectator = false,
        CurrentLap = r and r.currentLap or 0,
        TotalLaps = currentRace.totalLaps,
        Remaining = remaining,
    }
end

local function tallyVotesAndStart()
    local counts = {}
    local maxCount = 0

    for _, mapName in pairs(mapVotes) do
        counts[mapName] = (counts[mapName] or 0) + 1
        if counts[mapName] > maxCount then
            maxCount = counts[mapName]
        end
    end

    local winners = {}
    for name, count in pairs(counts) do
        if count == maxCount then
            table.insert(winners, name)
        end
    end

    local chosenMap = "Race1"
    if #winners > 0 then
        chosenMap = winners[math.random(1, #winners)]
    else
        local all = getAllRaceNames()
        if #all > 0 then
            chosenMap = all[math.random(1, #all)].Name
        end
    end

    broadcast("Map Selected: " .. chosenMap)

    task.wait(2)

    isIntermission = false
    currentRace = Race.init(chosenMap)

    if currentRace then
        currentRace:startRound()
    else
        isIntermission = true
    end
end

function Race:endRace()
    local self = self :: RaceObject
    if self._ended then
        return
    end
    self._ended = true
    self.start = false
    self.roundActive = false

    isIntermission = true
    table.clear(readyPlayers)
    table.clear(mapVotes)

    if RaceActiveFlag then
        RaceActiveFlag.Value = false
    end

    local results = {}
    local bestGlobal = globalBestTime
    local bestName = globalBestPlayer

    for _, p in ipairs(Players:GetPlayers()) do
        local r = self.rounds[p]
        if r then
            local best = math.huge
            for _, lap in ipairs(r.laps) do
                if lap.duration then
                    best = math.min(best, lap.duration)
                end
            end

            if best < math.huge then
                local update = rawget(_G, "UpdateBestLap")
                if typeof(update) == "function" then
                    update(p, best)
                else
                    p:SetAttribute("BestLapTime", best)
                end
            end

            if best < bestGlobal then
                bestGlobal = best
                bestName = p.Name
                pcall(function()
                    globalStore:SetAsync("Best", {
                        Name = p.Name,
                        Time = best,
                    })
                end)
            end

            results[p.Name] = {
                BestLapTime = (best ~= math.huge) and best or nil,
                TotalTime   = r.totalTime or nil,
                DNF         = r.DNF or false,
            }
        end
    end

    results.GlobalBest = { Name = bestName, Time = bestGlobal }
    globalBestTime = bestGlobal
    globalBestPlayer = bestName

    RaceEnd:FireAllClients(results)

    for _, p in ipairs(Players:GetPlayers()) do
        if CheckpointArrow then
            CheckpointArrow:FireClient(p, { visible = false })
        end
        task.defer(function()
            local car = self.activeVehicles[p]
            if car then
                self:recycleVehicle(car)
                self.activeVehicles[p] = nil
            end
            local char = p.Character or p.CharacterAdded:Wait()
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                if hum.SeatPart then
                    hum.Sit = false
                end
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
            local lobby = Workspace:FindFirstChild("Lobby")
            local spawnPart = lobby and lobby:FindFirstChild("lobby_spawn") :: BasePart?
            if spawnPart and char and char:FindFirstChild("HumanoidRootPart") then
                char:PivotTo(spawnPart.CFrame + Vector3.new(0, 3, 0))
            end
        end)
    end

    self.rounds = {}
    self.roundStartTime = nil

    local activeMap = Workspace:FindFirstChild("ActiveRaceMap")
    if activeMap then
        activeMap:Destroy()
    end

    if self._hbConn then
        self._hbConn:Disconnect()
        self._hbConn = nil
    end
    if self._timerConn then
        self._timerConn:Disconnect()
        self._timerConn = nil
    end

    if self.deathConns then
        for p, conn in pairs(self.deathConns) do
            if conn then
                conn:Disconnect()
            end
        end
        table.clear(self.deathConns)
    end

    if currentRace == self then
        currentRace = nil
    end

    broadcast("Intermission: Vote for map and Ready Up!")
end

function Race:_onHeartbeat(dt: number)
    local self = self :: RaceObject
    if currentRace ~= self then
        return
    end
    if not self.roundActive or not self.roundStartTime then
        return
    end

    local now = tick()
    local allFinished = true

    for p, round in pairs(self.rounds) do
        if not p or not Players:FindFirstChild(p.Name) then
            self.rounds[p] = nil
        else
            if not round.finished then
                allFinished = false
                local lap = round.laps[round.currentLap]
                for i, cp in ipairs(self.checkpoints) do
                    if playerNearCheckpoint(p, cp) then
                        local expectedNext = (lap.lastCheckpoint % #self.checkpoints) + 1
                        if i == expectedNext then
                            lap.checkpointsHit[i] = true
                            lap.lastCheckpoint = i
                            local nextIndex = (i % #self.checkpoints) + 1
                            self:updateArrowForPlayer(p, nextIndex)

                            if i == 1 and allHit(lap.checkpointsHit, #self.checkpoints) then
                                lap.endTime = now
                                lap.duration = now - lap.startTime

                                if lap.index < round.totalLaps then
                                    local newLap: Lap = {
                                        index = lap.index + 1,
                                        startTime = now,
                                        checkpointsHit = {},
                                        valid = true,
                                        lastCheckpoint = #self.checkpoints,
                                    }
                                    table.insert(round.laps, newLap)
                                    round.currentLap += 1
                                    self:updateLapDisplay(p, round.currentLap, self.totalLaps)
                                    self:updateArrowForPlayer(p, 1)
                                else
                                    round.finished = true
                                    round.totalTime = now - round.startTime
                                    self:updateLapDisplay(p, self.totalLaps, self.totalLaps)
                                    if CheckpointArrow then
                                        CheckpointArrow:FireClient(p, { visible = false })
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if allFinished or (now - self.roundStartTime) > self.roundTime then
        self:endRace()
    end
end

function Race:_onTimerHeartbeat(dt: number)
    local self = self :: RaceObject
    if currentRace ~= self then
        return
    end
    if not self.roundActive or not self.roundStartTime then
        return
    end

    self._timerAccum = (self._timerAccum or 0) + dt
    if self._timerAccum < 1 then
        return
    end
    self._timerAccum = 0

    local now = tick()
    local elapsed = now - self.roundStartTime
    local remaining = math.max(0, self.roundTime - elapsed)
    local payload = {
        elapsed = elapsed,
        remaining = remaining,
        total = self.roundTime,
    }
    if RaceTimerUpdate then
        RaceTimerUpdate:FireAllClients(payload)
    end
end

function Race.new(config: RaceConfig): RaceObject
    local self = setmetatable({}, Race) :: any
    self.name = config.name or "Race1"

    local raceTracksLocal = ServerStorage:WaitForChild("raceTracks")
    self.raceFolder = config.raceFolder or raceTracksLocal:WaitForChild(self.name)

    self.totalLaps    = config.laps or 3
    self.countdownTime= config.countdownTime or 3
    self.roundTime    = config.roundTime or 165

    self.roundActive    = false
    self.roundIndex     = 0
    self.roundStartTime = nil
    self.rounds         = {}
    self.activeVehicles = {}
    self.activeSpawns   = {}
    self.padByModel     = {}
    self.finishers      = {}
    self.state          = "Race state is" .. tostring(false)
    self.checkpoints    = {}
    self.checkpointsWorldFolder = nil
    self._ended         = false
    self._timerAccum    = 0
    self.deathConns     = {}
    self.spectators     = {}

    local oldMap = Workspace:FindFirstChild("ActiveRaceMap")
    if oldMap then oldMap:Destroy() end

    local activeMap = Instance.new("Folder")
    activeMap.Name = "ActiveRaceMap"
    activeMap.Parent = Workspace

    for _, child in ipairs(self.raceFolder:GetChildren()) do
        local clone = child:Clone()
        clone.Parent = activeMap
    end

    self.spawnPads = {}
    local spawnsFolder = activeMap:WaitForChild("Car_Spawns")
    for _, c in ipairs(spawnsFolder:GetChildren()) do
        if c:IsA("BasePart") then
            table.insert(self.spawnPads, c)
            c:SetAttribute("Occupied", false)
        end
    end

    self.storedVehicles = ReplicatedStorage:FindFirstChild("StoredVehicles") or Instance.new("Folder")
    self.storedVehicles.Name = "StoredVehicles"
    self.storedVehicles.Parent = ReplicatedStorage

    self.carStorageAnchor = Workspace:WaitForChild("car_storage"):WaitForChild("car_storageAnchor") :: BasePart

    self.checkpointsTemplateFolder = activeMap:WaitForChild("Checkpoints")

    local obj = self :: RaceObject

    if obj.checkpointsTemplateFolder and obj.checkpointsTemplateFolder:IsA("Folder") then
        obj:rebuildCheckpoints(obj.checkpointsTemplateFolder)
    end

    obj._hbConn = RunService.Heartbeat:Connect(function(dt)
        obj:_onHeartbeat(dt)
    end)
    obj._timerConn = RunService.Heartbeat:Connect(function(dt)
        obj:_onTimerHeartbeat(dt)
    end)

    currentRace = obj
    return obj
end

function Race.init(raceName: string?)
    return Race.new({
        name = raceName or "Race1",
    })
end

ReadyUp.OnServerEvent:Connect(function(p)
    if not isIntermission then return end 

    readyPlayers[p] = true
    local readyCount = 0
    local total = #Players:GetPlayers()
    for _, v in pairs(readyPlayers) do
        if v then readyCount += 1 end
    end

    broadcast(("%s is ready (%d/%d)"):format(p.Name, readyCount, total))

    if readyCount / math.max(total, 1) >= 0.52 then
        tallyVotesAndStart()
    end
end)

VoteMap.OnServerEvent:Connect(function(p, mapName)
    if not isIntermission then return end
    if type(mapName) ~= "string" then return end

    local track = ServerStorage.raceTracks:FindFirstChild(mapName)
    if track and track.Name ~= "car_storage" then
        mapVotes[p] = mapName
    end
end)

Players.PlayerAdded:Connect(function(p: Player)
    if currentRace and currentRace.roundActive then
        if currentRace.rounds[p] == nil then
            currentRace.spectators[p] = true
        end
    end

    p.CharacterAdded:Connect(function(char)
        task.defer(function()
            if isIntermission or (currentRace and currentRace.spectators[p]) then
                sendToLobby(p)

                local hum = char:FindFirstChildOfClass("Humanoid")
                if hum then
                    hum:GetPropertyChangedSignal("SeatPart"):Connect(function()
                        if hum.SeatPart then
                            hum.Sit = false
                        end
                    end)
                end
            end
        end)
    end)
end)

if CarRequest then
    CarRequest.OnServerEvent:Connect(function(p: Player, make: unknown, color: unknown)
        if typeof(make) ~= "string" then return end
        local makeStr = make :: string
        local colorStr: string? = nil
        if typeof(color) == "string" then colorStr = color :: string end

        p:SetAttribute("SelectedCar", makeStr)
        p:SetAttribute("SelectedColor", colorStr)
    end)
end

Players.PlayerRemoving:Connect(function(p: Player)
    readyPlayers[p] = nil
    mapVotes[p] = nil
    if currentRace then
        currentRace:handlePlayerRemoving(p)
    end
end)

GetMapList.OnServerInvoke = function(player: Player)
    return getAllRaceNames()
end

RaceStateRequest.OnServerInvoke = function(player: Player): RaceStateResponse
    if not currentRace then
        return {
            Active = false,
            Spectator = false,
            CurrentLap = 0,
            TotalLaps = 0,
            Remaining = 0,
        }
    end

    if currentRace.spectators[player] or isMidRaceJoiner(player) then
        local now = tick()
        local startTime = currentRace.roundStartTime or now
        local elapsed = now - startTime

        local remaining = math.max(0, currentRace.roundTime - elapsed)

        return {
            Active = true,
            Spectator = true,
            CurrentLap = 0,
            TotalLaps = currentRace.totalLaps,
            Remaining = remaining,
        }
    end

    local r = currentRace.rounds[player]
    local now = tick()
    local startTime = currentRace.roundStartTime or now
    local elapsed = now - startTime
    local remaining = math.max(0, currentRace.roundTime - elapsed)

    return {
        Active = currentRace.roundActive,
        Spectator = false,
        CurrentLap = r and r.currentLap or 0,
        TotalLaps = currentRace.totalLaps,
        Remaining = remaining,
    }
end

task.spawn(function()
    task.wait(5)
    broadcast("Intermission: Vote for map and Ready Up!")
end)

return Race
