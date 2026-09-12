--!strict
--!optimize 2
local Beef = require(game:GetService("ReplicatedStorage").Beef)

export type Landing = Beef.Buffer & {
	handle: { number },
	x: { number },
	y: { number },
	z: { number },
}

return Beef.Events.new("landing", "handle:u32", "x:f32", "y:f32", "z:f32") :: Landing
