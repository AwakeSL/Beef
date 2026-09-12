--!strict
--!optimize 2
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Beef = require(ReplicatedStorage.Beef)
local Rain = ReplicatedStorage.Rain
local Events, Kinds, Phase, Drivers, Stock = Beef.Events, Beef.Kinds, Beef.Phase, Beef.Drivers, Beef.Stock
local Landing = require(Rain.Events.Landing)
local Rained = require(Rain.Events.Rained)
local Drop = require(Rain.Kinds.Drop)
local Position = require(Rain.Components.Position)
local Velocity = require(Rain.Components.Velocity)
local Controllers = Rain.Controllers

-- the rain casts run in actors: packed after the phases on PreSimulation, back before them on Heartbeat
Drivers.parallel({
	name = "Rain",
	workers = 4,
	phase = Rain.Parallel.RainCast,
	ship = { Drop, Position, Velocity },
	back = { Landing },
})

local heartbeat = Phase.new("Heartbeat", {
	{ require(Controllers.Ground) },
	{ require(Controllers.Drip), Drop, Rained },
	{ require(Controllers.Land), Landing, Drop },
	{ require(Controllers.Fall), Drop, Position, Velocity },
	{ require(Controllers.Floor), Drop, Position },
	{ Stock.Send, "World", Kinds.died, Rained, Landing },
	{ require(Controllers.Report) },
})

print(heartbeat.describe())

RunService.PreAnimation:Connect(function()
	Events.lap()
	Kinds.lap()
end)
Drivers.events({
	Heartbeat = heartbeat,
})
