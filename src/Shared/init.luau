--!strict
--!optimize 2

-- Beef.Shared: live cross-server state over MemoryStore, gone at its TTL. What has to outlive a
-- session goes in a record; this is for what does not, a leaderboard, a matchmaking queue, a
-- table every server reads and writes at once.
--
-- Three declared shapes matching the service, and the same two habits on all three. First, no
-- call made from a controller ever touches the service: it goes on a queue that a pump drains on
-- its own thread, so a loop never waits and never yields out of its phase. Second, what changed
-- arrives as an Event, because MemoryStore has no push of its own: each structure polls on its
-- interval, compares what came back against what it last saw, and pushes the difference over the
-- declared columns. A change this server made is announced when it lands, so a controller hears
-- its own writes and another server's the same way.
--
-- What the counting below rests on, read off Roblox's memory store documentation in September
-- 2026 (create.roblox.com/docs/cloud-services/memory-stores):
--   quota       1000 + 120 request units a minute for every player, counted over the whole game
--               rather than per server
--   sorted map  GetAsync, SetAsync and RemoveAsync one unit; UpdateAsync at least two;
--               GetRangeAsync one unit an item, one when it hands back none
--   queue       AddAsync and RemoveAsync one unit; ReadAsync one unit an item, and one more for
--               every two seconds it spends waiting, which is why a read here never waits
--   hash map    GetAsync, SetAsync and RemoveAsync one unit; UpdateAsync at least two;
--               ListItemsAsync [partitions scanned] + [items returned]
--   limits      a key is at most 128 characters, a value at most 32 KB, a TTL at most 3,888,000
--               seconds, and a structure at most a million items or 100 MB
-- What a structure costs while it sits there is its `count` over its `poll`: twenty items every
-- five seconds is two hundred and forty units a minute, and those are the defaults. A structure
-- polled hard enough to outrun the quota holds its own calls up, which stats() shows.
--
-- Two of those the game cannot see from in here. A hash map's partition count is not exposed, so
-- a listing is counted as its items plus one and the real cost is a little above what stats()
-- says. And the quota is the game's, not the server's, so every server counting the base 1000
-- for itself counts more than the game has; a game with many servers takes its own share with
-- Shared.budget.

local Events = require(script.Parent.Events)
local Wire = require(script.Parent.Wire)
local Live = require(script.Live)
local Tables = require(script.Tables)

export type Item = { key: string, value: any }

export type SortedOptions = {
	value: string,
	ttl: number,
	poll: number?,
	count: number?,
	order: string?,
}

export type QueueOptions = {
	fields: { string },
	ttl: number,
	poll: number?,
	count: number?,
	invisibility: number?,
	priority: number?,
}

export type MapOptions = {
	fields: { string },
	ttl: number,
	poll: number?,
	count: number?,
}

export type Sorted = {
	name: string,
	changed: Events.Buffer,
	removed: Events.Buffer,
	set: (key: string, value: any) -> (),
	get: (key: string) -> any,
	remove: (key: string) -> (),
	range: (from: any?, to: any?, count: number?) -> { Item },
	refresh: () -> (),
}

export type Queue = {
	name: string,
	received: Events.Buffer,
	add: (...any) -> (),
	read: (count: number?) -> (),
	remove: (id: string) -> (),
	refresh: () -> (),
}

export type Map = {
	name: string,
	changed: Events.Buffer,
	removed: Events.Buffer,
	set: (key: string, ...any) -> (),
	get: (key: string) -> ...any,
	update: (key: string, transform: (...any) -> ...any) -> (),
	remove: (key: string) -> (),
	refresh: () -> (),
}

export type Stats = {
	units: number,      -- request units spent in the minute behind
	budget: number,     -- what the quota allows right now
	held: number,       -- calls waiting for the budget to make room
	calls: number,      -- calls made since the driver went in, a retry counting again
	spent: number,      -- request units spent over all of that
	throttled: number,  -- calls the service threw at, each one tried again
	failed: number,     -- calls given up on, and values found in a shape this structure did not write
	polls: number,      -- polls that came back
}

export type Budget = {
	base: number?,
	per: number?,
	drain: number?,
}

