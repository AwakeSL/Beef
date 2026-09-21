--!strict
--!optimize 2

local Registry = require(script.Parent.Registry)
local Values = require(script.Parent.Values)
local Intern = require(script.Parent.Intern)
local Compiler = require(script.Parent.Compiler)
local Entity = require(script.Parent.Entity)
local Attached = require(script.Parent.Attached)

local Runner = {}
Runner.__index = Runner

local MAX_DEPTH = 32
local MAX_FIRE_DEPTH = 16

-- how an invocation came out. An ask on an event is answered a pass or more later, so a step that
-- is still out is neither granted nor refused and the chain holding it parks until the answer lands
local PENDING = 0
local GRANTED = 1
local REFUSED = 2

-- seq is a u32 column and the counter runs for the life of the server, so it wraps rather than
-- overflowing the wire; 0 is kept free to mean "no invocation"
local SEQ_WRAP = 4294967295

export type Ictx = {
	self: any,
	ctx: { [string]: any },
	bindings: { [string]: any },
	depth: number,
}

-- a chain in flight: which steps, how far in, and the chain that is waiting on this one
type Node = {
	effect: Compiler.CompiledEffect,
	ictx: Ictx,
	stepIctx: Ictx,
	steps: { Compiler.Step },
	index: number,
	up: Node?,
}

-- an ask that has gone out and has not been answered
type Record = {
	effect: Compiler.CompiledEffect,
	ictx: Ictx,
	up: Node?,
}

function Runner.new(registry: Registry.Registry, values: Values.Values, intern: Intern.Intern)
	local self = setmetatable({}, Runner)
	self.registry = registry
	self.values = values
	self.intern = intern
	self.queue = nil :: any
	self.door = nil :: any
	self.wrap = nil :: any
	self.fireDepth = 0
	self.now = 0
	self.seqNext = 1
	self.inflight = {} :: { [number]: Record }
	self.free = {} :: { Record }
	self.slots = {} :: { any }
	self.boundAnchors = nil :: { Registry.AnchorDecl }?
	self.eventPrims = nil :: { Registry.PrimitiveDecl }?
	self.stats = {
		fired = {} :: { [string]: number },
		anchorsDeclared = {} :: { [string]: boolean },
		invoked = 0,
		granted = 0,
		refused = 0,
		refusedBy = {} :: { [string]: number },
		gateSkipped = 0,
		transformsRun = 0,
		transformRefusals = 0,
		rewrites = 0,
		depthHits = 0,
		deadDrops = 0,
		deadContextDrops = 0,
		grantsThisWindow = 0,
		unresolved = 0,
		asked = 0,
		answered = 0,
		strayAnswers = 0,
		inflight = 0,
	}
	return self
end

export type Runner = typeof(Runner.new(Registry.new(), Values.new(Registry.new()), Intern.new()))

local function resolveSub(self: Runner, subId: number): (any, any)
	local sub = self.intern:sub(subId)
	return sub, sub.contextEntity
end

local function childCtx(base: { [string]: any }, owner: any): { [string]: any }
	local c = table.clone(base)
	c.self = owner
	return c
end

local function resolverFor(self: Runner, ictx: Ictx, it: any?): Values.Resolver
	local reg = self.registry
	local etypeName = reg.entityType
	local ewords = if etypeName ~= nil
		then (reg.types[etypeName :: string] :: Registry.TypeDecl).words
		else {}
	return {
		ctx = ictx.ctx,
		it = it,
		-- a field names its component, so a read is the entity's slot in one column
		field = function(subject: string, component: any): any?
			local word = ewords[subject]
			local entity = if typeof(word) == "function" then word(ictx.ctx) else word
			if entity == nil then
				return nil
			end
			return Entity.read(entity, component)
		end,
		binding = function(prim: string, bind: string, component: any?): any?
			local bound = ictx.bindings[prim .. ":" .. bind]
			if bound == nil then
				return nil
			end
			if component ~= nil then
				return Entity.read(bound, component)
			end
			return bound
		end,
	}
end

