--!strict
--!optimize 2
-- the unpacking end of a published kind: what Publish packed lands in the same columns here, found through the
-- entity that carries the sender's handle. A value stamped before one already seen for that entity is refused,
-- so an unreliable payload arriving late does not walk a value backwards. A value for an entity this side has
-- not spawned yet is held, not dropped, and goes in the frame that entity appears.

local Wire = require(script.Parent.Parent.Wire)
local Remotes = require(script.Parent.Remotes)

type Kind = { name: string, at: (number) -> number? }
type Bucket = { value: { any }, slot: buffer?, cap: number? }
type Component = { name: string, wire: string?, of: (Kind) -> Bucket, add: (Kind, number, any) -> () }
type Origin = { find: (number) -> (Kind?, number?) }

local HEADER = 8 + 1 + 4

return function(linkName: string, link: Remotes.Link, kind: Kind, origin: Origin, components: { Component })
	local width = #components
	local readers = {}
	for i, component in components do
		assert(component.wire, ("Apply %s: component %s has no wire type"):format(linkName, component.name))
		readers[i] = Wire.read[component.wire :: string]
	end

	local pending: { buffer } = {}
	link.receive(function(payload: buffer)
		table.insert(pending, payload)
	end)

	local waiting: { [number]: { any } } = {}
	local seen: { [number]: number } = {}
	local handles: { number } = {}
	local positions: { number? } = {}
	local stale: { boolean } = {}

	local self: { [string]: any }
	self = {
		name = "Apply",
		link = linkName,
		time = 0,
		received = 0,
		applied = 0,
		refused = 0,
		waiting = 0,
		bytes = 0,
		pre = function()
			for senderHandle, values in waiting do
				local _, handle = origin.find(senderHandle)
				local n = handle and kind.at(handle)
				if n then
					for c = 1, width do
						components[c].add(kind, n, values[c])
						self.applied += 1
					end
					waiting[senderHandle] = nil
					self.waiting -= 1
				end
			end
			for _, b in pending do
				self.received += 1
				self.bytes += buffer.len(b)
				local time = buffer.readf64(b, 0)
				self.time = time
				local count = buffer.readu32(b, 9)
				local at = HEADER
				for i = 1, count do
					local senderHandle = buffer.readu32(b, at)
					at += 4
					handles[i] = senderHandle
					local last = seen[senderHandle]
					if last and time < last then
						stale[i] = true
						self.refused += 1
					else
						stale[i] = false
						seen[senderHandle] = time
					end
					local _, handle = origin.find(senderHandle)
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
