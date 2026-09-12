--!strict
--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Wire = require(script.Parent.Parent.Wire)

type Kind = { name: string, at: (number) -> number? }
type Bucket = { value: { any }, slot: buffer?, cap: number? }
type Component = { name: string, wire: string?, of: (Kind) -> Bucket, add: (Kind, number, any) -> () }
type Origin = { find: (number) -> (Kind?, number?) }

local HEADER = 8 + 1 + 4

return function(remoteName: string, kind: Kind, origin: Origin, ...: Component)
	local components = { ... }
	local width = #components
	local readers = {}
	for i, component in components do
		assert(component.wire, ("Apply: component %s has no wire type"):format(component.name))
		readers[i] = Wire.read[component.wire :: string]
	end

	local pending: { buffer } = {}
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild(remoteName)
	;(remote :: any).OnClientEvent:Connect(function(message: buffer)
		table.insert(pending, message)
	end)

	local waiting: { [number]: { any } } = {}
	local seen: { [number]: number } = {}
	local handles: { number } = {}
	local positions: { number? } = {}
	local stale: { boolean } = {}

	local self: { [string]: any }
	self = {
		name = "Apply",
		time = 0,
		applied = 0,
		refused = 0,
		waiting = 0,
		bytes = 0,
		pre = function()
			for serverHandle, values in waiting do
				local _, handle = origin.find(serverHandle)
				local n = handle and kind.at(handle)
				if n then
					for c = 1, width do
						components[c].add(kind, n, values[c])
						self.applied += 1
					end
					waiting[serverHandle] = nil
					self.waiting -= 1
				end
			end
			for _, b in pending do
				self.bytes += buffer.len(b)
				local time = buffer.readf64(b, 0)
				self.time = time
				local count = buffer.readu32(b, 9)
				local at = HEADER
				for i = 1, count do
					local serverHandle = buffer.readu32(b, at)
					at += 4
					handles[i] = serverHandle
					local last = seen[serverHandle]
					if last and time < last then
						stale[i] = true
						self.refused += 1
					else
						stale[i] = false
						seen[serverHandle] = time
					end
					local _, handle = origin.find(serverHandle)
					positions[i] = handle and kind.at(handle) or nil
				end
				for c = 1, width do
					local component = components[c]
					local bucket = component.of(kind)
					local value, slot = bucket.value, bucket.slot
					local reader = readers[c]
					for i = 1, count do
						local v
						v, at = reader(b, at)
						local n = positions[i]
						if stale[i] then
							continue
						elseif n then
							if not slot then
								value[n] = v
							else
								local m = if n <= (bucket.cap :: number) then buffer.readu32(slot, (n - 1) * 4) else 0
								if m ~= 0 then
									value[m] = v
								else
									component.add(kind, n, v)
								end
							end
							self.applied += 1
						else
							local held = waiting[handles[i]]
							if not held then
								held = {}
								waiting[handles[i]] = held
								self.waiting += 1
							end
							held[c] = v
						end
					end
				end
			end
			table.clear(pending)
		end,
	}
	return self
end
