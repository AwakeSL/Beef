--!strict
--!optimize 2
-- The sound driver a headless spec runs on: a listener it moves, walls it puts up, and a written record of
-- everything the controller asked for. Nothing in here is Roblox, so placement, occlusion, mixing, the
-- budget and who is close enough to hear are all assertable with no engine in the loop. A game testing its
-- own sounds uses the same thing.
--
-- It plays nothing and ends nothing on its own. A sound runs until the spec says it finished, which is what
-- makes the voice budget a thing a case can drive: fill it, push one more, and read which one lost.

local Speaker = {}

-- what one play was asked for. `volume` is what it started at and `heard` is what it is now, so a case can
-- tell the two apart after a group's volume moves.
export type Played = {
	voice: number,
	asset: string,
	at: Vector3?,
	volume: number,
	heard: number,
	pitch: number,
	carries: number?,
}

function Speaker.new(): any
	local where = Vector3.zero
	local wall = false
	local asked = 0
	local plays: { Played } = {}
	local order: { number } = {}
	local of: { [number]: Played } = {}
	local ended: { number } = {}
	local stopped: { number } = {}
	local booted = false

	local function forget(voice: number)
		for i = 1, #order do
			if order[i] == voice then
				table.remove(order, i)
				return
			end
		end
	end

	local self: any
	self = {
		-- the Driver
		start = function()
			booted = true
		end,

		listener = function(): Vector3
			return where
		end,

		blocked = function(from: Vector3, to: Vector3): boolean
			asked += 1
			return wall
		end,

		play = function(voice: number, asset: string, at: Vector3?, volume: number, pitch: number, carries: number?)
			local one: Played = {
				voice = voice,
				asset = asset,
				at = at,
				volume = volume,
				heard = volume,
				pitch = pitch,
				carries = carries,
			}
			table.insert(plays, one)
			table.insert(order, voice)
			of[voice] = one
		end,

		volume = function(voice: number, volume: number)
			local one = of[voice]
			if one ~= nil then
				one.heard = volume
			end
		end,

		stop = function(voice: number)
			table.insert(stopped, voice)
			forget(voice)
		end,

		ended = function(): { number }
			local out = ended
			ended = {}
			return out
		end,

		-- what a spec drives it with
		listen = function(at: Vector3)
			where = at
		end,

		blocks = function(on: boolean)
			wall = on
		end,

		-- a sound reaching its end: the one named, or the oldest still running
		finish = function(voice: number?)
			local which = voice or order[1]
			if which == nil then
				return
			end
			forget(which)
			table.insert(ended, which)
		end,

		-- and what it reads back
		booted = function(): boolean
			return booted
		end,

		played = function(): { Played }
			return plays
		end,

		last = function(): Played?
			return plays[#plays]
		end,

		playing = function(): { number }
			return table.move(order, 1, #order, 1, {})
		end,

		volumeOf = function(voice: number): number?
			local one = of[voice]
			return if one ~= nil then one.heard else nil
		end,

		stopped = function(): { number }
			return stopped
		end,

		rays = function(): number
			return asked
		end,
	}
	return self
end

return Speaker
