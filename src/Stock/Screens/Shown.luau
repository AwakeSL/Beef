--!strict
--!optimize 2
-- The driver a headless spec runs on: a viewport it can resize and a written record of everything it was
-- told to show, move and hide. Nothing in here is Roblox, so a screen that stacks, one that takes the place
-- of what is open, and a rectangle that lands where the anchor says are all assertable with no engine in
-- the loop. A game testing its own screens does the same.
--
-- `build` keeps what the controller asked for, so a spec can check the screens table was read the way it
-- meant it, and `trace` is every call in the order it came, which is usually what a case actually wants.

local Shown = {}

function Shown.new(): any
	local width, height = 1280, 720
	local asked: { any } = {}
	local where: { [string]: any } = {}
	local log: { string } = {}

	return {
		-- the Driver
		viewport = function(): (number, number)
			return width, height
		end,

		build = function(list: { any })
			asked = list
		end,

		show = function(name: string, at: any)
			where[name] = at
			table.insert(log, "show " .. name)
		end,

		hide = function(name: string)
			where[name] = nil
			table.insert(log, "hide " .. name)
		end,

		-- what a spec reads back
		declared = function(): { any }
			return asked
		end,

		-- the rectangle and order a shown screen was last given, or nil while it is hidden
		at = function(name: string): any
			return where[name]
		end,

		showing = function(): { string }
			local names: { string } = {}
			for name in where do
				table.insert(names, name)
			end
			table.sort(names)
			return names
		end,

		trace = function(): string
			return table.concat(log, " ")
		end,

		clear = function()
			table.clear(log)
		end,

		-- the player resized the window, or turned the phone over
		resize = function(w: number, h: number)
			width, height = w, h
		end,

		size = function(): (number, number)
			return width, height
		end,
	}
end

return Shown
