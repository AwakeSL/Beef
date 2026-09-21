--!strict
--!optimize 2

local Registry = require(script.Registry)
local Values = require(script.Values)
local Intern = require(script.Intern)
local Compiler = require(script.Compiler)
local Runner = require(script.Runner)
local Queue = require(script.Queue)
local Defaults = require(script.Defaults)
local Entity = require(script.Entity)
local Attached = require(script.Attached)
local Control = require(script.Control)

local Cue = {}
Cue.__index = Cue

local function fail(message: string): never
	error(("[cue] %s"):format(message), 0)
end

-- the controller that runs a cue in a Phase, and the one number a cue keeps per entity
Cue.Runner = Control
Cue.Attached = Attached.component

-- an entity is a Beef handle with its kind folded in, so one number says which kind and which
-- handle wherever a value, a column or a binding carries it
Cue.entity = Entity.of
Cue.is = Entity.is
Cue.kind = Entity.kind
Cue.handle = Entity.handle
Cue.read = Entity.read
Cue.alive = Entity.alive

function Cue.new()
	local self = setmetatable({}, Cue)
	local registry = Registry.new()
	local values = Values.new(registry)
	local intern = Intern.new()
	local compiler = Compiler.new(registry, values, intern)
	local runner = Runner.new(registry, values, intern)
	local queue = Queue.new()
	runner.queue = queue
	runner.door = self
	runner.wrap = function(baseId: number, contextEntity: any): number
		return Cue.wrapSub(self, baseId, contextEntity)
	end
	queue.runner = runner
	queue.intern = intern
	queue.registry = registry
	queue.values = values
	self.registry = registry
	self.values = values
	self.intern = intern
	self.compiler = compiler
	self.runner = runner
	self.queue = queue
	self.defineCount = 0
	self.wrapCache = {} :: { [number]: any }
	self.grantsTotal = 0
	self.grantsWindowStart = 0
	self.grantsWindowCount = 0
	self.grantsLastWindow = 0
	return self
end

export type Cue = typeof(Cue.new())
export type Ictx = Runner.Ictx

function Cue.type(self: Cue, name: string, decl: any): Cue
	self.registry:declareType(name, decl)
	return self
end

function Cue.operator(self: Cue, name: string, decl: any): Cue
	self.registry:declareOperator(name, decl)
	return self
end

function Cue.key(self: Cue, name: string, decl: any): Cue
	self.registry:declareKey(name, decl)
	return self
end

function Cue.field(self: Cue, name: string, decl: any): Cue
	self.registry:declareField(name, decl)
	return self
end

function Cue.anchor(self: Cue, name: string, decl: any): Cue
	self.registry:declareAnchor(name, decl)
	return self
end

function Cue.gate(self: Cue, name: string, decl: any): Cue
	self.registry:declareGate(name, decl)
	return self
end

function Cue.schedule(self: Cue, name: string, decl: any): Cue
	self.registry:declareSchedule(name, decl)
	return self
end

function Cue.primitive(self: Cue, name: string, decl: any): Cue
	self.registry:declarePrimitive(name, decl)
	return self
end

function Cue.outcome(self: Cue, name: string, decl: any): Cue
	self.registry:declareOutcome(name, decl)
	return self
end

function Cue.defaults(self: Cue): Cue
	Defaults(self)
	return self
end

function Cue.define(self: Cue, def: { [any]: any }, site: string?): number
	self.defineCount += 1
	local at = site or ("define #%d"):format(self.defineCount)
	return self.compiler:define(def, at)
end

function Cue.effect(self: Cue, authored: { [any]: any }, site: string?): any
	return self.compiler:effect(authored, site or "effect")
end

function Cue.wrapSub(self: Cue, baseId: number, contextEntity: any): number
	local byBase = self.wrapCache[baseId]
	if byBase == nil then
		byBase = setmetatable({}, { __mode = "k" })
		self.wrapCache[baseId] = byBase
	end
	local cached = byBase[contextEntity]
	if cached ~= nil then
		return cached
	end
	local base = self.intern:sub(baseId)
	local wrapper = table.clone(base)
	wrapper.base = baseId
	wrapper.contextEntity = contextEntity
	local id = self.intern:addSub(wrapper)
	self.intern.stats.mintedSubs += 1
	byBase[contextEntity] = id
	return id
end

local function queueLasts(self: Cue, entity: any, installId: number, lasts: number?)
	if lasts ~= nil then
		self.queue:addRevoke(entity, installId, lasts :: number)
	end
