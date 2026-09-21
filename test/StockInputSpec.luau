--!strict
-- Stock Input headless: the engine is a feed a case presses keys into with a clock it moves, so a hold
-- that fires at its threshold, a chord that needs two keys and a sequence that needs order are all read off
-- the Action pushes that came out of one phase.

return function(T)
	-- a Beef, a feed in place of the engine, and a phase with nothing in it but Input
	local function rig(bindings: any): (any, any, any)
		local Beef = T.load()
		local Stock = Beef.Stock
		local feed = Stock.feed()
		local phase = Beef.Phase.new("Input", { { Stock.Input, Stock.Action, bindings, feed } })
		return Beef, feed, phase
	end

	-- every push since `mark`, as "Jump:Began Slide:Ended", which is what a case actually wants to assert
	local function trace(Beef: any, mark: number): string
		local action = Beef.Stock.Action
		local named: { [number]: string } = {}
		for name, n in Beef.Stock.Phases do
			named[n] = name
		end
		local parts = {}
		for i = mark + 1, action.count do
			table.insert(parts, action.action[i] .. ":" .. named[action.phase[i]])
		end
		return table.concat(parts, " ")
	end

	local function mark(Beef: any): number
		return Beef.Stock.Action.count
	end

	local KEYS = { Enum.KeyCode.Space }

	-- ------------------------------------------------------------------ the surface

	T.case("Beef exports Stock, and Stock the action vocabulary and Input", function()
		local Beef = T.load()
		T.ok(Beef.Stock ~= nil, "Beef.Stock")
		for _, name in { "Action", "Phases", "Devices", "Edges", "Input", "feed" } do
			T.ok(Beef.Stock[name] ~= nil, "Beef.Stock." .. name)
		end
		T.eq(type(Beef.Stock.Input), "function", "Input is a factory a phase can call")
	end)

	T.case("Action is one Event with the six columns", function()
		local Beef = T.load()
		local action = Beef.Stock.Action
		T.eq(action.name, "action", "the Event still answers to its own name")
		T.eq(table.concat(action.columns, " "), "action phase value x y device")
		T.eq(action.wire.action, "string")
		T.eq(action.wire.phase, "u8")
		T.eq(action.wire.value, "f32")
		T.eq(action.wire.device, "u8")
	end)

	T.case("Input is a controller a phase runs, and describe reads", function()
		local Beef, _, phase = rig({ Jump = { keys = KEYS } })
		local said = phase.describe()
		T.ok(said:find("Input"), "the controller is named")
		T.ok(said:find("action"), "and the event type it writes")
		T.eq(mark(Beef), 0, "nothing pushed before a frame runs")
	end)

	T.case("a game's entries reach the driver, and a chord and a sequence do not", function()
		local _, feed, phase = rig({
			Crouch = { keys = { Enum.KeyCode.LeftControl } },
			Jump = { keys = KEYS },
			Look = { move = { stick = Enum.KeyCode.Thumbstick2 } },
			Slide = { chord = { "Crouch", "Jump" } },
			Throttle = { axis = { Enum.KeyCode.ButtonR2 }, scale = 2 },
		})
		phase.run()
		local declared = feed.declared()
		local names = {}
		for _, one in declared do
			table.insert(names, one.name .. "/" .. one.shape)
		end
		table.sort(names)
		T.eq(table.concat(names, " "), "Crouch/keys Jump/keys Look/move Throttle/axis")
		for _, one in declared do
			if one.name == "Throttle" then
				T.eq(one.scale, 2, "an option travels with the declaration")
				T.eq(one.keys[1], Enum.KeyCode.ButtonR2, "and so does the key")
			end
		end
	end)

	-- ------------------------------------------------------------------ a press and a release

	T.case("a press begins and a release ends", function()
		local Beef, feed, phase = rig({ Jump = { keys = KEYS } })
		local at = mark(Beef)
		feed.press("Jump")
		phase.run()
		T.eq(trace(Beef, at), "Jump:Began")

		at = mark(Beef)
		feed.release("Jump")
		phase.run()
		T.eq(trace(Beef, at), "Jump:Ended")

		at = mark(Beef)
		phase.run()
		T.eq(trace(Beef, at), "", "a quiet frame says nothing")
	end)

	T.case("the value and the device travel with the push", function()
		local Beef, feed, phase = rig({ Throttle = { axis = { Enum.KeyCode.ButtonR2 } } })
		local action = Beef.Stock.Action
		feed.using(Beef.Stock.Devices.Gamepad)
		feed.change("Throttle", 0.4)
		phase.run()
		T.eq(action.count, 1)
		T.eq(action.phase[1], Beef.Stock.Phases.Changed)
		T.eq(math.floor(action.value[1] * 100 + 0.5), 40)
		T.eq(action.device[1], Beef.Stock.Devices.Gamepad)
	end)

	T.case("a direction reports its axes and the magnitude as the value", function()
		local Beef, feed, phase = rig({
			Move = { move = { forward = Enum.KeyCode.W, back = Enum.KeyCode.S, left = Enum.KeyCode.A, right = Enum.KeyCode.D } },
		})
		local action = Beef.Stock.Action
		feed.change("Move", 3, 4)
		phase.run()
		T.eq(action.count, 1)
		T.eq(action.x[1], 3)
		T.eq(action.y[1], 4)
		T.eq(action.value[1], 5, "the magnitude")
	end)

	T.case("an action the bindings table never named is dropped", function()
		local Beef, feed, phase = rig({ Jump = { keys = KEYS } })
		feed.press("Fly")
		phase.run()
		T.eq(trace(Beef, 0), "", "nothing came of it")
	end)

	-- ------------------------------------------------------------------ holds

	T.case("a hold fires at its threshold, once, and not before", function()
		local Beef, feed, phase = rig({ Open = { keys = { Enum.KeyCode.E }, hold = 0.8 } })
		local at = mark(Beef)
		feed.press("Open")
		phase.run()
		T.eq(trace(Beef, at), "Open:Began")

		at = mark(Beef)
		feed.advance(0.5)
		phase.run()
		T.eq(trace(Beef, at), "", "half way is not there yet")

		at = mark(Beef)
		feed.advance(0.3)
		phase.run()
		T.eq(trace(Beef, at), "Open:Held", "at the threshold exactly")

		at = mark(Beef)
		feed.advance(1)
		phase.run()
		T.eq(trace(Beef, at), "", "and it does not fire again")

		at = mark(Beef)
		feed.release("Open")
		phase.run()
		T.eq(trace(Beef, at), "Open:Ended", "the release still comes")
	end)

	T.case("a press let go before the threshold never holds", function()
		local Beef, feed, phase = rig({ Open = { keys = { Enum.KeyCode.E }, hold = 0.8 } })
		feed.press("Open")
		phase.run()
		feed.advance(0.3)
		feed.release("Open")
		phase.run()
		feed.advance(2)
		phase.run()
		T.eq(trace(Beef, 0), "Open:Began Open:Ended")
	end)

	T.case("a second press starts the hold over", function()
		local Beef, feed, phase = rig({ Open = { keys = { Enum.KeyCode.E }, hold = 0.5 } })
		feed.press("Open")
		phase.run()
		feed.advance(0.4)
		feed.release("Open")
		feed.press("Open")
		phase.run()
		local at = mark(Beef)
		feed.advance(0.2)
		phase.run()
		T.eq(trace(Beef, at), "", "0.6 since the first press, 0.2 since the one that counts")
		at = mark(Beef)
		feed.advance(0.3)
		phase.run()
		T.eq(trace(Beef, at), "Open:Held")
	end)

	-- ------------------------------------------------------------------ buffers

	T.case("a buffered press stays pending for its window", function()
		local Beef, feed, phase = rig({ Jump = { keys = KEYS, buffer = 0.15 } })
		local at = mark(Beef)
		feed.press("Jump")
		phase.run()
		T.eq(trace(Beef, at), "Jump:Began", "the press frame says Began and nothing else")

		at = mark(Beef)
		feed.advance(0.05)
		phase.run()
		T.eq(trace(Beef, at), "Jump:Buffered")

		at = mark(Beef)
		feed.advance(0.05)
		phase.run()
		T.eq(trace(Beef, at), "Jump:Buffered")

		at = mark(Beef)
		feed.advance(0.1)
		phase.run()
		T.eq(trace(Beef, at), "", "past the window it is forgotten")
	end)

	T.case("a buffered press outlives the release that ends it", function()
		local Beef, feed, phase = rig({ Jump = { keys = KEYS, buffer = 0.2 } })
		feed.press("Jump")
		phase.run()
		local at = mark(Beef)
		feed.advance(0.05)
		feed.release("Jump")
		phase.run()
		T.eq(trace(Beef, at), "Jump:Buffered Jump:Ended", "still worth remembering, and already over")
		at = mark(Beef)
		feed.advance(0.05)
		phase.run()
		T.eq(trace(Beef, at), "Jump:Buffered")
	end)

	T.case("a press with no buffer repeats nothing", function()
		local Beef, feed, phase = rig({ Jump = { keys = KEYS } })
		feed.press("Jump")
		phase.run()
		feed.advance(0.5)
		phase.run()
		T.eq(trace(Beef, 0), "Jump:Began")
	end)

	-- ------------------------------------------------------------------ chords

	T.case("a chord needs both keys, and ends when one lifts", function()
		local Beef, feed, phase = rig({
			Crouch = { keys = { Enum.KeyCode.LeftControl } },
			Jump = { keys = KEYS },
			Slide = { chord = { "Crouch", "Jump" } },
		})
		local at = mark(Beef)
		feed.press("Crouch")
		phase.run()
		T.eq(trace(Beef, at), "Crouch:Began", "one key is not a chord")

		at = mark(Beef)
		feed.press("Jump")
		phase.run()
		T.eq(trace(Beef, at), "Jump:Began Slide:Began", "and a chord does not silence its members")

		at = mark(Beef)
		phase.run()
		T.eq(trace(Beef, at), "", "it begins once, not every frame it is on")

		at = mark(Beef)
		feed.release("Crouch")
		phase.run()
		T.eq(trace(Beef, at), "Crouch:Ended Slide:Ended")

		at = mark(Beef)
		feed.release("Jump")
		phase.run()
		T.eq(trace(Beef, at), "Jump:Ended", "the chord was already over")
	end)

	T.case("a chord takes its members in either order", function()
		local Beef, feed, phase = rig({
			Crouch = { keys = { Enum.KeyCode.LeftControl } },
			Jump = { keys = KEYS },
			Slide = { chord = { "Crouch", "Jump" } },
		})
		feed.press("Jump")
		phase.run()
		local at = mark(Beef)
		feed.press("Crouch")
		phase.run()
		T.eq(trace(Beef, at), "Crouch:Began Slide:Began")
	end)

	T.case("a chord holds like anything else that begins", function()
		local Beef, feed, phase = rig({
			Crouch = { keys = { Enum.KeyCode.LeftControl } },
			Jump = { keys = KEYS },
			Slide = { chord = { "Crouch", "Jump" }, hold = 0.4 },
		})
		feed.press("Crouch")
		feed.press("Jump")
		phase.run()
		local at = mark(Beef)
		feed.advance(0.4)
		phase.run()
		T.eq(trace(Beef, at), "Slide:Held")
	end)

	-- ------------------------------------------------------------------ sequences

	local FIGHT = {
		Down = { keys = { Enum.KeyCode.Down } },
		Forward = { keys = { Enum.KeyCode.Right } },
		Punch = { keys = { Enum.KeyCode.F } },
		Hadouken = { sequence = { "Down", "Forward", "Punch" }, within = 0.4 },
	}

	T.case("a sequence fires when its steps arrive in order", function()
		local Beef, feed, phase = rig(FIGHT)
		feed.tap("Down")
		phase.run()
		feed.advance(0.1)
		feed.tap("Forward")
		phase.run()
		local at = mark(Beef)
		feed.advance(0.1)
		feed.press("Punch")
		phase.run()
		T.eq(trace(Beef, at), "Punch:Began Hadouken:Fired")
	end)

	T.case("a sequence out of order fires nothing", function()
		local Beef, feed, phase = rig(FIGHT)
		feed.tap("Forward")
		phase.run()
		feed.advance(0.1)
		feed.tap("Down")
		phase.run()
		feed.advance(0.1)
		feed.tap("Punch")
		phase.run()
		T.ok(not trace(Beef, 0):find("Hadouken"), "no Hadouken")
	end)

	T.case("a step too late drops the sequence back to the start", function()
		local Beef, feed, phase = rig(FIGHT)
		feed.tap("Down")
		phase.run()
		feed.advance(0.1)
		feed.tap("Forward")
		phase.run()
		feed.advance(0.9)
		phase.run()
		feed.tap("Punch")
		phase.run()
		T.ok(not trace(Beef, 0):find("Hadouken"), "the window closed")

		local at = mark(Beef)
		feed.tap("Down")
		phase.run()
		feed.advance(0.1)
		feed.tap("Forward")
		phase.run()
		feed.advance(0.1)
		feed.tap("Punch")
		phase.run()
		T.ok(trace(Beef, at):find("Hadouken:Fired"), "and the next run works")
	end)

	T.case("an action the sequence never mentions does not break it", function()
		local Beef, feed, phase = rig({
			Down = { keys = { Enum.KeyCode.Down } },
			Forward = { keys = { Enum.KeyCode.Right } },
			Punch = { keys = { Enum.KeyCode.F } },
			Jump = { keys = KEYS },
			Hadouken = { sequence = { "Down", "Forward", "Punch" }, within = 0.4 },
		})
		feed.tap("Down")
		phase.run()
		feed.tap("Jump")
		phase.run()
		feed.tap("Forward")
		phase.run()
		feed.tap("Punch")
		phase.run()
		T.ok(trace(Beef, 0):find("Hadouken:Fired"), "Jump went past it")
	end)

	T.case("a repeat of the first step restarts rather than resets", function()
		local Beef, feed, phase = rig(FIGHT)
		feed.tap("Down")
		phase.run()
		feed.tap("Down")
		phase.run()
		feed.tap("Forward")
		phase.run()
		feed.tap("Punch")
		phase.run()
		T.ok(trace(Beef, 0):find("Hadouken:Fired"))
	end)

	T.case("a sequence fires again the next time round", function()
		local Beef, feed, phase = rig(FIGHT)
		for _ = 1, 2 do
			feed.tap("Down")
			phase.run()
			feed.tap("Forward")
			phase.run()
			feed.tap("Punch")
			phase.run()
		end
		local fired = 0
		for _, word in trace(Beef, 0):split(" ") do
			if word == "Hadouken:Fired" then
				fired += 1
			end
		end
		T.eq(fired, 2)
	end)

	-- ------------------------------------------------------------------ in a phase with a reader

	T.case("a controller reading Action sees the frame's input on the first pass", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		local feed = Stock.feed()
		local seen: { string } = {}
		local passes = 0

		local function Jumping(action: any)
			return {
				name = "Jumping",
				reads = { action },
				loop = function()
					passes += 1
					for i = action.from, action.last do
						table.insert(seen, action.action[i] .. ":" .. tostring(action.phase[i]))
					end
				end,
			}
		end

		local phase = Beef.Phase.new("Heartbeat", {
			{ Stock.Input, Stock.Action, { Jump = { keys = KEYS } }, feed },
			{ Jumping, Stock.Action },
		})

		feed.press("Jump")
		phase.run()
		T.eq(#seen, 1, "the reader got it")
		T.eq(seen[1], "Jump:" .. tostring(Stock.Phases.Began))
		T.eq(passes, 1, "on the first pass, with nothing to chase")
	end)

	-- ------------------------------------------------------------------ what it refuses

	T.case("an entry names one trigger, and a real one", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		local function build(bindings: any)
			return function()
				Stock.Input(Stock.Action, bindings, Stock.feed())
			end
		end
		T.throws(build({ Jump = {} }), "names one of", "no trigger")
		T.throws(build({ Jump = { keys = KEYS, axis = KEYS } }), "not both", "two triggers")
		T.throws(build({ Jump = "space" }), "an entry is a table", "not a table")
		T.throws(build({ [1] = { keys = KEYS } }), "named by a string", "a number for a name")
		T.throws(build({ Jump = { keys = {} } }), "a list of what triggers it", "an empty list")
		T.throws(build({ Jump = { keys = { "Space" } } }), "not a string", "a key by name")
	end)

	T.case("an option has to belong where it is put", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		local function build(bindings: any)
			return function()
				Stock.Input(Stock.Action, bindings, Stock.feed())
			end
		end
		T.throws(build({ Jump = { keys = KEYS, sticky = 1 } }), "is not an option here", "an invented option")
		T.throws(build({ Move = { move = { stick = Enum.KeyCode.Thumbstick1 }, hold = 1 } }), "is an option on", "hold on a direction")
		T.throws(build({ Jump = { keys = KEYS, within = 1 } }), "is an option on", "within outside a sequence")
		T.throws(build({ Jump = { keys = KEYS, hold = 0 } }), "a number of seconds", "nothing held for no time")
		T.throws(build({ Move = { move = { up = Enum.KeyCode.W } } }), "move takes", "a direction move has no word for")
	end)

	T.case("a chord and a sequence name actions the table declares", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		local function build(bindings: any)
			return function()
				Stock.Input(Stock.Action, bindings, Stock.feed())
			end
		end
		T.throws(build({ Slide = { chord = { "Crouch", "Jump" } } }), "which is not an action here", "an unknown member")
		T.throws(build({ Jump = { keys = KEYS }, Slide = { chord = { "Jump" } } }), "two or more other actions", "a chord of one")
		T.throws(
			build({
				Crouch = { keys = { Enum.KeyCode.LeftControl } },
				Jump = { keys = KEYS },
				Slide = { chord = { "Crouch", "Jump" } },
				Dive = { chord = { "Slide", "Jump" } },
			}),
			"which is itself a chord",
			"a chord of a chord"
		)
		T.throws(build({ Jump = { keys = KEYS }, Combo = { sequence = { "Jump", Enum.KeyCode.E } } }), "by name, not a", "a sequence step that is a key")
	end)

	T.case("the first thing handed to the factory is the Action event type", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		T.throws(function()
			Stock.Input({}, { Jump = { keys = KEYS } }, Stock.feed())
		end, "the Action event type")
	end)
end
