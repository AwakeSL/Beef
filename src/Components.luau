--!strict
--!optimize 2

-- a required component's bucket is the kind's column: value[n] at position n, no slot
-- an optional component's bucket is packed: slot maps position to index, 0 when absent
export type Bucket<T> = {
	value: { T },
	has: { number },
	slot: buffer?,
	count: number?,
	cap: number?,
	bits: buffer?,
	component: any?,
}

export type Component<T> = {
	name: string,
	of: (kind: any) -> Bucket<T>,
	add: (kind: any, n: number, value: T) -> (),
	remove: (kind: any, n: number) -> (),
	get: (kind: any, n: number) -> T?,
	has: (kind: any, n: number) -> boolean,
	find: (value: T) -> (any, number?),
	intersect: (kind: any, out: { number }, ...any) -> number,
	join: (kind: any, ...any) -> (number, ...any),
	groups: { any }?,
	on: { any },
	kinds: () -> { any },
	each: () -> (() -> (any, number?)),
	dense: { [any]: { T } },
	sparse: { [any]: Bucket<T> },
	indexed: boolean,
	bits: boolean,
	ref: boolean,
	watch: boolean,
	wire: string?,
}

export type Options = {
	index: boolean?,
	bits: boolean?,
	ref: boolean?,
	watch: boolean?,
	wire: string?,
}

local Component = {}

-- wraps a component so intersect treats it as "must not have"
local WITHOUT = {}
function Component.without(component: any)
	return { [WITHOUT] = component }
end

local WORD = 4
local FIRST_WORDS = 32

