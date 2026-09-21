--!strict
--!optimize 2

-- The headless driver for Beef.Shared: three tables and a clock the test moves by hand. Nothing
-- here yields, so a whole minute of cross-server traffic runs inside one case, and a poll, a TTL,
-- a held call and a throttle all happen exactly where the spec puts them.
--
-- The tables copy what the service does, not how it does it: an item carries its own expiry, a
-- sorted map orders by the sort key it was set with, and a queue hands out a batch id that hides
-- what it read until the invisibility window runs out.

export type Item = { key: string, value: any }

export type Sorted = {
	set: (key: string, value: any, ttl: number, sortKey: any) -> (),
	get: (key: string) -> any,
	remove: (key: string) -> (),
	range: (descending: boolean, count: number) -> { Item },
}

export type Queue = {
	add: (value: any, ttl: number, priority: number) -> (),
	read: (count: number) -> ({ any }, string?),
	remove: (id: string) -> (),
}

export type Map = {
	set: (key: string, value: any, ttl: number) -> (),
	get: (key: string) -> any,
	update: (key: string, transform: (any) -> any, ttl: number) -> any,
	remove: (key: string) -> (),
	list: (count: number) -> { Item },
}

export type Tables = {
	now: () -> number,
	players: () -> number,
	every: (seconds: number, fn: () -> ()) -> () -> (),
	sorted: (name: string) -> Sorted,
	queue: (name: string, invisibility: number) -> Queue,
	map: (name: string) -> Map,
	-- the parts only a test uses
	advance: (seconds: number) -> (),
	playing: (count: number) -> (),
	refuse: (calls: number) -> (),
	sizeOf: (name: string) -> number,
}

export type Options = {
	at: number?,
	players: number?,
}

type Entry = { value: any, sortKey: any, expires: number }
type Waiting = { value: any, expires: number, priority: number, order: number, hidden: number, batch: string? }
type Timer = { at: number, every: number, fn: () -> (), alive: boolean }

local FOREVER = math.huge

