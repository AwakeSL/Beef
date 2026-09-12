--!strict
--!optimize 2
-- worker side of the rain: each actor casts its slice of drops along their motion this frame
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Beef = ReplicatedStorage.Beef
local Rain = ReplicatedStorage.Rain
local Kinds = require(Beef.Kinds)
local Events = require(Beef.Events)
local Phase = require(Beef.Phase)

local Position = require(Rain.Components.Position)
local Velocity = require(Rain.Components.Velocity)
local Origin = require(Rain.Components.Origin)
local Landing = Events.new("landing", "handle:u32", "x:f32", "y:f32", "z:f32")
local drop = Kinds.new("drop", Position, Velocity)
local slice = { from = 0, to = 0, dt = 1 / 60, handles = {} }

local function Cast(kind, position, velocity, origin, hit, range)
	local params = RaycastParams.new()
	return {
		name = "Cast",
		writes = { hit },
		loop = function()
			local p, v = position.of(kind).value, velocity.of(kind).value
			local handles = range.handles
			for i = range.from, range.to do
				local h = handles[i]
				local _, local_ = origin.find(h)
				local n = local_ and kind.at(local_)
				if n then
					local result = workspace:Raycast(p[n], v[n] * range.dt, params)
					if result then
						hit.push(h, result.Position.X, result.Position.Y, result.Position.Z)
					end
				end
			end
		end,
	}
end

local phase = Phase.new("RainCast", { { Cast, drop, Position, Velocity, Origin, Landing, slice } })

return {
	phase = phase,
	kind = drop,
	components = { Position, Velocity },
	events = {},
	back = { Landing },
	origin = Origin,
	slice = slice,
}
