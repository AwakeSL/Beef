--!strict
--!optimize 2

local Events = require(script.Parent.Parent.Events)

local Registry = {}
Registry.__index = Registry

export type TypeDecl = {
	name: string,
	is: (any) -> boolean,
	zero: any?,
	opaque: boolean,
	words: { [string]: any },
	constructors: { [string]: { [string]: any } },
	construct: { [string]: (args: { [string]: any }) -> any },
	operators: { [string]: any },
	means: string?,
}

export type OperatorDecl = {
	name: string,
	stage: number,
	commutes: boolean,
	means: string?,
}

export type KeyDecl = { name: string, type: string, means: string }
export type FieldDecl = { name: string, type: string, component: any, means: string }
export type AnchorDecl = {
	name: string,
	means: string,
	bit: number,
	event: any?,
	selfColumn: string?,
	context: { string }?,
}
export type GateDecl = { name: string, test: (any, any, any) -> boolean, means: string? }
export type ScheduleDecl = {
	name: string,
	kind: "delay" | "repeat" | "await",
	type: string?,
	ready: any?,
	means: string?,
}
export type PrimitiveDecl = {
	name: string,
	takes: { [string]: string },
	returns: string?,
	refuses: { [string]: boolean },
	event: any?,
	order: { any }?,
	width: number?,
	chains: boolean,
	perform: ((any, any) -> (boolean, string?, any?))?,
	means: string?,
}
export type OutcomeDecl = { name: string, kind: "bind" | "branch", means: string? }

local function fail(site: string, message: string): never
	error(("[cue] %s: %s"):format(site, message), 0)
end

function Registry.new()
	local self = setmetatable({}, Registry)
	self.types = {} :: { [string]: TypeDecl }
	self.operators = {} :: { [string]: OperatorDecl }
	self.keys = {} :: { [string]: KeyDecl }
	self.fields = {} :: { [string]: FieldDecl }
	self.anchors = {} :: { [string]: AnchorDecl }
	self.anchorCount = 0
	self.gates = {} :: { [string]: GateDecl }
	self.schedules = {} :: { [string]: ScheduleDecl }
	self.primitives = {} :: { [string]: PrimitiveDecl }
	self.primitiveBits = {} :: { [string]: number }
	self.primitiveCount = 0
	self.outcomes = {} :: { [string]: OutcomeDecl }
	self.reservedEffectKeys = {} :: { [string]: string }
	self.entityType = nil :: string?
	return self
end

export type Registry = typeof(Registry.new())

local function reserve(self: Registry, name: string, slot: string, site: string)
	local taken = self.reservedEffectKeys[name]
	if taken ~= nil then
		fail(site, ("%q is already a %s; one name never means two things"):format(name, taken))
	end
	self.reservedEffectKeys[name] = slot
end

local function checkerFor(is: any, site: string): (any) -> boolean
	if typeof(is) == "function" then
		return is
	end
	if typeof(is) == "string" then
		return function(v)
			return typeof(v) == is
		end
	end
	fail(site, "`is` must be a typeof string or a predicate")
	error("unreachable")
end

function Registry.declareType(self: Registry, name: string, decl: any)
	local site = ("type %q"):format(name)
	if self.types[name] ~= nil then
		fail(site, "already declared")
	end
	if decl.entity == true then
		if self.entityType ~= nil then
			fail(site, ("a second entity type; %q already is one"):format(self.entityType :: string))
		end
		self.entityType = name
	end
	local constructors = {}
	local construct = {}
	if decl.constructors ~= nil then
		local ctors = decl.constructors :: { [string]: any }
		for cname, spec in ctors do
			if typeof(spec) == "table" and typeof(spec.make) == "function" then
				constructors[cname] = spec.args
				construct[cname] = spec.make
			else
				fail(site, ("constructor %q needs { args, make }"):format(cname))
			end
			reserve(self, cname, "constructor", site)
		end
	end
	local ops = (decl.operators or {}) :: { [string]: any }
	for opName in ops do
		if opName ~= "+" and self.operators[opName] == nil then
			fail(site, ("lists operator %q, which nobody declared"):format(opName))
		end
	end
	local declWords = (decl.words or {}) :: { [string]: any }
	for wordName in declWords do
		if self.operators[wordName] ~= nil then
			fail(site, ("word %q collides with an operator"):format(wordName))
		end
		if self.reservedEffectKeys[wordName] == "constructor" then
			fail(site, ("word %q collides with a constructor"):format(wordName))
		end
	end
	self.types[name] = table.freeze({
		name = name,
		is = checkerFor(decl.is, site),
		zero = decl.zero,
		opaque = decl.opaque == true,
		words = table.freeze(table.clone(decl.words or {})),
		constructors = table.freeze(constructors),
		construct = table.freeze(construct),
		operators = table.freeze(table.clone(decl.operators or {})),
		means = decl.means,
	}) :: TypeDecl
