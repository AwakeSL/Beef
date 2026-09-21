--!strict
--!optimize 2
-- fleet: the same boot table, one server over to another. `toClients` and `toServer` cross a link the engine
-- owns; this crosses a relay that holds nothing but where a thing lives and who owns it, so two servers of the
-- same game see each other's entities without either knowing the other exists.
--
-- Nothing new is declared to use it. An Event listed under `fleet.events` is the message: its columns are the
-- payload and their `Wire` types are the quantisation, and the entry carries what the relay needs to route and
-- hold it. A Kind listed under `fleet.kinds` gets a fleet id, minted at spawn and released at despawn, and that
-- id is the only name an entity has across the seam, because a handle means nothing on another machine.
--
-- What arrives lands where a local push lands. A cross-server hit is a push into the same Damage buffer the
-- local hit went into, in the frame it arrived, with the age it spent getting here in one of its columns, so a
-- controller reads both in the same lap of the same loop and never asks which it is reading.
--
-- There is no `every` here. A column offered twice with the same value is not sent twice, and a column that
-- changes inside the entry's window replaces what was already waiting, so the rate is the transport's beat
-- rather than a number the game picks.

local Components = require(script.Parent.Parent.Components)
local Events = require(script.Parent.Parent.Events)
local Kinds = require(script.Parent.Parent.Kinds)
local Codec = require(script.Codec)
local Transport = require(script.Transport)

local Fleet = {}

-- the fleet id column. It is indexed, so `find(id)` is how an arrival gets from a subject to the entity here
-- that carries it: that is the whole of the translation, one table lookup each way, and a game that mirrors a
-- foreign entity binds it by writing this column itself.
Fleet.id = Components.new("fleet", { index = true }) :: any

-- the three arrivals that are not a game's own Event. They are Events like any other, so they lap, they are
-- read in a phase, and a controller that reacts to a release does it beside the controller that reacts to a hit
Fleet.released = Events.new("Replicate.released", "id:u32", "age:f32")
Fleet.adopted = Events.new("Replicate.adopted", "id:u32", "server:string", "age:f32")
Fleet.claimed = Events.new("Replicate.claimed", "id:u32", "server:string", "age:f32")

export type Config = {
	url: string,
	identity: string?,
	interval: number?,
	budget: number?,
	cap: number?,
	kinds: { any }?,
	events: { any }?,
	publish: { any }?,
}

local CONFIG_KEYS: { [string]: boolean } =
	{ url = true, identity = true, interval = true, budget = true, cap = true, kinds = true, events = true, publish = true }
local EVENT_OPTIONS: { [string]: boolean } =
	{ route = true, collapse = true, retention = true, window = true, subject = true, age = true }
local PUBLISH_OPTIONS: { [string]: boolean } = { route = true, collapse = true, retention = true, window = true }
local ROUTES: { [string]: boolean } = { key = true, owner = true }
local RETENTIONS: { [string]: boolean } = { none = true, replace = true, append = true }

-- the built fleet, or nil when the boot table had none. Every call below goes through it, so a game that asks
-- for a place without declaring a fleet is told so rather than quietly doing nothing.
local live: any = nil

local function must(): any
	assert(live ~= nil, "Replicate: no fleet was declared in the boot table")
	return live
end

-- read one sparse or dense bucket at a position. A dense bucket is the kind's own column and has no slot; a
-- sparse one maps position to index and answers 0 for an entity that does not carry it.
local function valueAt(bucket: any, n: number): any
	local slot = bucket.slot
	if slot == nil then
		return bucket.value[n]
	end
	local m = if n <= bucket.cap then buffer.readu32(slot, (n - 1) * 4) else 0
	if m == 0 then
		return nil
	end
	return bucket.value[m]
end

