--!strict
--!optimize 2
-- Sound: the stock controller that owns every Sound instance on the client. A game pushes the Events it
-- already pushes, and this turns them into audio, so the thing that fires an Event never touches a Sound,
-- a volume or a distance. It runs on the client.
--
-- One table at boot is the whole of it, the way `Replicate` takes the whole map of a game's traffic in one
-- call. An entry is the Event then its options, and the map itself is that same shape one size up: the list
-- part is the entries, the hash part is the options that belong to no single entry.
--
-- What it decides, and what it leaves alone. It decides where a sound is, whether the listener can hear it
-- through what is in the way, how loud it is against the other sounds in its group, and which sound loses
-- when there are more of them than the budget allows. It decides nothing about when a sound happens: that
-- is a push, and the push was made by whoever knew.
--
-- Where a sound is comes off the Event's own columns, read once at boot and never guessed at afterwards.
-- An Event with an `at` column is placed there. An Event naming an entity, the way `Beef.Kinds.died` does,
-- with a `kind` column and a `handle` column, is placed where that entity's Transform is. An Event with
-- neither is heard everywhere, which is what a menu click wants.
--
-- The engine goes through a driver, the way Input's does, so the whole of placement, occlusion, mixing and
-- the budget runs headless: `Beef.Stock.speaker()` records every play, stop, position and volume and a spec
-- asserts on what it recorded.
--
-- What it keeps between frames is the voices it has running, and nothing else: it declares every mapped
-- Event in `reads`, so the phase freezes a window over each one the same way it would for a handed Event,
-- and this reads `from`/`last` off them at post like any other controller. The group volumes are the
-- game's own table, read every frame, so a settings slider writes a number into it and the next frame is
-- quieter. Time comes from `phase.dt`, the way Movement's does, because nothing here asks the engine what
-- the hour is.

local Duck = require(script.Parent.Duck)
local Engine = require(script.Engine)

-- what a blocked sound is multiplied by. One number rather than a filter: a ray four times a second and a
-- volume is a rule a game can reason about, and a game wanting a real low pass writes a driver of its own.
local MUFFLE = 0.35
-- seconds between one voice's occlusion checks. The listener walks behind a wall while a long sound plays,
-- so the answer cannot be taken once, and a ray a frame per voice is a cost for nothing.
local RECHECK = 0.25
-- how many sounds at once when the map does not say
local VOICES = 24

-- the engine edge. Live it is Sound instances under an Attachment; under Lune it is `Speaker`, which writes
-- down what it was asked to do. `ended` hands back the voices that finished since the last call.
export type Driver = {
	start: () -> (),
	listener: () -> Vector3,
	blocked: (from: Vector3, to: Vector3) -> boolean,
	play: (voice: number, asset: string, at: Vector3?, volume: number, pitch: number, carries: number?) -> (),
	volume: (voice: number, volume: number) -> (),
	stop: (voice: number) -> (),
	ended: () -> { number },
}

-- how far the music drops and for how long, pushed into `Beef.Stock.Duck` on the frame the sound plays
export type Ducking = {
	amount: number,
	lasts: number,
}

-- one entry as the factory keeps it
export type Entry = {
	event: any,
	asset: string,
	group: string?,
	volume: number,
	pitch: number,
	carries: number?,
	duck: Ducking?,
	placed: string, -- "at", "entity" or "nowhere"
}

local MAP_OPTIONS: { [string]: boolean } = { groups = true, transform = true, voices = true }
local ENTRY_OPTIONS: { [string]: boolean } = {
	asset = true,
	carries = true,
	duck = true,
	group = true,
	pitch = true,
	volume = true,
}
local DUCK_OPTIONS: { [string]: boolean } = { amount = true, lasts = true }

local function listed(allowed: { [string]: any }): string
	local names = {}
	for key in allowed do
		table.insert(names, key)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

local function isBuffer(value: any): boolean
	return type(value) == "table" and type(value.freeze) == "function"
end

local function above(where: string, option: string, value: any): number
	assert(type(value) == "number" and value > 0, ("Sound %s: %s is a number above zero"):format(where, option))
	return value
end

-- a position is a Vector3, or the position of a CFrame, because a Transform is as often one as the other
local function positionOf(value: any): Vector3?
	local kind = typeof(value)
	if kind == "Vector3" then
		return value
	elseif kind == "CFrame" then
		return value.Position
	end
	return nil
end

-- ---------------------------------------------------------------- the map

