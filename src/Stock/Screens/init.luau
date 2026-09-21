--!strict
--!optimize 2
-- Screens: the stock controller that decides which screen has the player's input and says what that takes
-- away from everyone else. It reads `Action` pushes, the ones Input writes, and it writes one Component,
-- `Focus`, so Movement, Camera and a game's own controllers can all find out whether their actions are
-- wanted right now without asking this one anything. It runs on the client.
--
-- Why Focus is a Component and not a call. If a reader asked Screens, every reader would have to hold a
-- reference to it, and a game that threw this controller away for one of its own would have to keep the
-- same call working. A Component is the thing those controllers already read, so the swap stays invisible,
-- which is the whole rule Stock is built on.
--
-- It draws nothing. A screen here is a name, a rectangle on the viewport, a claim on input and a list of
-- what that claim silences. What goes inside the rectangle is the game's own UI, parented into what the
-- driver shows, so this ships no widgets, no theme and no notion of what a menu looks like.
--
-- It does not act on the suppression it writes either. Screens reads the raw Action pushes, so a screen
-- that suppresses every action can still be closed by the action that opened it. Suppression is advice to
-- everyone else, the same way Input pushes a chord's members rather than silencing them.
--
-- Laying a screen out touches the engine, so it goes through a driver the way Input's does. `Engine` shows
-- a ScreenGui per declared screen under PlayerGui and reads the camera's viewport; `Shown` records what it
-- was told, so the whole of stacking, suppression and layout runs with no Roblox in the loop.

local Action = require(script.Parent.Action)
local Engine = require(script.Engine)

local Phases = Action.Phases
local BEGAN, FIRED = Phases.Began, Phases.Fired

-- one screen as the driver is asked to build it: a name to show and the shape it wants on the viewport.
-- `order` is missing when the screen did not name one, which means its depth in the stack.
export type Declared = {
	name: string,
	anchor: string,
	width: number,
	height: number,
	order: number?,
}

-- where a screen goes, in pixels from the top left of the viewport, and what it sits in front of. The
-- controller works the shares out against the viewport the driver reported, so a driver never divides
-- anything and a spec asserts on numbers.
export type Layout = {
	x: number,
	y: number,
	width: number,
	height: number,
	order: number,
}

-- the engine edge. Live it is a ScreenGui per screen and the camera's viewport; under Lune it is `Shown`,
-- which writes down every call. `show` comes again for a screen already shown when its rectangle changed,
-- which is what a resized window is.
export type Driver = {
	viewport: () -> (number, number),
	build: (declared: { Declared }) -> (),
	show: (name: string, at: Layout) -> (),
	hide: (name: string) -> (),
}

-- the nine places a screen can sit, as the share of the leftover space that goes above it and to its left.
-- A screen filling the viewport lands in the same place whichever of them it names.
local ANCHORS: { [string]: { number } } = {
	topLeft = { 0, 0 },
	top = { 0.5, 0 },
	topRight = { 1, 0 },
	left = { 0, 0.5 },
	middle = { 0.5, 0.5 },
	right = { 1, 0.5 },
	bottomLeft = { 0, 1 },
	bottom = { 0.5, 1 },
	bottomRight = { 1, 1 },
}

-- every key a screen may name. Unlike Input and Movement there is nothing here that belongs on some
-- entries and not others: a screen is one shape, and each of these is a question every screen answers.
local OPTIONS: { [string]: boolean } = {
	opens = true,
	closes = true,
	suppresses = true,
	stacks = true,
	anchor = true,
	width = true,
	height = true,
	order = true,
}

-- the word that stands in for every action there is, for a screen that wants the player's whole attention.
-- Screens never sees the bindings table, so it cannot write the list out, and a reader is told by a flag of
-- its own rather than by a set it would have to trust to be complete.
local EVERYTHING = "all"

local function listed(allowed: { [string]: any }): string
	local names = {}
	for key in allowed do
		table.insert(names, key)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

local function named(name: string, option: string, value: any): string
	assert(type(value) == "string", ("Screens %s: %s names an action, the name the bindings table gave it"):format(name, option))
	return value
end

