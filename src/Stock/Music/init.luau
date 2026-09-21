--!strict
--!optimize 2
-- Music: one stream of it, with states. The game pushes a state change and this crossfades from whatever
-- was playing to whatever that state plays, over the time the arriving track declared. That is the whole of
-- it. It writes nothing back into Beef, touches no Component, and decides nothing about when a state
-- changes: something else in the game knows the player walked into the boss room, and all it does about it
-- is push a state.
--
-- It runs on the client, because music is one player's.
--
-- The three things it is handed are the game's. `State` is an Event with a column named `state`, which the
-- game pushes a name into. `tracks` says what each of those names plays. `Duck` is the Event Sound declares
-- to ask the music out of the way for a moment, and a game with no Sound in it leaves it out.
--
-- Where the decisions went. The crossfade time belongs to the track arriving, not the one leaving, because
-- what a fade is for is the thing you are about to hear: getting into a fight is fast and getting out of
-- one is slow, and both are declared on the state you are getting into. Both streams move over that one
-- window, shaped so the middle of a fade does not dip. A duck drops the stream at once and eases back up,
-- since a duck that fades in is a duck that arrived too late to be any use. A state pushed that is already
-- playing does nothing, so a game may push the state it is in every frame and nothing restarts.
--
-- It is one `post`, once a frame. The State window there is the whole frame's pushes and the clock is
-- counted down once, the same reasoning Movement runs on.

local Engine = require(script.Engine)

-- how long a fade takes when the track does not say
local CROSSFADE = 2
-- how long the stream takes to climb back to full once the last duck has run out
local EASE = 0.3
-- volumes below this much apart are the same volume, so a steady track is not written every frame
local SAME = 1e-4

-- one state's track as the factory keeps it. `asset` is false for a state where nothing plays.
export type Track = {
	asset: string | boolean,
	volume: number,
	loop: boolean,
	crossfade: number,
}

-- the engine edge. Live it owns two Sounds and sets their volume and playing state; headless it is `Tape`,
-- which keeps every call so a spec can read the fade curve back. A slot is 1 or 2, the two streams a
-- crossfade needs.
export type Driver = {
	bind: () -> (),
	play: (slot: number, asset: string, looped: boolean) -> (),
	stop: (slot: number) -> (),
	volume: (slot: number, level: number) -> (),
}

-- what a state that plays something may say beyond its asset
local OPTIONS: { [string]: boolean } = { crossfade = true, loop = true, volume = true }
-- and what a quiet state may: only the fade, since there is no level and no loop on nothing
local QUIET: { [string]: boolean } = { crossfade = true }

local function listed(allowed: { [string]: any }): string
	local names = {}
	for key in allowed do
		table.insert(names, key)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

-- equal power: two streams at the same point of one fade add up to the same loudness as either of them
-- alone, so the middle of a crossfade does not sag the way a straight line through it does
local function shape(gain: number): number
	return math.sin(gain * math.pi * 0.5)
end

-- ---------------------------------------------------------------- the tracks table

