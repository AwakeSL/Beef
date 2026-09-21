--!strict
--!optimize 2

local Registry = require(script.Parent.Registry)
local Values = require(script.Parent.Values)
local Intern = require(script.Parent.Intern)

local Compiler = {}
Compiler.__index = Compiler

export type ScheduleEntry = { name: string, kind: string, cv: Values.CV? }
export type Step = { kind: "effect" | "group", effect: CompiledEffect?, effects: { CompiledEffect }? }
export type BranchEntry = { gates: { { name: string, value: any } }, effect: CompiledEffect }
export type CompiledEffect = {
	prim: any,
	keys: { [string]: Values.CV },
	steps: { [string]: { Step } },
	schedule: { ScheduleEntry }?,
	bindAs: string?,
	branch: { BranchEntry }?,
	site: string,
}

local function fail(site: string, message: string): never
	error(("[cue] %s: %s"):format(site, message), 0)
end

function Compiler.new(registry: Registry.Registry, values: Values.Values, intern: Intern.Intern)
	local self = setmetatable({}, Compiler)
	self.registry = registry
	self.values = values
	self.intern = intern
	self.definitions = {} :: { [number]: any }
	self.definitionCount = 0
	return self
end

export type Compiler = typeof(Compiler.new(Registry.new(), Values.new(Registry.new()), Intern.new()))

local compileEffect
local compileSubscriptionRef

local function compileScheduleList(self: Compiler, authored: any, site: string): { ScheduleEntry }
	local reg = self.registry
	if typeof(authored) ~= "table" or #authored == 0 then
		fail(site, "schedule is an ordered list: schedule = { { after = 1 }, ... }")
	end
	local out: { ScheduleEntry } = {}
	for i, entry in authored :: { any } do
		local entrySite = ("%s (schedule step %d)"):format(site, i)
		if typeof(entry) ~= "table" then
			fail(entrySite, "each schedule step is a table with one named key")
		end
		local name: string? = nil
		local value: any = nil
		local count = 0
		for k, v in entry :: { [string]: any } do
			name = k
			value = v
			count += 1
		end
		if count ~= 1 or typeof(name) ~= "string" then
			fail(entrySite, "each schedule step names exactly one schedule key")
		end
		local decl = reg.schedules[name :: string]
		if decl == nil then
			fail(entrySite, ("%q is not a schedule key anybody declared"):format(name :: string))
		end
		local cv: Values.CV? = nil
		if decl.type ~= nil then
			cv = self.values:compile(value, decl.type :: string, entrySite)
		end
		table.insert(out, { name = name :: string, kind = decl.kind, cv = cv, raw = value } :: any)
	end
	return out
end

local function compileSteps(self: Compiler, authored: any, site: string): { Step }
	if typeof(authored) ~= "table" then
		fail(site, "steps are a list")
	end
	local out: { Step } = {}
	for i, entry in authored :: { any } do
		local stepSite = ("%s (step %d)"):format(site, i)
		if typeof(entry) ~= "table" then
			fail(stepSite, "a step is an effect or a group of effects")
		end
		local hasNamed = false
		for k in entry :: { [any]: any } do
			if typeof(k) == "string" then
				hasNamed = true
				break
			end
		end
		if hasNamed then
			table.insert(out, { kind = "effect" :: "effect", effect = compileEffect(self, entry, stepSite, false) })
		else
			local group: { CompiledEffect } = {}
			for j, sub in entry :: { any } do
				table.insert(group, compileEffect(self, sub, ("%s (grouped %d)"):format(stepSite, j), false))
			end
			table.insert(out, { kind = "group" :: "group", effects = table.freeze(group) })
		end
	end
	return out
end

local function compileBranch(self: Compiler, authored: any, site: string): { BranchEntry }
	local reg = self.registry
	if typeof(authored) ~= "table" then
		fail(site, "a branch is a list of effects")
	end
	local out: { BranchEntry } = {}
	for i, entry in authored :: { any } do
		local entrySite = ("%s (branch %d)"):format(site, i)
		if typeof(entry) ~= "table" then
			fail(entrySite, "a branch entry is an effect")
		end
		local gates: { { name: string, value: any } } = {}
		local stripped: { [any]: any } = {}
		for k, v in entry :: { [any]: any } do
			if typeof(k) == "string" and reg.gates[k] ~= nil then
				table.insert(gates, { name = k, value = v })
			else
				stripped[k] = v
			end
		end
		table.insert(out, {
			gates = table.freeze(gates),
			effect = compileEffect(self, stripped, entrySite, false),
		})
	end
	return out
end

