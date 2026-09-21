--!strict
--!optimize 2
-- Camera: the stock camera controller. It puts the client's one camera where the mode says, lays the
-- effects the game pushed on top of that, and leaves the aim underneath readable, so whatever wants to
-- know where the player is looking reads a Component instead of the engine. It runs on the client.
--
-- The four things it is handed are the game's. `Transform` is a Component holding a CFrame, the body the
-- camera follows. A CFrame and not a position, because a follow camera swings around behind the body as
-- the body turns, and a position cannot say which way that is. `Effect` is an Event the game pushes camera
-- effects into. `View` is the Component that says what the camera is doing and where it ended up pointing:
-- the game writes the mode and the turn into it, this writes the aim back. `modes` says which modes exist
-- and what each one's constraints are.
--
-- The aim is in a Component rather than a field on the controller because a phase builds its controllers
-- itself and hands them to nobody, so a field on one is not readable from another. It goes on the body
-- rather than anywhere global for the same reason Movement's dash does: it dies with the entity.
--
-- Why the turn arrives in `View` rather than being read here. Turning a camera is input, and Input owns
-- input. A game binds a look action, reads its pushes, and adds to `yaw` and `pitch`; this clamps the pitch
-- to the mode's limits and writes the clamp back, so an accumulator does not wind up past the limit and
-- stick. That keeps this controller off `Action` entirely, which is what the spec fixed it to read.
--
-- Writing the camera touches the engine, so it goes through a driver the way Input's does: live it is
-- `workspace.CurrentCamera` and a raycast, headless it is `Beef.Stock.film()`, which records every write so
-- a spec can assert on it.
--
-- What it keeps between frames is the mechanism's own timing and nothing else: which effect is running,
-- how much of it is left, and a clock the shake is a function of. Everything else is on the entity.

local Engine = require(script.Engine)

-- the four modes, and no more: each puts the camera somewhere else for a different reason, and a game
-- wanting a fifth writes a controller of its own against the same Components
local NAMES: { string } = { "first", "fixed", "follow", "orbit" }

-- which effect a push names, and the slot its numbers live in while it runs
local SLOT: { [string]: number } = { punch = 1, shake = 2, zoom = 3 }
local RUNNING = 3

-- what the Effect event has to carry for this to read it
local COLUMNS: { string } = { "effect", "amount", "x", "y", "lasts" }

local FOV = 90 -- horizontal degrees when a mode does not say
local LOW, HIGH = -80, 80 -- pitch degrees when a mode does not say
local NARROW, WIDE = 1, 120 -- what Roblox takes for a field of view
local ASPECT = 16 / 9 -- what a viewport of no size is treated as, so a headless run still has an answer
local STEEP = 89 -- a pitch limit at or past straight up has no yaw left to turn around

-- two frequencies that do not divide into each other, so the shake traces a figure rather than a line, and
-- an offset so X and Y do not start together
local SHAKE_X, SHAKE_Y, SHAKE_OFF = 17.3, 13.1, 1.7

local ZERO = Vector3.zero

export type Mode = {
	name: string,
	distance: number,
	offset: Vector3,
	low: number, -- pitch limits in radians, ready to clamp against
	high: number,
	collide: boolean,
	fov: number, -- horizontal degrees
	at: CFrame?,
}

-- the engine edge. Live it writes `workspace.CurrentCamera` and reads the viewport; headless it is `film`,
-- which keeps every write. `clear` answers how much of the way from the subject out to where the camera
-- wants to sit is unobstructed, 1 being nothing in the way.
export type Driver = {
	start: () -> (),
	viewport: () -> Vector2,
	clear: (from: Vector3, to: Vector3) -> number,
	set: (at: CFrame, fov: number) -> (),
}

-- an option belongs to some modes and not others, the way a Movement option belongs to some moves
local OPTIONS: { [string]: { [string]: boolean } } = {
	at = { fixed = true },
	collide = { follow = true, orbit = true },
	distance = { follow = true, orbit = true },
	fov = { first = true, fixed = true, follow = true, orbit = true },
	offset = { first = true, fixed = true, follow = true, orbit = true },
	pitch = { first = true, follow = true, orbit = true },
}

-- and some of them are the mode: a follow with no distance is not a follow
local NEEDED: { [string]: { string } } = {
	first = {},
	fixed = { "at" },
	follow = { "distance" },
	orbit = { "distance" },
}

local function listed(allowed: { [string]: any }): string
	local names = {}
	for key in allowed do
		table.insert(names, key)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

local function above(name: string, option: string, value: any): number
	assert(type(value) == "number" and value > 0, ("Camera %s: %s is a number above zero"):format(name, option))
	return value
end

-- ---------------------------------------------------------------- the modes table

