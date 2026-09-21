--!strict
--!optimize 2
-- Movement: the second stock controller, and the first that reads what Input wrote. It turns the frame's
-- Action pushes into a velocity on every body the game marked as controlled, and that is all of it. It
-- never touches a Humanoid, a part, or the engine, so gravity, the ground, standing on a moving platform
-- and anything that pushes back are the game's, and it is the game that decides what a velocity does to a
-- body once this has written one.
--
-- The three things it is handed are the game's. `Action` is the Event Input writes. `Body` is a Component
-- the controlled body carries, whose value says what that body may do and which way forward is for it.
-- `Velocity` is the Component the answer goes in, a Vector3. `moves` says which action means which move
-- and with what numbers.
--
-- Where the decisions went. A jump is a Y this writes once and never takes back, because taking it back
-- is gravity and gravity is a physics opinion. A body that may not jump right now is a body whose
-- `granted.jump` is false, set by whoever does know about the ground. X and Z are this controller's every
-- frame; Y is only ever touched on the frame a jump begins, so whatever integrates it owns it the rest of
-- the time.
--
-- What it keeps between frames is what the edges add up to and nothing about any body: which move actions
-- are down, and where the steer last was, since a stick held still reports nothing. A dash in progress is
-- on the body, in the Body value, so it dies with the entity.
--
-- It is one `post`, once a frame. The Action window there is the whole frame's pushes, so nothing is
-- missed, and the clock is counted down once rather than once per pass of the loop. Whatever applies the
-- velocity to a body goes after this: later in the same phase's post, or in a later phase.

local Action = require(script.Parent.Action)

local Phases = Action.Phases
local BEGAN, CHANGED, ENDED, FIRED = Phases.Began, Phases.Changed, Phases.Ended, Phases.Fired

local FORWARD = Vector3.new(0, 0, -1)
local ZERO = Vector3.zero

-- one move as the factory keeps it
export type Move = {
	action: string,
	speed: number?,
	power: number?,
	lasts: number?,
	accelerate: number?,
}

-- the five moves, and no more: each is a different thing to do with a velocity, and a game wanting a sixth
-- writes a controller of its own against the same Action and the same Components
local NAMES: { string } = { "crouch", "dash", "jump", "sprint", "walk" }

-- an option belongs to some moves and not others, the way an Input option belongs to some triggers
local OPTIONS: { [string]: { [string]: boolean } } = {
	speed = { walk = true, sprint = true, crouch = true, dash = true },
	power = { jump = true },
	lasts = { dash = true },
	accelerate = { walk = true },
}