end

function Registry.declareOperator(self: Registry, name: string, decl: any)
	local site = ("operator %q"):format(name)
	if self.operators[name] ~= nil then
		fail(site, "already declared")
	end
	if typeof(decl.stage) ~= "number" then
		fail(site, "an operator declares a numeric stage; precedence is data")
	end
	reserve(self, name, "operator", site)
	self.operators[name] = table.freeze({
		name = name,
		stage = decl.stage,
		commutes = decl.commutes == true,
		means = decl.means,
	})
end

function Registry.declareKey(self: Registry, name: string, decl: any)
	local site = ("key %q"):format(name)
	if self.keys[name] ~= nil then
		fail(site, "already declared")
	end
	if self.types[decl.type] == nil then
		fail(site, ("declares type %q, which does not exist"):format(tostring(decl.type)))
	end
	if typeof(decl.means) ~= "string" then
		fail(site, "a key carries a meaning, not just a type")
	end
	self.keys[name] = table.freeze({ name = name, type = decl.type, means = decl.means })
end

function Registry.declareField(self: Registry, name: string, decl: any)
	local site = ("field %q"):format(name)
	if self.fields[name] ~= nil then
		fail(site, "already declared")
	end
	if self.types[decl.type] == nil then
		fail(site, ("declares type %q, which does not exist"):format(tostring(decl.type)))
	end
	if typeof(decl.means) ~= "string" then
		fail(site, "a field carries a meaning, not just a type")
	end
	if typeof(decl.component) ~= "table" or typeof(decl.component.get) ~= "function" then
		fail(site, "a field names the component it reads: { type = ..., component = Health }")
	end
	self.fields[name] =
		table.freeze({ name = name, type = decl.type, component = decl.component, means = decl.means })
end

-- an Event keeps its own bookkeeping on the table that holds its columns, so a column named after
-- one of those fields shadows it and the Phase reads a column array where it wanted a number; the
-- clash is caught at declaration rather than a frame later
local RESERVED: { [string]: boolean } = {
	name = true, columns = true, wire = true, count = true, base = true, lapStart = true,
	from = true, last = true, walked = true, lost = true, unread = true, keep = true,
	entity = true, push = true, freeze = true, lap = true, since = true, laps = true,
	lapWindow = true, done = true, refused = true,
}

local function checkColumns(site: string, event: any)
	for _, column in event.columns do
		if RESERVED[column] then
			fail(site, ("the event has a column %q, which is one of an Event's own fields; rename the column or the key"):format(column))
		end
	end
end

-- the columns a bound event hands the firing, self aside: an entity word reads them off the context
local function contextColumns(event: any, selfColumn: string): { string }
	local out: { string } = {}
	for _, column in event.columns do
		if column ~= selfColumn then
			table.insert(out, column)
		end
	end
	return out
end

-- an anchor is declared with a meaning and bound with an event; a second call carrying an event
-- and no meaning binds the anchor that is already there, which is how a default anchor gets one
function Registry.declareAnchor(self: Registry, name: string, decl: any)
	local site = ("anchor %q"):format(name)
	local held = self.anchors[name]
	if held ~= nil and decl.means ~= nil then
		fail(site, "already declared")
	end
	if held == nil and typeof(decl.means) ~= "string" then
		fail(site, "an anchor carries a meaning")
	end
	local event = decl.event
	local selfColumn: string? = nil
	if event ~= nil then
		if typeof(event) ~= "table" or typeof(event.freeze) ~= "function" then
			fail(site, "`event` is a Beef event type")
		end
		if held ~= nil and held.event ~= nil then
			fail(site, ("already bound to the event %q"):format(tostring(held.event.name)))
		end
		selfColumn = decl.self
		if typeof(selfColumn) ~= "string" then
			fail(site, "a bound anchor names the column the entity fired on sits in: self = \"self\"")
		end
		checkColumns(site, event)
		if table.find(event.columns, selfColumn) == nil then
			fail(site, ("%q is not a column of the event %q"):format(selfColumn :: string, tostring(event.name)))
		end
	elseif held ~= nil then
		fail(site, "already declared")
	end
	local bit
	if held ~= nil then
		bit = held.bit
	else
		self.anchorCount += 1
		bit = self.anchorCount
	end
	self.anchors[name] = table.freeze({
		name = name,
		means = if held ~= nil then held.means else decl.means,
		bit = bit,
		event = event or (held ~= nil and held.event) or nil,
		selfColumn = selfColumn or (held ~= nil and held.selfColumn) or nil,
		context = if event ~= nil then table.freeze(contextColumns(event, selfColumn :: string)) else
			(held ~= nil and held.context) or nil,
	})
end

