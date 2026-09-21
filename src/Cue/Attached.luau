--!strict
--!optimize 2

-- The one number cue keeps per entity, as a Beef component: the interned set of everything the
-- entity carries. Any kind with content takes it, so it is optional everywhere and costs a kind
-- that has no content nothing at all.

local Components = require(script.Parent.Parent.Components)
local Entity = require(script.Parent.Entity)

local component = Components.new("cue")

local Attached = {}

Attached.component = component

-- the set the entity holds, or nil when it holds none, or when it is already gone
function Attached.held(e: number): number?
	local kind, n = Entity.at(e)
	if n == nil then
		return nil
	end
	return component.get(kind, n :: number)
end

-- a set of 0 is no set at all, so the column drops the entity rather than carrying a zero
function Attached.hold(e: number, setId: number)
	local kind, n = Entity.at(e)
	if n == nil then
		return
	end
	if setId == 0 then
		component.remove(kind, n :: number)
	else
		component.add(kind, n :: number, setId)
	end
end

return Attached
