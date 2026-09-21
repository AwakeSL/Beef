--!strict
--!optimize 2

-- The engine driver for Beef.Shared: MemoryStoreService, one handle per declared structure.
-- Every call here yields, and every call here is made from the pump's own thread, never from a
-- controller, so a phase never waits on the service.

local Players = game:GetService("Players")

export type Item = { key: string, value: any }

local Live = {}

-- true where there is an engine to talk to; headless there is not, and Shared says so rather
-- than building a driver that cannot work
function Live.available(): boolean
	return task ~= nil
end

-- the service is fetched here rather than at the top of the file: Beef is required on the client
-- too, and nothing on the client has business holding a memory store
function Live.new(): any
	local MemoryStoreService = game:GetService("MemoryStoreService")
	local self = {} :: any

	self.now = function(): number
		return os.clock()
	end

	self.players = function(): number
		return #Players:GetPlayers()
	end

	-- one thread per timer: the work it runs yields on the service, and a slow call delays the
	-- next tick of that timer rather than piling threads up behind it
	self.every = function(seconds: number, fn: () -> ()): () -> ()
		local alive = true
		task.spawn(function()
			while alive do
				task.wait(seconds)
				if alive then
					fn()
				end
			end
		end)
		return function()
			alive = false
		end
	end

	self.sorted = function(name: string): any
		local store = MemoryStoreService:GetSortedMap(name)
		return {
			set = function(key: string, value: any, ttl: number, sortKey: any)
				store:SetAsync(key, value, ttl, sortKey)
			end,
			get = function(key: string): any
				return store:GetAsync(key)
			end,
			remove = function(key: string)
				store:RemoveAsync(key)
			end,
			range = function(descending: boolean, count: number): { Item }
				local direction = if descending then Enum.SortDirection.Descending else Enum.SortDirection.Ascending
				local got = store:GetRangeAsync(direction, count)
				local out: { Item } = {}
				for i, item in got do
					out[i] = { key = item.key, value = item.value }
				end
				return out
			end,
		}
	end

	self.queue = function(name: string, invisibility: number): any
		local store = MemoryStoreService:GetQueue(name, invisibility)
		return {
			add = function(value: any, ttl: number, priority: number)
				store:AddAsync(value, ttl, priority)
			end,
			-- the wait is zero on purpose: a read that waits costs a unit every two seconds it
			-- spends waiting, and the poll is already on an interval
			read = function(count: number): ({ any }, string?)
				local values, id = store:ReadAsync(count, false, 0)
				return values or {}, id
			end,
			remove = function(id: string)
				store:RemoveAsync(id)
			end,
		}
	end

	self.map = function(name: string): any
		local store = MemoryStoreService:GetHashMap(name)
		return {
			set = function(key: string, value: any, ttl: number)
				store:SetAsync(key, value, ttl)
			end,
			get = function(key: string): any
				return store:GetAsync(key)
			end,
			update = function(key: string, transform: (any) -> any, ttl: number): any
				return store:UpdateAsync(key, transform, ttl)
			end,
			remove = function(key: string)
				store:RemoveAsync(key)
			end,
			list = function(count: number): { Item }
				local pages = store:ListItemsAsync(count)
				local out: { Item } = {}
				while #out < count do
					for _, item in pages:GetCurrentPage() do
						table.insert(out, { key = item.key, value = item.value })
						if #out >= count then
							break
						end
					end
					if pages.IsFinished or #out >= count then
						break
					end
					pages:AdvanceToNextPageAsync()
				end
				return out
			end,
		}
	end

	return self
end

return Live
