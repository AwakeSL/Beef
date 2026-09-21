--!strict
--!optimize 2

-- Durable state, per key, a store behind it. A record is declared once with a shape, a version
-- and its migrations; a key is loaded under a session lock, read and written as a plain table,
-- saved on a timer, and released when it is done with. Nothing in here touches Roblox: the
-- store, the lock, the clock and the frame all arrive through the driver, so the whole of it
-- runs headless.

local Events = require(script.Parent.Events)
local Wire = require(script.Parent.Wire)
local Live = require(script.Live)
local Memory = require(script.Memory)

export type Options = {
	version: number,
	shape: { [string]: any },
	migrate: { [number]: (record: any) -> ...any }?,
	save: number?, -- seconds between timed saves
	lock: number?, -- seconds between lock refreshes
}

export type Record = {
	name: string,
	version: number,
	load: (key: string) -> any?,
	release: (key: string) -> (),
	of: (key: string) -> any?,
	held: (key: string) -> boolean,
	save: (key: string) -> boolean,
	keys: () -> { string },
	loaded: Events.Buffer,
	saved: Events.Buffer,
	lost: Events.Buffer,
	failed: Events.Buffer,
}

-- everything that leaves this process. `lock`, `refresh` and `unlock` are the session lock,
-- `get`, `update` and `release` the store, `now` and `wait` the clock, and `start` is where a
-- driver that has a frame hangs the timer and the close handler on it
export type Driver = {
	server: string,
	now: () -> number,
	wait: (seconds: number) -> (),
	get: (store: string, key: string) -> any,
	update: (store: string, key: string, transform: (old: any) -> any?) -> any,
	release: (store: string, key: string) -> (),
	lock: (store: string, key: string, server: string, ttl: number) -> (boolean, string?),
	refresh: (store: string, key: string, server: string, ttl: number) -> boolean,
	unlock: (store: string, key: string, server: string) -> (),
	start: ((step: () -> (), flush: () -> ()) -> ())?,
}

export type World = Memory.World

type Holding = {
	value: any,
	saveAt: number,
	refreshAt: number,
	lost: boolean,
}

local SAVE_EVERY = 30
local LOCK_EVERY = 60
local GRACE = 30 -- the lock outlives its refresh by this much, so a live server never loses one
local WAIT = 1 -- seconds between tries for a key another server holds
local TAG = "$" -- marks a stored table as a packed datatype, so no record may use it as a key

-- ---------------------------------------------------------------- shape

local plain: (path: string, t: { [any]: any }, seen: { [any]: boolean }) -> string?