end

function Cue.grantTo(self: Cue, target: any, subId: number, contextEntity: any?): boolean
	local installId = subId
	if contextEntity ~= nil then
		installId = self:wrapSub(subId, contextEntity)
	end
	local current = Attached.held(target) or 0
	Attached.hold(target, self.intern:grant(current, installId))
	self.grantsTotal += 1
	self.grantsWindowCount += 1
	local sub = self.intern:sub(installId)
	if sub.lifetime ~= nil then
		queueLasts(self, target, installId, sub.lifetime.lasts)
	end
	return true
end

function Cue.revokeFrom(self: Cue, entity: any, subId: number): boolean
	local current = Attached.held(entity)
	if current == nil or current == 0 then
		return false
	end
	local after = self.intern:revoke(current, subId)
	if after == current then
		return false
	end
	Attached.hold(entity, after)
	return true
end

function Cue.attach(self: Cue, entity: any, defId: number, ctx: { [string]: any }?): ()
	local def = self.compiler:definition(defId)
	if def == nil then
		fail(("attach: no definition %d"):format(defId))
	end
	local current = Attached.held(entity) or 0
	if current == 0 then
		Attached.hold(entity, def.baseSetId)
	elseif def.baseSetId ~= 0 then
		local info = self.intern:info(def.baseSetId)
		local merged = current
		for _, entry in (info :: Intern.SetInfo).entries do
			for _ = 1, entry.count do
				merged = self.intern:grant(merged, entry.id)
			end
		end
		Attached.hold(entity, merged)
	end
	for _, pending in def.lastsQueue :: { { subId: number, lasts: number } } do
		self.queue:addRevoke(entity, pending.subId, pending.lasts)
	end
	local etypeName = self.registry.entityType
	for _, grant in def.attachGrants :: { { subId: number, toWord: string, contextIsSelf: boolean } } do
		if etypeName == nil then
			fail("attach: a `to` grant needs an entity type")
		end
		local words = (self.registry.types[etypeName :: string] :: Registry.TypeDecl).words
		local word = words[grant.toWord]
		local wctx = if ctx ~= nil then table.clone(ctx) else {}
		wctx.self = entity
		local target = if typeof(word) == "function" then word(wctx) else word
		if target == nil then
			self.runner.stats.refusedBy.attachGrantTarget = (self.runner.stats.refusedBy.attachGrantTarget or 0) + 1
		else
			self:grantTo(target, grant.subId, if grant.contextIsSelf then entity else nil)
		end
	end
end

function Cue.detach(self: Cue, entity: any, defId: number): ()
	local def = self.compiler:definition(defId)
	if def == nil then
		fail(("detach: no definition %d"):format(defId))
	end
	if def.baseSetId == 0 then
		return
	end
	local current = Attached.held(entity)
	if current == nil or current == 0 then
		return
	end
	local info = self.intern:info(def.baseSetId)
	if info == nil then
		return
	end
	local merged = current
	for _, entry in (info :: Intern.SetInfo).entries do
		for _ = 1, entry.count do
			merged = self.intern:revoke(merged, entry.id)
		end
	end
	Attached.hold(entity, merged)
end

function Cue.fire(self: Cue, entity: any, anchorName: string, data: { [string]: any }?,
	scope: { [string]: any }?): number
	return self.runner:fire(entity, anchorName, data, scope)
end

function Cue.run(self: Cue, defId: number, anchorName: string, data: { [string]: any }?,
	scope: { [string]: any }?, asSelf: any): number
	return self.runner:runDef(defId, anchorName, data, scope, asSelf)
end

function Cue.responds(self: Cue, entity: any, anchorName: string): boolean
	return self.runner:responds(entity, anchorName)
end

-- the grant rate is read over a five second window; the controller moves the clock on
function Cue.window(self: Cue, now: number)
	if now - self.grantsWindowStart >= 5 then
		self.grantsLastWindow = self.grantsWindowCount
		self.grantsWindowCount = 0
		self.grantsWindowStart = now
	end
end

-- what a Phase needs to run this cue: the controller, the cue, then every buffer it touches, so
-- the Phase freezes each bound anchor and each answer for it and leaves the asks to their readers
function Cue.entry(self: Cue): { any }
	Runner.wire(self.runner)
	local entry: { any } = { Control, self }
	for _, buffer in Runner.reads(self.runner) do
		table.insert(entry, buffer)
	end
	for _, prim in self.runner.eventPrims :: { any } do
		table.insert(entry, prim.event)
	end
	return entry