local function read(tracks: { [string]: any }): { [string]: Track }
	assert(type(tracks) == "table", "Music: tracks is a table of state names and what plays in each")

	-- in one fixed order, so two clients build the same tracks the same way twice
	local named: { string } = {}
	for name in tracks do
		assert(type(name) == "string", ("Music: a state is named by a string, not a %s"):format(typeof(name)))
		table.insert(named, name)
	end
	table.sort(named)
	assert(#named > 0, "Music: tracks names at least one state")

	local declared: { [string]: Track } = {}
	for _, name in named do
		local given = tracks[name]
		assert(type(given) == "table", ("Music %s: a track is a table saying what plays in that state"):format(name))

		local asset = given.asset
		assert(
			type(asset) == "string" or asset == false,
			("Music %s: asset names the sound that plays, or false for a state where nothing does"):format(name)
		)
		local plays = asset ~= false
		local allowed = if plays then OPTIONS else QUIET

		for key in given do
			if key == "asset" then
				continue
			end
			assert(OPTIONS[key] ~= nil, ("Music %s: %s is not an option here; %s are"):format(name, tostring(key), listed(OPTIONS)))
			assert(
				allowed[key],
				("Music %s: %s is an option on a state that plays something, not on a quiet one"):format(name, tostring(key))
			)
		end

		local volume = given.volume
		if volume == nil then
			volume = 1
		end
		assert(
			type(volume) == "number" and volume >= 0 and volume <= 1,
			("Music %s: volume is a number from zero to one"):format(name)
		)

		local fade = given.crossfade
		if fade == nil then
			fade = CROSSFADE
		end
		assert(type(fade) == "number" and fade >= 0, ("Music %s: crossfade is a number of seconds, at or above zero"):format(name))

		local looped = given.loop
		if looped == nil then
			looped = true
		end
		assert(type(looped) == "boolean", ("Music %s: loop is true or false"):format(name))

		declared[name] = { asset = asset, volume = volume, loop = looped, crossfade = fade }
	end

	return declared
end

local function column(event: any, name: string): boolean
	return type(event) == "table" and type(event.columns) == "table" and table.find(event.columns, name) ~= nil
end

-- ---------------------------------------------------------------- the controller

-- the factory. `chosen` is the engine edge and a game never passes it: live it is two Sounds under
-- SoundService, and a spec hands a `Beef.Stock.tape()` instead and reads back every volume written.
return function(state: any, tracks: { [string]: any }, duck: any?, chosen: Driver?): any
	assert(
		type(state) == "table" and type(state.push) == "function",
		"Music: the first thing handed to it is the Event the game pushes its state changes into"
	)
	assert(column(state, "state"), "Music: that Event needs a column named state, which is the name of the state being entered")
	if duck ~= nil then
		assert(
			type(duck) == "table" and type(duck.push) == "function" and column(duck, "amount") and column(duck, "lasts"),
			"Music: the third thing handed to it is the Event Sound ducks with, whose columns are amount and lasts"
		)
	end

	local declared = read(tracks)
	local driver: Driver = chosen or Engine

	-- the two streams. `gain` walks between 0 and 1 toward `to` at `rate` a second, and a rate of zero is a
	-- cut. `level` is the last volume written, kept so a steady track is not written again every frame.
	local live = { false, false }
	local level = { -1, -1 }
	local volume = { 0, 0 }
	local gain = { 0, 0 }
	local to = { 0, 0 }
	local rate = { 0, 0 }
	local sounding: { [number]: string } = {}

	-- which slot the state now playing owns, zero while nothing does, and which slot the last track that
	-- started went into, so a track arriving never takes the slot of the newest thing anyone can hear
	local at = 0
	local last = 2
	local playing: string? = nil
	-- a state named nowhere in the tracks table is quiet, and said once: a name with nothing behind it is
	-- almost always a typo, and music that stops without saying why is hard to go looking for
	local unknown: { [string]: boolean } = {}

	-- every duck still running, as how far it drops the stream and how long it has left
	local amounts: { number } = {}
	local lefts: { number } = {}
	local dropped = 0

	local function enter(name: string)
		if name == playing then
			return
		end
		playing = name

		local track = declared[name]
		if track == nil and not unknown[name] then
			unknown[name] = true
			warn(("Beef.Stock.Music: nothing is declared for the state %s, so the stream goes quiet"):format(name))
		end
		local fade = if track ~= nil then track.crossfade else CROSSFADE
		local speed = if fade > 0 then 1 / fade else 0

		if at ~= 0 then
			to[at] = 0
			rate[at] = speed
		end
		if track == nil or track.asset == false then
			at = 0
			return
		end

		local asset = track.asset :: string
		if at ~= 0 and sounding[at] == asset then
			-- two states that play the same thing. Nothing has to move, so the track keeps going where it
			-- is and only the level it is heading for changes.
			volume[at] = track.volume
			to[at] = 1
			rate[at] = speed
			return
		end

		-- the slot the newest track is not in. With two streams a third state arriving mid fade has to take
		-- one of them, and the one already on its way out is the one nobody is still listening to.
		local n = 3 - last
		if live[n] and sounding[n] == asset then
			-- a state left and come back to while its track is still fading out: turn that one around where
			-- it is rather than starting it over, which is what anyone listening expects
			volume[n] = track.volume
			to[n] = 1
			rate[n] = speed
		else
			if live[n] then
				driver.stop(n)
			end
			live[n] = true
			sounding[n] = asset
			volume[n] = track.volume
			gain[n] = 0
			to[n] = 1
			rate[n] = speed
			level[n] = 0
			-- silent before it is audible, so a slot starting does not blip at whatever the last track left
			driver.volume(n, 0)
			driver.play(n, asset, track.loop)
		end
		at = n
		last = n
	end

	local self: any
	local reads = { state }
	if duck ~= nil then
		table.insert(reads, duck)
	end

	self = {
		name = "Music",
		reads = reads,

		boot = function()
			driver.bind()
		end,

		post = function()
			local dt = self.phase.dt

			-- the frame's state, which is the last one pushed in it: one stream, so a frame where the game
			-- changed its mind twice starts one track, not two
			local wanted: string? = nil
			for i = state.from, state.last do
				local name = state.state[i]
				if type(name) == "string" then
					wanted = name
				end
			end
			if wanted ~= nil then
				enter(wanted)
			end

			-- what the ducks add up to. A duck counts on the frame it arrives, however short it is.
			if duck ~= nil then
				for i = duck.from, duck.last do
					local amount = duck.amount[i]
					local lasts = duck.lasts[i]
					if type(amount) == "number" and type(lasts) == "number" and amount > 0 and lasts > 0 then
						table.insert(amounts, math.min(amount, 1))
						table.insert(lefts, lasts)
					end
				end
			end
			local want = 0
			for i = 1, #amounts do
				if amounts[i] > want then
					want = amounts[i]
				end
			end
			if want >= dropped then
				dropped = want
			else
				dropped = math.max(want, dropped - dt / EASE)
			end
			for i = #lefts, 1, -1 do
				lefts[i] -= dt
				if lefts[i] <= 0 then
					table.remove(lefts, i)
					table.remove(amounts, i)
				end
			end
			local mix = 1 - dropped

			for i = 1, 2 do
				if not live[i] then
					continue
				end
				if rate[i] <= 0 then
					gain[i] = to[i]
				elseif gain[i] < to[i] then
					gain[i] = math.min(to[i], gain[i] + rate[i] * dt)
				else
					gain[i] = math.max(to[i], gain[i] - rate[i] * dt)
				end

				if gain[i] <= 0 and to[i] == 0 then
					live[i] = false
					sounding[i] = nil
					driver.stop(i)
				else
					local want_ = shape(gain[i]) * volume[i] * mix
					if math.abs(want_ - level[i]) > SAME then
						level[i] = want_
						driver.volume(i, want_)
					end
				end
			end
		end,
	}
	return self
end