local function runBranch(self: Runner, effect: Compiler.CompiledEffect, because: string, ictx: Ictx)
	if effect.branch == nil then
		return
	end
	local outcomeCtx = { because = because }
	for _, entry in effect.branch :: { Compiler.BranchEntry } do
		local pass = true
		for _, gate in entry.gates do
			local gdecl = self.registry.gates[gate.name] :: Registry.GateDecl
			if not gdecl.test(gate.value, outcomeCtx, nil) then
				pass = false
				break
			end
		end
		if pass then
			Runner.invoke(self, entry.effect, ictx)
		end
	end
end

-- one refusal, counted, branched on, and reported up as a status
local function settleRefusal(self: Runner, effect: Compiler.CompiledEffect, ictx: Ictx,
	because: string): number
	self.stats.refused += 1
	self.stats.refusedBy[because] = (self.stats.refusedBy[because] or 0) + 1
	runBranch(self, effect, because, ictx)
	return REFUSED
end

local function gatherTransforms(self: Runner, prim: any, args: { [string]: any })
	local reg = self.registry
	local primBit = reg.primitiveBits[prim.name]
	local found: { { sub: any, owner: any, subId: number, contextEntity: any } }? = nil
	local seen: { [string]: boolean }? = nil
	local etype = reg.entityType
	for keyName in prim.takes :: { [string]: string } do
		local kdecl = reg.keys[keyName]
		if kdecl == nil or etype == nil or kdecl.type ~= etype then
			continue
		end
		local participant = args[keyName]
		if participant == nil then
			continue
		end
		local setId = Attached.held(participant)
		if setId == nil or setId == 0 then
			continue
		end
		local info = self.intern:info(setId)
		if info == nil then
			continue
		end
		local list = info.primBits[primBit]
		if list == nil then
			continue
		end
		for _, subId in list do
			local marker = tostring(subId) .. "\1" .. tostring(participant)
			if seen ~= nil and seen[marker] then
				continue
			end
			seen = seen or {}
			(seen :: { [string]: boolean })[marker] = true
			local sub, contextEntity = resolveSub(self, subId)
			found = found or {}
			table.insert(found :: any, { sub = sub, owner = participant, subId = subId, contextEntity = contextEntity })
		end
	end
	if found ~= nil then
		table.sort(found :: any, function(a: any, b: any)
			if a.sub.stage ~= b.sub.stage then
				return a.sub.stage < b.sub.stage
			end
			return a.subId < b.subId
		end)
	end
	return found
end

local function lifetimeBlocks(self: Runner, sub: any, owner: any, subId: number, testCtx: any): boolean
	local ends = sub.lifetime and sub.lifetime.ends
	if ends ~= nil then
		local gdecl = self.registry.gates.ends :: Registry.GateDecl
		if gdecl.test(ends, testCtx, sub) then
			local setId = Attached.held(owner)
			if setId ~= nil and setId ~= 0 then
				Attached.hold(owner, self.intern:revoke(setId, subId))
			end
			return true
		end
	end
	return false
end

local function selfRevokeIfLimited(self: Runner, sub: any, owner: any, subId: number, contextEntity: any?)
	if sub.lifetime == nil or sub.lifetime.limit == nil then
		return
	end
	local setId = Attached.held(owner)
	if setId == nil or setId == 0 then
		return
	end
	local afterRevoke = self.intern:revoke(setId, subId)
	local nextId = sub.nextId :: number?
	if nextId ~= nil then
		local installId = nextId :: number
		if contextEntity ~= nil then
			installId = (self.wrap :: any)(nextId, contextEntity)
		end
		afterRevoke = self.intern:grant(afterRevoke, installId)
	end
	Attached.hold(owner, afterRevoke)
end