local function share(name: string, option: string, value: any): number
	assert(
		type(value) == "number" and value > 0 and value <= 1,
		("Screens %s: %s is a share of the viewport, above zero and at most one"):format(name, option)
	)
	return value
end

-- ---------------------------------------------------------------- the screens table

type Screen = {
	name: string,
	opens: string,
	closes: string?,
	suppresses: { string }?,
	all: boolean, -- it named the word rather than a list
	stacks: boolean,
	anchor: string,
	width: number,
	height: number,
	order: number?,
}

local function suppression(name: string, given: any): ({ string }?, boolean)
	if given == nil then
		return nil, false
	end
	if given == EVERYTHING then
		return nil, true
	end
	assert(
		type(given) == "table" and #given > 0,
		("Screens %s: suppresses is a list of action names, or the word %s"):format(name, EVERYTHING)
	)
	for _, who in given do
		assert(
			type(who) == "string",
			("Screens %s: suppresses names actions by name, not a %s"):format(name, typeof(who))
		)
	end
	return given, false
end

local function read(screens: { [string]: any }): ({ [string]: Screen }, { [string]: string }, { Declared })
	assert(type(screens) == "table", "Screens: screens is a table of screen names and what each one is")

	-- names in one fixed order, so two clients build the same screens in the same order and a driver is
	-- handed the same list twice
	local names: { string } = {}
	for name in screens do
		assert(type(name) == "string", ("Screens: a screen is named by a string, not a %s"):format(typeof(name)))
		table.insert(names, name)
	end
	table.sort(names)

	local declared: { [string]: Screen } = {}
	local opensBy: { [string]: string } = {}
	local list: { Declared } = {}

	for _, name in names do
		local given = screens[name]
		assert(type(given) == "table", ("Screens %s: a screen is a table saying what opens it and where it sits"):format(name))

		for key in given do
			assert(
				OPTIONS[key] == true,
				("Screens %s: %s is not an option here; %s are"):format(name, tostring(key), listed(OPTIONS))
			)
		end

		assert(given.opens ~= nil, ("Screens %s: a screen names opens, the action that opens it"):format(name))
		local opens = named(name, "opens", given.opens)
		local already = opensBy[opens]
		assert(
			already == nil,
			("Screens %s: %s already opens %s, and one action cannot open two screens"):format(name, opens, already or "")
		)

		local anchor = given.anchor
		if anchor ~= nil then
			assert(
				type(anchor) == "string" and ANCHORS[anchor] ~= nil,
				("Screens %s: anchor is one of %s, not %s"):format(name, listed(ANCHORS), tostring(anchor))
			)
		end
		if given.stacks ~= nil then
			assert(type(given.stacks) == "boolean", ("Screens %s: stacks is true or false"):format(name))
		end
		if given.order ~= nil then
			assert(type(given.order) == "number", ("Screens %s: order is a number, and the higher one is in front"):format(name))
		end

		local suppresses, all = suppression(name, given.suppresses)
		local screen: Screen = {
			name = name,
			opens = opens,
			closes = if given.closes ~= nil then named(name, "closes", given.closes) else nil,
			suppresses = suppresses,
			all = all,
			stacks = given.stacks == true,
			anchor = anchor or "middle",
			width = if given.width ~= nil then share(name, "width", given.width) else 1,
			height = if given.height ~= nil then share(name, "height", given.height) else 1,
			order = given.order,
		}

		declared[name] = screen
		opensBy[opens] = name
		table.insert(list, {
			name = name,
			anchor = screen.anchor,
			width = screen.width,
			height = screen.height,
			order = screen.order,
		})
	end

	return declared, opensBy, list
end

-- the screen's share of the viewport, worked out in whole pixels so a driver is handed a rectangle and
-- never a fraction
local function laid(screen: Screen, depth: number, w: number, h: number): Layout
	local anchor = ANCHORS[screen.anchor]
	local width = math.floor(w * screen.width + 0.5)
	local height = math.floor(h * screen.height + 0.5)
	return {
		x = math.floor((w - width) * anchor[1] + 0.5),
		y = math.floor((h - height) * anchor[2] + 0.5),
		width = width,
		height = height,
		order = screen.order or depth,
	}
end

-- ---------------------------------------------------------------- the controller

