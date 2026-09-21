--!strict
--!optimize 2

local Compiler = require(script.Parent.Compiler)
local Entity = require(script.Parent.Entity)
local Attached = require(script.Parent.Attached)

local Queue = {}
Queue.__index = Queue

function Queue.new()
	local self = setmetatable({}, Queue)
	self.entries = {} :: { any }
	self.runner = nil :: any
	self.intern = nil :: any
	self.registry = nil :: any
	self.values = nil :: any
	self.now = 0
	self.stepped = false
	self.stats = {
		queued = 0,
		ran = 0,
		repeats = 0,
		deadDrops = 0,
		unresolvedSchedules = 0,
		revokesQueued = 0,
		live = 0,
	}
	return self
end

export type Queue = typeof(Queue.new())

local function resolveSeconds(self: Queue, entry: Compiler.ScheduleEntry, ictx: any): number?
	if entry.cv == nil then
		return nil
	end
	local resolver = self.runner:resolverFor(ictx)
	local v = self.values:resolve(entry.cv :: any, resolver)
	if typeof(v) ~= "number" then
		return nil
	end
	return v
end

function Queue.enqueue(self: Queue, effect: Compiler.CompiledEffect, ictx: any)
	local schedule = effect.schedule :: { Compiler.ScheduleEntry }
	local durations: { [number]: number } = {}
	for i, entry in schedule do
		if entry.kind == "delay" or entry.kind == "repeat" then
			local seconds = resolveSeconds(self, entry, ictx)
			if seconds == nil then
				self.stats.unresolvedSchedules += 1
				return
			end
			durations[i] = seconds :: number
		end
	end
	local resolvedArgs: { [string]: any }? = nil
	local lastIsRepeat = schedule[#schedule].kind == "repeat"
	local hasRepeat = false
	for _, entry in schedule do
		if entry.kind == "repeat" then
			hasRepeat = true
			break
		end
	end
	if not hasRepeat then
		local args, because = self.runner:resolveKeys(effect, ictx)
		if args == nil then
			self.runner:refuseQueued(effect, because :: string, ictx)
			return
		end
		resolvedArgs = args
	end
	local _ = lastIsRepeat
	local firstAt: number? = nil
	if self.stepped and durations[1] ~= nil then
		firstAt = self.now + durations[1]
	end
	self.stats.queued += 1
	self.stats.live += 1
	table.insert(self.entries, {
		kind = "pipeline",
		effect = effect,
		ictx = ictx,
		schedule = schedule,
		durations = durations,
		index = 1,
		at = firstAt,
		args = resolvedArgs,
	})
end

function Queue.addRevoke(self: Queue, entity: any, subId: number, delaySeconds: number)
	self.stats.revokesQueued += 1
	self.stats.live += 1
	local at: number? = if self.stepped then self.now + delaySeconds else nil
	table.insert(self.entries, {
		kind = "revoke", entity = entity, subId = subId,
		at = at, delay = delaySeconds,
	})
end

local function runPipelineEnd(self: Queue, entry: any)
	self.stats.ran += 1
	if entry.args ~= nil then
		self.runner:invokeResolved(entry.effect, table.clone(entry.args), entry.ictx)
	else
		self.runner:invoke(entry.effect, entry.ictx, true)
	end
end

local function stepPipeline(self: Queue, entry: any, now: number): boolean
	while true do
		local schedule = entry.schedule :: { Compiler.ScheduleEntry }
		local current = schedule[entry.index]
		if current == nil then
			runPipelineEnd(self, entry)
			return true
		end
		if current.kind == "delay" then
			if entry.at == nil then
				entry.at = now + entry.durations[entry.index]
			end
			if now < entry.at :: number then
				return false
			end
			entry.at = nil
			entry.index += 1
			continue
		end
		if current.kind == "await" then
			local decl = self.registry.schedules[current.name]
			if not decl.ready((current :: any).raw, entry.ictx.self, now) then
				return false
			end
			entry.index += 1
			continue
		end
		if entry.at == nil then
			entry.at = now + entry.durations[entry.index]
		end
		if now < entry.at :: number then
			return false
		end
		entry.at = (entry.at :: number) + entry.durations[entry.index]
		self.stats.repeats += 1
		if entry.index == #schedule then
			self.stats.ran += 1
			self.runner:invoke(entry.effect, entry.ictx, true)
		else
			local continuation = {
				kind = "pipeline",
				effect = entry.effect,
				ictx = entry.ictx,
				schedule = entry.schedule,
				durations = entry.durations,
				index = entry.index + 1,
				at = nil :: number?,
				args = nil,
			}
			self.stats.live += 1
			table.insert(self.entries, continuation)
		end
		return false
	end
end

function Queue.step(self: Queue, now: number)
	self.now = now
	self.stepped = true
	local entries = self.entries
	local i = 1
	while i <= #entries do
		local entry = entries[i]
		local done = false
		local subject = if entry.kind == "revoke" then entry.entity else entry.ictx.self
		if subject ~= nil and Entity.is(subject) and not Entity.alive(subject) then
			self.stats.deadDrops += 1
			done = true
		elseif entry.kind == "pipeline" then
			done = stepPipeline(self, entry, now)
		elseif entry.kind == "revoke" then
			if entry.at == nil then
				entry.at = now + entry.delay
			end
			if now >= entry.at then
				local setId = Attached.held(entry.entity)
				if setId ~= nil and setId ~= 0 then
					Attached.hold(entry.entity, self.intern:revoke(setId, entry.subId))
				end
				done = true
			end
		end
		if done then
			self.stats.live -= 1
			local last = #entries
			entries[i] = entries[last]
			entries[last] = nil
		else
			i += 1
		end
	end
end

return Queue
