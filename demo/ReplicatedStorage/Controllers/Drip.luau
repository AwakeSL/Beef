--!strict
--!optimize 2
type Kind = { spawn: (...any) -> number }
type Rained = { push: (number, Vector3, Vector3) -> () }
type Phase = { dt: number }
type Controller = { name: string, writes: { Rained }, pre: () -> (), phase: Phase? }

local RATE = 1000
local HEIGHT = 80

-- spawns the rain and announces each birth, so a client can run the same fall itself
return function(drop: Kind, rained: Rained)
	local rng = Random.new()
	local owed = 0
	local self: Controller
	self = {
		name = "Drip",
		writes = { rained },
		pre = function()
			owed += RATE * (self.phase :: Phase).dt
			while owed >= 1 do
				owed -= 1
				local position = Vector3.new(rng:NextNumber(-100, 100), HEIGHT, rng:NextNumber(-100, 100))
				local velocity = Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-3, 3))
				local handle = drop.spawn(position, velocity)
				rained.push(handle, position, velocity)
			end
		end,
	}
	return self
end
