--!strict
--!optimize 2
-- The camera driver a headless spec runs on: nothing in here is Roblox, so a mode that sits behind a body,
-- a pitch that clamps, a wall that pulls the camera in and a shake that decays are all assertable with no
-- engine in the loop. A game testing its own camera work against a stock camera uses the same thing.
--
-- It records rather than feeds, which is the other way round from `Beef.Stock.feed`: what a spec wants to
-- know is what was written to the camera. `sized` and `clears` are the two things it answers back with, so
-- a case can put the window at a shape it cares about and a wall in the way.

local Film = {}

local WIDE, TALL = 1920, 1080 -- a window of the usual shape, until a spec says otherwise

function Film.new(): any
	local width, height = WIDE, TALL
	local open = 1
	local booted = false
	local shots: { { at: CFrame, fov: number } } = {}
	local asked: { { from: Vector3, to: Vector3 } } = {}

	local self: any
	self = {
		-- the Driver
		start = function()
			booted = true
		end,

		viewport = function(): Vector2
			return Vector2.new(width, height)
		end,

		clear = function(from: Vector3, to: Vector3): number
			table.insert(asked, { from = from, to = to })
			return open
		end,

		set = function(at: CFrame, fov: number)
			table.insert(shots, { at = at, fov = fov })
		end,

		-- what a spec drives it with
		sized = function(w: number, h: number)
			width, height = w, h
		end,

		-- how much of the way out to the camera is unobstructed, 1 being nothing in the way
		clears = function(amount: number)
			open = amount
		end,

		-- and what it reads back
		started = function(): boolean
			return booted
		end,

		frames = function(): number
			return #shots
		end,

		at = function(): CFrame?
			local last = shots[#shots]
			return if last ~= nil then last.at else nil
		end,

		fov = function(): number?
			local last = shots[#shots]
			return if last ~= nil then last.fov else nil
		end,

		shots = function(): { { at: CFrame, fov: number } }
			return shots
		end,

		-- every collision question it was asked, so a case can check the mode asked one at all
		asked = function(): { { from: Vector3, to: Vector3 } }
			return asked
		end,
	}
	return self
end

return Film
