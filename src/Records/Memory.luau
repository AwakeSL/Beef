--!strict
--!optimize 2

-- The driver a headless test runs on: two tables and a clock the test moves. A world is the
-- backend, one per test, and a driver is one server's view of it, so a spec can stand two
-- servers up over the same keys and watch them argue. Time only passes when the test says so,
-- so a lock lapses exactly where the test wants it to.

export type World = {
	data: { [string]: { [string]: any } }, -- store name, key, what was written
	locks: { [string]: { [string]: { server: string, at: number, expires: number } } },
	faults: { [string]: string }, -- key to the error a request for it throws, for testing a load that fails
	now: number,
	servers: number,
	advance: (seconds: number) -> (),
	onWait: ((seconds: number) -> ())?, -- what the other servers do while this one waits
}

local Memory = {}

function Memory.world(): World
	local self = {
		data = {},
		locks = {},
		faults = {},
		now = 0,
		servers = 0,
	} :: any
	self.advance = function(seconds: number)
		self.now += seconds
	end
	return self :: World
end

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

-- a driver for one server. Give two of them the same world and they are two servers on one game
function Memory.new(world: World?, server: string?): any
	local self: any = world or Memory.world()
	self.servers += 1
	local name = server or ("server" .. self.servers)

	local function data(store: string): { [string]: any }
		local held = self.data[store]
		if not held then
			held = {}
			self.data[store] = held
		end
		return held
	end

	local function locks(store: string): { [string]: any }
		local held = self.locks[store]
		if not held then
			held = {}
			self.locks[store] = held
		end
		return held
	end

	local function live(store: string, key: string): any?
		local lock = locks(store)[key]
		if lock and lock.expires > self.now then
			return lock
		end
		return nil
	end

	local function fault(key: string)
		local why = self.faults[key]
		if why then
			error(why, 0)
		end
	end

	return {
		server = name,
		world = self,

		now = function(): number
			return self.now
		end,

		-- waiting is moving the clock: what else happens while this server waits is the world's
		wait = function(seconds: number)
			self.now += seconds
			local onWait = self.onWait
			if onWait then
				onWait(seconds)
			end
		end,

		get = function(store: string, key: string): any
			fault(key)
			return copy(data(store)[key])
		end,

		update = function(store: string, key: string, transform: (old: any) -> any?): any
			fault(key)
			local held = data(store)
			local value = transform(copy(held[key]))
			if value == nil then
				return nil
			end
			held[key] = copy(value)
			return value
		end,

		release = function() end,

		lock = function(store: string, key: string, who: string, ttl: number): (boolean, string?)
			local lock = live(store, key)
			if lock and lock.server ~= who then
				return false, lock.server
			end
			locks(store)[key] = { server = who, at = self.now, expires = self.now + ttl }
			return true
		end,

		refresh = function(store: string, key: string, who: string, ttl: number): boolean
			local lock = live(store, key)
			if not lock or lock.server ~= who then
				return false
			end
			lock.expires = self.now + ttl
			return true
		end,

		unlock = function(store: string, key: string, who: string)
			local lock = live(store, key)
			if lock and lock.server == who then
				locks(store)[key] = nil
			end
		end,
	}
end

return Memory
