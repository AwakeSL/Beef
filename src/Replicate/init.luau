--!strict
--!optimize 2
-- Replicate: one call at boot is the whole map of a game's traffic. An Event is a name and typed columns and a
-- Component is a column; neither says where it goes. This table says it, once, and the same table is handed to
-- both sides. Whichever side packs a key builds the packer and the other builds the unpacker, so the two ends
-- cannot drift: they are read off one declaration.
--
-- An entry is the thing then its options. A bare `Damage` means `{ Damage }` with defaults; `{ Landing,
-- channel = "unreliable" }` is the same event type on the other channel. A stream entry takes `channel`. A
-- publish entry takes `every`, `channel`, `keyframe`, `chunk`, and `origin`, the Component the receiving side
-- keeps the sender's handle in, since only the game knows which entity here is which entity there.
--
-- `fleet` is the same idea pointed at another server rather than at a client: the same Events and the same
-- columns, over a relay instead of a remote. It is a table rather than a list, and `Fleet` reads it.
--
-- Nothing runs in a Phase. The packing is a frame edge, not a pass: what arrived is delivered before every
-- phase on the signal and what the phases pushed is packed after them, both through `Drivers`, the way the
-- parallel driver collects and sends around the same phases.

local Kinds = require(script.Parent.Kinds)
local Drivers = require(script.Parent.Drivers)
local Remotes = require(script.Remotes)
local Send = require(script.Send)
local Receive = require(script.Receive)
local Publish = require(script.Publish)
local Apply = require(script.Apply)
local Fleet = require(script.Fleet)

export type Link = Remotes.Link
export type Driver = Remotes.Driver
export type Options = Publish.Options
export type Fleet = Fleet.Config

export type Map = {
	signal: string?,             -- the RunService signal the phases run on, Heartbeat by default
	toClients: { any }?,         -- event types the server packs and the clients read
	toServer: { any }?,          -- event types a client packs and the server reads
	publish: { any }?,           -- a kind's columns, packed on change and applied on the other side
	fleet: Fleet.Config?,        -- the relay: this server's Events and columns out to the rest of the fleet
}

export type Stats = {
	sent: number,
	received: number,
	bytesOut: number,
	bytesIn: number,
	pushesOut: number,
	pushesIn: number,
	entities: number,
	applied: number,
	refused: number,
	waiting: number,
	dropped: number,
	oversize: number,
	links: { [string]: { [string]: any } },
	fleet: { [string]: any }?,   -- nil when the boot table declared no fleet
}

export type Wiring = {
	controllers: { any },
	deliver: () -> (),
	pack: () -> (),
	stats: () -> Stats,
}

-- what an UnreliableRemoteEvent will carry; a payload over it is split rather than dropped
local UNRELIABLE = 900

local STREAM_OPTIONS: { [string]: boolean } = { channel = true }
local PUBLISH_OPTIONS: { [string]: boolean } = { every = true, channel = true, keyframe = true, chunk = true, origin = true }
local COUNTS = { "sent", "received", "pushes", "bytes", "entities", "applied", "refused", "waiting", "dropped", "oversize" }

local driver: Remotes.Driver = Remotes
local booted = false
local incoming: { any } = {}
local outgoing: { any } = {}
local windows: { any } = {}
local cursors: { number } = {}
local taken: { [string]: boolean } = {}

local function allowedList(allowed: { [string]: boolean }): string
	local names = {}
	for key in allowed do
		table.insert(names, key)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