-- and some of them are the move: a dash with no length is not a dash
local NEEDED: { [string]: { string } } = {
	crouch = { "speed" },
	dash = { "speed", "lasts" },
	jump = { "power" },
	sprint = { "speed" },
	walk = { "speed" },
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
	assert(type(value) == "number" and value > 0, ("Movement %s: %s is a number above zero"):format(name, option))
	return value
end

-- a move is granted when the body says so; a body that says nothing about it may make every move the table
-- declares, so a game that never takes a move away never writes the field
local function may(it: any, name: string): boolean
	local granted = it.granted
	if granted == nil then
		return true
	end
	return granted[name] == true
end

-- ---------------------------------------------------------------- the moves table

local function read(moves: { [string]: any }): ({ [string]: Move }, { [string]: { string } })
	assert(type(moves) == "table", "Movement: moves is a table of move names and what each one moves by")

	-- in one fixed order, so two clients build the same moves the same way twice
	local named: { string } = {}
	for name in moves do
		assert(type(name) == "string", ("Movement: a move is named by a string, not a %s"):format(typeof(name)))
		assert(
			table.find(NAMES, name) ~= nil,
			("Movement: %s is not a move here; %s are"):format(name, table.concat(NAMES, ", "))
		)
		table.insert(named, name)
	end
	table.sort(named)
	assert(moves.walk ~= nil, "Movement: moves names walk, the move the steer comes from and the others are measured against")

	local declared: { [string]: Move } = {}
	-- which moves an action name has anything to do with, so a push is looked up once
	local cares: { [string]: { string } } = {}

	for _, name in named do
		local given = moves[name]
		assert(type(given) == "table", ("Movement %s: a move is a table saying which action it reads and what it moves by"):format(name))

		local reads = given.action
		assert(type(reads) == "string", ("Movement %s: action names the action this move reads, the name the bindings table gave it"):format(name))

		for key in given do
			if key == "action" then
				continue
			end
			local allowed = OPTIONS[key]
			assert(allowed ~= nil, ("Movement %s: %s is not an option here; %s are"):format(name, tostring(key), listed(OPTIONS)))
			assert(allowed[name], ("Movement %s: %s is an option on %s, not on %s"):format(name, tostring(key), listed(allowed), name))
		end

		local move: Move = { action = reads }
		local into: any = move
		for _, option in NEEDED[name] do
			assert(given[option] ~= nil, ("Movement %s: a %s needs %s"):format(name, name, option))
			into[option] = above(name, option, given[option])
		end
		if given.accelerate ~= nil then
			move.accelerate = above(name, "accelerate", given.accelerate)
		end

		declared[name] = move
		local list = cares[reads]
		if list == nil then
			list = {}
			cares[reads] = list
		end
		table.insert(list, name)
	end

	return declared, cares
end

-- ---------------------------------------------------------------- the controller

return function(action: any, body: any, velocity: any, moves: { [string]: any }): any
	assert(type(action) == "table" and type(action.push) == "function", "Movement: the first thing handed to it is the Action event type")
	assert(type(body) == "table" and type(body.of) == "function", "Movement: the second thing handed to it is the Component a controlled body carries")
	assert(type(velocity) == "table" and type(velocity.of) == "function", "Movement: the third thing handed to it is the Component the velocity goes in")

	local declared, cares = read(moves)
	local walk = declared.walk :: Move
	local sprint = declared.sprint
	local crouch = declared.crouch
	local jump = declared.jump
	local dash = declared.dash

	local down: { [string]: boolean } = {}
	local steerX, steerY = 0, 0
	local jumping = false
	local dashing = false

	local self: any
	self = {
		name = "Movement",
		reads = { action },

		post = function()
			-- what the frame's pushes add up to. A move action that is down stays down until it ends, and
			-- the steer stays where it was put, because a stick held still reports nothing at all.
			for i = action.from, action.last do
				local names = cares[action.action[i]]
				if names == nil then
					continue
				end
				local phase = action.phase[i]
				for _, name in names do
					if name == "walk" then
						if phase == CHANGED then
							steerX, steerY = action.x[i], action.y[i]
						elseif phase == ENDED then
							steerX, steerY = 0, 0
						end
					elseif phase == BEGAN then
						down[name] = true
						if name == "jump" then
							jumping = true
						elseif name == "dash" then
							dashing = true
						end
					elseif phase == ENDED then
						down[name] = false
					elseif phase == CHANGED then
						-- an analog trigger bound to a move: it is down while it reads anything
						down[name] = action.value[i] ~= 0
					elseif phase == FIRED then
						-- a sequence completed. It has nothing to end, so it starts a move and holds none
						-- down, which is how a double tap becomes a dash.
						if name == "jump" then
							jumping = true
						elseif name == "dash" then
							dashing = true
						end
					end
				end
			end

			-- the steer, clamped: a reading past one is a stick the engine scaled, not a licence to go
			-- faster than the move says
			local steer = math.sqrt(steerX * steerX + steerY * steerY)
			local sx, sy = steerX, steerY
			if steer > 1 then
				sx, sy, steer = sx / steer, sy / steer, 1
			end

			local dt = self.phase.dt
			local faster = sprint ~= nil and down.sprint == true
			local slower = crouch ~= nil and down.crouch == true

			local kinds = body.kinds()
			for k = 1, #kinds do
				local kind = kinds[k]
				local n, bodies, bodyAt, speeds, speedAt = body.join(kind, velocity)
				for i = 1, n do
					local it = bodies[bodyAt[i]]
					assert(type(it) == "table", "Movement: a body's value is a table saying what it may do and which way it faces")
					local was = speeds[speedAt[i]] or ZERO

					-- the steer arrives in the frame the body says forward is, so it is turned into the
					-- world here and nowhere else. Flattened, because a body walks on the ground plane and
					-- a camera that looks down should not slow it.
					local face = it.facing or FORWARD
					local fx, fz = face.X, face.Z
					local flat = math.sqrt(fx * fx + fz * fz)
					if flat > 0 then
						fx, fz = fx / flat, fz / flat
					else
						fx, fz = FORWARD.X, FORWARD.Z
					end
					-- right of forward on that plane is forward crossed with up
					local dx = -fz * sx + fx * sy
					local dz = fx * sx + fz * sy

					local speed = 0
					if may(it, "walk") then
						speed = walk.speed :: number
						-- a crouched body is not sprinting, so crouch takes it when both are down
						if slower and may(it, "crouch") then
							speed = (crouch :: Move).speed :: number
						elseif faster and may(it, "sprint") then
							speed = (sprint :: Move).speed :: number
						end
					end

					local left = it.dash or 0
					if dashing and dash ~= nil and left <= 0 and may(it, "dash") then
						-- the way it is already steering, or the way it faces when it is not steering
						if steer > 0 then
							it.way = Vector3.new(dx / steer, 0, dz / steer)
						else
							it.way = Vector3.new(fx, 0, fz)
						end
						left = dash.lasts :: number
					end

					local vx, vz
					if left > 0 then
						-- a dash is a burst: it ignores the steer, and it is not accelerated into
						local way = it.way or FORWARD
						local burst = (dash :: Move).speed :: number
						vx, vz = way.X * burst, way.Z * burst
						left -= dt
						it.dash = if left > 0 then left else 0
					else
						local wantX, wantZ = dx * speed, dz * speed
						local rate = walk.accelerate
						if rate ~= nil and dt > 0 then
							local gapX, gapZ = wantX - was.X, wantZ - was.Z
							local gap = math.sqrt(gapX * gapX + gapZ * gapZ)
							local step = rate * dt
							if gap > step then
								vx, vz = was.X + gapX / gap * step, was.Z + gapZ / gap * step
							else
								vx, vz = wantX, wantZ
							end
						else
							vx, vz = wantX, wantZ
						end
					end

					-- Y is the body's own until the frame a jump begins, and this never takes it back
					local vy = was.Y
					if jumping and jump ~= nil and may(it, "jump") then
						vy = jump.power :: number
					end

					speeds[speedAt[i]] = Vector3.new(vx, vy, vz)
				end
			end

			jumping = false
			dashing = false
		end,
	}
	return self
end
