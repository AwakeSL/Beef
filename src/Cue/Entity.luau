--!strict
--!optimize 2

-- An entity is a Beef handle with its kind folded in. A handle on its own is only unique inside
-- its kind, and cue has to reach a component column from whatever an entity word resolved to, so
-- the kind rides above the handle in the same number: kind slot times 2^32, plus the u32 handle.
-- One number means entities compare by value, which is what transforms, bindings and the columns
-- of a push all want, and unpacking is one floor divide and one modulo.

local SHIFT = 4294967296

local Entity = {}

-- a kind takes its slot the first time cue sees it; slots start at 1 so a bare handle never reads
-- as an entity
local slots: { any } = {}
local slotOf: { [any]: number } = {}

function Entity.of(kind: any, handle: number): number
	local slot = slotOf[kind]
	if slot == nil then
		table.insert(slots, kind)
		slot = #slots
		slotOf[kind] = slot
	end
	return (slot :: number) * SHIFT + handle
end

function Entity.kind(e: number): any
	return slots[e // SHIFT]
end

function Entity.handle(e: number): number
	return e % SHIFT
end

function Entity.is(v: any): boolean
	return type(v) == "number" and v >= SHIFT and slots[v // SHIFT] ~= nil
end

-- the kind and the position the entity sits at right now; the position is nil once it is despawned
function Entity.at(e: number): (any, number?)
	local kind = slots[e // SHIFT]
	if kind == nil then
		return nil, nil
	end
	return kind, kind.at(e % SHIFT)
end

function Entity.alive(e: number): boolean
	local kind = slots[e // SHIFT]
	return kind ~= nil and kind.at(e % SHIFT) ~= nil
end

-- the value of a component column on an entity, or nil when the entity is gone or does not carry it
function Entity.read(e: number, component: any): any?
	local kind = slots[e // SHIFT]
	if kind == nil then
		return nil
	end
	local n = kind.at(e % SHIFT)
	if n == nil then
		return nil
	end
	local column = component.dense[kind]
	if column ~= nil then
		return column[n]
	end
	return component.get(kind, n)
end

return Entity