-- an entry is either the thing on its own or a list holding the things and then their options. A declared
-- Event, Component or Kind never has a first array element, so that alone tells the two apart.
local function split(entry: any, where: string, allowed: { [string]: boolean }): ({ any }, { [string]: any })
	assert(type(entry) == "table", ("Replicate %s: an entry is the thing, or a list of the thing and its options"):format(where))
	if entry[1] == nil then
		return { entry }, {}
	end
	local things = table.move(entry, 1, #entry, 1, {})
	local options: { [string]: any } = {}
	for key, value in entry do
		if type(key) ~= "number" then
			assert(allowed[key], ("Replicate %s: %s is not an option here; %s are"):format(where, tostring(key), allowedList(allowed)))
			options[key] = value
		end
	end
	return things, options
end

local function unreliableFrom(options: { [string]: any }, where: string): boolean
	local channel = options.channel
	if channel == nil or channel == "reliable" then
		return false
	end
	assert(channel == "unreliable", ("Replicate %s: channel is reliable or unreliable, not %s"):format(where, tostring(channel)))
	return true
end

local function linkFor(name: string, unreliable: boolean): Remotes.Link
	assert(not taken[name], ("Replicate: two entries both want the link %s"):format(name))
	taken[name] = true
	return driver.link(name, unreliable)
end

local function isBuffer(value: any): boolean
	return type(value) == "table" and type(value.freeze) == "function"
end

-- `toClients` and `toServer` are one thing pointed two ways: the side that packs is the server for one and the
-- client for the other, and the code on either end is the same. Every entry on one channel shares a link,
-- because one payload a frame beats one payload an event type.
local function stream(key: string, entries: { any }, packedByServer: boolean)
	local groups = {
		{ unreliable = false, buffers = {} :: { any } },
		{ unreliable = true, buffers = {} :: { any } },
	}
	for _, entry in entries do
		local things, options = split(entry, key, STREAM_OPTIONS)
		assert(#things == 1, ("Replicate %s: an entry names one event type"):format(key))
		local buffer_ = things[1]
		assert(isBuffer(buffer_), ("Replicate %s: %s is not an event type"):format(key, tostring(buffer_)))
		local group = groups[if unreliableFrom(options, key) then 2 else 1]
		table.insert(group.buffers, buffer_)
	end

	for _, group in groups do
		local buffers = group.buffers
		if #buffers == 0 then
			continue
		end
		local name = "Beef." .. key .. (if group.unreliable then ".unreliable" else "")
		local link = linkFor(name, group.unreliable)
		if (not not driver.isServer()) == packedByServer then
			table.insert(outgoing, Send(name, link, buffers, if group.unreliable then UNRELIABLE else math.huge))
			for _, buffer_ in buffers do
				table.insert(windows, buffer_)
				table.insert(cursors, buffer_.base + buffer_.count + 1)
			end
		else
			local into: { [string]: any } = {}
			for _, buffer_ in buffers do
				assert(into[buffer_.name] == nil, ("Replicate %s: two event types are both named %s"):format(key, buffer_.name))
				into[buffer_.name] = buffer_
			end
			table.insert(incoming, Receive(name, link, into, Kinds.named))
		end
	end
end

-- a publish entry is a kind and the columns of it that cross, or the columns alone when only one kind carries
-- them. It goes one way, the server's columns to the clients, so there is no side to choose.
local function published(entries: { any })
	for _, entry in entries do
		local things, options = split(entry, "publish", PUBLISH_OPTIONS)
		assert(#things > 0, "Replicate publish: an entry names what is published")

		local kind: any = nil
		local components: { any } = {}
		for i, thing in things do
			assert(type(thing) == "table", ("Replicate publish: %s is not a kind or a component"):format(tostring(thing)))
			if type(thing.spawn) == "function" then
				assert(i == 1, "Replicate publish: the kind comes first, then its columns")
				kind = thing
			else
				assert(type(thing.of) == "function", ("Replicate publish: %s is not a component"):format(tostring(thing)))
				table.insert(components, thing)
			end
		end
		assert(#components > 0, "Replicate publish: an entry names at least one component to publish")

		local names = {}
		for _, component in components do
			table.insert(names, component.name)
		end
		local columns = table.concat(names, "+")

		if not kind then
			-- a bare column says which kind it means when one kind carries it; with two the entry names the kind
			local found: { any } = {}
			local n = Kinds.with(found, table.unpack(components))
			assert(n == 1, ("Replicate publish: %d kinds carry %s; name the kind first in the entry"):format(n, columns))
			kind = found[1]
		end

		local origin = options.origin
		assert(
			type(origin) == "table" and type(origin.find) == "function",
			("Replicate publish: %s needs origin, the indexed component the reading side keeps the sender's handle in"):format(kind.name)
		)

		local name = ("Beef.publish.%s.%s"):format(kind.name, columns)
		local link = linkFor(name, unreliableFrom(options, "publish"))
		if driver.isServer() then
			table.insert(outgoing, Publish(name, link, driver, kind, components, options :: any))
		else
			table.insert(incoming, Apply(name, link, kind, origin, components))
		end
	end
end

-- every key of the boot table is one part, built in the order below. `fleet` is the last of them and the only
-- one that does not cross a link the engine owns: it is handed the same seams the others use, so it registers
-- its two ends in `incoming` and `outgoing` and its Events in `windows` like everything else here.
local parts: { { key: string, build: (value: any) -> () } } = {
	{ key = "toClients", build = function(value) stream("toClients", value, true) end },
	{ key = "toServer", build = function(value) stream("toServer", value, false) end },
	{ key = "publish", build = published },
	{
		key = "fleet",
		build = function(value)
			Fleet.build({
				driver = driver,
				split = split,
				incoming = incoming,
				outgoing = outgoing,
				windows = windows,
				cursors = cursors,
			}, value)
		end,
	},
}

local function deliver()
	for _, controller in incoming do
		controller.pre()
	end
end

-- the window a packed event type goes over is held here the way a Phase holds its own: every push since the
-- last time this packed. The phases on the signal have already run, so that is this frame's work.
local function pack()
	for i, buffer_ in windows do
		cursors[i] = buffer_.freeze(cursors[i])
	end
	for _, controller in outgoing do
		controller.post()
	end
end

local function report(controller: any): { [string]: any }
	local out: { [string]: any } = { role = controller.name }
	for _, key in COUNTS do
		if controller[key] ~= nil then
			out[key] = controller[key]
		end
	end
	return out
end

-- what crossed, both ways, since boot, and the same counts per link
local function stats(): Stats
	local out: Stats = {
		sent = 0,
		received = 0,
		bytesOut = 0,
		bytesIn = 0,
		pushesOut = 0,
		pushesIn = 0,
		entities = 0,
		applied = 0,
		refused = 0,
		waiting = 0,
		dropped = 0,
		oversize = 0,
		links = {},
	}
	for _, controller in outgoing do
		out.sent += controller.sent or 0
		out.bytesOut += controller.bytes
		out.pushesOut += controller.pushes or 0
		out.entities += controller.entities or 0
		out.oversize += controller.oversize or 0
		out.links[controller.link] = report(controller)
	end
	for _, controller in incoming do
		out.received += controller.received or 0
		out.bytesIn += controller.bytes
		out.pushesIn += controller.pushes or 0
		out.applied += controller.applied or 0
		out.refused += controller.refused or 0
		out.waiting += controller.waiting or 0
		out.dropped += controller.dropped or 0
		out.links[controller.link] = report(controller)
	end
	out.fleet = Fleet.stats()
	return out
end

local function boot(map: Map): Wiring
	assert(not booted, "Replicate: the boot table is given once; it is the whole map of a game's traffic")
	assert(type(map) == "table", "Replicate: takes the boot table")
	booted = true

	local known: { [string]: boolean } = { signal = true }
	for _, part in parts do
		known[part.key] = true
	end
	for key in map :: any do
		if not known[key] then
			error(("Replicate: %s is not a key of the boot table"):format(tostring(key)), 2)
		end
	end

	for _, part in parts do
		local value = (map :: any)[part.key]
		if value ~= nil then
			assert(type(value) == "table", ("Replicate: %s is a table"):format(part.key))
			part.build(value)
		end
	end

	local signal = map.signal or "Heartbeat"
	Drivers.before(signal, deliver)
	Drivers.after(signal, pack)

	local controllers: { any } = {}
	table.move(incoming, 1, #incoming, 1, controllers)
	table.move(outgoing, 1, #outgoing, #controllers + 1, controllers)
	return {
		controllers = controllers,
		deliver = deliver,
		pack = pack,
		stats = stats,
	}
end

local Replicate = {
	-- the engine edge, swapped before the boot call: live it is RemoteEvents, under Lune a pair of tables.
	-- The fleet side reads `http`, `spawn` and `clock` off the same table when they are there, and falls back
	-- to HttpService when they are not.
	driver = function(chosen: Remotes.Driver)
		assert(not booted, "Replicate: the driver is chosen before the boot call")
		driver = chosen
	end,
	stats = stats,

	-- the fleet: where an entity lives, what this server wants to hear, and the three ways ownership moves
	fleet = Fleet.id,
	place = Fleet.place,
	want = Fleet.want,
	adopt = Fleet.adopt,
	claim = Fleet.claim,
	disown = Fleet.disown,
	released = Fleet.released,
	adopted = Fleet.adopted,
	claimed = Fleet.claimed,
}

return setmetatable(Replicate, {
	__call = function(_, map: Map): Wiring
		return boot(map)
	end,
})
