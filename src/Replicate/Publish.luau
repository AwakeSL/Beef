--!strict
--!optimize 2
-- the packing end of a published kind: whose column values changed this frame, packed with the server clock and
-- the handles they belong to. A payload is the stamp, whether it is a full sweep, how many entities are in it,
-- then the handles and then each column, so the other side reads a column without touching the rest.
-- Someone who just arrived is sent every entity once, whatever changed, because they have none of them yet.

local Wire = require(script.Parent.Parent.Wire)
local Remotes = require(script.Parent.Remotes)

type Kind = { name: string, count: number, handle: { number } }
type Component = { name: string, wire: string?, of: (Kind) -> { value: { any } } }

export type Options = { every: number?, channel: ("reliable" | "unreliable")?, keyframe: number?, chunk: number?, origin: any? }

local HEADER = 8 + 1 + 4
local UNRELIABLE = 900

return function(linkName: string, link: Remotes.Link, driver: Remotes.Driver, kind: Kind, components: { Component }, options: Options)
	local width = #components
	assert(width > 0, ("Publish %s: %s has no columns to publish"):format(linkName, kind.name))
	local every = options.every or 1
	local unreliable = options.channel == "unreliable"
	local keyframe = options.keyframe or 60

	-- one entity's handle and then one value per column, the same bytes every time
	local perEntity = 4
	local writers = {}
	for i, component in components do
		local wire = component.wire
		assert(wire, ("Publish %s: component %s has no wire type"):format(linkName, component.name))
		assert(
			wire ~= "string" and wire ~= "kind" and Wire.known(wire),
			("Publish %s: component %s cannot publish as %s"):format(linkName, component.name, wire)
		)
		perEntity += Wire.sizeOf(wire, nil)
		writers[i] = Wire.write[wire]
	end
	local chunk = options.chunk or (if unreliable then math.floor((UNRELIABLE - HEADER) / perEntity) else math.huge)

	local lastSent: { { [number]: any } } = {}
	for i = 1, width do
		lastSent[i] = {}
	end

	local laps = 0
	local publishes = 0
	local joining: { any } = {}
	driver.joining(function(who: any)
		table.insert(joining, who)
	end)

	local outHandles: { number } = {}
	local outPositions: { number } = {}

	local function pack(now: number, full: boolean, first: number, last: number, columns: { { any } }): buffer
		local n = last - first + 1
		local b = buffer.create(HEADER + n * perEntity)
		buffer.writef64(b, 0, now)
		buffer.writeu8(b, 8, if full then 1 else 0)
		buffer.writeu32(b, 9, n)
		local at = HEADER
		for i = first, last do
			buffer.writeu32(b, at, outHandles[i])
			at += 4
		end
		for c = 1, width do
			local writer = writers[c]
			local values = columns[c]
			for i = first, last do
				at = writer(b, at, values[outPositions[i]])
			end
		end
		return b
	end

	local self: { [string]: any }
	self = {
		name = "Publish",
		link = linkName,
		sent = 0,
		entities = 0,
		bytes = 0,
		post = function()
			local columns: { { any } } = {}
			for i = 1, width do
				columns[i] = components[i].of(kind).value
			end
			local handles = kind.handle

			if #joining > 0 then
				local count = kind.count
				for position = 1, count do
					outHandles[position] = handles[position]
					outPositions[position] = position
				end
				local now = driver.now()
				local start = 1
				repeat
					local stop = math.min(start + chunk - 1, count)
					local full = pack(now, true, start, math.max(stop, start - 1), columns)
					for _, who in joining do
						link.send(full, who)
						self.sent += 1
						self.bytes += buffer.len(full)
					end
					start = stop + 1
				until start > count
				table.clear(joining)
			end

			laps += 1
			if laps % every ~= 0 then
				return
			end
			publishes += 1
			local all = unreliable and publishes % keyframe == 0
			local now = driver.now()

			local n = 0
			for position = 1, kind.count do
				local handle = handles[position]
				local changed = all
				if not changed then
					for i = 1, width do
						if lastSent[i][handle] ~= columns[i][position] then
							changed = true
							break
						end
					end
				end
				if changed then
					n += 1
					outHandles[n] = handle
					outPositions[n] = position
					for i = 1, width do
						lastSent[i][handle] = columns[i][position]
					end
				end
			end
			self.entities += n
			if n == 0 then
				-- nothing moved: there is nothing to say, so nothing is sent
				return
			end

			local start = 1
			repeat
				local stop = math.min(start + chunk - 1, n)
				local b = pack(now, false, start, math.max(stop, start - 1), columns)
				link.send(b)
				self.sent += 1
				self.bytes += buffer.len(b)
				start = stop + 1
			until start > n
		end,
	}
	return self
end
