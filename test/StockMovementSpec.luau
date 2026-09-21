--!strict
-- Stock Movement headless: Action pushes go in, a velocity comes out. Most cases push Action straight into
-- the Event, which is what Input would have written; the last one runs a real feed through Input and
-- Movement in one phase, to show the two meet.

return function(T)
	local function near(got: number, want: number, what: string?)
		if math.abs(got - want) > 1e-4 then
			error(("%s: got %s, want %s"):format(what or "near", tostring(got), tostring(want)), 2)
		end
	end

	local function vec(v: any, x: number, y: number, z: number, what: string?)
		local who = what or "velocity"
		near(v.X, x, who .. ".X")
		near(v.Y, y, who .. ".Y")
		near(v.Z, z, who .. ".Z")
	end

	local WALK = { walk = { action = "Move", speed = 16 } }

	-- a Beef, a kind carrying a body and a velocity, and a phase with nothing in it but Movement
	local function rig(moves: any, dt: number?): (any, any, any, any, any)
		local Beef = T.load()
		local Body = Beef.Components.new("body")
		local Velocity = Beef.Components.new("velocity", { wire = "vector3" })
		local Mover = Beef.Kinds.new("mover", Body, Velocity)
		local phase = Beef.Phase.new("Move", { { Beef.Stock.Movement, Beef.Stock.Action, Body, Velocity, moves } })
		phase.dt = dt or 1 / 60
		return Beef, Mover, Body, Velocity, phase
	end

	-- the velocity of the nth body on the kind, which is where the answer lands
	local function speed(Velocity: any, Mover: any, n: number?): any
		return Velocity.of(Mover).value[n or 1]
	end

	-- what Input would have written for each of these
	local function steer(Beef: any, x: number, y: number)
		Beef.Stock.Action.push("Move", Beef.Stock.Phases.Changed, math.sqrt(x * x + y * y), x, y, Beef.Stock.Devices.KeyboardAndMouse)
	end

	local function press(Beef: any, name: string)
		Beef.Stock.Action.push(name, Beef.Stock.Phases.Began, 1, 1, 0, Beef.Stock.Devices.KeyboardAndMouse)
	end

	local function lift(Beef: any, name: string)
		Beef.Stock.Action.push(name, Beef.Stock.Phases.Ended, 0, 0, 0, Beef.Stock.Devices.KeyboardAndMouse)
	end

	local function says(Beef: any, name: string, phase: number)
		Beef.Stock.Action.push(name, phase, 1, 1, 0, Beef.Stock.Devices.KeyboardAndMouse)
	end

	-- ------------------------------------------------------------------ the surface

	T.case("Stock exports Movement, a factory a phase can call", function()
		local Beef = T.load()
		T.ok(Beef.Stock.Movement ~= nil, "Beef.Stock.Movement")
		T.eq(type(Beef.Stock.Movement), "function")
	end)

	T.case("Movement is a controller a phase runs, and describe reads", function()
		local Beef, _, _, _, phase = rig(WALK)
		local said = phase.describe()
		T.ok(said:find("Movement"), "the controller is named")
		T.ok(said:find("reads"), "and what it reads")
		T.eq(Beef.Stock.Action.count, 0, "it pushes nothing of its own")
	end)

	-- ------------------------------------------------------------------ walking

	T.case("a steer becomes a velocity at the walk speed", function()
		local Beef, Mover, Body, Velocity, phase = rig(WALK)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "forward")

		steer(Beef, 1, 0)
		phase.run()
		vec(speed(Velocity, Mover), 16, 0, 0, "right")
		T.ok(Body ~= nil)
	end)

	T.case("half a tilt is half the speed", function()
		local Beef, Mover, _, Velocity, phase = rig(WALK)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 0.5)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -8)
	end)

	T.case("a reading past one does not go faster than the move says", function()
		local Beef, Mover, _, Velocity, phase = rig(WALK)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 3)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "clamped")
	end)

	T.case("the steer stays where it was put", function()
		local Beef, Mover, _, Velocity, phase = rig(WALK)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		phase.run()
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "a stick held still says nothing")
	end)

	T.case("an end to the steer stops the body", function()
		local Beef, Mover, _, Velocity, phase = rig(WALK)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		lift(Beef, "Move")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, 0)
	end)

	T.case("a steer back to nothing stops the body", function()
		local Beef, Mover, _, Velocity, phase = rig(WALK)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		steer(Beef, 0, 0)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, 0)
	end)

	T.case("the facing turns the steer into the world", function()
		local Beef, Mover, _, Velocity, phase = rig(WALK)
		Mover.spawn({ facing = Vector3.new(1, 0, 0) }, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		vec(speed(Velocity, Mover), 16, 0, 0, "forward is where the body says it is")

		steer(Beef, 1, 0)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, 16, "and right is right of that")
	end)

	T.case("a facing that points down is flattened", function()
		local Beef, Mover, _, Velocity, phase = rig(WALK)
		Mover.spawn({ facing = Vector3.new(0, -8, -1) }, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "a camera looking down does not slow it")
	end)

	-- ------------------------------------------------------------------ sprint and crouch

	T.case("sprint raises the speed while it is down, and the release puts it back", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			sprint = { action = "Sprint", speed = 24 },
		})
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "walking")

		press(Beef, "Sprint")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -24, "sprinting")

		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -24, "still sprinting, with nothing pushed")

		lift(Beef, "Sprint")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "back to walking")
	end)

	T.case("crouch takes it when both are down", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			sprint = { action = "Sprint", speed = 24 },
			crouch = { action = "Crouch", speed = 6 },
		})
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Sprint")
		press(Beef, "Crouch")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -6, "a crouched body is not sprinting")

		lift(Beef, "Crouch")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -24)
	end)

	T.case("an analog trigger is down while it reads anything", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			sprint = { action = "Throttle", speed = 24 },
		})
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		Beef.Stock.Action.push("Throttle", Beef.Stock.Phases.Changed, 0.6, 0.6, 0, 2)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -24)

		Beef.Stock.Action.push("Throttle", Beef.Stock.Phases.Changed, 0, 0, 0, 2)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16)
	end)

	-- ------------------------------------------------------------------ jumping

	T.case("a jump writes its power on Y and leaves the ground speed alone", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			jump = { action = "Jump", power = 50 },
		})
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Jump")
		phase.run()
		vec(speed(Velocity, Mover), 0, 50, -16)
	end)

	T.case("Y is the body's own on every other frame", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			jump = { action = "Jump", power = 50 },
		})
		Mover.spawn({}, Vector3.new(0, 25, 0))
		steer(Beef, 0, 1)
		phase.run()
		vec(speed(Velocity, Mover), 0, 25, -16, "gravity is not this controller's")
	end)

	T.case("a buffered jump does not jump again", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			jump = { action = "Jump", power = 50 },
		})
		Mover.spawn({}, Vector3.zero)
		press(Beef, "Jump")
		phase.run()
		near(speed(Velocity, Mover).Y, 50, "the press")

		-- whatever integrates Y has had it back to nothing by now
		Velocity.of(Mover).value[1] = Vector3.zero
		says(Beef, "Jump", Beef.Stock.Phases.Buffered)
		phase.run()
		near(speed(Velocity, Mover).Y, 0, "a buffer is for a reader that can refuse a jump; this one cannot")
	end)

	T.case("a held press does not jump again either", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			jump = { action = "Jump", power = 50 },
		})
		Mover.spawn({}, Vector3.zero)
		press(Beef, "Jump")
		phase.run()
		Velocity.of(Mover).value[1] = Vector3.zero
		says(Beef, "Jump", Beef.Stock.Phases.Held)
		phase.run()
		near(speed(Velocity, Mover).Y, 0)
	end)

	T.case("a sequence that fired starts a jump", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			jump = { action = "Leap", power = 50 },
		})
		Mover.spawn({}, Vector3.zero)
		says(Beef, "Leap", Beef.Stock.Phases.Fired)
		phase.run()
		near(speed(Velocity, Mover).Y, 50, "a double tap is as good as a press")
	end)

	-- ------------------------------------------------------------------ dashing

	local BURST = {
		walk = { action = "Move", speed = 16 },
		dash = { action = "Dash", speed = 60, lasts = 0.2 },
	}

	T.case("a dash runs its seconds at its speed and then stops", function()
		local Beef, Mover, _, Velocity, phase = rig(BURST, 0.1)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Dash")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -60, "the frame it begins")

		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -60, "and the frame after")

		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "then it is walking again")
	end)

	T.case("a dash ignores the steer while it runs", function()
		local Beef, Mover, _, Velocity, phase = rig(BURST, 0.1)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Dash")
		phase.run()
		steer(Beef, 1, 0)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -60, "it goes where it was going")
		phase.run()
		vec(speed(Velocity, Mover), 16, 0, 0, "and takes the steer when it is over")
	end)

	T.case("a dash with no steer goes the way the body faces", function()
		local Beef, Mover, _, Velocity, phase = rig(BURST, 0.1)
		Mover.spawn({ facing = Vector3.new(1, 0, 0) }, Vector3.zero)
		press(Beef, "Dash")
		phase.run()
		vec(speed(Velocity, Mover), 60, 0, 0)
	end)

	T.case("a dash already running is not begun again", function()
		local Beef, Mover, _, Velocity, phase = rig(BURST, 0.1)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Dash")
		phase.run()

		steer(Beef, 1, 0)
		press(Beef, "Dash")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -60, "the second press did nothing")

		phase.run()
		vec(speed(Velocity, Mover), 16, 0, 0, "and it ended when the first one said")
	end)

	T.case("a dash is kept on the body, so it dies with it", function()
		local Beef, Mover, Body, _, phase = rig(BURST, 0.1)
		Mover.spawn({}, Vector3.zero)
		press(Beef, "Dash")
		phase.run()
		local it = Body.of(Mover).value[1]
		near(it.dash, 0.1, "a tenth of the two left")
		T.ok(it.way ~= nil, "and the way it is going")
	end)

	-- ------------------------------------------------------------------ what a body may do

	T.case("a body that may not walk stands still", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			jump = { action = "Jump", power = 50 },
		})
		Mover.spawn({ granted = { jump = true } }, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Jump")
		phase.run()
		vec(speed(Velocity, Mover), 0, 50, 0, "it can still jump")
	end)

	T.case("a body that may not jump does not jump", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			jump = { action = "Jump", power = 50 },
		})
		Mover.spawn({ granted = { walk = true } }, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Jump")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "whoever knows about the ground took it away")
	end)

	T.case("a body that may not sprint walks", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			sprint = { action = "Sprint", speed = 24 },
		})
		Mover.spawn({ granted = { walk = true } }, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Sprint")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16)
	end)

	T.case("a body that says nothing may make every move the table declares", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16 },
			jump = { action = "Jump", power = 50 },
		})
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		press(Beef, "Jump")
		phase.run()
		vec(speed(Velocity, Mover), 0, 50, -16)
	end)

	-- ------------------------------------------------------------------ acceleration

	T.case("acceleration ramps toward the speed rather than snapping to it", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16, accelerate = 80 },
		}, 0.1)
		Mover.spawn({}, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -8, "eight a frame")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "and it stops at the speed")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "no further")
	end)

	T.case("acceleration brings it back down when the steer goes", function()
		local Beef, Mover, _, Velocity, phase = rig({
			walk = { action = "Move", speed = 16, accelerate = 80 },
		}, 0.1)
		Mover.spawn({}, Vector3.new(0, 0, -16))
		steer(Beef, 0, 0)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -8)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, 0)
	end)

	-- ------------------------------------------------------------------ more than one body

	T.case("every controlled body takes the same actions", function()
		local Beef, Mover, _, Velocity, phase = rig(WALK)
		Mover.spawn({}, Vector3.zero)
		Mover.spawn({ facing = Vector3.new(1, 0, 0) }, Vector3.zero)
		steer(Beef, 0, 1)
		phase.run()
		vec(speed(Velocity, Mover, 1), 0, 0, -16, "the first")
		vec(speed(Velocity, Mover, 2), 16, 0, 0, "the second, facing its own way")
	end)

	T.case("a kind that carries the body as an option is driven too", function()
		local Beef = T.load()
		local Body = Beef.Components.new("body")
		local Velocity = Beef.Components.new("velocity", { wire = "vector3" })
		local Tag = Beef.Components.new("tag")
		local Crowd = Beef.Kinds.new("crowd", Tag)
		local phase = Beef.Phase.new("Move", { { Beef.Stock.Movement, Beef.Stock.Action, Body, Velocity, WALK } })
		phase.dt = 1 / 60

		Crowd.spawn(true)
		Crowd.spawn(true)
		Body.add(Crowd, 2, {})
		Velocity.add(Crowd, 2, Vector3.zero)

		steer(Beef, 0, 1)
		phase.run()
		vec(Velocity.get(Crowd, 2), 0, 0, -16, "the one carrying both")
		T.eq(Velocity.get(Crowd, 1), nil, "and the one carrying neither is untouched")
	end)

	-- ------------------------------------------------------------------ with Input in front of it

	T.case("a phase with Input and Movement takes a key to a velocity", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		local feed = Stock.feed()
		local Body = Beef.Components.new("body")
		local Velocity = Beef.Components.new("velocity", { wire = "vector3" })
		local Mover = Beef.Kinds.new("mover", Body, Velocity)

		local bindings = {
			Move = { move = { forward = Enum.KeyCode.W, back = Enum.KeyCode.S, left = Enum.KeyCode.A, right = Enum.KeyCode.D } },
			Sprint = { keys = { Enum.KeyCode.LeftShift } },
			Jump = { keys = { Enum.KeyCode.Space }, buffer = 0.2 },
		}
		local moves = {
			walk = { action = "Move", speed = 16 },
			sprint = { action = "Sprint", speed = 24 },
			jump = { action = "Jump", power = 50 },
		}
		local phase = Beef.Phase.new("Heartbeat", {
			{ Stock.Input, Stock.Action, bindings, feed },
			{ Stock.Movement, Stock.Action, Body, Velocity, moves },
		})
		phase.dt = 1 / 60
		Mover.spawn({}, Vector3.zero)

		feed.change("Move", 0, 1)
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -16, "W is forward at the walk speed")

		feed.press("Sprint")
		phase.run()
		vec(speed(Velocity, Mover), 0, 0, -24, "and shift is forward faster")

		feed.press("Jump")
		phase.run()
		near(speed(Velocity, Mover).Y, 50, "space is up")

		-- the buffer keeps pushing Jump, and none of it jumps twice
		Velocity.of(Mover).value[1] = Vector3.new(0, 0, -24)
		feed.advance(0.05)
		phase.run()
		near(speed(Velocity, Mover).Y, 0, "the frames of Buffered after it do nothing")
	end)

	-- ------------------------------------------------------------------ what it refuses

	T.case("a move is one of the five, named by a string, and a table", function()
		local Beef = T.load()
		local function build(moves: any)
			return function()
				Beef.Stock.Movement(Beef.Stock.Action, Beef.Components.new("body"), Beef.Components.new("velocity"), moves)
			end
		end
		T.throws(build({ fly = { action = "Fly", speed = 1 } }), "is not a move here", "a move it has never heard of")
		T.throws(build({ [1] = { action = "Move", speed = 1 } }), "named by a string", "a number for a name")
		T.throws(build({ walk = "fast" }), "a move is a table", "not a table")
		T.throws(build({ walk = { speed = 16 } }), "action names the action", "no action")
		T.throws(build({ walk = { action = Enum.KeyCode.W, speed = 16 } }), "action names the action", "a key rather than an action name")
		T.throws(build({ jump = { action = "Jump", power = 50 } }), "moves names walk", "no walk")
		T.throws(build("walk"), "moves is a table", "not a table at all")
	end)

	T.case("an option has to belong where it is put", function()
		local Beef = T.load()
		local function build(moves: any)
			return function()
				Beef.Stock.Movement(Beef.Stock.Action, Beef.Components.new("body"), Beef.Components.new("velocity"), moves)
			end
		end
		T.throws(build({ walk = { action = "Move", speed = 16, sticky = 1 } }), "is not an option here", "an invented option")
		T.throws(
			build({ walk = { action = "Move", speed = 16 }, jump = { action = "Jump", power = 50, lasts = 1 } }),
			"is an option on",
			"a length on a jump"
		)
		T.throws(
			build({ walk = { action = "Move", speed = 16 }, sprint = { action = "Sprint", speed = 24, accelerate = 8 } }),
			"is an option on",
			"acceleration on a sprint"
		)
	end)

	T.case("a move needs the numbers that make it", function()
		local Beef = T.load()
		local function build(moves: any)
			return function()
				Beef.Stock.Movement(Beef.Stock.Action, Beef.Components.new("body"), Beef.Components.new("velocity"), moves)
			end
		end
		T.throws(build({ walk = { action = "Move" } }), "a walk needs speed", "a walk with no speed")
		T.throws(build({ walk = { action = "Move", speed = 16 }, jump = { action = "Jump" } }), "a jump needs power", "a jump with no power")
		T.throws(
			build({ walk = { action = "Move", speed = 16 }, dash = { action = "Dash", speed = 60 } }),
			"a dash needs lasts",
			"a dash with no length"
		)
		T.throws(build({ walk = { action = "Move", speed = 0 } }), "a number above zero", "nothing moves at no speed")
		T.throws(build({ walk = { action = "Move", speed = "fast" } }), "a number above zero", "a speed in words")
	end)

	T.case("the things handed to the factory are the Action event and two Components", function()
		local Beef = T.load()
		local Body = Beef.Components.new("body")
		local Velocity = Beef.Components.new("velocity")
		T.throws(function()
			Beef.Stock.Movement({}, Body, Velocity, WALK)
		end, "the first thing handed to it is the Action event type")
		T.throws(function()
			Beef.Stock.Movement(Beef.Stock.Action, {}, Velocity, WALK)
		end, "the second thing handed to it")
		T.throws(function()
			Beef.Stock.Movement(Beef.Stock.Action, Body, Beef.Stock.Action, WALK)
		end, "the third thing handed to it")
	end)
end
