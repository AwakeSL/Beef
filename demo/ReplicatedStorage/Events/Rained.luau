--!strict
--!optimize 2
local Beef = require(game:GetService("ReplicatedStorage").Beef)

export type Rained = Beef.Buffer & {
	handle: { number },
	position: { Vector3 },
	velocity: { Vector3 },
}

return Beef.Events.new("rained", "handle:u32", "position:vector3", "velocity:vector3") :: Rained