local function applyTransforms(self: Runner, effect: Compiler.CompiledEffect, args: { [string]: any },
	ictx: Ictx): (boolean, string?)
	local prim = effect.prim
	local found = gatherTransforms(self, prim, args)
	if found == nil then
		return true, nil
	end
	for _, hit in found :: { any } do
		local sub = hit.sub
		local owner = hit.owner
		local pass = true
		for _, filter in sub.keyFilters :: { { key: string, word: string } } do
			local participant = args[filter.key]
			local etype = self.registry.entityType :: string
			local words = (self.registry.types[etype] :: Registry.TypeDecl).words
			local word = words[filter.word]
			local wctx = childCtx(ictx.ctx, owner)
			local resolved = if typeof(word) == "function" then word(wctx) else word
			if resolved == nil or resolved ~= participant then
				pass = false
				break
			end
		end
		if pass then
			for _, gate in sub.whenGates :: { { name: string, value: any } } do
				local gdecl = self.registry.gates[gate.name] :: Registry.GateDecl
				if not gdecl.test(gate.value, { args = args, ctx = ictx.ctx }, sub) then
					pass = false
					break
				end
			end
		end
		if not pass then
			continue
		end
		if lifetimeBlocks(self, sub, owner, hit.subId, { args = args, ctx = ictx.ctx }) then
			continue
		end
		self.stats.transformsRun += 1
		local tctx: Ictx = {
			self = if hit.contextEntity ~= nil then hit.contextEntity else owner,
			ctx = childCtx(ictx.ctx, if hit.contextEntity ~= nil then hit.contextEntity else owner),
			bindings = ictx.bindings,
			depth = ictx.depth + 1,
		}
		for key, cv in sub.rewrites :: { [string]: Values.CV } do
			local resolver = resolverFor(self, tctx, args[key])
			local v = self.values:resolve(cv, resolver)
			if v == nil then
				self.stats.transformRefusals += 1
				return false, key
			end
			args[key] = v
			self.stats.rewrites += 1
		end
		for _, sideEffect in sub.effects :: { Compiler.CompiledEffect } do
			Runner.invoke(self, sideEffect, tctx)
		end
		selfRevokeIfLimited(self, sub, owner, hit.subId, hit.contextEntity)
		if sub.refuse ~= nil then
			self.stats.transformRefusals += 1
			return false, if typeof(sub.refuse) == "string" then sub.refuse :: string else "refused"
		end
	end
	return true, nil
end

function Runner.resolverFor(self: Runner, ictx: Ictx): Values.Resolver
	return resolverFor(self, ictx, nil)
end

function Runner.resolveKeys(self: Runner, effect: Compiler.CompiledEffect, ictx: Ictx): ({ [string]: any }?, string?)
	local resolver = resolverFor(self, ictx, nil)
	local args: { [string]: any } = {}
	for key, cv in effect.keys do
		local v = self.values:resolve(cv, resolver)
		if v == nil then
			return nil, key
		end
		args[key] = v
	end
	return args, nil
end

function Runner.refuseQueued(self: Runner, effect: Compiler.CompiledEffect, because: string, ictx: Ictx)
	self.stats.unresolved += 1
	settleRefusal(self, effect, ictx, because)
end

function Runner.actxFor(self: Runner, effect: Compiler.CompiledEffect, ictx: Ictx): any
	return {
		cue = self.door,
		self = ictx.self,
		ctx = ictx.ctx,
		bindings = ictx.bindings,
		subs = (effect :: any).subIds,
		bindAs = effect.bindAs,
		grant = function(target: any, subId: number, contextEntity: any?): boolean
			return self.door:grantTo(target, subId, contextEntity)
		end,
	}
end

local function bindResult(self: Runner, effect: Compiler.CompiledEffect, prim: any, value: any, ictx: Ictx)
	if effect.bindAs == nil then
		return
	end
	local returnsType = self.registry.types[prim.returns :: string] :: Registry.TypeDecl?
	if value == nil or returnsType == nil or not returnsType.is(value) then
		self.stats.refusedBy.badReturn = (self.stats.refusedBy.badReturn or 0) + 1
		return
	end
	ictx.bindings[prim.name .. ":" .. (effect.bindAs :: string)] = value
end

