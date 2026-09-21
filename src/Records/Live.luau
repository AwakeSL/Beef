--!strict
--!optimize 2

-- The driver a live server runs on: a DataStore holds the record, a MemoryStore hash map holds
-- the session lock, and Heartbeat turns the timer. A server that dies stops refreshing and its
-- locks fall out of the hash map on their own, so nothing here waits on a wall clock.

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local RunService = game:GetService("RunService")

local TURN = 1 -- seconds between turns of the timer; the record's own save and lock times are longer

local Live = {}

function Live.new(): any
	local stores: { [string]: any } = {}
	local maps: { [string]: any } = {}
	local refreshed: { [string]: number } = {}

	local jobId = game.JobId
	local server = if type(jobId) == "string" and jobId ~= "" then jobId else "studio"

	local function store(name: string): any
		local found = stores[name]
		if not found then
			found = DataStoreService:GetDataStore(name)
			stores[name] = found
		end
		return found
	end

	local function map(name: string): any
		local found = maps[name]
		if not found then
			found = MemoryStoreService:GetHashMap("beef:lock:" .. name)
			maps[name] = found
		end
		return found
	end

	-- the hash map entry is this server's or it is nobody's: the transform aborts on anyone else's
	local function hold(who: string)
		return function(old: any): any?
			if old ~= nil and old.server ~= who then
				return nil
			end
			return { server = who, at = os.time() }
		end
	end

	local self: any = {}

	self.server = server

	self.now = function(): number
		return os.clock()
	end

	self.wait = function(seconds: number)
		task.wait(seconds)
	end

	self.get = function(name: string, key: string): any
		return store(name):GetAsync(key)
	end

	self.update = function(name: string, key: string, transform: (old: any) -> any?): any
		return store(name):UpdateAsync(key, transform)
	end

	-- a DataStore has no session of its own to close; the lock is the session, and it goes below
	self.release = function() end

	self.lock = function(name: string, key: string, who: string, ttl: number): (boolean, string?)
		local ok, got = pcall(function()
			return map(name):UpdateAsync(key, hold(who), math.ceil(ttl))
		end)
		if not ok then
			return false, "the lock store did not answer: " .. tostring(got)
		end
		if got == nil then
			local read, held = pcall(function()
				return map(name):GetAsync(key)
			end)
			return false, if read and type(held) == "table" then tostring(held.server) else "another server"
		end
		refreshed[name .. "/" .. key] = os.clock()
		return true
	end

	self.refresh = function(name: string, key: string, who: string, ttl: number): boolean
		local id = name .. "/" .. key
		local ok, got = pcall(function()
			return map(name):UpdateAsync(key, hold(who), math.ceil(ttl))
		end)
		if ok then
			if got == nil then
				refreshed[id] = nil
				return false
			end
			refreshed[id] = os.clock()
			return true
		end
		-- the request failed, which is not the same as the lock being gone: it stands until the
		-- one this server last took would have run out
		local last = refreshed[id]
		if last ~= nil and os.clock() - last < ttl then
			warn(("[Beef] %s %s: the lock store did not answer, the lock stands: %s"):format(name, key, tostring(got)))
			return true
		end
		refreshed[id] = nil
		return false
	end

	self.unlock = function(name: string, key: string, who: string)
		refreshed[name .. "/" .. key] = nil
		pcall(function()
			local held = map(name):GetAsync(key)
			if held ~= nil and held.server == who then
				map(name):RemoveAsync(key)
			end
		end)
	end

	-- the timer and the last save a server ever does
	self.start = function(step: () -> (), flush: () -> ())
		if RunService:IsServer() then
			game:BindToClose(flush)
		end
		local since = 0
		RunService.Heartbeat:Connect(function(dt: number)
			since += dt
			if since >= TURN then
				since = 0
				step()
			end
		end)
	end

	return self
end

return Live
