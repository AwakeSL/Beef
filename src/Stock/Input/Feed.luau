--!strict
--!optimize 2
-- The driver a headless spec runs on: a clock it moves and a set of actions it presses and releases.
-- Nothing in here is Roblox, so a hold that fires at its threshold, a chord that needs two keys and a
-- sequence that needs order are all assertable with no engine in the loop. A game testing its own
-- controllers against fed input uses the same thing.
--
-- `bind` keeps what the controller asked for, so a spec can check the bindings table was read the way it
-- meant it, and `drain` swaps between two tables so a frame of edges costs nothing.

local Action = require(script.Parent.Parent.Action)

local PRESSED, RELEASED, CHANGED = Action.Edges.Pressed, Action.Edges.Released, Action.Edges.Changed

local Feed = {}

function Feed.new(): any
	local clock = 0
	local device = Action.Devices.KeyboardAndMouse
	local down: { [string]: boolean } = {}
	local declared: { any } = {}
	local one: { any } = {}
	local two: { any } = {}
	local queue = one

	local function edge(name: string, kind: number, value: number, x: number, y: number)
		table.insert(queue, { action = name, edge = kind, value = value, x = x, y = y, device = device })
	end

	local self: any
	self = {
		-- the Driver
		now = function(): number
			return clock
		end,

		device = function(): number
			return device
		end,

		active = function(name: string): boolean
			return down[name] == true
		end,

		bind = function(list: { any })
			declared = list
		end,

		drain = function(): { any }
			local out = queue
			queue = if queue == one then two else one
			table.clear(queue)
			return out
		end,

		-- what a spec drives it with
		declared = function(): { any }
			return declared
		end,

		at = function(): number
			return clock
		end,

		advance = function(seconds: number)
			clock += seconds
		end,

		using = function(which: number)
			device = which
		end,

		press = function(name: string, amount: number?)
			local value = amount or 1
			down[name] = true
			edge(name, PRESSED, value, value, 0)
		end,

		release = function(name: string)
			down[name] = false
			edge(name, RELEASED, 0, 0, 0)
		end,

		-- an analog or a direction moving: one number is an amount, two are the axes and `value` is the
		-- magnitude, the way the Action columns read
		change = function(name: string, x: number, y: number?)
			local value = if y == nil then x else math.sqrt(x * x + y * y)
			down[name] = value ~= 0
			edge(name, CHANGED, value, x, y or 0)
		end,

		tap = function(name: string)
			self.press(name)
			self.release(name)
		end,
	}
	return self
end

return Feed