-- an entry is the thing on its own or a list holding the thing and then its options, the same rule
-- `Replicate` reads its boot table by. A declared Event never has a first array element, so that alone
-- tells the two apart.
local function split(entry: any, where: string, allowed: { [string]: boolean }): ({ any }, { [string]: any })
	assert(type(entry) == "table", ("Sound %s: an entry is the event type, or a list of it and its options"):format(where))
	local things: { any } = {}
	local options: { [string]: any } = {}
	if entry[1] == nil then
		things[1] = entry
		return things, options
	end
	table.move(entry, 1, #entry, 1, things)
	for key, value in entry do
		if type(key) ~= "number" then
			assert(allowed[key], ("Sound %s: %s is not an option here; %s are"):format(where, tostring(key), listed(allowed)))
			options[key] = value
		end
	end
	return things, options
end

local function ducking(where: string, given: any): Ducking
	assert(type(given) == "table", ("Sound %s: duck says how far the music drops and for how long"):format(where))
	for key in given do
		assert(DUCK_OPTIONS[key], ("Sound %s: duck takes %s, not %s"):format(where, listed(DUCK_OPTIONS), tostring(key)))
	end
	local amount = above(where, "duck.amount", given.amount)
	assert(amount <= 1, ("Sound %s: duck.amount is at most one, which is silence"):format(where))
	return { amount = amount, lasts = above(where, "duck.lasts", given.lasts) }
end

-- where a push of this Event says its sound is, decided once, off the columns the Event was declared with
local function placement(event: any): string
	local has: { [string]: boolean } = {}
	for _, column in event.columns do
		has[column] = true
	end
	if has.at then
		return "at"
	elseif has.kind and has.handle then
		return "entity"
	end
	return "nowhere"
end

local function read(map: { any }): ({ Entry }, { [string]: any }, number, any)
	assert(type(map) == "table", "Sound: the map is the Events a game pushes and the sounds each one makes")

	local options: { [string]: any } = {}
	for key, value in map do
		if type(key) ~= "number" then
			assert(MAP_OPTIONS[key], ("Sound: %s is not a key of the map; %s are"):format(tostring(key), listed(MAP_OPTIONS)))
			options[key] = value
		end
	end

	local groups: { [string]: any } = {}
	if options.groups ~= nil then
		assert(type(options.groups) == "table", "Sound: groups is a table of group names and how loud each one is")
		groups = options.groups
		for name, volume in groups do
			assert(type(name) == "string", ("Sound: a group is named by a string, not a %s"):format(typeof(name)))
			assert(type(volume) == "number" and volume >= 0, ("Sound %s: a group's volume is a number, nothing or more"):format(name))
		end
	end

	local voices = VOICES
	if options.voices ~= nil then
		voices = above("voices", "voices", options.voices)
	end

	local transform = options.transform
	if transform ~= nil then
		assert(
			type(transform) == "table" and type(transform.get) == "function",
			"Sound: transform is the Component a placed entity keeps its position in"
		)
	end

	local entries: { Entry } = {}
	local taken: { [any]: boolean } = {}
	for i = 1, #map do
		local things, given = split(map[i], "entry " .. i, ENTRY_OPTIONS)
		local where = "entry " .. i
		assert(#things == 1, ("Sound %s: an entry names one event type"):format(where))
		local event = things[1]
		assert(isBuffer(event), ("Sound %s: %s is not an event type"):format(where, tostring(event)))
		where = event.name
		assert(not taken[event], ("Sound %s: two entries both name it; one Event makes one sound"):format(where))
		taken[event] = true

		assert(type(given.asset) == "string" and given.asset ~= "", ("Sound %s: asset is the sound it plays, as a string"):format(where))

		local group = given.group
		if group ~= nil then
			assert(type(group) == "string", ("Sound %s: group names one of the map's groups, as a string"):format(where))
			assert(groups[group] ~= nil, ("Sound %s: %s is not a group here; %s are"):format(where, group, listed(groups)))
		end

		local volume = 1
		if given.volume ~= nil then
			assert(
				type(given.volume) == "number" and given.volume >= 0,
				("Sound %s: volume is a number, nothing or more"):format(where)
			)
			volume = given.volume
		end

		local placed = placement(event)
		if placed == "entity" then
			assert(transform ~= nil, ("Sound %s: names an entity, so the map needs transform, the Component its position is in"):format(where))
		end

		table.insert(entries, {
			event = event,
			asset = given.asset,
			group = group,
			volume = volume,
			pitch = if given.pitch ~= nil then above(where, "pitch", given.pitch) else 1,
			carries = if given.carries ~= nil then above(where, "carries", given.carries) else nil,
			duck = if given.duck ~= nil then ducking(where, given.duck) else nil,
			placed = placed,
		})
	end

	return entries, groups, voices, transform
end

-- ---------------------------------------------------------------- the controller

-- one sound running right now, and the only thing this controller remembers between frames
type Voice = {
	id: number,
	entry: Entry,
	at: Vector3?,
	muffled: boolean,
	check: number,
	sent: number,
}

-- the factory. `chosen` is the engine edge and a game never passes it: live it is Sound instances, and a
-- spec hands a `Beef.Stock.speaker()` instead, with a listener it moves and walls it puts up.
return function(map: { any }, chosen: Driver?): any
	local driver: Driver = chosen or Engine
	local entries, groups, voices, transform = read(map)

	local reads: { any } = {}
	local ducks = false
	for _, entry in entries do
		table.insert(reads, entry.event)
		if entry.duck ~= nil then
			ducks = true
		end
	end

	local live: { Voice } = {}
	local next_ = 0

	-- how loud a group is right now. The table is the game's own, so a settings slider writes into it and
	-- this reads what is there; a group nobody declared is full volume.
	local function mix(name: string?): number
		if name == nil then
			return 1
		end
		local volume = groups[name]
		if type(volume) ~= "number" then
			return 1
		end
		return math.max(volume, 0)
	end

	-- what the engine is told: the sound's own volume, its group's, and whether something is in the way.
	-- The fall with distance is the engine's, so it is not in here.
	local function volumeOf(entry: Entry, muffled: boolean): number
		local volume = entry.volume * mix(entry.group)
		if muffled then
			volume *= MUFFLE
		end
		return volume
	end

	-- and what the budget ranks by, which is the same with the distance folded in, so the voice that loses
	-- is the one the listener was least able to hear
	local function loudness(entry: Entry, at: Vector3?, muffled: boolean, listener: Vector3): number
		local volume = volumeOf(entry, muffled)
		local carries = entry.carries
		if at ~= nil and carries ~= nil then
			volume *= math.max(0, 1 - (at - listener).Magnitude / carries)
		end
		return volume
	end

	local function drop(which: number)
		local last = #live
		live[which] = live[last]
		live[last] = nil
	end

	local function free(id: number)
		for i = 1, #live do
			if live[i].id == id then
				drop(i)
				return
			end
		end
	end

	-- room for one more. The quietest voice running loses its place, and a sound quieter than every one of
	-- them never starts, because a budget spent on what nobody can hear is a budget spent on nothing.
	local function room(loud: number, listener: Vector3): boolean
		if #live < voices then
			return true
		end
		local worst, quietest = 0, loud
		for i = 1, #live do
			local voice = live[i]
			local was = loudness(voice.entry, voice.at, voice.muffled, listener)
			if was < quietest then
				worst, quietest = i, was
			end
		end
		if worst == 0 then
			return false
		end
		driver.stop(live[worst].id)
		drop(worst)
		return true
	end

	local function start(entry: Entry, at: Vector3?, listener: Vector3)
		local muffled = at ~= nil and driver.blocked(listener, at)
		if not room(loudness(entry, at, muffled, listener), listener) then
			return
		end
		next_ += 1
		local id = next_
		local volume = volumeOf(entry, muffled)
		driver.play(id, entry.asset, at, volume, entry.pitch, entry.carries)
		table.insert(live, { id = id, entry = entry, at = at, muffled = muffled, check = RECHECK, sent = volume })
		local duck = entry.duck
		if duck ~= nil then
			Duck.push(duck.amount, duck.lasts)
		end
	end

	-- where the push says its sound is. The second answer is whether it is to be heard at all: an entity
	-- that is gone has no position, and a sound past what it carries is not worth a voice.
	local function whereabouts(entry: Entry, i: number, listener: Vector3): (Vector3?, boolean)
		local event = entry.event
		local at: Vector3? = nil
		if entry.placed == "at" then
			at = positionOf(event.at[i])
		elseif entry.placed == "entity" then
			local kind = event.kind[i]
			if type(kind) ~= "table" then
				return nil, false
			end
			local handle = event.handle[i]
			-- an entity that died this frame is still where it was, which is where its last sound belongs
			local n = kind.at(handle) or kind.dying(handle)
			if n == nil then
				return nil, false
			end
			at = positionOf(transform.get(kind, n))
		else
			return nil, true
		end
		if at == nil then
			return nil, false
		end
		local carries = entry.carries
		if carries ~= nil and (at - listener).Magnitude > carries then
			return at, false
		end
		return at, true
	end

	local self: any
	self = {
		name = "Sound",
		reads = reads,
		writes = if ducks then { Duck } else nil,

		boot = function()
			driver.start()
		end,

		-- one post, once a frame: the window then holds every push the frame made, whichever controller
		-- made it, and the clock the occlusion checks run against counts down once rather than once a pass
		post = function()
			local dt = self.phase.dt
			local listener = driver.listener()

			local done = driver.ended()
			for i = 1, #done do
				free(done[i])
			end

			for _, entry in entries do
				local event = entry.event
				for i = event.from, event.last do
					local at, heard = whereabouts(entry, i, listener)
					if heard then
						start(entry, at, listener)
					end
				end
			end

			-- and the ones already running are kept right: what is in the way is asked again on a timer,
			-- and a group the game turned down reaches every voice in it on the next frame
			for i = 1, #live do
				local voice = live[i]
				local at = voice.at
				if at ~= nil then
					voice.check -= dt
					if voice.check <= 0 then
						voice.check = RECHECK
						voice.muffled = driver.blocked(listener, at)
					end
				end
				local volume = volumeOf(voice.entry, voice.muffled)
				if volume ~= voice.sent then
					voice.sent = volume
					driver.volume(voice.id, volume)
				end
			end
		end,
	}
	return self
end