-- the factory. `chosen` is the engine edge and a game never passes it: live it is a ScreenGui per screen,
-- and a spec hands a `Beef.Stock.shown()` instead, which writes down what it was told.
return function(action: any, focus: any, screens: { [string]: any }, chosen: Driver?): any
	assert(type(action) == "table" and type(action.push) == "function", "Screens: the first thing handed to it is the Action event type")
	assert(type(focus) == "table" and type(focus.of) == "function", "Screens: the second thing handed to it is the Component the focus goes in")
	local driver: Driver = chosen or Engine
	local declared, opensBy, list = read(screens)

	-- what is open, the one with the player's input last. Everything else this holds is worked out from it.
	local open: { string } = {}
	local shown: { [string]: Layout } = {}
	local viewW, viewH = 0, 0
	local moved = true -- so the first frame lays out whatever the game opened before it

	-- one table, shared by every entity carrying Focus and rebuilt only when the stack changed. A reader
	-- reads it and never writes into it; writing would be writing into every other entity's focus too.
	local value: any

	local function rebuild()
		local suppressed: { [string]: boolean } = {}
		local all = false
		local standing: { string } = table.create(#open)
		for i, name in open do
			standing[i] = name
			local screen = declared[name]
			if screen.all then
				all = true
			elseif screen.suppresses ~= nil then
				for _, who in screen.suppresses do
					suppressed[who] = true
				end
			end
		end
		value = { screen = open[#open], open = standing, suppressed = suppressed, all = all }
	end
	rebuild()

	return {
		name = "Screens",
		reads = { action },

		boot = function()
			driver.build(list)
		end,

		-- a loop, so it runs after Input's pre has written the frame's pushes and before anything in post
		-- reads the focus. Put it straight after Input and every reader in the same phase sees this frame's
		-- focus on the first pass.
		loop = function()
			for i = action.from, action.last do
				local phase = action.phase[i]
				-- a press opens or closes, and a sequence that completed does the same, so a screen can be
				-- bound to one. A buffered press would toggle once a frame for the length of its window,
				-- and a release is the same press coming back, so neither is worth acting on.
				if phase ~= BEGAN and phase ~= FIRED then
					continue
				end
				local name = action.action[i]

				-- the one on top answers first: it is the screen holding the input, so its own opens is a
				-- toggle and its closes is the way out. A screen further down is covered, and an action
				-- cannot reach past what is over it.
				local top = open[#open]
				if top ~= nil and (declared[top].closes == name or declared[top].opens == name) then
					table.remove(open)
					moved = true
					continue
				end

				local wants = opensBy[name]
				if wants ~= nil and table.find(open, wants) == nil then
					-- a screen that does not stack takes the place of everything open, so backing out of it
					-- lands on the game rather than on a pile nobody remembers opening
					if not declared[wants].stacks then
						table.clear(open)
					end
					table.insert(open, wants)
					moved = true
				end
			end

			if moved then
				rebuild()
			end

			-- a window the player resized is the same work as a screen that opened, so it goes through the
			-- same relay rather than a path of its own
			local w, h = driver.viewport()
			if w ~= viewW or h ~= viewH then
				viewW, viewH = w, h
				moved = true
			end

			if moved then
				local standing: { [string]: boolean } = {}
				for depth, name in open do
					standing[name] = true
					local at = laid(declared[name], depth, viewW, viewH)
					local was = shown[name]
					if
						was == nil
						or was.x ~= at.x
						or was.y ~= at.y
						or was.width ~= at.width
						or was.height ~= at.height
						or was.order ~= at.order
					then
						shown[name] = at
						driver.show(name, at)
					end
				end
				for name in shown do
					if not standing[name] then
						shown[name] = nil
						driver.hide(name)
					end
				end
				moved = false
			end

			-- the focus goes on every entity carrying it, whatever Kind that is. The Action pushes carry no
			-- entity, because Input runs on the client for one player, so on a client this is the one
			-- entity the player is; a game giving Focus to more gives every one of them the same answer.
			local kinds = focus.kinds()
			for k = 1, #kinds do
				local kind = kinds[k]
				local n, values, at = focus.join(kind)
				for i = 1, n do
					values[at[i]] = value
				end
			end
		end,
	}
end
