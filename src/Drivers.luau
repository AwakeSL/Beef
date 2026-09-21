--!strict
--!optimize 2

local RunService = game:GetService("RunService")

local Phase = require(script.Parent.Phase)
local Events = require(script.Parent.Events)
local Kinds = require(script.Parent.Kinds)

export type Step = {
	time: number,
	dt: number,
	steps: number,
}

export type StepOptions = {
	kinds: { any }?,
	priority: number?,
}

local Drivers = {}

-- one connection per RunService signal, owned here, so the order within a frame is fixed and not the engine's
-- (signals fire their connections newest first): parallel collects deliver first, then the phases run, then the
-- parallel sends pack what the phases left
type Hook = { before: { () -> () }, phases: { Phase.Phase }, after: { () -> () } }
local hooks: { [string]: Hook } = {}
local function hook(name: string): Hook
	local h = hooks[name]
	if not h then
		local made: Hook = { before = {}, phases = {}, after = {} }
		hooks[name] = made
		h = made
		local signal = (RunService :: any)[name] :: RBXScriptSignal
		signal:Connect(function(dt: number?)
			local before, phases, after = made.before, made.phases, made.after
			for i = 1, #before do
				before[i]()
			end
			local frameDt = if type(dt) == "number" then dt else 0
			for i = 1, #phases do
				local phase: any = phases[i]
				phase.dt = frameDt
				phase.run()
			end
			for i = 1, #after do
				after[i]()
			end
		end)
	end
	return h
end

-- the two edges of a signal's frame: `before` runs ahead of every phase on it, `after` behind all of them.
-- Replicate delivers what arrived on the before edge and packs what the phases pushed on the after edge, the
-- way the parallel driver collects and sends around the same phases
function Drivers.before(signal: string, fn: () -> ())
	table.insert(hook(signal).before, fn)
end

function Drivers.after(signal: string, fn: () -> ())
	table.insert(hook(signal).after, fn)
end

-- each phase runs on its RunService signal; the frame time arrives as `phase.dt` for controllers that integrate
function Drivers.events(phases: { [string]: Phase.Phase })
	for event, phase in phases do
		table.insert(hook(event).phases, phase)
	end
end

-- runs the phases once per engine simulation step and keeps the step clock
-- with `kinds` given, each step also laps the events with that clock and ticks those kinds' history;
-- without, the boot does its own lapping and ticking from the returned clock
function Drivers.step(phases: { Phase.Phase }, frequency: Enum.StepFrequency, options: StepOptions?): Step
	local kinds = options and options.kinds
	local self: Step = { time = 0, dt = 0, steps = 0 }
	RunService:BindToSimulation(function(dt: number)
		self.dt = dt
		self.time += dt
		self.steps += 1
		for _, phase in phases do
			phase.run()
		end
		if kinds then
			Events.lap(self.time)
			Kinds.lap()
			for _, kind in kinds do
				kind.tick(self.time)
			end
		end
	end, frequency, options and options.priority or 2000)
	return self
end

-- ---------------------------------------------------------------- parallel

local SharedTableRegistry = game:GetService("SharedTableRegistry")
local Wire = require(script.Parent.Wire)

export type ParallelOptions = {
	name: string,                 -- names the shared table and the actors
	workers: number,
	phase: ModuleScript,          -- required inside each actor; returns the worker-side wiring (see Stock/Worker)
	ship: { any },                -- the kind first, then the components that cross each frame (all must have wire types)
	events: { any }?,             -- event types whose pushes cross each frame
	back: { any },                -- event types the worker phase pushes into; their pushes land here at `collect`
	send: string?,                -- RunService signal to pack and send on, PreSimulation by default
	collect: string?,             -- RunService signal to deliver results on, Heartbeat by default
}

export type Parallel = {
	frame: number,
	sent: number,
	received: number,
	bytes: number,
	busy: number,
	worst: number,
	sendTime: number,
	collectTime: number,
	workerWorst: number,
	workerTotal: number,
	gcGrowth: number,
}