type Call = {
	what: string,
	units: number,
	run: () -> number?,
	tries: number,
}

type Structure = {
	name: string,
	poll: number,
	tick: () -> (),
	attach: (driver: any, fresh: boolean) -> (),
}

local TTL_MAX = 3888000
local KEY_MAX = 128
local WINDOW = 60
local TRIES = 3
local BATCH = 64

-- Wire says what a column is. A memory store holds what its own serialiser holds, so the Roblox
-- datatypes Wire knows are out and everything else crosses as it is.
local NOT_STORED: { [string]: boolean } = { vector3 = true, color3 = true, kind = true }

local quota = { base = 1000, per = 120, drain = 0.1 }

local driver: any = nil
local cancels: { () -> () } = {}
local structures: { Structure } = {}
local declared: { [string]: boolean } = {}

-- calls wait here in the order they were made and leave in that order; budget holds the head of
-- the queue, it never picks something cheaper out of the middle
local work: { Call } = {}
local workHead, workTail = 1, 0

-- request units spent, oldest first, and what they cost, so the minute behind can be released
local spentAt: { number } = {}
local spentUnits: { number } = {}
local spentHead, spentTail = 1, 0
local used = 0

local counts = { calls = 0, spent = 0, throttled = 0, failed = 0, polls = 0 }

local Shared = {}

local function enqueue(what: string, units: number, run: () -> number?)
	workTail += 1
	work[workTail] = { what = what, units = units, run = run, tries = 0 }
end

local function spend(now: number, units: number)
	spentTail += 1
	spentAt[spentTail] = now
	spentUnits[spentTail] = units
	used += units
	counts.spent += units
end

-- a call that cost more or less than it reserved corrects the entry it just made, so the minute
-- holds what was actually spent
local function correct(units: number)
	if units == 0 or spentTail < spentHead then
		return
	end
	spentUnits[spentTail] += units
	used += units
	counts.spent += units
end

local function release(now: number)
	local edge = now - WINDOW
	while spentHead <= spentTail and spentAt[spentHead] <= edge do
		used -= spentUnits[spentHead]
		spentAt[spentHead] = nil
		spentUnits[spentHead] = nil
		spentHead += 1
	end
end

local function allowance(): number
	return quota.base + quota.per * driver.players()
end

-- the pump: take calls off the head while the minute has room for them. a call the service threw
-- at goes back on the head and the tick ends, so nothing overtakes it and nothing is dropped
-- until it has had its tries.
local function drain()
	if driver == nil then
		return
	end
	local now = driver.now()
	release(now)
	local cap = allowance()
	local ran = 0
	while workHead <= workTail and ran < BATCH do
		local call = work[workHead]
		if used + call.units > cap then
			break
		end
		work[workHead] = nil
		workHead += 1
		ran += 1
		counts.calls += 1
		spend(now, call.units)
		local ok, got = pcall(call.run)
		if ok then
			if type(got) == "number" then
				correct(got - call.units)
			end
		else
			counts.throttled += 1
			call.tries += 1
			if call.tries < TRIES then
				workHead -= 1
				work[workHead] = call
				break
			end
			counts.failed += 1
			warn(("Beef.Shared: %s gave up after %d tries: %s"):format(call.what, call.tries, tostring(got)))
		end
	end
end

-- (re)starts the pump and every structure's poll on the driver that is in. `fresh` empties the
-- mirrors with it, which a new driver wants and a change of budget does not
local function bind(fresh: boolean)
	for _, cancel in cancels do
		cancel()
	end
	table.clear(cancels)
	table.insert(cancels, driver.every(quota.drain, drain))
	for _, structure in structures do
		structure.attach(driver, fresh)
		table.insert(cancels, driver.every(structure.poll, structure.tick))
	end
end

local function ensure()
	if driver ~= nil then
		return
	end
	assert(
		Live.available(),
		"Beef.Shared: no driver. On Roblox one is built over MemoryStoreService; headless, put Beef.Shared.tables() in with Beef.Shared.driver before declaring a structure."
	)
	driver = Live.new()
	bind(true)
end

