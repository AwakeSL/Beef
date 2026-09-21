--!strict
--!optimize 2

local Events = require(script.Parent.Events)

export type Controller = {
	name: string,
	reads: { any }?,
	writes: { any }?,
	boot: (() -> ())?,
	pre: (() -> ())?,
	loop: (() -> ())?,
	post: (() -> ())?,
	phase: Phase?,
}

export type Entry = { any }

export type Phase = {
	name: string,
	dt: number,
	run: () -> (),
	passes: number,
	describe: () -> string,
	replay: (kind: any, handle: number, from: number, to: number) -> number,
}

local DONE = {}
local PASS_CAP = 32

local function isBuffer(value: any): boolean
	return type(value) == "table" and type(value.freeze) == "function"
end

local Phase = {}

function Phase.new(name: string, entries: { Entry }): Phase
	local buffers: { Events.Buffer } = {}
	local seen: { [Events.Buffer]: boolean } = {}
	local boot: { () -> () } = {}
	local pre: { () -> () } = {}
	local loop: { () -> () } = {}
	local post: { () -> () } = {}
	local owner: { [() -> ()]: string } = {}
	local controllers: { Controller } = {}
	local usage: { { buffer: Events.Buffer, controller: string, how: string } } = {}
	local kinds: { any } = {}
	local kindSeen: { [any]: boolean } = {}
	local readsOf: { [Controller]: { Events.Buffer } } = {}

	local function frozen(buffer: Events.Buffer)
		if not seen[buffer] then
			seen[buffer] = true
			table.insert(buffers, buffer)
		end
	end

	for _, entry in entries do
		local factory = entry[1]
		assert(type(factory) == "function", name .. ": each entry starts with a controller factory")
		local controller: Controller = factory(table.unpack(entry, 2))
		assert(type(controller) == "table" and type(controller.name) == "string", name .. ": a factory must return a controller")
		local who = controller.name
		assert(
			controller.boot or controller.pre or controller.loop or controller.post,
			("%s/%s: a controller needs a boot, pre, loop or post"):format(name, who)
		)
		table.insert(controllers, controller)

		local declared: { [any]: string } = {}
		for _, buffer in (controller.reads or {}) :: { any } do
			assert(isBuffer(buffer), ("%s/%s: reads must hold event types"):format(name, who))
			declared[buffer] = "reads"
		end
		for _, buffer in (controller.writes or {}) :: { any } do
			assert(isBuffer(buffer), ("%s/%s: writes must hold event types"):format(name, who))
			declared[buffer] = if declared[buffer] then "reads, writes" else "writes"
		end

		-- a buffer this controller declared gets exactly what a handed one gets: frozen, in readsOf,
		-- in usage. A controller can be handed the same buffer besides (Gun above), or never handed it
		-- at all (Sound's Events live inside a map table); either way it is registered once.
		local registered: { [any]: boolean } = {}
		local function register(buffer: any, how: string)
			if registered[buffer] then
				return
			end
			registered[buffer] = true
			table.insert(usage, { buffer = buffer, controller = who, how = how })
			if how ~= "writes" then
				frozen(buffer)
				local list = readsOf[controller]
				if not list then
					list = {}
					readsOf[controller] = list
				end
				table.insert(list, buffer)
			end
		end
		for buffer, how in declared do
			register(buffer, how)
		end

		for i = 2, #entry do
			local handed = entry[i]
			if isBuffer(handed) then
				register(handed, declared[handed] or "uses")
			elseif type(handed) == "table" and type(handed.spawn) == "function" and not kindSeen[handed] then
				kindSeen[handed] = true
				table.insert(kinds, handed)
			end
		end

		if controller.boot then
			table.insert(boot, controller.boot)
			owner[controller.boot] = who
		end
		if controller.pre then
			table.insert(pre, controller.pre)
			owner[controller.pre] = who
		end
		if controller.loop then
			table.insert(loop, controller.loop)
			owner[controller.loop] = who
		end
		if controller.post then
			table.insert(post, controller.post)
			owner[controller.post] = who
		end
	end
	local m = #buffers
	local npre, nloop, npost = #pre, #loop, #post

	-- a pass after the first delivers new events to their readers only: a loop controller reading nothing that moved
	-- (an integrator, say) runs once per frame, not once per pass
	local bufferIndex: { [Events.Buffer]: number } = {}
	for i, buffer in buffers do
		bufferIndex[buffer] = i
	end
	local loopReads: { { number } } = {}
	do
		local j = 0
		for _, controller in controllers do
			if controller.loop then
				j += 1
				local list = {}
				for _, buffer in (readsOf[controller] or {}) :: { Events.Buffer } do
					table.insert(list, bufferIndex[buffer])
				end
				loopReads[j] = list
			end
		end
	end
	local movedFlag: { boolean } = table.create(m, false)

	local cursors: { number } = {}
	local passCursors: { number } = {}
	local preCursors: { number } = {}
	for i, buffer in buffers do
		cursors[i] = buffer.base + buffer.count + 1
		passCursors[i] = cursors[i]
		preCursors[i] = cursors[i]
	end

	local self: Phase = {
		name = name,
		dt = 0,
		run = function() end,
		passes = 0,
		describe = function()
			return ""
		end,
		replay = function()
			return 0
		end,
	}
	for _, controller in controllers do
		controller.phase = self
	end

	local function body()
		-- boot runs once, in order, before the first frame
		for i = 1, #boot do
			boot[i]()
		end
		table.clear(boot)
		while true do
			-- pre sees every push since the previous frame's pre; a lap moves the pushes, so the window is taken fresh
			for i = 1, m do
				preCursors[i] = buffers[i].freeze(preCursors[i])
			end
			for i = 1, npre do
				pre[i]()
			end

			-- passCursors is never reset from cursors here: it already sits where the loop left off
			-- last frame. Usually that is the same point cursors holds too, since a frame that quiets
			-- down naturally has nothing left unfrozen. A frame that hits the pass cap below is the
			-- exception: passCursors stops short of what the capped pass pushed, on purpose, so that
			-- leftover is exactly what the next frame's first pass (which always runs) freezes and
			-- delivers, once, before anything else. post keeps reading from `cursors`, unaffected.
			local passes = 0
			if nloop > 0 then
				while true do
					for i = 1, m do
						passCursors[i] = buffers[i].freeze(passCursors[i])
					end
					if passes == 0 then
						for i = 1, nloop do
							loop[i]()
						end
					else
						for j = 1, nloop do
							local reads = loopReads[j]
							for r = 1, #reads do
								if movedFlag[reads[r]] then
									loop[j]()
									break
								end
							end
						end
					end
					passes += 1
					local moved = false
					for i = 1, m do
						local buffer = buffers[i]
						local grew = buffer.base + buffer.count + 1 > passCursors[i]
						movedFlag[i] = grew
						if grew then
							moved = true
						end
					end
					if not moved then
						break
					end
					if passes >= PASS_CAP then
						warn(name .. " hit the pass cap; the rest carries to the next frame")
						break
					end
				end
			end
			self.passes = passes

			if npost > 0 then
				for i = 1, m do
					cursors[i] = buffers[i].freeze(cursors[i])
				end
				for i = 1, npost do
					post[i]()
				end
			else
				for i = 1, m do
					local buffer = buffers[i]
					cursors[i] = buffer.base + buffer.count + 1
				end
			end

			coroutine.yield(DONE)
		end
	end

	local co = coroutine.create(body)

	local function yielder(): string
		for level = 1, 100 do
			local fn = debug.info(co, level, "f")
			if not fn then
				break
			end
			local who = owner[fn]
			if who then
				return who
			end
		end
		return "?"
	end

	self.run = function()
		if npre > 0 then
			for i = 1, m do
				buffers[i].freeze(cursors[i])
			end
		end

		local ok, mark = coroutine.resume(co)
		if not ok then
			warn(name .. " errored: " .. tostring(mark))
			co = coroutine.create(body)
		elseif mark ~= DONE then
			warn(name .. "/" .. yielder() .. " yielded")
			coroutine.close(co)
			co = coroutine.create(body)
		end
	end

	-- every event type a controller here can push into: silenced while replaying
	local pushed: { Events.Buffer } = {}
	do
		local seenPush: { [Events.Buffer]: boolean } = {}
		for _, use in usage do
			if use.how ~= "reads" and not seenPush[use.buffer] then
				seenPush[use.buffer] = true
				table.insert(pushed, use.buffer)
			end
		end
	end
	local function silent() end

	-- rewind one entity to `from`, then run the loop stage over each retained lap stamped after it up to `to`
	-- an event type that names its entity column is stepped one matching push at a time; one without is replayed whole
	-- pushes made by this phase's controllers are dropped for the duration
	local savedFrom: { number } = {}
	local savedLast: { number } = {}
	local savedPush: { (...any) -> () } = {}
	local stamps: { number } = {}
	local stampSeen: { [number]: boolean } = {}
	self.replay = function(kind: any, handle: number, from: number, to: number): number
		assert(kind.rewind, name .. ": replay needs a kind with history")
		local start = kind.rewind(handle, from)
		if not start then
			return 0
		end
		-- the lap stamps to walk, from every kept event type read here, ascending
		table.clear(stamps)
		table.clear(stampSeen)
		for i = 1, m do
			local buffer = buffers[i]
			for k = 1, buffer.laps() do
				local _, _, time = buffer.lapWindow(k)
				if time > start and time <= to and not stampSeen[time] then
					stampSeen[time] = true
					table.insert(stamps, time)
				end
			end
		end
		if #stamps == 0 then
			return 0
		end
		table.sort(stamps)

		for i = 1, m do
			savedFrom[i] = buffers[i].from
			savedLast[i] = buffers[i].last
		end
		for i, buffer in pushed do
			savedPush[i] = buffer.push
			buffer.push = silent
		end

		for _, time in stamps do
			for i = 1, m do
				buffers[i].from, buffers[i].last = 1, 0
			end
			for i = 1, m do
				local buffer = buffers[i]
				local f, l = 1, 0
				for k = 1, buffer.laps() do
					local lf, ll, t = buffer.lapWindow(k)
					if t == time then
						f, l = lf, ll
						break
					end
				end
				if l < f then
					continue
				end
				local column = buffer.entity and buffer[buffer.entity]
				if column then
					for i = f, l do
						if column[i] == handle then
							buffer.from, buffer.last = i, i
							for j = 1, nloop do
								loop[j]()
							end
						end
					end
				else
					buffer.from, buffer.last = f, l
					for j = 1, nloop do
						loop[j]()
					end
				end
				buffer.from, buffer.last = 1, 0
			end
		end

		for i, buffer in pushed do
			buffer.push = savedPush[i]
		end
		for i = 1, m do
			buffers[i].from = savedFrom[i]
			buffers[i].last = savedLast[i]
		end
		return #stamps
	end

	self.describe = function(): string
		local lines = { name }
		local byBuffer: { [Events.Buffer]: { string } } = {}
		local order: { Events.Buffer } = {}
		for _, use in usage do
			if not byBuffer[use.buffer] then
				byBuffer[use.buffer] = {}
				table.insert(order, use.buffer)
			end
			table.insert(byBuffer[use.buffer], use.controller .. " " .. use.how)
		end
		for _, buffer in order do
			table.insert(lines, ("  %-10s %s"):format(buffer.name, table.concat(byBuffer[buffer], ", ")))
			local kept = if buffer.keep > 1 then ("  kept %d laps, %s"):format(buffer.keep, buffer.entity and ("entity " .. buffer.entity) or "global") else ""
			table.insert(lines, ("  %-10s held %d  lost %d  unread %d%s"):format("", buffer.count, buffer.lost, buffer.unread, kept))
		end
		for _, kind in kinds do
			local names = {}
			for _, component in kind.required do
				table.insert(names, component.name)
			end
			for _, component in kind.optional do
				table.insert(names, component.name .. "?")
			end
			table.insert(lines, ("  %-10s alive %d  components %s"):format(kind.name, kind.count, table.concat(names, ", ")))
		end
		return table.concat(lines, "\n")
	end

	return self
end

return Phase