-- pack a kind: a header naming each component and its element size, u32 count, the handles, then each component's
-- column in wire form; every column is contiguous with fixed-size elements, so a worker can read any slice of any
-- column by offset without touching the rest
local function packKind(kind: any, components: { any }): string
	local count = kind.count
	local header = 1
	for _, component in components do
		header += 1 + #component.name + 1
	end
	local size = header + 4 + count * 4
	for _, component in components do
		size += Wire.sizeOf(component.wire, nil) * count
	end
	local b = buffer.create(size)
	buffer.writeu8(b, 0, #components)
	local at = 1
	for _, component in components do
		local name = component.name
		buffer.writeu8(b, at, #name)
		buffer.writestring(b, at + 1, name)
		buffer.writeu8(b, at + 1 + #name, Wire.sizeOf(component.wire, nil))
		at += 2 + #name
	end
	buffer.writeu32(b, at, count)
	at += 4
	local handles = kind.handle
	for i = 1, count do
		buffer.writeu32(b, at, handles[i])
		at += 4
	end
	for _, component in components do
		local bucket = component.of(kind)
		local value, slot = bucket.value, bucket.slot
		local wire = component.wire
		if slot then
			-- optional here: go through the slot; rare on a shipped kind, keep the generic writer
			local writer = Wire.write[wire]
			for i = 1, count do
				at = writer(b, at, value[buffer.readu32(slot, (i - 1) * 4)])
			end
		elseif wire == "vector3" then
			for i = 1, count do
				local v = value[i]
				buffer.writef32(b, at, v.X)
				buffer.writef32(b, at + 4, v.Y)
				buffer.writef32(b, at + 8, v.Z)
				at += 12
			end
		elseif wire == "f32" then
			for i = 1, count do
				buffer.writef32(b, at, value[i])
				at += 4
			end
		elseif wire == "f64" then
			for i = 1, count do
				buffer.writef64(b, at, value[i])
				at += 8
			end
		elseif wire == "u32" or wire == "i32" then
			local write: (buffer, number, number) -> () = if wire == "u32" then buffer.writeu32 else buffer.writei32
			for i = 1, count do
				write(b, at, value[i])
				at += 4
			end
		else
			local writer = Wire.write[wire]
			for i = 1, count do
				at = writer(b, at, value[i])
			end
		end
	end
	return buffer.tostring(b)
end

-- pack this lap's pushes of an event type: u32 count then each column in wire form
local function packEvents(buffer_: any, from: number, last: number): string
	local count = math.max(0, last - from + 1)
	local size = 4
	for _, column in buffer_.columns do
		local kind = buffer_.wire[column]
		if kind == "string" then
			for i = from, last do
				size += 2 + #buffer_[column][i]
			end
		else
			size += Wire.sizeOf(kind, nil) * count
		end
	end
	local b = buffer.create(size)
	buffer.writeu32(b, 0, count)
	local at = 4
	for _, column in buffer_.columns do
		local writer = Wire.write[buffer_.wire[column]]
		local values = buffer_[column]
		for i = from, last do
			at = writer(b, at, values[i])
		end
	end
	return buffer.tostring(b)
end

-- unpack pushes packed by packEvents into an event type with the same columns
local function unpackEvents(s: string, buffer_: any)
	local b = buffer.fromstring(s)
	local count = buffer.readu32(b, 0)
	if count == 0 then
		return
	end
	local at = 4
	local width = #buffer_.columns
	local columns = {}
	for c, column in buffer_.columns do
		local reader = Wire.read[buffer_.wire[column]]
		local values = {}
		for i = 1, count do
			values[i], at = reader(b, at)
		end
		columns[c] = values
	end
	local args = {}
	for i = 1, count do
		for c = 1, width do
			args[c] = columns[c][i]
		end
		buffer_.push(table.unpack(args, 1, width))
	end
end

-- a phase run in actors: the shipped kind and events are packed ONCE into a shared table at `send`, each worker is
-- told its slice, and what the worker phase pushed into `back` is delivered into this side's event types at `collect`
-- sent before physics (PreAnimation or PreSimulation) the work runs inside the frame and is back by Heartbeat;
-- sent from Heartbeat it is back the next frame. on its collect signal the delivery runs before any phase, and on
-- its send signal the pack runs after them, whatever order the driver and the phases were created in
function Drivers.parallel(options: ParallelOptions): Parallel
	local kind = options.ship[1]
	local components = {}
	for i = 2, #options.ship do
		local component = options.ship[i]
		assert(component.wire and component.wire ~= "string" and component.wire ~= "kind", ("parallel %s: %s cannot cross"):format(options.name, component.name))
		table.insert(components, component)
	end
	local events: { any } = options.events or {}
	for _, e in events do
		for _, column in e.columns do
			assert(e.wire[column] and e.wire[column] ~= "kind", ("parallel %s: event %s column %s cannot cross"):format(options.name, e.name, column))
		end
	end
	for _, e in options.back do
		for _, column in e.columns do
			assert(e.wire[column] and e.wire[column] ~= "kind", ("parallel %s: back event %s column %s cannot cross"):format(options.name, e.name, column))
		end
	end

	local shared = SharedTable.new()
	SharedTableRegistry:SetSharedTable(options.name, shared)
	shared.frame = 0
	shared.kind = kind.name

	local self: Parallel = { frame = 0, sent = 0, received = 0, bytes = 0, busy = 0, worst = 0, sendTime = 0, collectTime = 0, workerWorst = 0, workerTotal = 0, gcGrowth = 0 }

	local template = script.Parent:WaitForChild("Stock"):WaitForChild("Worker")
	local actors = {}
	for w = 1, options.workers do
		local actor = Instance.new("Actor")
		actor.Name = options.name .. w
		actor:SetAttribute("shared", options.name)
		actor:SetAttribute("worker", w)
		local phaseRef = Instance.new("ObjectValue")
		phaseRef.Name = "Phase"
		phaseRef.Value = options.phase
		phaseRef.Parent = actor
		local root = Instance.new("ObjectValue")
		root.Name = "Beef"
		root.Value = script.Parent
		root.Parent = actor
		local worker = template:Clone()
		worker.Parent = actor
		actor.Parent = game:GetService("ServerScriptService")
		actors[w] = actor
	end

	local lastDt = 0
	RunService.Heartbeat:Connect(function(dt: number)
		lastDt = dt
	end)

	Drivers.before(options.collect or "Heartbeat", function()
		local t0 = os.clock()
		for w = 1, options.workers do
			local key = "result" .. w
			local blob = shared[key]
			if blob then
				shared[key] = nil
				self.received += 1
				self.bytes += #blob
				local b = buffer.fromstring(blob)
				local at = 0
				for _, e in options.back do
					local n = buffer.readu32(b, at)
					local size = buffer.readu32(b, at + 4)
					at += 8
					if n > 0 then
						unpackEvents(buffer.tostring(b):sub(at + 1, at + size), e)
					end
					at += size
				end
			end
		end
		-- what the workers reported about their own frame
		for w = 1, options.workers do
			local spent = shared["time" .. w]
			if spent then
				self.workerTotal += spent
				if spent > self.workerWorst then
					self.workerWorst = spent
				end
			end
		end
		local spent = os.clock() - t0
		self.busy += spent
		self.collectTime += spent
	end)

	local gcBefore = gcinfo()
	Drivers.after(options.send or "PreSimulation", function()
		local t0 = os.clock()
		local gcNow = gcinfo()
		if gcNow > gcBefore then
			self.gcGrowth += gcNow - gcBefore
		end
		gcBefore = gcNow
		local frameDt = lastDt
		self.frame += 1
		local frame = self.frame
		local kindBlob = packKind(kind, components)
		shared["kind" .. frame % 2] = kindBlob
		self.bytes += #kindBlob
		for _, e in events do
			local blob = packEvents(e, e.lapStart, e.count)
			shared[e.name .. frame % 2] = blob
			self.bytes += #blob
		end
		shared.frame = frame
		local count = kind.count
		local per = math.ceil(count / options.workers)
		for w = 1, options.workers do
			local from = (w - 1) * per + 1
			local to = math.min(w * per, count)
			actors[w]:SendMessage("run", frame, from, to, frameDt)
			self.sent += 1
		end
		local spent = os.clock() - t0
		self.busy += spent
		self.sendTime += spent
		if spent > self.worst then
			self.worst = spent
		end
		gcBefore = gcinfo()
	end)

	return self
end

Drivers.packEvents = packEvents
Drivers.unpackEvents = unpackEvents

return Drivers
