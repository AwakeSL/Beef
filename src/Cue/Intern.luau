--!strict
--!optimize 2

local Intern = {}
Intern.__index = Intern

export type SetEntry = { id: number, count: number }
export type SetInfo = {
	id: number,
	entries: { SetEntry },
	anchorBits: { [number]: { number } },
	primBits: { [number]: { number } },
}

function Intern.new()
	local self = setmetatable({}, Intern)
	self.subs = {} :: { [number]: any }
	self.subCount = 0
	self.sets = {} :: { [number]: SetInfo }
	self.setByKey = {} :: { [string]: number }
	self.setCount = 0
	self.grantEdges = {} :: { [number]: { [number]: number } }
	self.revokeEdges = {} :: { [number]: { [number]: number } }
	self.stats = {
		setsInterned = 0,
		edgeHits = 0,
		edgeMisses = 0,
		mintedSubs = 0,
	}
	return self
end

export type Intern = typeof(Intern.new())

function Intern.addSub(self: Intern, sub: any): number
	self.subCount += 1
	local id = self.subCount
	local held = table.clone(sub)
	held.id = id
	self.subs[id] = table.freeze(held)
	return id
end

function Intern.sub(self: Intern, id: number): any
	return self.subs[id]
end

local function keyOf(entries: { SetEntry }): string
	local parts = table.create(#entries)
	for i, e in entries do
		parts[i] = ("%d*%d"):format(e.id, e.count)
	end
	return table.concat(parts, ",")
end

local function checkStageCollisions(self: Intern, entries: { SetEntry }, key: string)
	local byPrimKeyStage: { [string]: { class: string, site: string } } = {}
	for _, e in entries do
		local sub = self.subs[e.id]
		if sub.kind ~= "transform" then
			continue
		end
		for rewriteKey in sub.rewrites :: { [string]: any } do
			local slot = ("%s|%s|%s"):format(sub.prim :: string, rewriteKey, tostring(sub.stage))
			local seen = byPrimKeyStage[slot]
			local class = sub.rewriteClass[rewriteKey] :: string
			if seen ~= nil then
				if seen.class ~= class or class == "opaque" then
					error(("[cue] interning %q: %q and %q both rewrite %q at stage %d and do not commute; "
						.. "give one a different stage"):format(
						key, seen.site, sub.site :: string, rewriteKey, sub.stage :: number), 0)
				end
			else
				byPrimKeyStage[slot] = { class = class, site = sub.site :: string }
			end
		end
	end
end

function Intern.intern(self: Intern, entries: { SetEntry }): number
	local sorted = table.clone(entries)
	table.sort(sorted, function(a, b)
		return a.id < b.id
	end)
	local key = keyOf(sorted)
	local existing = self.setByKey[key]
	if existing ~= nil then
		return existing
	end
	checkStageCollisions(self, sorted, key)
	self.setCount += 1
	local id = self.setCount
	local anchorBits: { [number]: { number } } = {}
	local primBits: { [number]: { number } } = {}
	for _, e in sorted do
		local sub = self.subs[e.id]
		if sub.kind == "reaction" then
			for bit in sub.anchorBits :: { [number]: boolean } do
				local list = anchorBits[bit]
				if list == nil then
					list = {}
					anchorBits[bit] = list
				end
				for _ = 1, e.count do
					table.insert(list, e.id)
				end
			end
		else
			local bit = sub.primBit :: number
			local list = primBits[bit]
			if list == nil then
				list = {}
				primBits[bit] = list
			end
			for _ = 1, e.count do
				table.insert(list, e.id)
			end
		end
	end
	local info: SetInfo = table.freeze({
		id = id,
		entries = table.freeze(sorted),
		anchorBits = table.freeze(anchorBits),
		primBits = table.freeze(primBits),
	}) :: any
	self.sets[id] = info
	self.setByKey[key] = id
	self.stats.setsInterned += 1
	return id
end

function Intern.info(self: Intern, setId: number): SetInfo?
	return self.sets[setId]
end

local function shifted(self: Intern, setId: number, subId: number, delta: number): number
	local entries: { SetEntry } = if setId == 0 then {} else table.clone(self.sets[setId].entries) :: any
	local found = false
	for i, e in entries do
		if e.id == subId then
			local count = e.count + delta
			if count <= 0 then
				table.remove(entries, i)
			else
				entries[i] = { id = subId, count = count }
			end
			found = true
			break
		end
	end
	if not found then
		if delta < 0 then
			return setId
		end
		table.insert(entries, { id = subId, count = delta })
	end
	if #entries == 0 then
		return 0
	end
	return Intern.intern(self, entries)
end

local function edgeWalk(self: Intern, edges: { [number]: { [number]: number } }, setId: number, subId: number, delta: number): number
	local fromSet = edges[setId]
	if fromSet == nil then
		fromSet = {}
		edges[setId] = fromSet
	end
	local cached = fromSet[subId]
	if cached ~= nil then
		self.stats.edgeHits += 1
		return cached
	end
	self.stats.edgeMisses += 1
	local result = shifted(self, setId, subId, delta)
	fromSet[subId] = result
	return result
end

function Intern.grant(self: Intern, setId: number, subId: number): number
	return edgeWalk(self, self.grantEdges, setId, subId, 1)
end

function Intern.revoke(self: Intern, setId: number, subId: number): number
	return edgeWalk(self, self.revokeEdges, setId, subId, -1)
end

return Intern