-- one invocation, one push: the keys fill the columns the registry worked out once, and `seq` is
-- the name the controller answers under
local function ask(self: Runner, prim: any, args: { [string]: any }): number
	local seq = self.seqNext
	self.seqNext = seq % SEQ_WRAP + 1
	local order = prim.order
	local width = prim.width
	local slots = self.slots
	for i = 1, width do
		local column = order[i]
		slots[i] = if column == false then seq else args[column]
	end
	prim.event.push(table.unpack(slots, 1, width))
	self.stats.asked += 1
	return seq
end

local function takeRecord(self: Runner, effect: Compiler.CompiledEffect, ictx: Ictx, up: Node?): Record
	local n = #self.free
	if n > 0 then
		local rec = self.free[n]
		self.free[n] = nil
		rec.effect = effect
		rec.ictx = ictx
		rec.up = up
		return rec
	end
	return { effect = effect, ictx = ictx, up = up }
end

local function stepChain(self: Runner, node: Node): number
	while true do
		local step = node.steps[node.index]
		if step == nil then
			self.stats.granted += 1
			return GRANTED
		end
		node.index += 1
		if step.kind == "group" then
			for _, groupEffect in step.effects :: { Compiler.CompiledEffect } do
				Runner.invoke(self, groupEffect, node.stepIctx)
			end
			continue
		end
		local status = Runner.invoke(self, step.effect :: Compiler.CompiledEffect, node.stepIctx, nil, node)
		if status == PENDING then
			return PENDING
		end
		if status == REFUSED then
			return settleRefusal(self, node.effect, node.ictx, "step")
		end
	end
end

-- an answer came back for a step; carry the chain on, and carry whatever it comes to up to the
-- chain that is waiting on it
local function resume(self: Runner, node: Node, status: number)
	local current = node
	local carried = status
	while true do
		local out
		if carried == GRANTED then
			out = stepChain(self, current)
		else
			out = settleRefusal(self, current.effect, current.ictx, "step")
		end
		if out == PENDING then
			return
		end
		local up = current.up
		if up == nil then
			return
		end
		current = up
		carried = out
	end
end

function Runner.invokeResolved(self: Runner, effect: Compiler.CompiledEffect, args: { [string]: any },
	ictx: Ictx, up: Node?): number
	local prim = effect.prim

	local okT, becauseT = applyTransforms(self, effect, args, ictx)
	if not okT then
		return settleRefusal(self, effect, ictx, becauseT :: string)
	end

	-- a chain drives its own steps through the loop; nothing about it goes on the wire
	if prim.chains then
		local node: Node = {
			effect = effect,
			ictx = ictx,
			stepIctx = {
				self = ictx.self,
				ctx = ictx.ctx,
				bindings = ictx.bindings,
				depth = ictx.depth + 1,
			},
			steps = (effect.steps :: any).steps,
			index = 1,
			up = up,
		}
		return stepChain(self, node)
	end

	-- cue's own verbs, the ones that only move cue's bookkeeping, answer where they stand
	if prim.perform ~= nil then
		local actx = Runner.actxFor(self, effect, ictx)
		local ok, because, value = (prim.perform :: any)(table.freeze(args), actx)
		if not ok then
			local label = because or "refused"
			if because ~= nil and prim.refuses[because] == nil then
				label = "refused"
			end
			return settleRefusal(self, effect, ictx, label :: string)
		end
		self.stats.granted += 1
		bindResult(self, effect, prim, value, ictx)
		return GRANTED
	end

	local seq = ask(self, prim, args)
	self.inflight[seq] = takeRecord(self, effect, ictx, up)
	self.stats.inflight += 1
	return PENDING
end

function Runner.invoke(self: Runner, effect: Compiler.CompiledEffect, ictx: Ictx,
	skipSchedule: boolean?, up: Node?): number
	self.stats.invoked += 1
	if ictx.depth > MAX_DEPTH then
		self.stats.depthHits += 1
		return REFUSED
	end

	if effect.schedule ~= nil and skipSchedule ~= true then
		self.queue:enqueue(effect, ictx)
		return GRANTED
	end

	local args, becauseKey = Runner.resolveKeys(self, effect, ictx)
	if args == nil then
		self.stats.unresolved += 1
		return settleRefusal(self, effect, ictx, becauseKey :: string)
	end

	return Runner.invokeResolved(self, effect, args :: { [string]: any }, ictx, up)