-- what a store will take: numbers, strings, booleans, tables of those, and the datatypes Wire
-- knows how to flatten. Everything else is refused here rather than at the far end of a request
local function storable(path: string, value: any, seen: { [any]: boolean }): string?
	local kind = typeof(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return path .. " is not a finite number"
		end
		return nil
	elseif kind == "string" or kind == "boolean" then
		return nil
	elseif kind == "table" then
		if seen[value] then
			return path .. " is a table that holds itself"
		end
		seen[value] = true
		local why = plain(path, value, seen)
		seen[value] = nil
		return why
	elseif Wire.nameOf(value) ~= nil then
		return nil
	end
	return ("%s is a %s, which does not store"):format(path, kind)
end

-- a stored table is a list or it is keyed by strings; a store takes neither a mix of the two nor
-- a list with holes in it
plain = function(path: string, t: { [any]: any }, seen: { [any]: boolean }): string?
	local count = 0
	local strings = 0
	for key in t do
		count += 1
		if type(key) == "string" then
			strings += 1
			if key == TAG then
				return ("%s has a key named %s, which Beef keeps for packed values"):format(path, TAG)
			end
		elseif type(key) ~= "number" then
			return ("%s has a %s key, and a key is a string or a number"):format(path, typeof(key))
		end
	end
	if strings > 0 and strings < count then
		return path .. " mixes string keys with number keys"
	end
	if strings == 0 and count > 0 and #t ~= count then
		return path .. " is a list with holes in it"
	end
	for key, value in t do
		local why = storable(("%s.%s"):format(path, tostring(key)), value, seen)
		if why then
			return why
		end
	end
	return nil
end

-- the record against the shape it was declared with: every field the shape names, nothing it
-- does not, and an empty table in the shape is an open one, anything storable goes in it
local function matches(path: string, want: any, got: any, seen: { [any]: boolean }): string?
	if got == nil then
		return path .. " is missing"
	end
	local kind = typeof(want)
	if kind == "table" then
		if type(got) ~= "table" then
			return ("%s is a %s, the shape wants a table"):format(path, typeof(got))
		end
		if next(want) == nil then
			return storable(path, got, seen)
		end
		for key, inner in want do
			local why = matches(("%s.%s"):format(path, tostring(key)), inner, got[key], seen)
			if why then
				return why
			end
		end
		for key in got do
			if want[key] == nil then
				return ("%s.%s is not in the shape"):format(path, tostring(key))
			end
		end
		return nil
	end
	local named = Wire.nameOf(want)
	if named ~= nil then
		if Wire.nameOf(got) ~= named then
			return ("%s is a %s, the shape wants a %s"):format(path, typeof(got), typeof(want))
		end
		return nil
	end
	if typeof(got) ~= kind then
		return ("%s is a %s, the shape wants a %s"):format(path, typeof(got), kind)
	end
	return storable(path, got, seen)
end

-- ---------------------------------------------------------------- storage form

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, inner in value do
		out[key] = copy(inner)
	end
	return out
end

-- a datatype goes down as { ["$"] = "vector3", n = { x, y, z } }: keyed by strings throughout,
-- since a store takes no table that mixes a list with a name
local function packed(value: any): any
	if type(value) == "table" then
		local out = {}
		for key, inner in value do
			out[key] = packed(inner)
		end
		return out
	end
	local named = Wire.nameOf(value)
	if named ~= nil then
		return { [TAG] = named, n = Wire.flatten[named](value) }
	end
	return value
end

local function rebuilt(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local named = value[TAG]
	if type(named) == "string" and Wire.rebuild[named] ~= nil and type(value.n) == "table" then
		return Wire.rebuild[named](value.n)
	end
	local out = {}
	for key, inner in value do
		out[key] = rebuilt(inner)
	end
	return out
end

-- ---------------------------------------------------------------- the module

type Entry = {
	step: (now: number) -> (),
	flush: () -> (),
	busy: () -> boolean,
}

local all: { Entry } = {}

local Records = {}

local driver: Driver? = nil
local started = false

local function pump()
	Records.step()
end

local function drain()
	Records.flush()
end

-- the live driver is what a game gets without asking; a test names its own before the first load
local function current(): Driver
	local self = driver
	if self == nil then
		self = Live.new()
		driver = self
	end
	if not started then
		started = true
		local start = (self :: Driver).start
		if start then
			start(pump, drain)
		end
	end
	return self :: Driver
end

function Records.new(name: string, options: Options): Record
	assert(type(name) == "string" and name ~= "", "Records.new needs a name")
	assert(type(options) == "table", ("%s: Records.new needs its options"):format(name))
	local version = options.version
	assert(
		type(version) == "number" and version >= 1 and version % 1 == 0,
		("%s: version is a whole number from 1 up"):format(name)
	)
	local shape = options.shape
	assert(type(shape) == "table", ("%s: a record needs a shape"):format(name))
	local bad = storable(name, shape, {})
	assert(bad == nil, ("%s: the shape does not store: %s"):format(name, tostring(bad)))
	local migrate: { [number]: (record: any) -> ...any } = options.migrate or {}
	for at, step in migrate do
		assert(type(at) == "number" and at % 1 == 0, ("%s: a migration is keyed by its version"):format(name))
		assert(type(step) == "function", ("%s: migrate[%d] is not a function"):format(name, at))
		assert(at >= 2 and at <= version, ("%s: migrate[%d] is outside 2 to %d"):format(name, at, version))
	end
	local every = options.save or SAVE_EVERY
	local lockEvery = options.lock or LOCK_EVERY
	local ttl = lockEvery + GRACE

	local holdings: { [string]: Holding } = {}

	local self = {
		name = name,
		version = version,
		loaded = Events.new(name .. ".loaded", "key:string"),
		saved = Events.new(name .. ".saved", "key:string"),
		lost = Events.new(name .. ".lost", "key:string"),
		failed = Events.new(name .. ".failed", "key:string", "why:string"),
	} :: any

	local function fail(key: string, why: string)
		self.failed.push(key, why)
	end

	-- the lock is gone, so another server may already be writing this key: the record stays
	-- readable for whatever is mid-frame, nothing it says ever reaches the store again
	local function lose(key: string, holding: Holding)
		if holding.lost then
			return
		end
		holding.lost = true
		self.lost.push(key)
		warn(("[Beef] %s %s: the session lock is gone, this copy is read-only now"):format(name, key))
	end

	local function write(key: string, holding: Holding): boolean
		if holding.lost then
			return false
		end
		local d = current()
		local why = matches(name, shape, holding.value, {})
		if why then
			fail(key, why)
			warn(("[Beef] %s %s: not saved, %s"):format(name, key, why))
			return false
		end
		if not d.refresh(name, key, d.server, ttl) then
			lose(key, holding)
			return false
		end
		holding.refreshAt = d.now() + lockEvery
		local body = { version = version, at = os.time(), data = packed(holding.value) }
		local newer = false
		local ok, err = pcall(d.update, name, key, function(old: any): any?
			if type(old) == "table" and type(old.version) == "number" and old.version > version then
				newer = true
				return nil
			end
			return body
		end)
		if not ok then
			fail(key, tostring(err))
			return false
		end
		if newer then
			fail(key, ("the stored record is newer than version %d, so it was left alone"):format(version))
			return false
		end
		holding.saveAt = d.now() + every
		self.saved.push(key)
		return true
	end

	-- a key another live server holds is waited for: that server either lets go or stops
	-- refreshing, and either way the lock is free within its own lifetime
	local function take(key: string, d: Driver): (boolean, string?)
		local waited = 0
		while true do
			local took, holder = d.lock(name, key, d.server, ttl)
			if took then
				return true
			end
			if waited >= ttl + WAIT then
				return false, ("the session lock is held by %s"):format(tostring(holder))
			end
			d.wait(WAIT)
			waited += WAIT
		end
	end

	local function decode(stored: any): (any?, string?)
		if stored == nil then
			return copy(shape), nil
		end
		if type(stored) ~= "table" or type(stored.version) ~= "number" then
			return nil, "what is stored under this key is not a Beef record"
		end
		if stored.version > version then
			return nil, ("the stored record is version %d and this server knows %d"):format(stored.version, version)
		end
		local value = rebuilt(stored.data)
		if type(value) ~= "table" then
			return nil, "the stored record is not a table"
		end
		-- a version with no migration changed nothing; if it did, the shape below says so
		for at = stored.version + 1, version do
			local step = migrate[at]
			if step then
				local ok, err = pcall(step, value)
				if not ok then
					return nil, ("migrate[%d] threw: %s"):format(at, tostring(err))
				end
			end
		end
		local why = matches(name, shape, value, {})
		if why then
			return nil, ("the loaded record does not match the shape: %s"):format(why)
		end
		return value, nil
	end

	self.load = function(key: string): any?
		assert(type(key) == "string", ("%s: a key is a string"):format(name))
		local holding = holdings[key]
		if holding then
			return holding.value
		end
		local d = current()
		local took, why = take(key, d)
		if not took then
			fail(key, why :: string)
			return nil
		end
		local ok, stored = pcall(d.get, name, key)
		if not ok then
			pcall(d.unlock, name, key, d.server)
			fail(key, tostring(stored))
			return nil
		end
		local value, bad = decode(stored)
		if value == nil then
			pcall(d.unlock, name, key, d.server)
			fail(key, bad :: string)
			return nil
		end
		local now = d.now()
		holdings[key] = { value = value, saveAt = now + every, refreshAt = now + lockEvery, lost = false }
		self.loaded.push(key)
		return value
	end

	self.release = function(key: string)
		local holding = holdings[key]
		if not holding then
			return
		end
		local d = current()
		write(key, holding)
		holdings[key] = nil
		pcall(d.release, name, key)
		pcall(d.unlock, name, key, d.server)
	end

	self.of = function(key: string): any?
		local holding = holdings[key]
		return if holding then holding.value else nil
	end

	self.held = function(key: string): boolean
		local holding = holdings[key]
		return holding ~= nil and not holding.lost
	end

	self.save = function(key: string): boolean
		local holding = holdings[key]
		if not holding then
			return false
		end
		return write(key, holding)
	end

	self.keys = function(): { string }
		local out = {}
		for key in holdings do
			table.insert(out, key)
		end
		table.sort(out)
		return out
	end

	table.insert(all, {
		step = function(now: number)
			for key, holding in holdings do
				if holding.lost then
					continue
				end
				if now >= holding.refreshAt then
					local d = current()
					if not d.refresh(name, key, d.server, ttl) then
						lose(key, holding)
						continue
					end
					holding.refreshAt = now + lockEvery
				end
				if now >= holding.saveAt then
					write(key, holding)
				end
			end
		end,
		flush = function()
			for key, holding in holdings do
				write(key, holding)
			end
		end,
		busy = function(): boolean
			return next(holdings) ~= nil
		end,
	})

	return self :: Record
end

-- the timed half: lock refreshes first, then the saves that are due. The live driver calls this
-- off its own frame; a headless test moves its clock and calls it when it wants the timer to go
function Records.step(now: number?)
	local d = current()
	local at = now or d.now()
	for _, entry in all do
		entry.step(at)
	end
end

function Records.flush()
	for _, entry in all do
		entry.flush()
	end
end

function Records.driver(swap: Driver)
	assert(type(swap) == "table", "Records.driver takes a driver")
	for _, entry in all do
		assert(not entry.busy(), "Records.driver: a record is still held, release it before the driver moves")
	end
	driver = swap
	started = false
end

-- the one convenience: a player's id is a key, and their session is the hold
function Records.players(record: Record)
	local Players = game:GetService("Players")
	local function joined(player: any)
		record.load(tostring(player.UserId))
	end
	Players.PlayerAdded:Connect(joined)
	Players.PlayerRemoving:Connect(function(player: any)
		record.release(tostring(player.UserId))
	end)
end

-- the two drivers Beef ships: tables in memory for a test, the services for a live server
Records.world = Memory.world
Records.memory = Memory.new :: (world: World?, server: string?) -> Driver
Records.live = Live.new :: () -> Driver

return Records