compileEffect = function(self: Compiler, authored: { [any]: any }, site: string, allowIt: boolean): CompiledEffect
	local reg = self.registry

	local primName = authored.primitive
	if primName == nil then
		local onlyName: string? = nil
		local onlyValue: any = nil
		local namedCount = 0
		for k, v in authored do
			if typeof(k) == "string" then
				namedCount += 1
				onlyName = k
				onlyValue = v
			end
		end
		if namedCount == 1 and onlyName ~= nil then
			local decl = reg.primitives[onlyName :: string]
			if decl ~= nil and (decl :: any).sugar ~= nil then
				local expanded: { [any]: any } = { primitive = onlyName, [(decl :: any).sugar] = onlyValue }
				return compileEffect(self, expanded, site, allowIt)
			end
		end
		fail(site, "an effect names its primitive")
	end
	local prim = reg.primitives[primName]
	if prim == nil then
		fail(site, ("%q is a primitive nobody declared"):format(tostring(primName)))
	end

	local keys: { [string]: Values.CV } = {}
	local steps: { [string]: { Step } } = {}
	local schedule: { ScheduleEntry }? = nil
	local bareScheduleKey: string? = nil
	local bindAs: string? = nil
	local branch: { BranchEntry }? = nil
	local subIds: { number }? = nil

	for k, v in authored do
		if typeof(k) == "number" then
			if (prim :: any).takesSubs == true then
				local sub = compileSubscriptionRef(self, v, ("%s (subscription %d)"):format(site, k))
				if sub.toWord ~= nil then
					fail(site, "`to` on a granted subscription is the grant's own `to`; say it there")
				end
				subIds = subIds or {}
				table.insert(subIds :: any, self.intern:addSub(sub))
				continue
			end
			fail(site, "an effect has no array part; steps go under the key the primitive declares")
		end
		local key = k :: string
		if key == "primitive" then
			continue
		end
		if key == "schedule" then
			schedule = compileScheduleList(self, v, site)
			continue
		end
		local sdecl = reg.schedules[key]
		if sdecl ~= nil then
			if bareScheduleKey ~= nil then
				fail(site, ("both %q and %q: order is written, use schedule = { ... }"):format(bareScheduleKey :: string, key))
			end
			bareScheduleKey = key
			local cv: Values.CV? = nil
			if sdecl.type ~= nil then
				cv = self.values:compile(v, sdecl.type :: string, site)
			end
			schedule = { { name = key, kind = sdecl.kind, cv = cv, raw = v } :: any }
			continue
		end
		local odecl = reg.outcomes[key]
		if odecl ~= nil then
			if odecl.kind == "bind" then
				if typeof(v) ~= "string" then
					fail(site, ("%q names the result; it takes a string"):format(key))
				end
				if prim.returns == nil then
					fail(site, ("%q on %q, which returns nothing"):format(key, primName))
				end
				bindAs = v
			else
				branch = compileBranch(self, v, ("%s (%s)"):format(site, key))
			end
			continue
		end
		local stepKeys = (prim :: any).stepKeys
		if stepKeys ~= nil and stepKeys[key] ~= nil then
			steps[key] = table.freeze(compileSteps(self, v, ("%s (%s)"):format(site, key))) :: any
			continue
		end
		if reg.gates[key] ~= nil then
			fail(site, ("%q is a gate; gates sit on subscriptions and branch entries, not effects"):format(key))
		end
		if prim.takes[key] ~= nil then
			local kdecl = reg.keys[key] :: Registry.KeyDecl
			keys[key] = self.values:compile(v, kdecl.type, ("%s (%s)"):format(site, key), allowIt)
			continue
		end
		if reg.keys[key] ~= nil then
			fail(site, ("%q does not take %q"):format(primName, key))
		end
		fail(site, ("%q is a key nobody declared"):format(key))
	end

	if branch ~= nil then
		for _, entry in branch :: { BranchEntry } do
			for _, gate in entry.gates do
				local label = gate.value
				if typeof(label) == "string" and reg.outcomes[gate.name] == nil
					and prim.refuses[label] == nil and prim.takes[label] == nil
					and reg.keys[label] ~= nil then
					fail(site, ("because = %q, a field %q cannot fail on"):format(label, primName))
				end
			end
		end
	end

	return table.freeze({
		prim = prim,
		keys = table.freeze(keys),
		steps = table.freeze(steps),
		schedule = if schedule ~= nil then table.freeze(schedule) else nil,
		bindAs = bindAs,
		branch = branch,
		subIds = if subIds ~= nil then table.freeze(subIds) else nil,
		site = site,
	}) :: any
end

function Compiler.effect(self: Compiler, authored: { [any]: any }, site: string): CompiledEffect
	return compileEffect(self, authored, site, false)
end