end

local function answer(self: Runner, seq: number, granted: boolean, value: any, because: string?)
	local rec = self.inflight[seq]
	if rec == nil then
		self.stats.strayAnswers += 1
		return
	end
	self.inflight[seq] = nil
	self.stats.inflight -= 1
	self.stats.answered += 1
	local effect, ictx, up = rec.effect, rec.ictx, rec.up
	rec.effect = nil :: any
	rec.ictx = nil :: any
	rec.up = nil
	table.insert(self.free, rec)
	if granted then
		self.stats.granted += 1
		bindResult(self, effect, effect.prim, value, ictx)
		if up ~= nil then
			resume(self, up :: Node, GRANTED)
		end
		return
	end
	local prim = effect.prim
	local label = because or "refused"
	if because ~= nil and prim.refuses[because] == nil then
		label = "refused"
	end
	settleRefusal(self, effect, ictx, label :: string)
	if up ~= nil then
		resume(self, up :: Node, REFUSED)
	end
end

-- the anchors that carry an event and the primitives that ask on one, worked out once; a
-- declaration after this is a load-time mistake, so the lists never go stale mid-frame
function Runner.wire(self: Runner)
	local anchors: { Registry.AnchorDecl } = {}
	for _, anchor in self.registry.anchors do
		if anchor.event ~= nil then
			table.insert(anchors, anchor)
		end
	end
	table.sort(anchors, function(a, b)
		return a.name < b.name
	end)
	local prims: { Registry.PrimitiveDecl } = {}
	for _, prim in self.registry.primitives do
		if prim.event ~= nil then
			table.insert(prims, prim)
		end
	end
	table.sort(prims, function(a, b)
		return a.name < b.name
	end)
	self.boundAnchors = anchors
	self.eventPrims = prims
end

-- what the Phase has to freeze for this runner: every bound anchor, and both answers of every
-- primitive that asks on an event
function Runner.reads(self: Runner): { any }
	if self.eventPrims == nil then
		Runner.wire(self)
	end
	local out: { any } = {}
	for _, anchor in self.boundAnchors :: { any } do
		table.insert(out, anchor.event)
	end
	for _, prim in self.eventPrims :: { any } do
		table.insert(out, prim.event.done)
		table.insert(out, prim.event.refused)
	end
	return out
end

-- the asks, which this runner is the only one to push
function Runner.writes(self: Runner): { any }
	if self.eventPrims == nil then
		Runner.wire(self)
	end
	local out: { any } = {}
	for _, prim in self.eventPrims :: { any } do
		table.insert(out, prim.event)
	end
	return out
end

-- one pass of the loop: read every answer first, so a chain that gets one pushes its next step in
-- this same pass, then fire on everything pushed at a bound anchor
function Runner.pump(self: Runner)
	if self.eventPrims == nil then
		Runner.wire(self)
	end
	for _, prim in self.eventPrims :: { any } do
		local event = prim.event
		local done = event.done
		local seqs = done.seq
		local results = done.result
		for i = done.from, done.last do
			answer(self, seqs[i], true, if results ~= nil then results[i] else nil, nil)
		end
		local refused = event.refused
		local rseqs = refused.seq
		local whys = refused.because
		for i = refused.from, refused.last do
			answer(self, rseqs[i], false, nil, whys[i])
		end
	end
	for _, anchor in self.boundAnchors :: { any } do
		local event = anchor.event
		local column = event[anchor.selfColumn]
		local context = anchor.context
		local extra = #context
		for i = event.from, event.last do
			local data: { [string]: any }? = nil
			if extra > 0 then
				data = {}
				for j = 1, extra do
					local name = context[j]
					;(data :: any)[name] = event[name][i]
				end
			end
			Runner.fire(self, column[i], anchor.name, data, nil)
		end
	end