end

function Cue.stats(self: Cue): { [string]: any }
	local subscribed: { [string]: boolean } = {}
	for _, info in self.intern.sets :: { [number]: Intern.SetInfo } do
		for _, entry in info.entries do
			local sub = self.intern:sub(entry.id)
			if sub.anchorNames ~= nil then
				for _, name in sub.anchorNames :: { string } do
					subscribed[name] = true
				end
			end
		end
	end
	local neverFired: { string } = {}
	for name in subscribed do
		if self.runner.stats.fired[name] == nil then
			table.insert(neverFired, name)
		end
	end
	table.sort(neverFired)
	return {
		runner = self.runner.stats,
		queue = self.queue.stats,
		intern = self.intern.stats,
		grantsTotal = self.grantsTotal,
		grantsLastWindow = self.grantsLastWindow,
		subscribedNeverFired = neverFired,
	}
end

function Cue.primitives(self: Cue): { string }
	local out = {}
	for name in self.registry.primitives do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function Cue.keysOf(self: Cue, primName: string): { [string]: string }?
	local prim = self.registry.primitives[primName]
	if prim == nil then
		return nil
	end
	return prim.takes
end

function Cue.typeOf(self: Cue, keyName: string): string?
	local key = self.registry.keys[keyName]
	if key == nil then
		return nil
	end
	return key.type
end

function Cue.wordsOf(self: Cue, typeName: string): { string }?
	local t = self.registry.types[typeName]
	if t == nil then
		return nil
	end
	local out = {}
	for name in t.words do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function Cue.constructorsOf(self: Cue, typeName: string): { string }?
	local t = self.registry.types[typeName]
	if t == nil then
		return nil
	end
	local out = {}
	for name in t.constructors do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function Cue.reference(self: Cue): string
	local reg = self.registry
	local lines: { string } = { "# Reference", "" }
	local function section(title: string)
		table.insert(lines, ("## %s"):format(title))
		table.insert(lines, "")
	end
	local function sortedNames(map: { [string]: any }): { string }
		local names = {}
		for name in map do
			table.insert(names, name)
		end
		table.sort(names)
		return names
	end
	section("Types")
	for _, name in sortedNames(reg.types) do
		local t = reg.types[name]
		local words = {}
		for w in t.words do
			table.insert(words, w)
		end
		table.sort(words)
		local ctors = {}
		for c in t.constructors do
			table.insert(ctors, c)
		end
		table.sort(ctors)
		local ops = {}
		for o in t.operators do
			table.insert(ops, o)
		end
		table.sort(ops)
		table.insert(lines, ("- **%s**: %s"):format(name, t.means or ""))
		if #words > 0 then
			table.insert(lines, ("  - words: %s"):format(table.concat(words, " · ")))
		end
		if #ctors > 0 then
			table.insert(lines, ("  - constructors: %s"):format(table.concat(ctors, " · ")))
		end
		if #ops > 0 then
			table.insert(lines, ("  - operators: %s"):format(table.concat(ops, " · ")))
		end
	end
	table.insert(lines, "")
	section("Keys")
	for _, name in sortedNames(reg.keys) do
		local key = reg.keys[name]
		table.insert(lines, ("- **%s** `<%s>`: %s"):format(name, key.type, key.means))
	end
	table.insert(lines, "")
	section("Fields")
	for _, name in sortedNames(reg.fields) do
		local field = reg.fields[name]
		table.insert(lines, ("- **%s** `<%s>`: %s"):format(name, field.type, field.means))
	end
	table.insert(lines, "")
	section("Anchors")
	for _, name in sortedNames(reg.anchors) do
		table.insert(lines, ("- **%s**: %s"):format(name, reg.anchors[name].means))
	end
	table.insert(lines, "")
	section("Primitives")
	for _, name in sortedNames(reg.primitives) do
		local prim = reg.primitives[name]
		table.insert(lines, ("- **%s**: %s"):format(name, prim.means or ""))
		local takeNames = sortedNames(prim.takes)
		for _, keyName in takeNames do
			local keyDecl = reg.keys[keyName]
			table.insert(lines, ("  - %s `<%s>`: %s"):format(keyName, keyDecl.type, prim.takes[keyName]))
		end
		if prim.returns ~= nil then
			table.insert(lines, ("  - returns `<%s>`"):format(prim.returns :: string))
		end
	end
	return table.concat(lines, "\n")
end

return Cue
