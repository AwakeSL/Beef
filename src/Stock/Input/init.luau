--!strict
--!optimize 2
-- Input: the first stock controller, and the only one that touches the engine. A game says what its actions
-- are called and what triggers them, once, in the bindings table; every controller after this one reads
-- `Action` pushes and never asks the engine anything. It runs on the client.
--
-- What Roblox gives and what this adds. The Input Action System
-- (https://create.roblox.com/docs/input/input-action-system) gives an InputContext holding InputActions,
-- each with InputBinding children: a binding names a KeyCode, an on-screen UIButton, or the Forward,
-- Backward, Left and Right KeyCodes of a composite direction, and an action of Enum.InputActionType.Bool
-- fires Pressed and Released while Direction1D and Direction2D fire StateChanged. An analog trigger counts
-- as pressed at the binding's PressedThreshold. Which device the player is on is
-- UserInputService.PreferredInput. All of that lives in `Engine`, behind the driver, and nothing in this
-- file knows any of it.
--
-- What the system has no notion of is time. A press held for eight tenths of a second, a press remembered
-- for a sixth of one, two keys that have to be down together, three actions that have to arrive in order:
-- holds, buffers, chords and sequences are what this controller is, and they are all it is. It decides
-- nothing about what an action means. A chord does not silence its members, a buffered press is not
-- consumed by anyone, a hold does not cancel the release that follows it. Every one of those is a game's
-- call, made by whoever reads the pushes.
--
-- What it keeps between frames is its own timing and nothing else: when a press that declared a hold or a
-- buffer happened, whether a chord was on last frame, how far along a sequence is. Which keys are down is
-- the engine's, read back through `driver.active`, and every fact a game could want leaves as a push.

local Action = require(script.Parent.Action)
local Engine = require(script.Engine)

local Phases = Action.Phases
local PRESSED, RELEASED = Action.Edges.Pressed, Action.Edges.Released

-- one action as the driver is asked to build it. A chord and a sequence are made of other entries, so
-- neither reaches the driver at all.
export type Declared = {
	name: string,
	shape: string, -- "keys", "axis" or "move"
	keys: { any }?, -- KeyCodes, or GuiButtons for an on-screen binding
	move: { [string]: any }?, -- forward, back, left, right, stick
	press: number?, -- where an analog trigger counts as pressed
	release: number?, -- and where it counts as released again
	scale: number?,
}

-- what the engine did, flattened. `edge` is one of `Beef.Stock.Edges`; `value`, `x` and `y` read the way
-- the Action columns do.
export type Edge = {
	action: string,
	edge: number,
	value: number,
	x: number,
	y: number,
	device: number,
}

-- the engine edge. Live it is InputContext and friends; under Lune it is `Feed`, a clock and a set of keys
-- a spec presses. `drain` hands back the edges since the last call and may hand back the same table again
-- next frame, so a caller reads it before it drains again.
export type Driver = {
	now: () -> number,
	device: () -> number,
	active: (action: string) -> boolean,
	bind: (declared: { Declared }) -> (),
	drain: () -> { Edge },
}

local WITHIN = 0.5 -- how long a sequence has for its next step when the entry does not say

-- a trigger says where the action comes from; an entry names exactly one
local TRIGGERS: { string } = { "keys", "axis", "move", "chord", "sequence" }
-- and the rest of its keys are options, each allowed on some triggers and not others
local OPTIONS: { [string]: { [string]: boolean } } = {
	buffer = { keys = true, chord = true },
	hold = { keys = true, chord = true },
	within = { sequence = true },
	press = { keys = true },
	release = { keys = true },
	scale = { axis = true, move = true },
}
local MOVE: { [string]: boolean } = { forward = true, back = true, left = true, right = true, stick = true }

local function listed(allowed: { [string]: any }): string
	local names = {}
	for key in allowed do
		table.insert(names, key)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

local function seconds(name: string, option: string, value: any): number
	assert(type(value) == "number" and value > 0, ("Input %s: %s is a number of seconds"):format(name, option))
	return value
end

-- a hardware trigger is a KeyCode or the GuiButton an on-screen binding sits on; everything else is caught
-- here rather than at the far end of an Instance assignment
local function hardware(name: string, where: string, list: any): { any }
	assert(type(list) == "table" and #list > 0, ("Input %s: %s is a list of what triggers it"):format(name, where))
	for _, key in list do
		local kind = typeof(key)
		assert(
			kind == "EnumItem" or kind == "Instance",
			("Input %s: %s holds KeyCodes and on-screen buttons, not a %s"):format(name, where, kind)
		)
	end
	return list
end

-- ---------------------------------------------------------------- the bindings table

type Entry = {
	name: string,
	trigger: string,
	of: { any }, -- the hardware, or the names a chord or a sequence is made of
	buffer: number?,
	hold: number?,
	within: number,
	holds: { [string]: boolean }, -- for a sequence: which names are steps of it, in any position
}

local function read(bindings: { [string]: any }): ({ string }, { [string]: Entry }, { Declared })
	assert(type(bindings) == "table", "Input: bindings is a table of action names and what triggers each")

	-- names in one fixed order, so two clients build the same actions in the same order and a describe reads
	-- the same twice
	local names: { string } = {}
	for name in bindings do
		assert(type(name) == "string", ("Input: an action is named by a string, not a %s"):format(typeof(name)))
		table.insert(names, name)
	end
	table.sort(names)

	local entries: { [string]: Entry } = {}
	local declared: { Declared } = {}

	for _, name in names do
		local given = bindings[name]
		assert(type(given) == "table", ("Input %s: an entry is a table saying what triggers the action"):format(name))

		local trigger: string? = nil
		for _, candidate in TRIGGERS do
			if given[candidate] ~= nil then
				if trigger ~= nil then
					error(("Input %s: an entry names one of %s, not both %s and %s"):format(name, table.concat(TRIGGERS, ", "), trigger, candidate), 0)
				end
				trigger = candidate
			end
		end
		assert(trigger ~= nil, ("Input %s: an entry names one of %s"):format(name, table.concat(TRIGGERS, ", ")))
		local on = trigger :: string

		for key in given do
			if key ~= on then
				local allowed = OPTIONS[key]
				assert(allowed ~= nil, ("Input %s: %s is not an option here; %s are"):format(name, tostring(key), listed(OPTIONS)))
				assert(allowed[on], ("Input %s: %s is an option on %s, not on %s"):format(name, tostring(key), listed(allowed), on))
			end
		end

		local entry: Entry = {
			name = name,
			trigger = on,
			of = {},
			buffer = if given.buffer ~= nil then seconds(name, "buffer", given.buffer) else nil,
			hold = if given.hold ~= nil then seconds(name, "hold", given.hold) else nil,
			within = if given.within ~= nil then seconds(name, "within", given.within) else WITHIN,
			holds = {},
		}

		if on == "keys" or on == "axis" then
			entry.of = hardware(name, on, given[on])
			table.insert(declared, {
				name = name,
				shape = on,
				keys = entry.of,
				press = given.press,
				release = given.release,
				scale = given.scale,
			})
		elseif on == "move" then
			local move = given.move
			assert(type(move) == "table", ("Input %s: move names the keys of each direction and the stick"):format(name))
			local any = false
			for key, value in move do
				assert(MOVE[key], ("Input %s: move takes %s, not %s"):format(name, listed(MOVE), tostring(key)))
				assert(typeof(value) == "EnumItem", ("Input %s: move.%s is a KeyCode, not a %s"):format(name, tostring(key), typeof(value)))
				any = true
			end
			assert(any, ("Input %s: move names at least one direction or the stick"):format(name))
			table.insert(declared, { name = name, shape = "move", move = move, scale = given.scale })
		else
			local of = given[on]
			assert(type(of) == "table" and #of >= 2, ("Input %s: %s names two or more other actions, in a list"):format(name, on))
			entry.of = of
		end

		entries[name] = entry
	end

	-- a chord and a sequence are made of entries the engine drives, so every member has to be one, and the
	-- frame order below holds: engine edges first, then the chords those edges completed
	for _, name in names do
		local entry = entries[name]
		if entry.trigger ~= "chord" and entry.trigger ~= "sequence" then
			continue
		end
		for _, member in entry.of do
			assert(type(member) == "string", ("Input %s: %s names other actions by name, not a %s"):format(name, entry.trigger, typeof(member)))
			local found = entries[member]
			assert(found ~= nil, ("Input %s: %s names %s, which is not an action here"):format(name, entry.trigger, member))
			assert(
				found.trigger ~= "chord" and found.trigger ~= "sequence",
				("Input %s: %s names %s, which is itself a %s; a chord and a sequence are made of what the engine drives"):format(name, entry.trigger, member, found.trigger)
			)
			entry.holds[member] = true
		end
	end

	return names, entries, declared
end

-- ---------------------------------------------------------------- the controller

-- the factory. `chosen` is the engine edge and a game never passes it: live it is the Input Action System,
-- and a spec hands a `Beef.Stock.feed()` instead, with a clock it moves and keys it presses.
return function(action: any, bindings: { [string]: any }, chosen: Driver?): any
	assert(type(action) == "table" and type(action.push) == "function", "Input: the first thing handed to it is the Action event type")
	local driver: Driver = chosen or Engine
	local names, entries, declared = read(bindings)

	local chords: { Entry } = {}
	local sequences: { Entry } = {}
	for _, name in names do
		local entry = entries[name]
		if entry.trigger == "chord" then
			table.insert(chords, entry)
		elseif entry.trigger == "sequence" then
			table.insert(sequences, entry)
		end
	end

	-- this controller's own timing, and nothing else. A name is in `holdAt` only while a press that
	-- declared a hold is down and has not reached it, and in `bufferUntil` only while a press that declared
	-- a buffer is still worth remembering.
	local holdAt: { [string]: number } = {}
	local holdOn: { [string]: number } = {}
	local bufferUntil: { [string]: number } = {}
	local bufferOn: { [string]: number } = {}
	local chordOn: { boolean } = table.create(#chords, false)
	local seqAt: { number } = table.create(#sequences, 0)
	local seqBy: { number } = table.create(#sequences, 0)

	local function arm(name: string, entry: Entry, now: number, device: number)
		if entry.hold then
			holdAt[name] = now + entry.hold
			holdOn[name] = device
		end
		if entry.buffer then
			bufferUntil[name] = now + entry.buffer
			bufferOn[name] = device
		end
	end

	-- every sequence this name is a step of moves, one step at a time. A step out of order drops the
	-- sequence back to the start, or to one if the name is the first step; an action the sequence never
	-- mentions goes past it untouched.
	local function step(name: string, now: number, device: number)
		for s, sequence in sequences do
			if not sequence.holds[name] then
				continue
			end
			local of = sequence.of
			local at = seqAt[s]
			if of[at + 1] == name then
				at += 1
				if at == #of then
					action.push(sequence.name, Phases.Fired, 1, 1, 0, device)
					at = 0
				end
				seqAt[s] = at
				seqBy[s] = now + sequence.within
			elseif of[1] == name then
				seqAt[s] = 1
				seqBy[s] = now + sequence.within
			else
				seqAt[s] = 0
			end
		end
	end

	return {
		name = "Input",
		writes = { action },

		boot = function()
			driver.bind(declared)
		end,

		-- a source, so it runs once before the passes: every controller reading Action sees this frame's
		-- input on the first pass
		pre = function()
			local now = driver.now()

			-- what the clock brought. Timers run ahead of the frame's edges, so a press armed below is not
			-- also repeated in the same frame it was made.
			for name, at in holdAt do
				if now >= at then
					holdAt[name] = nil
					action.push(name, Phases.Held, 1, 1, 0, holdOn[name])
				end
			end
			for name, until_ in bufferUntil do
				if now < until_ then
					action.push(name, Phases.Buffered, 1, 1, 0, bufferOn[name])
				else
					bufferUntil[name] = nil
				end
			end
			for s, sequence in sequences do
				if seqAt[s] > 0 and now > seqBy[s] then
					seqAt[s] = 0
				end
			end

			-- what the engine did
			local queue = driver.drain()
			for i = 1, #queue do
				local raw = queue[i]
				local entry = entries[raw.action]
				if entry == nil then
					continue
				end
				if raw.edge == PRESSED then
					action.push(raw.action, Phases.Began, raw.value, raw.x, raw.y, raw.device)
					arm(raw.action, entry, now, raw.device)
					step(raw.action, now, raw.device)
				elseif raw.edge == RELEASED then
					action.push(raw.action, Phases.Ended, raw.value, raw.x, raw.y, raw.device)
					holdAt[raw.action] = nil
				else
					action.push(raw.action, Phases.Changed, raw.value, raw.x, raw.y, raw.device)
				end
			end

			-- and what those edges add up to: a chord is on while every member is, and each edge of that is
			-- one push. A buffered press keeps its window across the release, which is the whole point of
			-- one, so only a hold is dropped when the action ends.
			for c, chord in chords do
				local all = true
				for _, member in chord.of do
					if not driver.active(member) then
						all = false
						break
					end
				end
				if all ~= chordOn[c] then
					chordOn[c] = all
					local device = driver.device()
					if all then
						action.push(chord.name, Phases.Began, 1, 1, 0, device)
						arm(chord.name, chord, now, device)
					else
						action.push(chord.name, Phases.Ended, 0, 0, 0, device)
						holdAt[chord.name] = nil
					end
				end
			end
		end,
	}
end