local function read(modes: { [string]: any }): { [string]: Mode }
	assert(type(modes) == "table", "Camera: modes is a table of mode names and what each one does with the camera")

	-- in one fixed order, so two clients build the same modes the same way twice
	local named: { string } = {}
	for name in modes do
		assert(type(name) == "string", ("Camera: a mode is named by a string, not a %s"):format(typeof(name)))
		assert(
			table.find(NAMES, name) ~= nil,
			("Camera: %s is not a mode here; %s are"):format(name, table.concat(NAMES, ", "))
		)
		table.insert(named, name)
	end
	table.sort(named)
	assert(#named > 0, "Camera: modes names at least one mode")

	local declared: { [string]: Mode } = {}

	for _, name in named do
		local given = modes[name]
		assert(
			type(given) == "table",
			("Camera %s: a mode is a table saying where it puts the camera and what it may not do"):format(name)
		)

		for key in given do
			local allowed = OPTIONS[key]
			assert(allowed ~= nil, ("Camera %s: %s is not an option here; %s are"):format(name, tostring(key), listed(OPTIONS)))
			assert(allowed[name], ("Camera %s: %s is an option on %s, not on %s"):format(name, tostring(key), listed(allowed), name))
		end

		-- "an orbit", not "a orbit": the message is read by a person
		local article = if name:sub(1, 1):find("[aeiou]") then "an" else "a"
		for _, option in NEEDED[name] do
			assert(given[option] ~= nil, ("Camera %s: %s %s needs %s"):format(name, article, name, option))
		end

		local low, high = LOW, HIGH
		if given.pitch ~= nil then
			local limits = given.pitch
			assert(
				type(limits) == "table" and type(limits[1]) == "number" and type(limits[2]) == "number",
				("Camera %s: pitch is how far down and how far up it may look, in degrees"):format(name)
			)
			low, high = limits[1], limits[2]
			assert(low < high, ("Camera %s: pitch looks down first and up second"):format(name))
			assert(
				low >= -STEEP and high <= STEEP,
				("Camera %s: pitch stays inside %d degrees of level, since straight up has no way left to turn"):format(name, STEEP)
			)
		end

		local fov = FOV
		if given.fov ~= nil then
			fov = given.fov
			assert(
				type(fov) == "number" and fov > 0 and fov < 180,
				("Camera %s: fov is how many degrees of the world are across the screen"):format(name)
			)
		end

		local offset = ZERO
		if given.offset ~= nil then
			assert(typeof(given.offset) == "Vector3", ("Camera %s: offset is a Vector3 from the body"):format(name))
			offset = given.offset
		end

		if given.collide ~= nil then
			assert(type(given.collide) == "boolean", ("Camera %s: collide is true or false"):format(name))
		end

		if given.at ~= nil then
			assert(typeof(given.at) == "CFrame", ("Camera %s: at is the CFrame the camera sits at"):format(name))
		end

		declared[name] = {
			name = name,
			distance = if given.distance ~= nil then above(name, "distance", given.distance) else 0,
			offset = offset,
			low = math.rad(low),
			high = math.rad(high),
			collide = given.collide == true,
			fov = fov,
			at = given.at,
		}
	end

	return declared
end

-- ---------------------------------------------------------------- the controller

-- the factory. `chosen` is the engine edge and a game never passes it: live it is `workspace.CurrentCamera`,
-- and a spec hands a `Beef.Stock.film()` instead, which records every write.
return function(transform: any, effect: any, view: any, modes: { [string]: any }, chosen: Driver?): any
	assert(
		type(transform) == "table" and type(transform.of) == "function",
		"Camera: the first thing handed to it is the Component holding the body's CFrame"
	)
	assert(type(effect) == "table" and type(effect.push) == "function", "Camera: the second thing handed to it is the Effect event type")
	assert(type(view) == "table" and type(view.of) == "function", "Camera: the third thing handed to it is the Component the camera's view goes in")
	for _, column in COLUMNS do
		assert(
			table.find(effect.columns, column) ~= nil,
			("Camera: the Effect event needs a %s column; it carries %s"):format(column, table.concat(effect.columns, ", "))
		)
	end

	local driver: Driver = chosen or Engine
	local declared = read(modes)

	-- the mode a body takes when its view names none. One declared mode is unambiguous; more than one and
	-- the body has to say which, since guessing would put the camera somewhere the game never asked for.
	local only: string? = nil
	local count = 0
	for name in declared do
		count += 1
		only = name
	end
	local lone = if count == 1 then only else nil

	-- this controller's own timing, and nothing else: what each effect was pushed with, how much of its
	-- length is left, and a clock the shake is a function of
	local amount: { number } = table.create(RUNNING, 0)
	local left: { number } = table.create(RUNNING, 0)
	local span: { number } = table.create(RUNNING, 0)
	local ex: { number } = table.create(RUNNING, 0)
	local ey: { number } = table.create(RUNNING, 0)
	local clock = 0

	-- reused, so finding the subject costs no garbage
	local spots: { number } = {}

	-- how much of a running effect is left, 1 on the frame it was pushed and 0 when it is over
	local function strength(slot: number): number
		local full = span[slot]
		if full <= 0 then
			return 0
		end
		local rest = left[slot]
		if rest <= 0 then
			return 0
		end
		return rest / full
	end

	-- the yaw of a CFrame's look, which is the way a follow camera swings around to sit behind
	local function facing(at: CFrame): number
		local look = at.LookVector
		return math.atan2(-look.X, -look.Z)
	end

	local self: any
	self = {
		name = "Camera",
		reads = { effect },

		boot = function()
			driver.start()
		end,

		post = function()
			local dt = self.phase.dt
			clock += dt

			-- what the game pushed. One of each effect runs at a time and a new push replaces what was
			-- running, so a zoom a game wants held is pushed every frame and a shake that lands twice does
			-- not stack into something nobody can watch.
			for i = effect.from, effect.last do
				local slot = SLOT[effect.effect[i]]
				if slot == nil then
					continue
				end
				local lasts = effect.lasts[i]
				if type(lasts) ~= "number" or lasts <= 0 then
					continue
				end
				amount[slot] = effect.amount[i] or 0
				ex[slot] = effect.x[i] or 0
				ey[slot] = effect.y[i] or 0
				span[slot] = lasts
				left[slot] = lasts
			end

			-- the subject: the one body carrying the view. There is one camera, so the first one found is
			-- it, and a client gives the view Component to exactly one body.
			local kinds = view.kinds()
			local subject: any = nil
			local kind: any = nil
			local spot = 0
			for k = 1, #kinds do
				local candidate = kinds[k]
				local n = view.intersect(candidate, spots)
				if n > 0 then
					kind = candidate
					spot = spots[1]
					subject = view.get(candidate, spot)
					break
				end
			end

			if subject ~= nil then
				assert(type(subject) == "table", "Camera: a view's value is a table saying which mode the camera is in and where it is turned")
				local named = subject.mode or lone
				assert(
					named ~= nil,
					"Camera: the view names no mode and more than one is declared, so there is nothing to pick between them"
				)
				local mode = declared[named]
				assert(mode ~= nil, ("Camera: the view asks for %s, which is not a mode here"):format(tostring(named)))

				local body: CFrame? = transform.get(kind, spot)
				local here = if body ~= nil then body.Position else ZERO
				local pivot = here + mode.offset

				-- the pitch is clamped here and written back, so a game that keeps adding to it does not
				-- have to unwind a long way before the camera moves again
				local pitch = subject.pitch or 0
				if pitch < mode.low then
					pitch = mode.low
				elseif pitch > mode.high then
					pitch = mode.high
				end
				local yaw = subject.yaw or 0

				local aim: CFrame
				if mode.name == "fixed" then
					local sits = (mode.at :: CFrame)
					if body ~= nil then
						local toward = pivot - sits.Position
						if toward.Magnitude > 1e-4 then
							local way = toward.Unit
							aim = CFrame.new(sits.Position)
								* CFrame.fromEulerAnglesYXZ(math.asin(math.clamp(way.Y, -1, 1)), math.atan2(-way.X, -way.Z), 0)
						else
							aim = sits
						end
					else
						aim = sits
					end
				else
					subject.pitch = pitch
					-- a follow camera adds the body's own yaw, so it sits behind the body and stays there as
					-- the body turns; an orbit camera does not, so the body turns underneath it
					local turn = if mode.name == "follow" and body ~= nil then yaw + facing(body) else yaw
					local rot = CFrame.fromEulerAnglesYXZ(pitch, turn, 0)
					if mode.name == "first" then
						aim = CFrame.new(pivot) * rot
					else
						local wanted = pivot + rot * Vector3.new(0, 0, mode.distance)
						if mode.collide then
							local open = driver.clear(pivot, wanted)
							wanted = pivot + (wanted - pivot) * math.clamp(open, 0, 1)
						end
						aim = CFrame.new(wanted) * rot
					end
				end

				-- the aim with nothing on it, which is what a game reads to know where the player is looking
				subject.at = aim

				local out = aim
				local fov = mode.fov

				local punch = strength(1)
				if punch > 0 then
					-- x kicks the view right, y kicks it up, in degrees, decaying back to where the mode put it
					local by = amount[1] * punch
					out = out * CFrame.Angles(math.rad(by * ey[1]), -math.rad(by * ex[1]), 0)
				end

				local shake = strength(2)
				if shake > 0 then
					local by = amount[2] * shake
					out = out * CFrame.new(by * math.sin(clock * SHAKE_X), by * math.sin(clock * SHAKE_Y + SHAKE_OFF), 0)
				end

				local zoom = strength(3)
				if zoom > 0 then
					fov += amount[3] * zoom
				end

				-- the mode says how much of the world is across the screen; Roblox wants the angle up the
				-- screen, and which is which depends on how wide the window is, so the viewport is read here
				local size = driver.viewport()
				local aspect = if size ~= nil and size.Y > 0 then size.X / size.Y else ASPECT
				local across = math.clamp(fov, NARROW, 179)
				local up = math.deg(2 * math.atan(math.tan(math.rad(across) / 2) / aspect))
				driver.set(out, math.clamp(up, NARROW, WIDE))
			end

			-- every running effect loses its frame whether or not there was a camera to put it on
			for i = 1, RUNNING do
				if left[i] > 0 then
					left[i] -= dt
					if left[i] <= 0 then
						left[i] = 0
						span[i] = 0
					end
				end
			end
		end,
	}
	return self
end
