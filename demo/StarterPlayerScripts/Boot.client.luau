--!strict
--!optimize 2
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Beef = require(ReplicatedStorage:WaitForChild("Beef"))
local Rain = ReplicatedStorage:WaitForChild("Rain")
local Events, Kinds, Phase, Drivers = Beef.Events, Beef.Kinds, Beef.Phase, Beef.Drivers
local Rained = require(Rain.Events.Rained)
local Landing = require(Rain.Events.Landing)
local Drop = require(Rain.Kinds.Drop)
local Position = require(Rain.Components.Position)
local Velocity = require(Rain.Components.Velocity)
local Origin = require(Rain.Components.Origin)
local Controllers = Rain.Controllers

-- the same table the server booted with; here it waits for the remotes and unpacks into the same event types,
-- before the phase runs, so the first pass of the loop is the first window that holds what arrived
Beef.Replicate(require(Rain.Traffic))

-- the client runs the same fall as the server: a drop is born when the server says so and dies when it lands there
local heartbeat = Phase.new("Heartbeat", {
	{ require(Controllers.Rain), Rained, Landing, Drop, Origin },
	{ require(Controllers.Fall), Drop, Position, Velocity },
	{ require(Controllers.Floor), Drop, Position },
	{ require(Controllers.Drops), Drop, Position },
	{ require(Controllers.Report) },
})

task.delay(3, function()
	print("[client]\n" .. heartbeat.describe())
end)

RunService.PreAnimation:Connect(function()
	Events.lap()
	Kinds.lap()
end)
Drivers.events({
	Heartbeat = heartbeat,
})
