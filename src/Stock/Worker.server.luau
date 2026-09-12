--!strict
--!optimize 2
-- the stock worker: cloned under each Actor by Drivers.parallel; inert anywhere else
-- reads the frame's shipped kind and events from the shared table into this actor's own store, runs the phase
-- module's phase over its slice, and writes back what the phase pushed into the `back` event types
local actor = script:GetActor()
if not actor then
	return
end

local SharedTableRegistry = game:GetService("SharedTableRegistry")
-- a clone under an Actor has no path back to the package, so the driver leaves one on the actor
local Beef = (actor:WaitForChild("Beef") :: ObjectValue).Value :: Folder
local Kinds = require(Beef:WaitForChild("Kinds") :: ModuleScript) :: any
local Events = require(Beef:WaitForChild("Events") :: ModuleScript) :: any
local Wire = require(Beef:WaitForChild("Wire") :: ModuleScript) :: any
local Drivers = require(Beef:WaitForChild("Drivers") :: ModuleScript) :: any

local shared = SharedTableRegistry:GetSharedTable(actor:GetAttribute("shared") :: string)
local worker = actor:GetAttribute("worker") :: number
local setup = require((actor:WaitForChild("Phase") :: ObjectValue).Value :: ModuleScript) :: any
local kind, origin, components = setup.kind, setup.origin, setup.components
local seen: { [number]: number } = {}
local handles: { number } = {}
setup.slice.handles = handles

-- reads the header, resolves the components this phase declared by name, and unpacks only the rows this worker owns
-- (every row when the phase module says `everyone = true`) and only those columns
local names: { string } = {}
local sizes: { number } = {}
local columnAt: { number } = {}
local readers = {}
local wanted: { number } = {}
for c, component in components do
	readers[c] = Wire.read[component.wire]
end

local function unpackKind(blob: string, frame: number, from: number, to: number)
	local b = buffer.fromstring(blob)
	local nComponents = buffer.readu8(b, 0)
	local at = 1
	for c = 1, nComponents do
		local len = buffer.readu8(b, at)
		names[c] = buffer.readstring(b, at + 1, len)
		sizes[c] = buffer.readu8(b, at + 1 + len)
		at += 2 + len
	end
	local count = buffer.readu32(b, at)
	at += 4
	local handlesAt = at
	at += count * 4
	for c = 1, nComponents do
		columnAt[c] = at
		at += sizes[c] * count
	end
	for c, component in components do
		local col = table.find(names, component.name, 1)
		assert(col, ("worker: %s was not shipped"):format(component.name))
		wanted[c] = col
	end
	for i = #handles, 1, -1 do
		handles[i] = nil
	end
	local first, last = from, to
	if setup.everyone then
		first, last = 1, count
	end
	for i = first, last do
		local h = buffer.readu32(b, handlesAt + (i - 1) * 4)
		handles[i] = h
		seen[h] = frame
		local _, local_ = origin.find(h)
		local n = local_ and kind.at(local_)
		if n then
			for c, component in components do
				local col = wanted[c]
				component.of(kind).value[n] = readers[c](b, columnAt[col] + (i - 1) * sizes[col])
			end
		else
			local args = {}
			for c = 1, #components do
				local col = wanted[c]
				args[c] = readers[c](b, columnAt[col] + (i - 1) * sizes[col])
			end
			local spawned = kind.spawn(table.unpack(args, 1, #components))
			origin.add(kind, kind.at(spawned), h)
		end
	end
	-- anything this side still holds that it no longer owns is gone
	for h, f in seen do
		if f ~= frame then
			local _, local_ = origin.find(h)
			if local_ then
				kind.despawn(local_)
			end
			seen[h] = nil
		end
	end
	kind.apply()
end

actor:BindToMessageParallel("run", function(frame: number, from: number, to: number, dt: number)
	local t0 = os.clock()
	local slot = frame % 2
	unpackKind(shared["kind" .. slot], frame, from, to)
	for _, e in setup.events do
		local blob = shared[e.name .. slot]
		if blob then
			Drivers.unpackEvents(blob, e)
		end
	end
	setup.slice.from, setup.slice.to, setup.slice.dt = from, to, dt
	setup.phase.run()
	-- pack what the phase pushed this lap
	local parts = {}
	local total = 0
	for _, e in setup.back do
		local blob = Drivers.packEvents(e, e.lapStart, e.count)
		table.insert(parts, { n = math.max(0, e.count - e.lapStart + 1), blob = blob })
		total += 8 + #blob
	end
	local out = buffer.create(total)
	local at = 0
	for _, part in parts do
		buffer.writeu32(out, at, part.n)
		buffer.writeu32(out, at + 4, #part.blob)
		buffer.writestring(out, at + 8, part.blob)
		at += 8 + #part.blob
	end
	Events.lap(frame)
	Kinds.lap()
	shared["result" .. worker] = buffer.tostring(out)
	shared["time" .. worker] = os.clock() - t0
end)