local function join(structure: Structure)
	assert(not declared[structure.name], ("Beef.Shared: %s is declared twice"):format(structure.name))
	declared[structure.name] = true
	table.insert(structures, structure)
	if driver == nil then
		ensure()
	else
		structure.attach(driver, true)
		table.insert(cancels, driver.every(structure.poll, structure.tick))
	end
end

-- ---------------------------------------------------------------- declarations

local function checked(what: string, kind: string): string
	assert(Wire.known(kind), ("%s: %s is not a wire type"):format(what, kind))
	assert(not NOT_STORED[kind], ("%s: a %s cannot go in a memory store"):format(what, kind))
	return kind
end

local function columns(what: string, fields: { string }): number
	assert(type(fields) == "table" and #fields > 0, ("%s: needs at least one field"):format(what))
	for _, field in fields do
		local column, kind = Wire.split(field)
		assert(kind ~= nil, ("%s: field %s needs a wire type, as in %s:u32"):format(what, column, column))
		checked(what, kind :: string)
	end
	return #fields
end

local function ttlOf(what: string, ttl: number): number
	assert(type(ttl) == "number" and ttl > 0, ("%s: needs a ttl in seconds"):format(what))
	assert(ttl <= TTL_MAX, ("%s: a ttl is at most %d seconds"):format(what, TTL_MAX))
	return ttl
end

-- the values behind a set or an add, checked against the declared width: a column is typed, so a
-- missing one is a mistake rather than a hole to store
local function fieldsOf(what: string, fields: { string }, ...: any): { any }
	local width = #fields
	local n = select("#", ...)
	assert(n == width, ("%s: takes %s, got %d"):format(what, table.concat(fields, ", "), n))
	local list = table.pack(...)
	list.n = nil
	for i = 1, width do
		assert(list[i] ~= nil, ("%s: %s is nil"):format(what, fields[i]))
	end
	return list
end

local function keyed(what: string, key: string)
	assert(type(key) == "string" and #key > 0, ("%s: a key is a string"):format(what))
	assert(#key <= KEY_MAX, ("%s: a key is at most %d characters"):format(what, KEY_MAX))
end

-- one key to one value, ordered by that value: a leaderboard, a rating ladder, anything read as a
-- top few. the poll pulls the first `count` in `order` and the mirror it fills is what get and
-- range read, so neither of those spends a unit.
function Shared.sorted(name: string, options: SortedOptions): Sorted
	local what = "Shared.sorted " .. name
	local kind = checked(what, options.value)
	local ttl = ttlOf(what, options.ttl)
	local every = options.poll or 5
	local count = options.count or 20
	local descending = (options.order or "descending") == "descending"

	local changed = Events.new(name .. ".changed", "key:string", "value:" .. kind)
	local removed = Events.new(name .. ".removed", "key:string")

	local store: any = nil
	local mirror: { [string]: any } = {}
	local window: { Item } = {}
	local polling = false

	local function announce(key: string, value: any)
		mirror[key] = value
		changed.push(key, value)
	end

	local function forget(key: string)
		if mirror[key] ~= nil then
			mirror[key] = nil
			removed.push(key)
		end
	end

	local function took(got: { Item }): number
		local seen: { [string]: boolean } = {}
		for _, item in got do
			seen[item.key] = true
			if mirror[item.key] ~= item.value then
				announce(item.key, item.value)
			end
		end
		-- gone from the window is gone: removed by another server, expired at its TTL, or pushed
		-- out of the first `count` by something better
		for key in mirror do
			if not seen[key] then
				mirror[key] = nil
				removed.push(key)
			end
		end
		window = got
		counts.polls += 1
		return math.max(#got, 1)
	end

	local function poll()
		if store == nil or polling then
			return
		end
		polling = true
		enqueue(name .. ".poll", count, function()
			polling = false
			return took(store.range(descending, count))
		end)
	end

	local self: Sorted = {
		name = name,
		changed = changed,
		removed = removed,

		set = function(key: string, value: any)
			keyed(what, key)
			enqueue(name .. ".set", 1, function()
				-- the value is the sort key: what the structure is ordered by is what it holds
				store.set(key, value, ttl, value)
				if mirror[key] ~= value then
					announce(key, value)
				end
				return 1
			end)
		end,

		get = function(key: string): any
			return mirror[key]
		end,

		remove = function(key: string)
			keyed(what, key)
			enqueue(name .. ".remove", 1, function()
				store.remove(key)
				forget(key)
				return 1
			end)
		end,

		-- the last poll's window, held to the values between `from` and `to`, in the order the
		-- service handed it back. a set made here is in `get` as soon as it lands and in here at
		-- the next poll, which is the one that knows where it belongs in the order
		range = function(from: any?, to: any?, limit: number?): { Item }
			local out: { Item } = {}
			local cap = limit or count
			for _, item in window do
				if (from == nil or item.value >= from) and (to == nil or item.value <= to) then
					table.insert(out, { key = item.key, value = item.value })
					if #out >= cap then
						break
					end
				end
			end
			return out
		end,

		refresh = poll,
	}

	join({
		name = name,
		poll = every,
		tick = poll,
		attach = function(d: any, fresh: boolean)
			store = d.sorted(name)
			if fresh then
				table.clear(mirror)
				window = {}
			end
			polling = false
		end,
	})
	return self
end

-- a line every server adds to and every server takes from. a read hides what it took for the
-- invisibility window and hands back the id that removes it, so a push that nobody removes comes
-- round again; that is the service's contract and this keeps it.
function Shared.queue(name: string, options: QueueOptions): Queue
	local what = "Shared.queue " .. name
	local width = columns(what, options.fields)
	local ttl = ttlOf(what, options.ttl)
	local every = options.poll or 5
	local count = options.count or 10
	local invisibility = options.invisibility or 30
	local priority = options.priority or 0

	local declaration = { name .. ".received", "id:string" }
	for _, field in options.fields do
		table.insert(declaration, field)
	end
	local received = Events.new(table.unpack(declaration))

	local store: any = nil
	local polling = false

	local function took(values: { any }, id: string?): number
		if id ~= nil then
			for _, packed in values do
				if type(packed) == "table" then
					received.push(id, table.unpack(packed :: { any }, 1, width))
				else
					-- something another server wrote in another shape; leave it in the queue and
					-- let stats say it was seen
					counts.failed += 1
				end
			end
		end
		counts.polls += 1
		return math.max(#values, 1)
	end

	local function pull(n: number, polled: boolean)
		enqueue(name .. ".read", n, function()
			if polled then
				polling = false
			end
			return took(store.read(n))
		end)
	end

	local function poll()
		if store == nil or polling then
			return
		end
		polling = true
		pull(count, true)
	end

	local self: Queue = {
		name = name,
		received = received,

		add = function(...: any)
			local packed = fieldsOf(name .. ".add", options.fields, ...)
			enqueue(name .. ".add", 1, function()
				store.add(packed, ttl, priority)
				return 1
			end)
		end,

		read = function(n: number?)
			pull(n or count, false)
		end,

		-- the id from a read covers everything that read took, so removing it accepts the batch
		remove = function(id: string)
			enqueue(name .. ".remove", 1, function()
				store.remove(id)
				return 1
			end)
		end,

		refresh = poll,
	}

	join({
		name = name,
		poll = every,
		tick = poll,
		attach = function(d: any, _fresh: boolean)
			store = d.queue(name, invisibility)
			polling = false
		end,
	})
	return self
end

-- one key to a handful of typed fields, no order: an auction, a claim table, whatever every
-- server has to agree on right now.
function Shared.map(name: string, options: MapOptions): Map
	local what = "Shared.map " .. name
	local width = columns(what, options.fields)
	local ttl = ttlOf(what, options.ttl)
	local every = options.poll or 5
	local count = options.count or 20

	local declaration = { name .. ".changed", "key:string" }
	for _, field in options.fields do
		table.insert(declaration, field)
	end
	local changed = Events.new(table.unpack(declaration))
	local removed = Events.new(name .. ".removed", "key:string")

	local store: any = nil
	local mirror: { [string]: { any } } = {}
	local polling = false

	local function same(a: { any }?, b: { any }?): boolean
		if a == nil or b == nil then
			return a == b
		end
		for i = 1, width do
			if a[i] ~= b[i] then
				return false
			end
		end
		return true
	end

	local function announce(key: string, packed: { any })
		mirror[key] = packed
		changed.push(key, table.unpack(packed, 1, width))
	end

	local function forget(key: string)
		if mirror[key] ~= nil then
			mirror[key] = nil
			removed.push(key)
		end
	end

	local function took(got: { Item }): number
		local seen: { [string]: boolean } = {}
		for _, item in got do
			if type(item.value) == "table" then
				seen[item.key] = true
				if not same(mirror[item.key], item.value) then
					announce(item.key, item.value)
				end
			end
		end
		for key in mirror do
			if not seen[key] then
				mirror[key] = nil
				removed.push(key)
			end
		end
		counts.polls += 1
		-- a listing costs the partitions it walked as well as the items it found, and a game
		-- cannot see how many partitions there are
		return #got + 1
	end

	local function poll()
		if store == nil or polling then
			return
		end
		polling = true
		enqueue(name .. ".poll", count + 1, function()
			polling = false
			return took(store.list(count))
		end)
	end

	local self: Map = {
		name = name,
		changed = changed,
		removed = removed,

		set = function(key: string, ...: any)
			keyed(what, key)
			local packed = fieldsOf(name .. ".set", options.fields, ...)
			enqueue(name .. ".set", 1, function()
				store.set(key, packed, ttl)
				if not same(mirror[key], packed) then
					announce(key, packed)
				end
				return 1
			end)
		end,

		get = function(key: string): ...any
			local packed = mirror[key]
			if packed == nil then
				return nil
			end
			return table.unpack(packed, 1, width)
		end,

		-- the transform runs on the server that holds the update, over the fields as they are
		-- there; returning nothing leaves the key alone
		update = function(key: string, transform: (...any) -> ...any)
			keyed(what, key)
			enqueue(name .. ".update", 2, function()
				local made = store.update(key, function(old: any): any
					local was = if type(old) == "table" then old else nil
					local result = table.pack(transform(table.unpack(was or {}, 1, width)))
					if result.n == 0 then
						return nil
					end
					assert(
						result.n == width,
						("%s.update: answers with %s, got %d"):format(name, table.concat(options.fields, ", "), result.n)
					)
					result.n = nil
					return result
				end, ttl)
				if type(made) == "table" and not same(mirror[key], made) then
					announce(key, made)
				end
				return 2
			end)
		end,

		remove = function(key: string)
			keyed(what, key)
			enqueue(name .. ".remove", 1, function()
				store.remove(key)
				forget(key)
				return 1
			end)
		end,

		refresh = poll,
	}

	join({
		name = name,
		poll = every,
		tick = poll,
		attach = function(d: any, fresh: boolean)
			store = d.map(name)
			if fresh then
				table.clear(mirror)
			end
			polling = false
		end,
	})
	return self
end

-- ---------------------------------------------------------------- the rest of the surface

-- the headless driver, tables and a clock the test moves by hand
Shared.tables = Tables

-- swapping the driver is a new world: what was waiting was waiting on the old one, and every
-- mirror is emptied so the next poll announces what the new one holds
function Shared.driver(swap: any)
	assert(type(swap) == "table", "Beef.Shared.driver: takes a driver")
	driver = swap
	table.clear(work)
	workHead, workTail = 1, 0
	table.clear(spentAt)
	table.clear(spentUnits)
	spentHead, spentTail = 1, 0
	used = 0
	counts.calls, counts.spent = 0, 0
	counts.throttled, counts.failed, counts.polls = 0, 0, 0
	bind(true)
end

function Shared.budget(options: Budget)
	quota.base = options.base or quota.base
	quota.per = options.per or quota.per
	quota.drain = options.drain or quota.drain
	if driver ~= nil then
		bind(false)
	end
end

function Shared.stats(): Stats
	if driver ~= nil then
		release(driver.now())
	end
	return {
		units = used,
		budget = if driver ~= nil then allowance() else 0,
		held = workTail - workHead + 1,
		calls = counts.calls,
		spent = counts.spent,
		throttled = counts.throttled,
		failed = counts.failed,
		polls = counts.polls,
	}
end

return Shared
