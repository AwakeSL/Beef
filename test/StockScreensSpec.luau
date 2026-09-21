--!strict
-- Stock Screens headless: the engine is a driver that writes down what it was shown, so which screen has
-- the input, what that suppresses and where the rectangle landed are all read back with no Roblox in the
-- loop. Most cases push Action straight into the Event, which is what Input would have written; the last
-- one runs a real feed through Input and Screens in one phase, to show the two meet.

return function(T)
	-- a Beef, a driver that records, a Kind carrying the focus, and a phase with nothing in it but Screens
	local function rig(screens: any): (any, any, any, any, any)
		local Beef = T.load()
		local Stock = Beef.Stock
		local shown = Stock.shown()
		local Focus = Beef.Components.new("focus")
		local Player = Beef.Kinds.new("player", Focus)
		local phase = Beef.Phase.new("Screens", { { Stock.Screens, Stock.Action, Focus, screens, shown } })
		return Beef, shown, Focus, Player, phase
	end

	-- what Input would have written for a press of that action
	local function press(Beef: any, name: string)
		Beef.Stock.Action.push(name, Beef.Stock.Phases.Began, 1, 1, 0, Beef.Stock.Devices.KeyboardAndMouse)
	end

	local function says(Beef: any, name: string, phase: number)
		Beef.Stock.Action.push(name, phase, 1, 1, 0, Beef.Stock.Devices.KeyboardAndMouse)
	end

	local function focused(Focus: any, Player: any, n: number?): any
		return Focus.get(Player, n or 1)
	end

	-- one screen, opened by Open and closed by Back
	local ONE = {
		Inventory = { opens = "Open", closes = "Back" },
	}

	-- a pair: the map takes the place of what is open, the dialog goes over it
	local TWO = {
		Map = { opens = "Map", closes = "Back", suppresses = { "Move", "Jump" } },
		Confirm = { opens = "Ask", closes = "Back", stacks = true, width = 0.5, height = 0.25, anchor = "bottom" },
	}

	-- ------------------------------------------------------------------ the surface

	T.case("Stock exports Screens and a driver a spec can hand it", function()
		local Beef = T.load()
		T.ok(Beef.Stock.Screens ~= nil, "Beef.Stock.Screens")
		T.eq(type(Beef.Stock.Screens), "function", "Screens is a factory a phase can call")
		T.eq(type(Beef.Stock.shown), "function", "Beef.Stock.shown")
	end)

	T.case("Screens is a controller a phase runs, and describe reads", function()
		local Beef, _, _, _, phase = rig(ONE)
		local said = phase.describe()
		T.ok(said:find("Screens"), "the controller is named")
		T.ok(said:find("reads"), "and what it reads")
		T.eq(Beef.Stock.Action.count, 0, "it pushes nothing of its own")
	end)

	T.case("every declared screen reaches the driver at boot, in one fixed order", function()
		local _, shown, _, _, phase = rig(TWO)
		phase.run()
		local declared = shown.declared()
		local names = {}
		for _, one in declared do
			table.insert(names, one.name)
		end
		T.eq(table.concat(names, " "), "Confirm Map", "sorted, so two clients build the same screens twice")
		T.eq(declared[1].width, 0.5, "the shape travels with the declaration")
		T.eq(declared[1].anchor, "bottom")
		T.eq(declared[2].anchor, "middle", "and a screen that said nothing gets the middle")
	end)

	T.case("nothing is shown until something opens one", function()
		local _, shown, Focus, Player, phase = rig(ONE)
		Player.spawn(false)
		phase.run()
		T.eq(shown.trace(), "", "the driver was told nothing")
		local focus = focused(Focus, Player)
		T.eq(focus.screen, nil, "no screen has the input")
		T.eq(#focus.open, 0)
		T.eq(focus.all, false)
	end)

	-- ------------------------------------------------------------------ opening and closing

	T.case("the action a screen names opens it, shows it, and gives it the input", function()
		local Beef, shown, Focus, Player, phase = rig(ONE)
		Player.spawn(false)
		press(Beef, "Open")
		phase.run()
		T.eq(shown.trace(), "show Inventory")
		T.eq(focused(Focus, Player).screen, "Inventory")
		T.ok(shown.at("Inventory") ~= nil, "and the driver knows where it went")
	end)

	T.case("back closes the screen that has the input", function()
		local Beef, shown, Focus, Player, phase = rig(ONE)
		Player.spawn(false)
		press(Beef, "Open")
		phase.run()
		shown.clear()
		press(Beef, "Back")
		phase.run()
		T.eq(shown.trace(), "hide Inventory")
		T.eq(focused(Focus, Player).screen, nil)
		T.eq(shown.at("Inventory"), nil)
	end)

	T.case("the action that opened it closes it again", function()
		local Beef, shown, Focus, Player, phase = rig(ONE)
		Player.spawn(false)
		press(Beef, "Open")
		phase.run()
		press(Beef, "Open")
		phase.run()
		T.eq(shown.trace(), "show Inventory hide Inventory")
		T.eq(focused(Focus, Player).screen, nil)
	end)

	T.case("an action opening a screen already open does nothing", function()
		local Beef, shown, _, Player, phase = rig(TWO)
		Player.spawn(false)
		press(Beef, "Map")
		phase.run()
		press(Beef, "Ask")
		phase.run()
		shown.clear()
		press(Beef, "Map")
		phase.run()
		T.eq(shown.trace(), "", "the map is covered, so the key cannot reach it")
		T.eq(table.concat(shown.showing(), " "), "Confirm Map", "and both are still up")
	end)

	T.case("a screen that stacks goes over the one below, and back lands on it again", function()
		local Beef, shown, Focus, Player, phase = rig(TWO)
		Player.spawn(false)
		press(Beef, "Map")
		phase.run()
		press(Beef, "Ask")
		phase.run()
		local focus = focused(Focus, Player)
		T.eq(focus.screen, "Confirm", "the one on top has the input")
		T.eq(table.concat(focus.open, " "), "Map Confirm", "and both are open, the one with the input last")

		shown.clear()
		press(Beef, "Back")
		phase.run()
		T.eq(shown.trace(), "hide Confirm", "only the top one went")
		T.eq(focused(Focus, Player).screen, "Map")
	end)

	T.case("a screen that does not stack takes the place of everything open", function()
		local Beef, shown, Focus, Player, phase = rig({
			Map = { opens = "Map", closes = "Back" },
			Settings = { opens = "Settings", closes = "Back" },
		})
		Player.spawn(false)
		press(Beef, "Map")
		phase.run()
		shown.clear()
		press(Beef, "Settings")
		phase.run()
		T.ok(shown.trace():find("hide Map"), "the map went")
		T.ok(shown.trace():find("show Settings"), "and settings came up")
		local focus = focused(Focus, Player)
		T.eq(table.concat(focus.open, " "), "Settings", "nothing is left under it")

		press(Beef, "Back")
		phase.run()
		T.eq(focused(Focus, Player).screen, nil, "so backing out lands on the game")
	end)

	T.case("a sequence that completed opens a screen, and the phases that are not a press do not", function()
		local Beef, shown, _, Player, phase = rig(ONE)
		local Phases = Beef.Stock.Phases
		Player.spawn(false)

		says(Beef, "Open", Phases.Ended)
		says(Beef, "Open", Phases.Held)
		says(Beef, "Open", Phases.Buffered)
		says(Beef, "Open", Phases.Changed)
		phase.run()
		T.eq(shown.trace(), "", "a release, a hold, a buffered press and a move are all left alone")

		says(Beef, "Open", Phases.Fired)
		phase.run()
		T.eq(shown.trace(), "show Inventory", "a sequence can be bound to a screen")
	end)

	T.case("a buffered press does not toggle the screen once a frame", function()
		local Beef, shown, _, Player, phase = rig(ONE)
		local Phases = Beef.Stock.Phases
		Player.spawn(false)
		press(Beef, "Open")
		phase.run()
		shown.clear()
		for _ = 1, 5 do
			says(Beef, "Open", Phases.Buffered)
			phase.run()
		end
		T.eq(shown.trace(), "", "the window went by and the screen stayed")
	end)

	-- ------------------------------------------------------------------ what it suppresses

	T.case("a screen's list of actions is what the focus says is suppressed", function()
		local Beef, _, Focus, Player, phase = rig(TWO)
		Player.spawn(false)
		press(Beef, "Map")
		phase.run()
		local focus = focused(Focus, Player)
		T.eq(focus.suppressed.Move, true)
		T.eq(focus.suppressed.Jump, true)
		T.eq(focus.suppressed.Look, nil, "and nothing it did not name")
		T.eq(focus.all, false)
	end)

	T.case("every open screen suppresses, not only the one with the input", function()
		local Beef, _, Focus, Player, phase = rig(TWO)
		Player.spawn(false)
		press(Beef, "Map")
		phase.run()
		press(Beef, "Ask")
		phase.run()
		local focus = focused(Focus, Player)
		T.eq(focus.screen, "Confirm", "the dialog has the input and suppresses nothing")
		T.eq(focus.suppressed.Move, true, "but the map under it still does")
	end)

	T.case("a screen wanting the whole attention says so with a flag rather than a list", function()
		local Beef, _, Focus, Player, phase = rig({
			Menu = { opens = "Menu", closes = "Back", suppresses = "all" },
		})
		Player.spawn(false)
		press(Beef, "Menu")
		phase.run()
		local focus = focused(Focus, Player)
		T.eq(focus.all, true)
		T.eq(next(focus.suppressed), nil, "it never sees the bindings table, so it writes no list")

		press(Beef, "Back")
		phase.run()
		T.eq(focused(Focus, Player).all, false, "and it goes back with the screen")
	end)

	T.case("a screen suppressing everything can still be closed", function()
		local Beef, shown, _, Player, phase = rig({
			Menu = { opens = "Menu", suppresses = "all" },
		})
		Player.spawn(false)
		press(Beef, "Menu")
		phase.run()
		shown.clear()
		press(Beef, "Menu")
		phase.run()
		T.eq(shown.trace(), "hide Menu", "Screens reads the pushes, not the focus it wrote")
	end)

	T.case("the suppression clears when the last screen closes", function()
		local Beef, _, Focus, Player, phase = rig(TWO)
		Player.spawn(false)
		press(Beef, "Map")
		phase.run()
		press(Beef, "Back")
		phase.run()
		local focus = focused(Focus, Player)
		T.eq(focus.suppressed.Move, nil)
		T.eq(#focus.open, 0)
	end)

	-- ------------------------------------------------------------------ where a screen lands

	T.case("a screen that says nothing fills the viewport", function()
		local Beef, shown, _, Player, phase = rig(ONE)
		Player.spawn(false)
		press(Beef, "Open")
		phase.run()
		local at = shown.at("Inventory")
		T.eq(at.x, 0)
		T.eq(at.y, 0)
		T.eq(at.width, 1280)
		T.eq(at.height, 720)
	end)

	T.case("the shares become pixels and the anchor places them", function()
		local Beef, shown, _, Player, phase = rig({
			Half = { opens = "Half", width = 0.5, height = 0.5, anchor = "middle" },
			Corner = { opens = "Corner", width = 0.25, height = 0.5, anchor = "bottomRight", stacks = true },
		})
		Player.spawn(false)
		press(Beef, "Half")
		phase.run()
		local at = shown.at("Half")
		T.eq(at.width, 640)
		T.eq(at.height, 360)
		T.eq(at.x, 320, "half the leftover width is to its left")
		T.eq(at.y, 180)

		press(Beef, "Corner")
		phase.run()
		local corner = shown.at("Corner")
		T.eq(corner.width, 320)
		T.eq(corner.height, 360)
		T.eq(corner.x, 960, "the bottom right corner leaves every leftover pixel above and to the left")
		T.eq(corner.y, 360)
	end)

	T.case("the order is the depth in the stack unless a screen names one", function()
		local Beef, shown, _, Player, phase = rig({
			Map = { opens = "Map" },
			Confirm = { opens = "Ask", stacks = true },
			Toast = { opens = "Toast", stacks = true, order = 100 },
		})
		Player.spawn(false)
		press(Beef, "Map")
		phase.run()
		T.eq(shown.at("Map").order, 1)
		press(Beef, "Ask")
		phase.run()
		T.eq(shown.at("Confirm").order, 2, "the one over it is in front of it")
		press(Beef, "Toast")
		phase.run()
		T.eq(shown.at("Toast").order, 100, "and a screen that named one keeps it whatever the depth")
	end)

	T.case("a resized viewport lays every shown screen out again", function()
		local Beef, shown, _, Player, phase = rig({
			Half = { opens = "Half", width = 0.5, height = 0.5 },
		})
		Player.spawn(false)
		press(Beef, "Half")
		phase.run()
		shown.clear()

		phase.run()
		T.eq(shown.trace(), "", "a frame where nothing moved says nothing to the driver")

		shown.resize(640, 480)
		phase.run()
		T.eq(shown.trace(), "show Half", "the rectangle changed, so it is laid out again")
		local at = shown.at("Half")
		T.eq(at.width, 320)
		T.eq(at.height, 240)
		T.eq(at.x, 160)
	end)

	-- ------------------------------------------------------------------ who gets the focus

	T.case("every entity carrying Focus gets the answer, whatever Kind it is on", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		local shown = Stock.shown()
		local Focus = Beef.Components.new("focus")
		local Tag = Beef.Components.new("tag")
		local Crowd = Beef.Kinds.new("crowd", Tag)
		local phase = Beef.Phase.new("Screens", { { Stock.Screens, Stock.Action, Focus, ONE, shown } })

		Crowd.spawn(true)
		Crowd.spawn(true)
		Focus.add(Crowd, 2, false)

		press(Beef, "Open")
		phase.run()
		T.eq(Focus.get(Crowd, 2).screen, "Inventory", "the one carrying it")
		T.eq(Focus.get(Crowd, 1), nil, "and the one that does not is untouched")
	end)

	T.case("an entity that arrives later gets the focus on its next frame", function()
		local Beef, _, Focus, Player, phase = rig(ONE)
		press(Beef, "Open")
		phase.run()
		Player.spawn(false)
		T.eq(focused(Focus, Player), false, "it starts with whatever the game spawned it with")
		phase.run()
		T.eq(focused(Focus, Player).screen, "Inventory")
	end)

	T.case("a controller reading Focus in the same phase sees this frame's answer", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		local shown = Stock.shown()
		local Focus = Beef.Components.new("focus")
		local Player = Beef.Kinds.new("player", Focus)
		local seen: { string } = {}

		local function Moving(focus: any, kind: any)
			return {
				name = "Moving",
				post = function()
					local value = focus.get(kind, 1)
					if type(value) == "table" and not (value.all or value.suppressed.Move) then
						table.insert(seen, "moved")
					else
						table.insert(seen, "still")
					end
				end,
			}
		end

		local phase = Beef.Phase.new("Heartbeat", {
			{ Stock.Screens, Stock.Action, Focus, { Menu = { opens = "Menu", suppresses = { "Move" } } }, shown },
			{ Moving, Focus, Player },
		})
		Player.spawn(false)

		phase.run()
		press(Beef, "Menu")
		phase.run()
		T.eq(table.concat(seen, " "), "moved still", "the screen opened and the reader stopped in the same frame")
	end)

	-- ------------------------------------------------------------------ with Input in front of it

	T.case("a phase with Input and Screens takes a key to a screen", function()
		local Beef = T.load()
		local Stock = Beef.Stock
		local feed = Stock.feed()
		local shown = Stock.shown()
		local Focus = Beef.Components.new("focus")
		local Player = Beef.Kinds.new("player", Focus)

		local bindings = {
			Open = { keys = { Enum.KeyCode.Tab } },
			Back = { keys = { Enum.KeyCode.Escape } },
		}
		local phase = Beef.Phase.new("Heartbeat", {
			{ Stock.Input, Stock.Action, bindings, feed },
			{ Stock.Screens, Stock.Action, Focus, ONE, shown },
		})
		Player.spawn(false)

		feed.tap("Open")
		phase.run()
		T.eq(Focus.get(Player, 1).screen, "Inventory", "tab opened it")

		feed.tap("Back")
		phase.run()
		T.eq(Focus.get(Player, 1).screen, nil, "and escape closed it")
		T.eq(shown.trace(), "show Inventory hide Inventory")
	end)

	-- ------------------------------------------------------------------ what it refuses

	local function build(Beef: any, screens: any)
		return function()
			Beef.Stock.Screens(Beef.Stock.Action, Beef.Components.new("focus"), screens, Beef.Stock.shown())
		end
	end

	T.case("a screen is named by a string, is a table, and says what opens it", function()
		local Beef = T.load()
		T.throws(build(Beef, "menu"), "screens is a table", "not a table at all")
		T.throws(build(Beef, { [1] = { opens = "Open" } }), "named by a string", "a number for a name")
		T.throws(build(Beef, { Inventory = "Open" }), "a screen is a table", "not a table")
		T.throws(build(Beef, { Inventory = { closes = "Back" } }), "a screen names opens", "nothing opens it")
		T.throws(build(Beef, { Inventory = { opens = Enum.KeyCode.Tab } }), "names an action", "a key rather than an action name")
		T.throws(build(Beef, { Inventory = { opens = "Open", closes = 1 } }), "names an action", "a number for back")
	end)

	T.case("an option has to be one this table has a word for", function()
		local Beef = T.load()
		T.throws(build(Beef, { Inventory = { opens = "Open", sticky = 1 } }), "is not an option here", "an invented option")
		T.throws(build(Beef, { Inventory = { opens = "Open", anchor = "middling" } }), "anchor is one of", "an anchor it has never heard of")
		T.throws(build(Beef, { Inventory = { opens = "Open", stacks = 1 } }), "stacks is true or false", "a number for stacks")
		T.throws(build(Beef, { Inventory = { opens = "Open", order = "front" } }), "order is a number", "an order in words")
	end)

	T.case("a share of the viewport is above zero and at most one", function()
		local Beef = T.load()
		T.throws(build(Beef, { Inventory = { opens = "Open", width = 0 } }), "a share of the viewport", "nothing is that wide")
		T.throws(build(Beef, { Inventory = { opens = "Open", height = 2 } }), "a share of the viewport", "taller than the screen")
		T.throws(build(Beef, { Inventory = { opens = "Open", width = "half" } }), "a share of the viewport", "a width in words")
	end)

	T.case("suppresses is a list of action names, or the one word", function()
		local Beef = T.load()
		T.throws(build(Beef, { Inventory = { opens = "Open", suppresses = "most" } }), "a list of action names", "a word it does not know")
		T.throws(build(Beef, { Inventory = { opens = "Open", suppresses = {} } }), "a list of action names", "an empty list")
		T.throws(build(Beef, { Inventory = { opens = "Open", suppresses = { Enum.KeyCode.W } } }), "by name, not a", "a key in the list")
	end)

	T.case("one action cannot open two screens", function()
		local Beef = T.load()
		T.throws(
			build(Beef, { Inventory = { opens = "Open" }, Map = { opens = "Open" } }),
			"cannot open two screens",
			"two screens on one key"
		)
	end)

	T.case("the things handed to the factory are the Action event and the Focus Component", function()
		local Beef = T.load()
		local Focus = Beef.Components.new("focus")
		T.throws(function()
			Beef.Stock.Screens({}, Focus, ONE, Beef.Stock.shown())
		end, "the first thing handed to it is the Action event type")
		T.throws(function()
			Beef.Stock.Screens(Beef.Stock.Action, {}, ONE, Beef.Stock.shown())
		end, "the second thing handed to it")
	end)
end