local function entityWordOrFail(self: Compiler, word: any, site: string, what: string): string
	local reg = self.registry
	if typeof(word) ~= "string" then
		fail(site, ("%s takes an entity word"):format(what))
	end
	local etype = reg.entityType
	if etype == nil then
		fail(site, "no entity type is declared")
	end
	local et = reg.types[etype :: string]
	if (et :: Registry.TypeDecl).words[word] == nil then
		fail(site, ("%q is not a %q word"):format(word :: string, etype :: string))
	end
	return word
end

local function compileLifetime(self: Compiler, key: string, value: any, out: { [string]: any }, site: string): boolean
	local reg = self.registry
	if key == "limit" then
		if typeof(value) ~= "number" or value < 1 or value % 1 ~= 0 then
			fail(site, "limit is a whole number of firings")
		end
		out.limit = value
		return true
	end
	if key == "lasts" then
		if typeof(value) ~= "number" or value <= 0 then
			fail(site, "lasts is seconds")
		end
		out.lasts = value
		return true
	end
	if key == "ends" then
		if reg.gates.ends == nil then
			fail(site, "ends needs a registered `ends` gate to test it")
		end
		out.ends = value
		return true
	end
	return false
end

local function compileSubscription(self: Compiler, authored: { [any]: any }, site: string): any
	local _ = compileSubscriptionRef
	local reg = self.registry
	local anchorBits: { [number]: boolean } = {}
	local anchorNames: { string } = {}
	local gates: { { name: string, value: any } } = {}
	local lifetime: { [string]: any } = {}
	local toWord: string? = nil
	local contextWord: string? = nil
	local effects: { CompiledEffect } = {}

	local anchors = authored.anchor
	if anchors == nil then
		fail(site, "a subscription names its anchor; `anchor = \"any\"` must be said out loud, never implied")
	end
	if typeof(anchors) == "string" then
		anchors = { anchors }
	end
	for _, name in anchors :: { string } do
		local decl = reg.anchors[name]
		if decl == nil then
			fail(site, ("%q is an anchor nobody declared"):format(tostring(name)))
		end
		anchorBits[decl.bit] = true
		table.insert(anchorNames, name)
	end

	for k, v in authored do
		if typeof(k) == "number" then
			table.insert(effects, compileEffect(self, v, ("%s (effect %d)"):format(site, k), false))
			continue
		end
		local key = k :: string
		if key == "anchor" then
			continue
		end
		if key == "to" then
			toWord = entityWordOrFail(self, v, site, "to")
			continue
		end
		if key == "context" then
			contextWord = entityWordOrFail(self, v, site, "context")
			continue
		end
		if compileLifetime(self, key, v, lifetime, site) then
			continue
		end
		if reg.gates[key] ~= nil then
			table.insert(gates, { name = key, value = v })
			continue
		end
		fail(site, ("%q is not a gate, a lifetime key, `to`, or `context`"):format(key))
	end

	if contextWord ~= nil and toWord == nil then
		fail(site, "`context` without `to` says nothing; a base subscription already runs as its owner")
	end

	return {
		kind = "reaction",
		site = site,
		anchorBits = table.freeze(anchorBits),
		anchorNames = table.freeze(anchorNames),
		gates = table.freeze(gates),
		lifetime = table.freeze(lifetime),
		toWord = toWord,
		contextWord = contextWord,
		effects = table.freeze(effects),
	}
end

compileSubscriptionRef = compileSubscription

local function classifyRewrite(self: Compiler, cv: Values.CV): string
	local reg = self.registry
	local itCount = 0
	for _, term in cv.terms do
		if term.kind == "it" then
			itCount += 1
		else
			return "opaque"
		end
	end
	if itCount ~= 1 then
		return "opaque"
	end
	if #cv.mods == 0 then
		return "additive"
	end
	if cv.const ~= nil then
		return "opaque"
	end
	for _, mod in cv.mods do
		local op = reg.operators[mod.op]
		if op == nil or not op.commutes then
			return "opaque"
		end
	end
	return "multiplicative"
end