end

local function dispatchSet(self: Runner, setId: number, holder: any, anchor: any,
	anchorName: string, data: { [string]: any }?, scope: { [string]: any }?,
	installed: boolean): number
	local reg = self.registry
	local info = self.intern:info(setId)
	if info == nil then
		return 0
	end
	local list = info.anchorBits[anchor.bit]
	if list == nil then
		return 0
	end
	self.fireDepth += 1
	local ran = 0
	local ctx = if data ~= nil then table.clone(data) else {}
	ctx.self = holder
	local firing = { entity = holder, anchor = anchorName, data = ctx, ctx = ctx }
	local snapshot = table.clone(list)
	for _, subId in snapshot do
		local sub, contextEntity = resolveSub(self, subId)
		if contextEntity ~= nil and not Entity.alive(contextEntity) then
			self.stats.deadContextDrops += 1
			if installed then
				local held = Attached.held(holder)
				if held ~= nil and held ~= 0 then
					Attached.hold(holder, self.intern:revoke(held, subId))
				end
			end
			continue
		end
		local pass = true
		for _, gate in sub.gates :: { { name: string, value: any } } do
			local gdecl = reg.gates[gate.name] :: Registry.GateDecl
			if not gdecl.test(gate.value, firing, sub) then
				pass = false
				break
			end
		end
		if not pass then
			self.stats.gateSkipped += 1
			continue
		end
		if installed and lifetimeBlocks(self, sub, holder, subId, firing) then
			continue
		end
		local owner = if contextEntity ~= nil then contextEntity else holder
		local ictx: Ictx = {
			self = owner,
			ctx = childCtx(ctx, owner),
			bindings = scope or {},
			depth = 1,
		}
		for _, effect in sub.effects :: { Compiler.CompiledEffect } do
			Runner.invoke(self, effect, ictx)
		end
		ran += 1
		if installed then
			selfRevokeIfLimited(self, sub, holder, subId, contextEntity)
		end
	end
	self.fireDepth -= 1
	return ran
end

local function anchorOf(self: Runner, anchorName: string, site: string): any
	local anchor = self.registry.anchors[anchorName]
	if anchor == nil then
		error(("[cue] %s: %q is an anchor nobody declared"):format(site, anchorName), 0)
	end
	return anchor
end

function Runner.fire(self: Runner, entity: any, anchorName: string, data: { [string]: any }?,
	scope: { [string]: any }?): number
	local anchor = anchorOf(self, anchorName, "fire")
	self.stats.fired[anchorName] = (self.stats.fired[anchorName] or 0) + 1
	if self.fireDepth >= MAX_FIRE_DEPTH then
		self.stats.depthHits += 1
		return 0
	end
	local setId = Attached.held(entity)
	if setId == nil or setId == 0 then
		return 0
	end
	return dispatchSet(self, setId, entity, anchor, anchorName, data, scope, true)
end

function Runner.runDef(self: Runner, defId: number, anchorName: string,
	data: { [string]: any }?, scope: { [string]: any }?, asSelf: any): number
	local anchor = anchorOf(self, anchorName, "run")
	local def = self.door.compiler:definition(defId)
	if def == nil then
		error(("[cue] run: no definition %d"):format(defId), 0)
	end
	self.stats.fired[anchorName] = (self.stats.fired[anchorName] or 0) + 1
	if self.fireDepth >= MAX_FIRE_DEPTH then
		self.stats.depthHits += 1
		return 0
	end
	if def.baseSetId == 0 then
		return 0
	end
	return dispatchSet(self, def.baseSetId, asSelf, anchor, anchorName, data, scope, false)
end

function Runner.responds(self: Runner, entity: any, anchorName: string): boolean
	local anchor = self.registry.anchors[anchorName]
	if anchor == nil then
		return false
	end
	local setId = Attached.held(entity)
	if setId == nil or setId == 0 then
		return false
	end
	local info = self.intern:info(setId)
	if info == nil then
		return false
	end
	return info.anchorBits[anchor.bit] ~= nil
end

return Runner