function Registry.declareGate(self: Registry, name: string, decl: any)
	local site = ("gate %q"):format(name)
	if self.gates[name] ~= nil then
		fail(site, "already declared")
	end
	if typeof(decl.test) ~= "function" then
		fail(site, "a gate is a test")
	end
	reserve(self, name, "gate", site)
	self.gates[name] = table.freeze({ name = name, test = decl.test, means = decl.means })
end

function Registry.declareSchedule(self: Registry, name: string, decl: any)
	local site = ("schedule %q"):format(name)
	if self.schedules[name] ~= nil then
		fail(site, "already declared")
	end
	if decl.kind ~= "delay" and decl.kind ~= "repeat" and decl.kind ~= "await" then
		fail(site, "kind must be delay, repeat or await")
	end
	if decl.kind == "await" and typeof(decl.ready) ~= "function" then
		fail(site, "an await schedule declares `ready`, polled until it answers true")
	end
	if decl.kind ~= "await" and decl.type == nil then
		fail(site, "a timed schedule declares the type its value is read as")
	end
	reserve(self, name, "schedule", site)
	self.schedules[name] = table.freeze({
		name = name,
		kind = decl.kind,
		type = decl.type,
		ready = decl.ready,
		means = decl.means,
	})
end

-- an invocation is one push, so the ask event's columns have to be exactly the keys the primitive
-- takes plus `seq`; this works out, once, which key fills which column
local function pushOrder(site: string, event: any, takes: { [string]: string }): ({ any }, number)
	checkColumns(site, event)
	local order: { any } = {}
	local filled: { [string]: boolean } = {}
	local hasSeq = false
	for i, column in event.columns do
		if column == "seq" then
			order[i] = false
			hasSeq = true
		elseif takes[column] ~= nil then
			order[i] = column
			filled[column] = true
		else
			fail(site, ("the event has a column %q, which is not a key this primitive takes"):format(column))
		end
	end
	if not hasSeq then
		fail(site, "the event needs a `seq` column: it is what an answer names the invocation by")
	end
	for keyName in takes do
		if not filled[keyName] then
			fail(site, ("takes %q but the event has no column for it"):format(keyName))
		end
	end
	return order, #event.columns
end

function Registry.declarePrimitive(self: Registry, name: string, decl: any)
	local site = ("primitive %q"):format(name)
	if self.primitives[name] ~= nil then
		fail(site, "already declared")
	end
	local chains = decl.chains == true
	local perform = decl.perform
	local event = decl.event
	if event == nil and perform == nil and not chains then
		fail(site, "declared with no implementation is a load error; a primitive names the event it asks on")
	end
	if event ~= nil and (typeof(event) ~= "table" or typeof(event.freeze) ~= "function") then
		fail(site, "`event` is a Beef event type")
	end
	if event ~= nil and (event.done ~= nil or event.refused ~= nil) then
		fail(site, ("the event %q already answers for another primitive"):format(tostring(event.name)))
	end
	local takes = {}
	local declTakes = (decl.takes or {}) :: { [string]: string }
	for keyName, meaning in declTakes do
		if self.keys[keyName] == nil then
			fail(site, ("takes %q, a key nobody declared"):format(keyName))
		end
		takes[keyName] = meaning
	end
	local refuses = {}
	local declRefuses = (decl.refuses or {}) :: { string }
	for _, label in declRefuses do
		refuses[label] = true
	end
	if decl.returns ~= nil and self.types[decl.returns] == nil then
		fail(site, ("returns %q, a type nobody declared"):format(tostring(decl.returns)))
	end
	local order: { any }? = nil
	local width: number? = nil
	if event ~= nil then
		order, width = pushOrder(site, event, takes)
		event.done = if decl.returns ~= nil
			then Events.new(event.name .. ".done", "seq:u32", "result")
			else Events.new(event.name .. ".done", "seq:u32")
		event.refused = Events.new(event.name .. ".refused", "seq:u32", "because")
	end
	self.primitiveCount += 1
	self.primitiveBits[name] = self.primitiveCount
	self.primitives[name] = table.freeze({
		name = name,
		takes = table.freeze(takes),
		returns = decl.returns,
		refuses = table.freeze(refuses),
		event = event,
		order = if order ~= nil then table.freeze(order) else nil,
		width = width,
		chains = chains,
		perform = perform,
		sugar = decl.sugar,
		stepKeys = if decl.stepKeys ~= nil then table.freeze(decl.stepKeys) else nil,
		takesSubs = decl.takesSubs == true,
		means = decl.means,
	})
end

function Registry.declareOutcome(self: Registry, name: string, decl: any)
	local site = ("outcome %q"):format(name)
	if self.outcomes[name] ~= nil then
		fail(site, "already declared")
	end
	if decl.kind ~= "bind" and decl.kind ~= "branch" then
		fail(site, "kind must be bind or branch")
	end
	reserve(self, name, "outcome", site)
	self.outcomes[name] = table.freeze({ name = name, kind = decl.kind, means = decl.means })
end

return Registry
