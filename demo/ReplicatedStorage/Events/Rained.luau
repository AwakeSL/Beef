--!strict
--!optimize 2
local Events = require(game:GetService("ReplicatedStorage").Beef.Events)

export type Rained = Events.Buffer & {
	handle: { number },
	position: { Vector3 },
	velocity: { Vector3 },
}

return Events.new("rained", "handle:u32", "position:vector3", "velocity:vector3") :: Rained