local function setBit(bits: buffer, n: number)
	local at = ((n - 1) // 32) * WORD
	buffer.writeu32(bits, at, bit32.bor(buffer.readu32(bits, at), bit32.lshift(1, (n - 1) % 32)))
end

local function clearBit(bits: buffer, n: number)
	local at = ((n - 1) // 32) * WORD
	buffer.writeu32(bits, at, bit32.band(buffer.readu32(bits, at), bit32.bnot(bit32.lshift(1, (n - 1) % 32))))
end

local function grown(bits: buffer, n: number): buffer
	local words = buffer.len(bits) // WORD
	if (n - 1) // 32 < words then
		return bits
	end
	while (n - 1) // 32 >= words do
		words *= 2
	end
	local bigger = buffer.create(words * WORD)
	buffer.copy(bigger, 0, bits)
	return bigger
end

function Component.new<T>(name: string, options: Options?): Component<T>
	local indexed = options ~= nil and options.index == true
	local withBits = options ~= nil and options.bits == true
	local ref = options ~= nil and options.ref == true
	local watch = options ~= nil and options.watch == true
	assert(not watch or indexed, name .. ": watch needs index, the entity is found through the reverse table")
	local connections: { [any]: RBXScriptConnection } = {}
	local reverseKind: { [any]: any } = {}
	local reversePosition: { [any]: number } = {}

	local self = {
		name = name,
		dense = {},
		sparse = {},
		groups = nil,
		on = {},
		indexed = indexed,
		bits = withBits,
		ref = ref or indexed,
		watch = watch,
		wire = options and options.wire or nil,
	} :: any

	local function watching(value: any)
		if not watch then
			return
		end
		connections[value] = value.Destroying:Connect(function()
			local kind, handle = self.find(value)
			if handle then
				kind.despawn(handle)
			end
		end)
	end

	local function unwatching(value: any)
		if not watch then
			return
		end
		local connection = connections[value]
		if connection then
			connection:Disconnect()
			connections[value] = nil
		end
	end

	local denseBuckets: { [any]: Bucket<T> } = {}

	local function sparseOf(kind: any): Bucket<T>
		local bucket = self.sparse[kind]
		if not bucket then
			local cap = math.max(64, kind.count)
			bucket = { value = {}, has = {}, slot = buffer.create(cap * 4), cap = cap, count = 0, component = self }
			if withBits then
				bucket.bits = buffer.create(FIRST_WORDS * WORD)
			end
			self.sparse[kind] = bucket
			table.insert(kind.optional, self)
			table.insert(self.on, kind)
		end
		return bucket
	end

	-- reading never creates: a kind that does not carry this component gets the shared empty bucket
	local empty: Bucket<T> = { value = {}, has = {}, slot = buffer.create(0), cap = 0, count = 0 }

	self.of = function(kind: any): Bucket<T>
		local bucket = denseBuckets[kind]
		if bucket then
			return bucket
		end
		local column = self.dense[kind]
		if column then
			bucket = { value = column, has = kind.has }
			denseBuckets[kind] = bucket
			return bucket
		end
		return self.sparse[kind] or empty
	end

	self.add = function(kind: any, n: number, value: T)
		local column = self.dense[kind]
		if column then
			if indexed then
				local old = column[n]
				if old ~= nil then
					reverseKind[old] = nil
					reversePosition[old] = nil
					unwatching(old)
				end
				reverseKind[value] = kind
				reversePosition[value] = n
				watching(value)
			end
			column[n] = value
			return
		end
		local bucket = sparseOf(kind)
		local m = n <= bucket.cap and buffer.readu32(bucket.slot, (n - 1) * 4) or 0
		if m ~= 0 then
			if indexed then
				local old = bucket.value[m]
				reverseKind[old] = nil
				reversePosition[old] = nil
				unwatching(old)
				reverseKind[value] = kind
				reversePosition[value] = n
				watching(value)
			end
			bucket.value[m] = value
			return
		end
		m = bucket.count + 1
		bucket.count = m
		bucket.has[m] = n
		bucket.value[m] = value
		if n > bucket.cap then
			local cap = bucket.cap
			repeat
				cap *= 2
			until n <= cap
			local bigger = buffer.create(cap * 4)
			buffer.copy(bigger, 0, bucket.slot)
			bucket.slot = bigger
			bucket.cap = cap
		end
		buffer.writeu32(bucket.slot, (n - 1) * 4, m)
		local list = kind.attached[n]
		if not list then
			list = {}
			kind.attached[n] = list
		end
		list[#list + 1] = bucket
		if withBits then
			local bits = grown(bucket.bits :: buffer, n)
			bucket.bits = bits
			setBit(bits, n)
		end
		if indexed then
			reverseKind[value] = kind
			reversePosition[value] = n
			watching(value)
		end
		local groups = self.groups
		if groups then
			for g = 1, #groups do
				local group = groups[g]
				local perKind = group.buckets[kind]
				if not perKind then
					perKind = {}
					group.buckets[kind] = perKind
				end
				local list = perKind[self]
				if not list then
					list = {}
					for _, other in group.others[self] do
						table.insert(list, other.of(kind))
					end
					perKind[self] = list
				end
				local all = true
				for i = 1, #list do
					local b = list[i]
					local slot = b.slot
					if slot then
						if n > b.cap or buffer.readu32(slot, (n - 1) * 4) == 0 then
							all = false
							break
						end
					elseif b.value[n] == nil then
						all = false
						break
					end
				end
				if all then
					group.add(kind, n, true)
				end
			end
		end
	end

	self.remove = function(kind: any, n: number)
		local column = self.dense[kind]
		if column then
			local old = column[n]
			if old ~= nil and indexed then
				reverseKind[old] = nil
				reversePosition[old] = nil
				unwatching(old)
			end
			column[n] = nil
			return
		end
		local bucket = self.sparse[kind]
		if not bucket then
			return
		end
		local m = n <= bucket.cap and buffer.readu32(bucket.slot, (n - 1) * 4) or 0
		if m == 0 then
			return
		end
		if indexed then
			local old = bucket.value[m]
			reverseKind[old] = nil
			reversePosition[old] = nil
			unwatching(old)
		end
		local has, value = bucket.has, bucket.value
		local last = bucket.count
		bucket.count = last - 1
		local movedN = has[last]
		has[m] = movedN
		value[m] = value[last]
		buffer.writeu32(bucket.slot, (movedN - 1) * 4, m)
		has[last] = nil
		value[last] = nil
		buffer.writeu32(bucket.slot, (n - 1) * 4, 0)
		if withBits then
			clearBit(bucket.bits :: buffer, n)
		end
		local list = kind.attached[n]
		local count = #list
		for i = 1, count do
			if list[i] == bucket then
				list[i] = list[count]
				list[count] = nil
				break
			end
		end
		local groups = self.groups
		if groups then
			for g = 1, #groups do
				groups[g].remove(kind, n)
			end
		end
	end

	self.get = function(kind: any, n: number): T?
		local column = self.dense[kind]
		if column then
			return column[n]
		end
		local bucket = self.sparse[kind]
		if not bucket then
			return nil
		end
		local m = n <= bucket.cap and buffer.readu32(bucket.slot, (n - 1) * 4) or 0
		if m == 0 then
			return nil
		end
		return bucket.value[m]
	end

	self.has = function(kind: any, n: number): boolean
		local column = self.dense[kind]
		if column then
			return column[n] ~= nil
		end
		local bucket = self.sparse[kind]
		if not bucket then
			return false
		end
		return n <= bucket.cap and buffer.readu32(bucket.slot, (n - 1) * 4) ~= 0
	end

	-- every kind this component is on, in the order they took it
	self.kinds = function(): { any }
		return self.on
	end

	-- kind and position of every entity holding it, one call per entity; the nested loop over kinds() and of(kind).has is the fast form
	self.each = function(): () -> (any, number?)
		local list = self.kinds()
		local k, m, kind, has = 0, 0, nil, nil
		return function()
			while true do
				if has and m < #has then
					m += 1
					return kind, has[m]
				end
				k += 1
				kind = list[k]
				if not kind then
					return nil
				end
				has = self.of(kind).has
				m = 0
			end
		end
	end

	-- the entities on this kind holding this and every other given component, with each component's value array and an
	-- index list into it, all in the same order: returns n, valuesA, indexA, valuesB, indexB, ...
	-- on a kind where a component is required its index list is the kind's own positions, no copying
	local joinOut: { number } = {}
	local joinIndex: { { number } } = {}
	local joinRets: { any } = {}
	self.join = function(kind: any, ...: any)
		local n = self.intersect(kind, joinOut, ...)
		local k = 1 + select("#", ...)
		for c = 1, k do
			local component = if c == 1 then self else select(c - 1, ...)
			local column = component.dense[kind]
			if column then
				joinRets[c * 2 - 1] = column
				joinRets[c * 2] = if n == kind.count then kind.has else joinOut
			else
				local bucket = component.sparse[kind]
				local index = joinIndex[c]
				if not index then
					index = {}
					joinIndex[c] = index
				end
				local slot = bucket.slot
				for i = 1, n do
					index[i] = buffer.readu32(slot, (joinOut[i] - 1) * 4)
				end
				joinRets[c * 2 - 1] = bucket.value
				joinRets[c * 2] = index
			end
		end
		return n, table.unpack(joinRets, 1, k * 2)
	end

	self.find = function(value: T): (any, number?)
		local kind = reverseKind[value]
		if not kind then
			return nil, nil
		end
		return kind, kind.handle[reversePosition[value]]
	end

	self.reindex = function(value: T, n: number)
		reversePosition[value] = n
	end

	self.rekey = function(kind: any, from: number, to: number)
		local bucket = self.sparse[kind]
		local m = from <= bucket.cap and buffer.readu32(bucket.slot, (from - 1) * 4) or 0
		if m == 0 then
			return
		end
		bucket.has[m] = to
		buffer.writeu32(bucket.slot, (to - 1) * 4, m)
		buffer.writeu32(bucket.slot, (from - 1) * 4, 0)
		if withBits then
			local bits = grown(bucket.bits :: buffer, to)
			bucket.bits = bits
			clearBit(bits, from)
			setBit(bits, to)
		end
		if indexed then
			reversePosition[bucket.value[m]] = to
		end
	end

	-- positions on this kind holding this component and every other given one, written into out; returns how many
	-- required members cost nothing, the shortest optional list drives the walk, and the bitmap takes over when every
	-- optional member has bits and the shortest list is still a large share of the kind
	local walkers: { any } = {}
	local otherSlots: { buffer } = {}
	local otherCaps: { number } = {}
	local excluded: { any } = {}
	self.intersect = function(kind: any, out: { number }, ...: any): number
		local count = kind.count
		table.clear(walkers)
		table.clear(excluded)
		local allBits = true
		local smallest = nil
		local function consider(component: any): boolean
			if component.dense[kind] then
				return true
			end
			local bucket = component.sparse[kind]
			if not bucket then
				return false
			end
			table.insert(walkers, bucket)
			if not bucket.bits then
				allBits = false
			end
			if not smallest or bucket.count < smallest.count then
				smallest = bucket
			end
			return true
		end
		if not consider(self) then
			table.clear(out)
			return 0
		end
		for i = 1, select("#", ...) do
			local given = select(i, ...)
			local barred = given[WITHOUT]
			if barred then
				if barred.dense[kind] then
					-- every entity here has it: nothing qualifies
					table.clear(out)
					return 0
				end
				local bucket = barred.sparse[kind]
				if bucket and bucket.count > 0 then
					table.insert(excluded, bucket)
				end
			elseif not consider(given) then
				table.clear(out)
				return 0
			end
		end
		local n = 0
		if #excluded > 0 then
			-- exclusions: walk the positives (or the whole kind), drop anything a barred bucket holds
			local candidates, total
			if smallest then
				candidates, total = smallest.has, smallest.count
			else
				candidates, total = kind.has, count
			end
			local others = 0
			for _, bucket in walkers do
				if bucket ~= smallest then
					others += 1
					otherSlots[others] = bucket.slot
					otherCaps[others] = bucket.cap
				end
			end
			for m = 1, total do
				local p = candidates[m]
				local ok = true
				for i = 1, others do
					if p > otherCaps[i] or buffer.readu32(otherSlots[i], (p - 1) * 4) == 0 then
						ok = false
						break
					end
				end
				if ok then
					for _, bucket in excluded do
						if p <= bucket.cap and buffer.readu32(bucket.slot, (p - 1) * 4) ~= 0 then
							ok = false
							break
						end
					end
				end
				if ok then
					n += 1
					out[n] = p
				end
			end
			for i = #out, n + 1, -1 do
				out[i] = nil
			end
			return n
		end
		if not smallest then
			-- every member is required here: the whole kind
			for i = 1, count do
				out[i] = i
			end
			n = count
		elseif allBits and #walkers > 1 and smallest.count * 8 > count then
			local words = math.huge
			for _, bucket in walkers do
				words = math.min(words, buffer.len(bucket.bits :: buffer) // WORD)
			end
			local first = walkers[1].bits :: buffer
			for w = 0, words - 1 do
				local at = w * WORD
				local word = buffer.readu32(first, at)
				for i = 2, #walkers do
					if word == 0 then
						break
					end
					word = bit32.band(word, buffer.readu32(walkers[i].bits :: buffer, at))
				end
				while word ~= 0 do
					local bit = bit32.countrz(word)
					n += 1
					out[n] = w * 32 + bit + 1
					word = bit32.band(word, word - 1)
				end
			end
		else
			local has = smallest.has
			local others = 0
			for _, bucket in walkers do
				if bucket ~= smallest then
					others += 1
					otherSlots[others] = bucket.slot
					otherCaps[others] = bucket.cap
				end
			end
			if others == 0 then
				-- one optional member, the rest required: its whole list
				table.move(has, 1, smallest.count, 1, out)
				n = smallest.count
			elseif others == 1 then
				local slot, cap = otherSlots[1], otherCaps[1]
				for m = 1, smallest.count do
					local p = has[m]
					if p <= cap and buffer.readu32(slot, (p - 1) * 4) ~= 0 then
						n += 1
						out[n] = p
					end
				end
			else
				for m = 1, smallest.count do
					local p = has[m]
					local all = true
					for i = 1, others do
						if p > otherCaps[i] or buffer.readu32(otherSlots[i], (p - 1) * 4) == 0 then
							all = false
							break
						end
					end
					if all then
						n += 1
						out[n] = p
					end
				end
			end
		end
		for i = #out, n + 1, -1 do
			out[i] = nil
		end
		return n
	end

	return self :: Component<T>
end

-- a group is a component with no value of its own: an entity is in it while it holds every member
function Component.group(name: string, ...: any): Component<boolean>
	local members = { ... }
	assert(#members >= 2, name .. ": a group needs at least two members")
	local group = Component.new(name) :: any
	group.members = members
	group.others = {}
	group.buckets = {}
	for _, member in members do
		local others = {}
		for _, m in members do
			if m ~= member then
				table.insert(others, m)
			end
		end
		group.others[member] = others
		member.groups = member.groups or {}
		table.insert(member.groups, group)
	end
	-- the kinds carrying every member, in the first member's order
	local carrying = {}
	group.kinds = function(): { any }
		table.clear(carrying)
		for _, kind in members[1].on do
			local all = true
			for i = 2, #members do
				local member = members[i]
				if not member.dense[kind] and not member.sparse[kind] then
					all = false
					break
				end
			end
			if all then
				table.insert(carrying, kind)
			end
		end
		return carrying
	end

	-- on a kind that requires every member, every entity is in the group: hand back the kind's own positions
	local sparseOf = group.of
	local wholeKind = {}
	group.of = function(kind: any)
		local bucket = wholeKind[kind]
		if bucket then
			return bucket
		end
		for _, member in members do
			if not member.dense[kind] then
				return sparseOf(kind)
			end
		end
		bucket = { value = kind.has, has = kind.has }
		wholeKind[kind] = bucket
		return bucket
	end
	return group
end

return Component
