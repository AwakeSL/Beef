--!strict
--!optimize 2

local Events = require(script.Parent.Events)

export type Options = {
	history: number?,
}

export type Kind = {
	name: string,
	count: number,
	has: { number },
	handle: { number },
	required: { any },
	optional: { any },
	attached: { { any } },
	spawn: (...any) -> number,
	despawn: (handle: number) -> (),
	at: (handle: number) -> number?,
	dying: (handle: number) -> number?,
	apply: () -> number,
	history: number?,
	tick: ((time: number) -> ())?,
	track: ((component: any) -> number)?,
	around: ((handle: number, time: number) -> (number?, { { any } }?, number?, { { any } }?, number?))?,
	rewind: ((handle: number, time: number) -> number?)?,
}

local TRIM_FRACTION = 0.25
local TRIM_FLOOR = 256

local all: { Kind } = {}

local Kinds = {}

Kinds.named = {} :: { [string]: Kind }

Kinds.died = Events.new("died", "kind:kind", "handle:u32")
local died = Kinds.died

function Kinds.new(name: string, ...: any): Kind
	local required = { ... }
	local options = nil
	if type(required[#required]) == "table" and required[#required].name == nil then
		options = table.remove(required)
	end
	local width = #required
	local columns: { { any } } = {}
	local isIndexed: { boolean } = {}
	local positionOf: { [number]: number } = {}
	local doomed: { number } = {}
	local doomedAt: { boolean } = table.create(256)
	local doomedCap = 256
	local dyingOf: { [number]: number } = {}
	local refColumns: { { any } } = {}
	local highWater = 0
	local nextId = 0

	local self = {
		name = name,
		count = 0,
		has = {},
		handle = {},
		required = required,
		optional = {},
		attached = {},
	} :: any

	for i, component in required do
		local column = {}
		columns[i] = column
		isIndexed[i] = component.indexed
		if component.ref then
			table.insert(refColumns, column)
		end
		component.dense[self] = column
		table.insert(component.on, self)
	end

	local has, handles, attached = self.has, self.handle, self.attached

	local anyIndexed = false
	for i = 1, width do
		if isIndexed[i] then
			anyIndexed = true
		end
	end

	self.spawn = function(a: any, b: any, c: any, ...: any): number
		local n = self.count + 1
		nextId += 1
		has[n] = n
		handles[n] = nextId
		positionOf[nextId] = n
		self.count = n
		if n > highWater then
			highWater = n
			if n > doomedCap then
				doomedCap *= 2
				local bigger = table.create(doomedCap)
				table.move(doomedAt, 1, n - 1, 1, bigger)
				doomedAt = bigger
			end
		end
		if anyIndexed or width > 3 then
			local values = { a, b, c, ... }
			for i = 1, width do
				if isIndexed[i] then
					required[i].add(self, n, values[i])
				else
					columns[i][n] = values[i]
				end
			end
		else
			if width >= 1 then
				columns[1][n] = a
			end
			if width >= 2 then
				columns[2][n] = b
			end
			if width == 3 then
				columns[3][n] = c
			end
		end
		return nextId
	end

	self.at = function(handle: number): number?
		return positionOf[handle]
	end

	self.despawn = function(handle: number)
		local n = positionOf[handle]
		if not n then
			return
		end
		positionOf[handle] = nil
		dyingOf[handle] = n
		doomed[#doomed + 1] = n
		died.push(self, handle)
	end

	self.dying = function(handle: number): number?
		return dyingOf[handle]
	end

	local function removeAt(n: number)
		local last = self.count
		local mine = attached[n]
		if mine then
			for i = #mine, 1, -1 do
				local bucket = mine[i]
				local component = bucket.component
				if component.indexed then
					component.remove(self, n)
				else
					local has, value, slot = bucket.has, bucket.value, bucket.slot
					local m = buffer.readu32(slot, (n - 1) * 4)
					local lastM = bucket.count
					bucket.count = lastM - 1
					local movedN = has[lastM]
					has[m] = movedN
					value[m] = value[lastM]
					buffer.writeu32(slot, (movedN - 1) * 4, m)
					has[lastM] = nil
					value[lastM] = nil
					buffer.writeu32(slot, (n - 1) * 4, 0)
					local bits = bucket.bits
					if bits then
						local at = ((n - 1) // 32) * 4
						buffer.writeu32(bits, at, bit32.band(buffer.readu32(bits, at), bit32.bnot(bit32.lshift(1, (n - 1) % 32))))
					end
					local groups = component.groups
					if groups then
						for g = 1, #groups do
							groups[g].remove(self, n)
						end
					end
				end
			end
			attached[n] = nil
		end
		for i = 1, width do
			if isIndexed[i] then
				required[i].remove(self, n)
			end
		end
		if n ~= last then
			for i = 1, width do
				local column = columns[i]
				column[n] = column[last]
				if isIndexed[i] then
					required[i].reindex(column[n], n)
				end
			end
			local theirs = attached[last]
			if theirs then
				attached[n] = theirs
				attached[last] = nil
				for _, bucket in theirs do
					local component = bucket.component
					if component.indexed or bucket.bits then
						component.rekey(self, last, n)
					else
						local slot = bucket.slot
						local m = buffer.readu32(slot, (last - 1) * 4)
						bucket.has[m] = n
						buffer.writeu32(slot, (n - 1) * 4, m)
						buffer.writeu32(slot, (last - 1) * 4, 0)
					end
				end
			end
			local moved = handles[last]
			handles[n] = moved
			positionOf[moved] = n
		end
		has[last] = nil
		handles[last] = nil
		self.count = last - 1
	end

	self.apply = function(): number
		local pending = #doomed
		if pending == 0 then
			return 0
		end
		for i = 1, pending do
			doomedAt[doomed[i]] = true
		end
		for i = 1, pending do
			local n = doomed[i]
			if not doomedAt[n] then
				continue
			end
			-- pop doomed entities off the tail first so the swap never brings a doomed one forward
			local count = self.count
			while count > 0 and doomedAt[count] and count ~= n do
				doomedAt[count] = nil
				removeAt(count)
				count -= 1
			end
			if doomedAt[n] then
				doomedAt[n] = nil
				removeAt(n)
			end
		end
		table.clear(doomed)
		table.clear(dyingOf)
		local count = self.count
		local stale = highWater - count
		if stale > TRIM_FLOOR and stale > count * TRIM_FRACTION then
			for _, column in refColumns do
				for slot = count + 1, highWater do
					column[slot] = nil
				end
			end
			highWater = count
		end
		return pending
	end

	-- history: a ring of snapshots of the wired required columns, taken only when the caller ticks
	local history = options and options.history
	if history then
		local tracked: { { any } } = {}
		local trackOf: { [any]: number } = {}
		for i, component in required do
			if component.wire then
				table.insert(tracked, columns[i])
				trackOf[component] = #tracked
			end
		end
		assert(#tracked > 0, name .. ": history needs at least one required component with a wire type")
		local slots = {}
		for s = 1, history do
			local slot = { time = -math.huge, count = 0, built = false, handle = {}, column = {}, index = {} }
			for i = 1, #tracked do
				slot.column[i] = {}
			end
			slots[s] = slot
		end
		local head = 0
		self.history = history

		-- which column index a component has inside a slot
		self.track = function(component: any): number
			local c = trackOf[component]
			assert(c, name .. ": " .. component.name .. " is not in this kind's history")
			return c
		end

		-- where the entity sits in a slot: usually still at its live position, else through the slot's index
		local function within(slot, handle: number): number?
			local p = positionOf[handle]
			if p and p <= slot.count and slot.handle[p] == handle then
				return p
			end
			local index = slot.index
			if not slot.built then
				table.clear(index)
				local list = slot.handle
				for i = 1, slot.count do
					index[list[i]] = i
				end
				slot.built = true
			end
			return index[handle]
		end

		-- the two snapshots either side of time and where the entity is in each
		-- returns fraction, columnsBefore, indexBefore, columnsAfter, indexAfter; after is nil when time is at or past the newest
		self.around = function(handle: number, time: number)
			local s = head
			local newer = nil
			for _ = 1, history do
				local slot = slots[s]
				if slot.time <= time then
					local i = within(slot, handle)
					if not i then
						return nil
					end
					if not newer then
						return 0, slot.column, i, nil, nil
					end
					local j = within(newer, handle)
					if not j then
						return 0, slot.column, i, nil, nil
					end
					local span = newer.time - slot.time
					local f = if span > 0 then (time - slot.time) / span else 0
					return f, slot.column, i, newer.column, j
				end
				newer = slot
				s = (s - 2) % history + 1
			end
			return nil
		end

		-- put one entity's tracked values back to the newest snapshot at or before time; returns that snapshot's time
		self.rewind = function(handle: number, time: number): number?
			local n = positionOf[handle]
			if not n then
				return nil
			end
			local s = head
			for _ = 1, history do
				local slot = slots[s]
				if slot.time <= time then
					local i = within(slot, handle)
					if not i then
						return nil
					end
					for c, column in tracked do
						column[n] = slot.column[c][i]
					end
					return slot.time
				end
				s = (s - 2) % history + 1
			end
			return nil
		end

		self.tick = function(time: number)
			head = head % history + 1
			local slot = slots[head]
			local count = self.count
			slot.time = time
			slot.count = count
			slot.built = false
			table.move(handles, 1, count, 1, slot.handle)
			for i, column in tracked do
				table.move(column, 1, count, 1, slot.column[i])
			end
		end
	end

	table.insert(all, self)
	Kinds.named[name] = self
	return self :: Kind
end

-- every kind carrying all of the given components, required or optional; fills out and returns the count
function Kinds.with(out: { Kind }, ...: any): number
	local count = 0
	for _, kind in all do
		local carries = true
		for i = 1, select("#", ...) do
			local component = select(i, ...)
			if not component.dense[kind] and not component.sparse[kind] then
				carries = false
				break
			end
		end
		if carries then
			count += 1
			out[count] = kind
		end
	end
	for i = #out, count + 1, -1 do
		out[i] = nil
	end
	return count
end

function Kinds.lap()
	for _, kind in all do
		kind.apply()
	end
end

return Kinds
