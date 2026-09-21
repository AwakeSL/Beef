--!strict
--!optimize 2
-- The driver a headless spec runs on: it plays nothing and keeps everything. Every call the controller
-- makes is written down in the order it was made, so a fade is a list of numbers a case can walk, a
-- crossfade is two of those lists side by side, and a duck is a dent in both. A game testing its own music
-- states uses the same thing.
--
-- Nothing in here is Roblox. `slot` is 1 or 2, the two streams a crossfade needs.

local Tape = {}

export type Call = {
	what: string, -- "play", "stop" or "volume"
	slot: number,
	asset: string?,
	looped: boolean?,
	level: number?,
}

function Tape.new(): any
	local bound = false
	local calls: { Call } = {}
	local levels: { { number } } = { {}, {} }
	local lasts: { number } = { 0, 0 }
	local on: { [number]: string } = {}

	local self: any
	self = {
		-- the Driver
		bind = function()
			bound = true
		end,

		play = function(slot: number, asset: string, looped: boolean)
			on[slot] = asset
			table.insert(calls, { what = "play", slot = slot, asset = asset, looped = looped })
		end,

		stop = function(slot: number)
			on[slot] = nil
			table.insert(calls, { what = "stop", slot = slot })
		end,

		volume = function(slot: number, level: number)
			lasts[slot] = level
			table.insert(levels[slot], level)
			table.insert(calls, { what = "volume", slot = slot, level = level })
		end,

		-- what a spec reads back
		bound = function(): boolean
			return bound
		end,

		-- every call, in order
		log = function(): { Call }
			return calls
		end,

		-- every volume written to a stream since the tape was last cleared, which is the fade curve
		levels = function(slot: number): { number }
			return levels[slot]
		end,

		-- the level a stream is at now, which is nothing at all while it is stopped. Kept apart from the
		-- curve above, so a case that cleared the tape can still ask where the music is.
		level = function(slot: number): number
			if on[slot] == nil then
				return 0
			end
			return lasts[slot]
		end,

		-- the asset a stream is running, or nil while it is stopped
		playing = function(slot: number): string?
			return on[slot]
		end,

		-- which streams are running and what is on them, as "1:calm 2:chase", so a case asserts one string
		-- rather than four fields
		streams = function(): string
			local parts = {}
			for slot = 1, 2 do
				if on[slot] ~= nil then
					table.insert(parts, slot .. ":" .. on[slot])
				end
			end
			return table.concat(parts, " ")
		end,

		-- forget what has been written so far, so a case can read one frame's worth on its own
		clear = function()
			table.clear(calls)
			table.clear(levels[1])
			table.clear(levels[2])
		end,
	}
	return self
end

return Tape
