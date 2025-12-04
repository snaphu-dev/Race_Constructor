local Race = require(script.Parent:WaitForChild("race_constructor"))
Race.init("Race1")

--[[local Race = {}
Race.__index = Race

local Players = game:GetService("Players")
local ReadyUp = game:GetService("ReplicatedStorage"):WaitForChild("VehicleNet"):WaitForChild("ReadyUp")

local local_players:{Player} = {}

export type playerState = {
    ready:boolean?,
    current_playerLap:number?,
    lapStart:number?,
    current_playerCheckpoint:number?,
    lapEnd:number?,
    DID_NOT_FINISH:boolean, -- leavers still show up as DNFers.
}

export type raceConfig = {
    selected_raceTrack:Folder,
    laps:number?,
    checkpoints:Folder?,
    players_ready:boolean?,
    countdownTime:number,
    start:boolean,
    timeRemaining:number,
    finishers:{[Player]:playerState}

}

Players.PlayerAdded:Connect(function(plr)
    table.insert(local_players, plr)
end)

Players.PlayerRemoving:Connect(function(plr)
    for i, p in ipairs(local_players) do
        if p == plr then
            table.remove(local_players, i)
            break
        end
    end
end)

function Race.new(config:raceConfig)
    local self = setmetatable({}, Race)

    self.state = "Race state is"..tostring(config.start)
    self.selected_raceTrack = config.selected_raceTrack
    self.racers = {}::{[Player]:playerState}
    self.countdownTime = config.countdownTime
    self.start = config.start
    self.timeRemaining = config.timeRemaining
    self.laps = config.laps
    self.checkpoints = config.checkpoints
    self.finishers = config.finishers::{[Player]:playerState}

    return self
end

function Race:endRace()
    if self._ended then return end
    self._ended = true

    self.start = false

    for plr, state in pairs(self.racers) do
        if not state.lapEnd then
            state.DID_NOT_FINISH = true
        end
    end

    local RaceEnd = game.ReplicatedStorage.VehicleNet:WaitForChild("RaceEnd")
    RaceEnd:FireAllClients(self.finishers, self.racers)
end

function Race:start_timeRemaining()
    if self._timeRemainingRunning then return end
    self._timeRemainingRunning = true

    local RaceTimerUpdate = game.ReplicatedStorage.VehicleNet:WaitForChild("RaceTimerUpdate")

    task.spawn(function()
        while self.start and self.timeRemaining > 0 do
            self.timeRemaining -= 1
            RaceTimerUpdate:FireAllClients(self.timeRemaining)
            task.wait(1)
        end

        if self.timeRemaining == 0  then
            Race:endRace()
        end
    end)
end

function Race:startCountdown()
    if self._countdownStarted then return end
    self._countdownStarted = true

    local RaceCountdown = game.ReplicatedStorage.VehicleNet:WaitForChild("RaceCountdown")
    local RaceActiveFlag = game.ReplicatedStorage.VehicleNet:WaitForChild("RaceActiveFlag")

    for i = self.countdownTime or 3, 1, -1 do
        RaceCountdown:FireAllClients(i)
        task.wait(1)
    end

    RaceCountdown:FireAllClients("GO")
    self.start = true
    RaceActiveFlag.Value = true
    self._raceStartTime = tick()
    Race:start_timeRemaining()
end

function Race:readiness(plr: Player)
    if not plr then return end
    local state = self.racers[plr]
    if state.ready then return end
    state.ready = true

    local allReady = false

    for _, s in pairs(self.racers) do
        if not s.ready then
            allReady = false
            break
        end
    end

    if allReady then
        print("All racers ready. Starting countdown...")
        Race:startCountdown()
    end
end

function Race:readyCheck(plr:Player)
    if not plr then return end
    local state = self.racers[plr]
    ReadyUp.OnServerEvent:Connect(function(plr)
        Race:readiness(plr)
    end)
end

for i, plr in ipairs(local_players) do
    Race:readyCheck()
end

return Race]]