function Fleet.build(ctx: any, config: Config)
	assert(live == nil, "Replicate: the fleet is built once")
	assert(type(config) == "table", "Replicate fleet: takes a table")
	for key in config :: any do
		assert(CONFIG_KEYS[key], ("Replicate fleet: %s is not a key of the fleet table"):format(tostring(key)))
	end
	assert(type(config.url) == "string", "Replicate fleet: url is the relay this posts to")

	local driver = ctx.driver
	-- only a server talks to the relay: the fleet is servers of one game finding each other, and a client
	-- reaches its own server the way it already does
	if not driver.isServer() then
		return
	end

	local http = driver.http
	local spawn = driver.spawn
	local clock = driver.clock
	if http == nil then
		local Live = require(script.Live)
		http = Live.http
		spawn = spawn or Live.spawn
		clock = clock or Live.clock
	end
	local nowMs: () -> number = clock or function()
		return os.clock() * 1000
	end

	local kindList: { any } = config.kinds or {}
	local isFleetKind: { [any]: boolean } = {}
	for _, kind in kindList do
		assert(
			type(kind) == "table" and type(kind.spawn) == "function",
			("Replicate fleet: kinds names kinds; %s is not one"):format(tostring(kind))
		)
		isFleetKind[kind] = true
	end

	local messages = { byId = {} :: { [number]: any }, byName = {} :: { [string]: any } }
	local nextId = 0

	-- a message is what the relay is told about an Event or a published column: an id, how it routes, whether
	-- two of it for the same subject collapse, how long the relay holds it, and how wide an entry is
	local function declare(name: string, columns: { string }, wire: { [string]: string }, options: any, collapseBy: boolean, retainBy: string, where: string): any
		nextId += 1
		assert(
			nextId <= Transport.MAX_MESSAGE_ID,
			("Replicate %s: a fleet declares at most %d messages"):format(where, Transport.MAX_MESSAGE_ID)
		)
		local route = options.route or "key"
		assert(ROUTES[route], ("Replicate %s: route is key or owner, not %s"):format(where, tostring(route)))
		local retention = options.retention or retainBy
		assert(
			RETENTIONS[retention],
			("Replicate %s: retention is none, replace or append, not %s"):format(where, tostring(retention))
		)
		local collapse = if options.collapse == nil then collapseBy else options.collapse == true
		local window = options.window or 0
		assert(type(window) == "number" and window >= 0, ("Replicate %s: window is seconds, a number"):format(where))
		assert(messages.byName[name] == nil, ("Replicate %s: two entries are both named %s"):format(where, name))

		local message = {
			id = nextId,
			name = name,
			columns = columns,
			wire = wire,
			routing = route,
			retention = retention,
			collapsible = collapse,
			window = window,
			fixed = 0,
			special = {},
			stride = nil :: number?,
		}
		Codec.prepare(message :: any, "Replicate " .. where)
		messages.byId[nextId] = message
		messages.byName[name] = message
		return message
	end

	-- ------------------------------------------------------------ events

	-- an Event entry: the Event is the message, its entity column is the subject, and every other column
	-- crosses. The age column does not cross either; it is what the far side is told about the trip, so it is
	-- filled on arrival and a local push leaves it as the pusher left it.
	local eventSends: { any } = {}
	local eventOf: { [any]: any } = {}

	for _, entry in config.events or {} do
		local things, options = ctx.split(entry, "fleet.events", EVENT_OPTIONS)
		assert(#things == 1, "Replicate fleet.events: an entry names one event type")
		local buffer_ = things[1]
		assert(
			type(buffer_) == "table" and type(buffer_.freeze) == "function",
			("Replicate fleet.events: %s is not an event type"):format(tostring(buffer_))
		)

		local subject = options.subject
		if subject == nil then
			assert(
				#kindList == 1,
				("Replicate fleet.events: %s needs subject, the kind its entity column holds; %d kinds are listed"):format(buffer_.name, #kindList)
			)
			subject = kindList[1]
		end
		assert(
			isFleetKind[subject],
			("Replicate fleet.events: %s names a subject kind that is not in fleet.kinds"):format(buffer_.name)
		)

		local entity = buffer_.entity
		assert(
			entity ~= nil,
			("Replicate fleet.events: %s needs an entity column; the entity is what the subject names"):format(buffer_.name)
		)

		local age = options.age or (if table.find(buffer_.columns, "age") then "age" else nil)
		if age ~= nil then
			assert(
				table.find(buffer_.columns, age),
				("Replicate fleet.events: %s has no column %s to put the age in"):format(buffer_.name, tostring(age))
			)
		end

		local columns: { string } = {}
		local slots: { number } = {}
		local sources: { { any } } = {}
		local entityAt, ageAt
		for c, column in buffer_.columns do
			if column == entity then
				entityAt = c
			elseif column == age then
				ageAt = c
			else
				table.insert(columns, column)
				table.insert(slots, c)
				table.insert(sources, buffer_[column])
			end
		end

		local message = declare(buffer_.name, columns, buffer_.wire, options, false, "none", "fleet.events")
		local binding = {
			message = message,
			buffer = buffer_,
			kind = subject,
			width = #buffer_.columns,
			entityAt = entityAt,
			ageAt = ageAt,
			slots = slots,
			sources = sources,
			entityColumn = buffer_[entity],
			args = table.create(#buffer_.columns),
			values = table.create(#columns),
		}
		eventOf[message] = binding
		table.insert(eventSends, binding)

		-- the window this reads over is the frame's pushes, frozen by Replicate the same way a packed stream's
		-- is, so a push crosses the fleet and the clients off one freeze
		table.insert(ctx.windows, buffer_)
		table.insert(ctx.cursors, buffer_.base + buffer_.count + 1)
	end

	-- ------------------------------------------------------------ publish

	-- a publish entry is a kind and the columns of it that cross. There is no change detection here: every
	-- placed entity is offered every frame and the transport buffer drops what has not moved, which is one
	-- encode and one compare against what last went out rather than a shadow copy of every column.
	local publishes: { any } = {}
	local publishOf: { [any]: any } = {}

	for _, entry in config.publish or {} do
		local things, options = ctx.split(entry, "fleet.publish", PUBLISH_OPTIONS)
		assert(#things > 0, "Replicate fleet.publish: an entry names what is published")

		local kind: any = nil
		local components: { any } = {}
		for i, thing in things do
			assert(type(thing) == "table", ("Replicate fleet.publish: %s is not a kind or a component"):format(tostring(thing)))
			if type(thing.spawn) == "function" then
				assert(i == 1, "Replicate fleet.publish: the kind comes first, then its columns")
				kind = thing
			else
				assert(type(thing.of) == "function", ("Replicate fleet.publish: %s is not a component"):format(tostring(thing)))
				table.insert(components, thing)
			end
		end
		assert(#components > 0, "Replicate fleet.publish: an entry names at least one component to publish")

		local names = {}
		local wire: { [string]: string } = {}
		for _, component in components do
			table.insert(names, component.name)
			local kindOf = component.wire
			assert(kindOf, ("Replicate fleet.publish: component %s has no wire type"):format(component.name))
			wire[component.name] = kindOf
		end

		if not kind then
			local found: { any } = {}
			local n = Kinds.with(found, table.unpack(components))
			assert(
				n == 1,
				("Replicate fleet.publish: %d kinds carry %s; name the kind first in the entry"):format(n, table.concat(names, "+"))
			)
			kind = found[1]
		end
		assert(
			isFleetKind[kind],
			("Replicate fleet.publish: %s is not in fleet.kinds, so its entities have no fleet id"):format(kind.name)
		)

		local name = ("publish.%s.%s"):format(kind.name, table.concat(names, "+"))
		local message = declare(name, names, wire, options, true, "replace", "fleet.publish")
		local entry_ = {
			message = message,
			kind = kind,
			components = components,
			width = #components,
			values = table.create(#components),
			waiting = {} :: { [number]: { any } },
			held = 0,
		}
		publishOf[message] = entry_
		table.insert(publishes, entry_)
	end

	-- ------------------------------------------------------------ the wire

	local transport = Transport.new({
		url = config.url,
		identity = config.identity or "beef",
		messages = messages,
		named = Kinds.named,
		http = http :: any,
		spawn = spawn,
		intervalMs = if config.interval then config.interval * 1000 else nil,
		callsPerMinute = config.budget,
		cap = config.cap,
	})

	-- ------------------------------------------------------------ ids

	local deferred: { any } = {}
	local placeLater: { any } = {}

	local function bind(kind: any, handle: number, id: number): boolean
		local n = kind.at(handle)
		if n == nil then
			return false
		end
		Fleet.id.add(kind, n, id)
		return true
	end

	local function idOf(kind: any, handle: number): number?
		local n = kind.at(handle)
		if n == nil then
			return nil
		end
		return valueAt(Fleet.id.of(kind), n)
	end

	-- spawn mints, despawn releases. Wrapping the two calls is what makes that true whatever spawns an entity,
	-- and it is read at the moment of the call rather than swept for later, so an id is never released twice
	-- and never missed. A spawn while the pool is dry does not wait: the entity is made, and the id lands in a
	-- later frame.
	for _, kind in kindList do
		local spawn_ = kind.spawn
		local despawn_ = kind.despawn
		kind.spawn = function(...)
			local handle = spawn_(...)
			local id = transport:mint()
			if id ~= nil then
				bind(kind, handle, id)
			else
				table.insert(deferred, kind)
				table.insert(deferred, handle)
			end
			return handle
		end
		kind.despawn = function(handle: number)
			local id = idOf(kind, handle)
			if id ~= nil then
				transport:release(id)
			end
			despawn_(handle)
		end
	end

	-- ------------------------------------------------------------ arrivals

	local counts = {
		pushesIn = 0,
		pushesOut = 0,
		applied = 0,
		unmatched = 0,
		unplaced = 0,
		waiting = 0,
		offered = 0,
	}

	local function forget(subject: number)
		for _, entry in publishes do
			if entry.waiting[subject] ~= nil then
				entry.waiting[subject] = nil
				entry.held -= 1
				counts.waiting -= 1
			end
		end
	end

	-- the entity an arrival is about is whatever carries that id here, whatever kind it is. A mirror of another
	-- server's creature is usually a kind of its own, outside `fleet.kinds` so it mints nothing of its own, and
	-- the columns are the contract rather than the kind.
	local function applyPublish(entry: any, subject: number, values: { any }): boolean
		local found, handle = Fleet.id.find(subject)
		if found == nil or handle == nil then
			return false
		end
		local n = found.at(handle)
		if n == nil then
			return false
		end
		local components = entry.components
		for c = 1, entry.width do
			components[c].add(found, n, values[c])
		end
		counts.applied += entry.width
		return true
	end

	local function deliver()
		-- a value held for an entity that had not spawned yet goes in the frame it appears, the same way a
		-- published value from this game's own server does
		for _, entry in publishes do
			if entry.held == 0 then
				continue
			end
			for subject, values in entry.waiting do
				if applyPublish(entry, subject, values) then
					entry.waiting[subject] = nil
					entry.held -= 1
					counts.waiting -= 1
				end
			end
		end

		for _, inbound in transport:drain() do
			local what = inbound.what
			if what == "$release" then
				forget(inbound.subject)
				Fleet.released.push(inbound.subject, inbound.ageMs / 1000)
				counts.pushesIn += 1
				continue
			end
			if what == "$adopt" then
				Fleet.adopted.push(inbound.subject, inbound.body, inbound.ageMs / 1000)
				counts.pushesIn += 1
				continue
			end
			if what == "$claim" then
				-- a claim that was won names this server, because this server now owns it; one that was lost
				-- names nobody, because the relay never says who took it
				Fleet.claimed.push(
					inbound.subject,
					if inbound.granted then transport.identity else "",
					inbound.ageMs / 1000
				)
				counts.pushesIn += 1
				continue
			end

			local message = inbound.message
			local values = inbound.values :: { any }
			local binding = eventOf[message]
			if binding ~= nil then
				local _, handle = Fleet.id.find(inbound.subject)
				if handle == nil then
					-- nothing here carries that id, so there is no entity for the push to be about. It is
					-- counted and dropped rather than held: a hit is worth nothing once it is late
					counts.unmatched += 1
					continue
				end
				local args = binding.args
				args[binding.entityAt] = handle
				if binding.ageAt then
					args[binding.ageAt] = inbound.ageMs / 1000
				end
				local slots = binding.slots
				for c = 1, #slots do
					args[slots[c]] = values[c]
				end
				binding.buffer.push(table.unpack(args, 1, binding.width))
				counts.pushesIn += 1
				continue
			end

			local entry = publishOf[message]
			if entry ~= nil then
				if not applyPublish(entry, inbound.subject, values) then
					if entry.waiting[inbound.subject] == nil then
						entry.held += 1
						counts.waiting += 1
					end
					entry.waiting[inbound.subject] = values
				end
			end
		end
	end

	-- ------------------------------------------------------------ the frame edge

	local function pack()
		local now = nowMs()

		-- an entity that spawned while the pool was dry gets its id here, and a place that was waiting on it
		-- goes out in the same breath
		if #deferred > 0 then
			local kept = 0
			for i = 1, #deferred, 2 do
				local kind, handle = deferred[i], deferred[i + 1]
				if kind.at(handle) == nil then
					continue
				end
				local id = transport:mint()
				if id == nil then
					deferred[kept + 1] = kind
					deferred[kept + 2] = handle
					kept += 2
				else
					bind(kind, handle, id)
				end
			end
			for i = #deferred, kept + 1, -1 do
				deferred[i] = nil
			end
		end
		if #placeLater > 0 then
			local kept = 0
			for i = 1, #placeLater, 3 do
				local kind, handle, key = placeLater[i], placeLater[i + 1], placeLater[i + 2]
				local id = idOf(kind, handle)
				if id ~= nil then
					transport:place(id, key)
				elseif kind.at(handle) ~= nil then
					placeLater[kept + 1] = kind
					placeLater[kept + 2] = handle
					placeLater[kept + 3] = key
					kept += 3
				end
			end
			for i = #placeLater, kept + 1, -1 do
				placeLater[i] = nil
			end
		end

		for _, binding in eventSends do
			local buffer_ = binding.buffer
			local from, last = buffer_.from, buffer_.last
			if last < from then
				continue
			end
			local kind = binding.kind
			local bucket = Fleet.id.of(kind)
			local handles = binding.entityColumn
			local sources = binding.sources
			local values = binding.values
			local width = #sources
			for i = from, last do
				local n = kind.at(handles[i])
				local id = if n ~= nil then valueAt(bucket, n) else nil
				if id == nil then
					counts.unplaced += 1
					continue
				end
				for c = 1, width do
					values[c] = sources[c][i]
				end
				transport:offer(binding.message, id, values, now)
				counts.pushesOut += 1
			end
		end

		local places = transport.places
		for _, entry in publishes do
			local kind = entry.kind
			local bucket = Fleet.id.of(kind)
			local count = bucket.count or 0
			if count == 0 then
				continue
			end
			local has, ids = bucket.has, bucket.value
			local components = entry.components
			local width = entry.width
			local values = entry.values
			local buckets = table.create(width)
			for c = 1, width do
				buckets[c] = components[c].of(kind)
			end
			for m = 1, count do
				local id = ids[m]
				-- only a placed entity is offered: the relay routes by where a subject lives, so a column of
				-- one that lives nowhere has nowhere to go
				if places[id] == nil then
					continue
				end
				local n = has[m]
				local whole = true
				for c = 1, width do
					local v = valueAt(buckets[c], n)
					if v == nil then
						whole = false
						break
					end
					values[c] = v
				end
				if whole then
					transport:offer(entry.message, id, values, now)
					counts.offered += 1
				end
			end
		end

		transport:step(now)
	end

	live = {
		transport = transport,
		counts = counts,
		deliver = deliver,
		pack = pack,
		placeLater = placeLater,
		bind = bind,
		idOf = idOf,
		kinds = isFleetKind,
	}

	-- two controllers over one fleet: one runs before the phases and one after them, the same two edges every
	-- other part of Replicate sits on
	table.insert(ctx.incoming, { name = "Fleet", link = "Beef.fleet.in", bytes = 0, pre = deliver })
	table.insert(ctx.outgoing, { name = "Fleet", link = "Beef.fleet.out", bytes = 0, post = pack })
end

-- ---------------------------------------------------------------- the calls

-- which relay key this entity lives under. The relay holds nothing but that, and it is what decides who hears
-- the entity's pushes: a server that wants the key hears them, one that does not never sees a byte.
function Fleet.place(kind: any, handle: number, key: string | number)
	local self = must()
	assert(self.kinds[kind], ("Replicate.place: %s is not in fleet.kinds"):format(tostring(kind and kind.name)))
	local id = self.idOf(kind, handle)
	if id == nil then
		-- the entity spawned before the first block of ids arrived; the place goes out with the id
		table.insert(self.placeLater, kind)
		table.insert(self.placeLater, handle)
		table.insert(self.placeLater, tostring(key))
		return
	end
	self.transport:place(id, tostring(key))
end

-- which keys this server wants to hear. The whole list every time, because the relay keeps one per server and
-- a list is cheaper to state than a difference is to agree on.
function Fleet.want(keys: { string | number })
	local self = must()
	local out = table.create(#keys)
	for i, key in keys do
		out[i] = tostring(key)
	end
	self.transport:setWant(out)
end

-- put a subject up for another server to take: its key, and a body the taker is handed with the offer. With no
-- key it goes up under the one it is already placed at.
function Fleet.adopt(id: number, key: (string | number)?, body: string?)
	local self = must()
	local where = if key ~= nil then tostring(key) else self.transport.places[id]
	assert(where ~= nil, ("Replicate.adopt: %d is not placed, so name the key to adopt it under"):format(id))
	self.transport:adopt(id, where, body or self.transport.identity)
end

-- take a subject that was put up. Two servers may claim the same one; the relay settles it and the answer comes
-- back as a push into `Replicate.claimed`.
function Fleet.claim(id: number, hold: number?)
	must().transport:claim(id, if hold then math.round(hold * 1000) else nil)
end

-- take a subject back off the board
function Fleet.disown(id: number)
	must().transport:disown(id)
end

-- ---------------------------------------------------------------- stats

function Fleet.stats(): { [string]: any }?
	if live == nil then
		return nil
	end
	local transport = live.transport
	local out: { [string]: any } = table.clone(transport.stats)
	for key, value in live.counts do
		out[key] = value
	end
	out.minted = transport.pool.stats.minted
	out.deferred = transport.pool.stats.deferred
	out.granted = transport.pool.stats.granted
	out.ids = transport.pool.remaining
	out.unchanged = transport.buffer.unchanged
	out.replaced = transport.buffer.replaced
	out.appended = transport.buffer.appended
	out.droppedOffers = transport.buffer.dropped
	out.lead = transport:leadStats()
	return out
end

return Fleet
