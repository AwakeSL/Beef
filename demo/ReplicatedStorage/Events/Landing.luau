--!strict
--!optimize 2
local Events = require(game:GetService("ReplicatedStorage").Beef.Events)

export type Landing = Events.Buffer & {
	handle: { number },
	x: { number },
	y: { number },
	z: { number },
}

return Events.new("landing", "handle:u32", "x:f32", "y:f32", "z:f32") :: Landing