local function compileTransform(self: Compiler, authored: { [any]: any }, site: string): any
	local reg = self.registry
	local when = authored.when
	if typeof(when) ~= "table" then
		fail(site, "a transform names what it hooks: when = { primitive = ... }")
	end
	local primName = (when :: { [string]: any }).primitive
	local prim = reg.primitives[primName]
	if prim == nil then
		fail(site, ("transforms hook a primitive; %q is not one"):format(tostring(primName)))
	end
	local keyFilters: { { key: string, word: string } } = {}
	local whenGates: { { name: string, value: any } } = {}
	for k, v in when :: { [string]: any } do
		if k == "primitive" then
			continue
		end
		local kdecl = reg.keys[k]
		if kdecl ~= nil and kdecl.type == reg.entityType then
			if prim.takes[k] == nil then
				fail(site, ("when filters on %q, a key %q does not take"):format(k, primName :: string))
			end
			table.insert(keyFilters, { key = k, word = entityWordOrFail(self, v, site, ("filter %q"):format(k)) })
			continue
		end
		if reg.gates[k] ~= nil then
			table.insert(whenGates, { name = k, value = v })
			continue
		end
		fail(site, ("%q in a when is neither an entity key the primitive takes nor a gate"):format(k))
	end

	local stage = 0
	local refuse: any = nil
	local rewrites: { [string]: Values.CV } = {}
	local rewriteClass: { [string]: string } = {}
	local lifetime: { [string]: any } = {}
	local effects: { CompiledEffect } = {}

	for k, v in authored do
		if typeof(k) == "number" then
			table.insert(effects, compileEffect(self, v, ("%s (effect %d)"):format(site, k), false))
			continue
		end
		local key = k :: string
		if key == "when" then
			continue
		end
		if key == "stage" then
			if typeof(v) ~= "number" then
				fail(site, "stage is a number")
			end
			stage = v
			continue
		end
		if key == "refuse" then
			if v ~= true and typeof(v) ~= "string" then
				fail(site, "refuse is true, or the label `because` will carry")
			end
			refuse = v
			continue
		end
		if compileLifetime(self, key, v, lifetime, site) then
			continue
		end
		if prim.takes[key] ~= nil then
			local kdecl = reg.keys[key] :: Registry.KeyDecl
			local cv = self.values:compile(v, kdecl.type, ("%s (rewrite %s)"):format(site, key), true)
			rewrites[key] = cv
			rewriteClass[key] = classifyRewrite(self, cv)
			continue
		end
		if reg.keys[key] ~= nil then
			fail(site, ("%q does not take %q, so a transform on it cannot rewrite that"):format(primName :: string, key))
		end
		fail(site, ("%q is a key nobody declared"):format(key))
	end

	return {
		kind = "transform",
		site = site,
		prim = primName,
		primBit = reg.primitiveBits[primName],
		stage = stage,
		keyFilters = table.freeze(keyFilters),
		whenGates = table.freeze(whenGates),
		refuse = refuse,
		rewrites = table.freeze(rewrites),
		rewriteClass = table.freeze(rewriteClass),
		lifetime = table.freeze(lifetime),
		effects = table.freeze(effects),
	}
end

function Compiler.define(self: Compiler, def: { [any]: any }, site: string): number
	if typeof(def) ~= "table" then
		fail(site, "a definition is a table")
	end
	local baseEntries: { Intern.SetEntry } = {}
	local attachGrants: { { subId: number, toWord: string, contextIsSelf: boolean } } = {}
	local lastsQueue: { { subId: number, lasts: number } } = {}

	local function addWithChain(sub: any): number
		local n = sub.lifetime.limit
		if n == nil or n <= 1 then
			return self.intern:addSub(sub)
		end
		local nextId: number? = nil
		local headId = 0
		for _ = 1, n :: number do
			local link = table.clone(sub)
			link.nextId = nextId
			headId = self.intern:addSub(link)
			nextId = headId
		end
		return headId
	end

	for k, v in def do
		if k == "events" then
			for i, authored in v :: { any } do
				local subSite = ("%s events[%d]"):format(site, i)
				local sub = compileSubscription(self, authored, subSite)
				local subId = addWithChain(sub)
				if sub.toWord ~= nil then
					table.insert(attachGrants, {
						subId = subId,
						toWord = sub.toWord :: string,
						contextIsSelf = sub.contextWord ~= nil,
					})
				else
					table.insert(baseEntries, { id = subId, count = 1 })
				end
				if sub.lifetime.lasts ~= nil then
					table.insert(lastsQueue, { subId = subId, lasts = sub.lifetime.lasts :: number })
				end
			end
		elseif k == "transforms" then
			for i, authored in v :: { any } do
				local subSite = ("%s transforms[%d]"):format(site, i)
				local sub = compileTransform(self, authored, subSite)
				local subId = addWithChain(sub)
				table.insert(baseEntries, { id = subId, count = 1 })
				if sub.lifetime.lasts ~= nil then
					table.insert(lastsQueue, { subId = subId, lasts = sub.lifetime.lasts :: number })
				end
			end
		else
			fail(site, ("%q is not part of a definition; a definition is events and transforms"):format(tostring(k)))
		end
	end

	local baseSetId = if #baseEntries > 0 then self.intern:intern(baseEntries) else 0
	self.definitionCount += 1
	local id = self.definitionCount
	self.definitions[id] = table.freeze({
		id = id,
		site = site,
		baseSetId = baseSetId,
		attachGrants = table.freeze(attachGrants),
		lastsQueue = table.freeze(lastsQueue),
	})
	return id
end

function Compiler.definition(self: Compiler, id: number): any
	return self.definitions[id]
end

return Compiler