return function(options: Options?): Tables
	local clock = options and options.at or 0
	local players = options and options.players or 0
	local refusals = 0
	local batches = 0

	local timers: { Timer } = {}
	local sizes: { [string]: () -> number } = {}
	-- a store is its name: asking twice hands back the one that holds the items, the way the
	-- service does
	local made: { [string]: any } = {}

	-- every call goes through here so a test can make the service refuse: the held call is the one
	-- the budget stopped, this is the one the service threw at, and Shared treats them differently
	local function attempt()
		if refusals > 0 then
			refusals -= 1
			error("MemoryStoreService: request was throttled", 0)
		end
	end

	local self = {} :: Tables

	self.now = function(): number
		return clock
	end

	self.players = function(): number
		return players
	end

	self.every = function(seconds: number, fn: () -> ()): () -> ()
		assert(seconds > 0, "Shared.tables: a timer needs an interval above zero")
		local timer: Timer = { at = clock + seconds, every = seconds, fn = fn, alive = true }
		table.insert(timers, timer)
		return function()
			timer.alive = false
		end
	end

	-- the clock the test holds: move it and every timer due in that span fires in time order, at
	-- the moment it was due, so a poll on a five second interval fires twice over eleven seconds
	self.advance = function(seconds: number)
		local target = clock + seconds
		while true do
			local soonest: Timer? = nil
			local at = FOREVER
			for _, timer in timers do
				if timer.alive and timer.at <= target and timer.at < at then
					soonest = timer
					at = timer.at
				end
			end
			if soonest == nil then
				break
			end
			clock = at
			soonest.at = at + soonest.every
			soonest.fn()
		end
		clock = target
	end

	self.playing = function(count: number)
		players = count
	end

	self.refuse = function(calls: number)
		refusals = calls
	end

	-- how many items a structure holds, expiry taken into account: what a test asserts a TTL by
	self.sizeOf = function(name: string): number
		local size = sizes[name]
		return if size then size() else 0
	end

	self.sorted = function(name: string): Sorted
		local found = made["sorted/" .. name]
		if found then
			return found
		end
		local items: { [string]: Entry } = {}

		local function live(key: string): Entry?
			local entry = items[key]
			if entry == nil then
				return nil
			end
			if entry.expires <= clock then
				items[key] = nil
				return nil
			end
			return entry
		end

		local function size(): number
			local n = 0
			for key in items do
				if live(key) then
					n += 1
				end
			end
			return n
		end
		sizes[name] = size

		local store: Sorted = {
			set = function(key: string, value: any, ttl: number, sortKey: any)
				attempt()
				items[key] = { value = value, sortKey = sortKey, expires = clock + ttl }
			end,
			get = function(key: string): any
				attempt()
				local entry = live(key)
				return if entry then entry.value else nil
			end,
			remove = function(key: string)
				attempt()
				items[key] = nil
			end,
			range = function(descending: boolean, count: number): { Item }
				attempt()
				local keys: { string } = {}
				for key in items do
					if live(key) then
						table.insert(keys, key)
					end
				end
				-- the service orders by the sort key and breaks a tie on the key, and so does this
				table.sort(keys, function(a: string, b: string): boolean
					local x, y = items[a].sortKey, items[b].sortKey
					if x == y then
						return a < b
					end
					if descending then
						return x > y
					end
					return x < y
				end)
				local out: { Item } = {}
				for i = 1, math.min(count, #keys) do
					out[i] = { key = keys[i], value = items[keys[i]].value }
				end
				return out
			end,
		}
		made["sorted/" .. name] = store
		return store
	end

	self.queue = function(name: string, invisibility: number): Queue
		local found = made["queue/" .. name]
		if found then
			return found
		end
		local waiting: { Waiting } = {}
		local added = 0

		local function sweep()
			for i = #waiting, 1, -1 do
				if waiting[i].expires <= clock then
					table.remove(waiting, i)
				end
			end
		end

		sizes[name] = function(): number
			sweep()
			return #waiting
		end

		local store: Queue = {
			add = function(value: any, ttl: number, priority: number)
				attempt()
				added += 1
				table.insert(waiting, {
					value = value,
					expires = clock + ttl,
					priority = priority,
					order = added,
					hidden = 0,
					batch = nil,
				})
			end,
			read = function(count: number): ({ any }, string?)
				attempt()
				sweep()
				local ready: { Waiting } = {}
				for _, item in waiting do
					if item.hidden <= clock then
						table.insert(ready, item)
					end
				end
				-- the service hands out the highest priority first and falls back on the order it
				-- was added in
				table.sort(ready, function(a: Waiting, b: Waiting): boolean
					if a.priority == b.priority then
						return a.order < b.order
					end
					return a.priority > b.priority
				end)
				local values: { any } = {}
				if #ready == 0 then
					return values, nil
				end
				batches += 1
				local id = ("%s:%d"):format(name, batches)
				for i = 1, math.min(count, #ready) do
					local item = ready[i]
					item.hidden = clock + invisibility
					item.batch = id
					values[i] = item.value
				end
				return values, id
			end,
			remove = function(id: string)
				attempt()
				for i = #waiting, 1, -1 do
					if waiting[i].batch == id then
						table.remove(waiting, i)
					end
				end
			end,
		}
		made["queue/" .. name] = store
		return store
	end

	self.map = function(name: string): Map
		local found = made["map/" .. name]
		if found then
			return found
		end
		local items: { [string]: Entry } = {}

		local function live(key: string): Entry?
			local entry = items[key]
			if entry == nil then
				return nil
			end
			if entry.expires <= clock then
				items[key] = nil
				return nil
			end
			return entry
		end

		sizes[name] = function(): number
			local n = 0
			for key in items do
				if live(key) then
					n += 1
				end
			end
			return n
		end

		local store: Map = {
			set = function(key: string, value: any, ttl: number)
				attempt()
				items[key] = { value = value, sortKey = nil, expires = clock + ttl }
			end,
			get = function(key: string): any
				attempt()
				local entry = live(key)
				return if entry then entry.value else nil
			end,
			update = function(key: string, transform: (any) -> any, ttl: number): any
				attempt()
				local entry = live(key)
				local made = transform(if entry then entry.value else nil)
				if made == nil then
					return nil
				end
				items[key] = { value = made, sortKey = nil, expires = clock + ttl }
				return made
			end,
			remove = function(key: string)
				attempt()
				items[key] = nil
			end,
			list = function(count: number): { Item }
				attempt()
				local keys: { string } = {}
				for key in items do
					if live(key) then
						table.insert(keys, key)
					end
				end
				table.sort(keys)
				local out: { Item } = {}
				for i = 1, math.min(count, #keys) do
					out[i] = { key = keys[i], value = items[keys[i]].value }
				end
				return out
			end,
		}
		made["map/" .. name] = store
		return store
	end

	return self
end
