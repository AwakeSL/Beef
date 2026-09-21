--!strict
--!optimize 2
-- The engine edge of Screens, and the only file here that knows what a ScreenGui is. Everything above it
-- is names, a stack and a rectangle, so the whole of focus, suppression and layout runs headless.
--
-- What it does with the data model. A screen named in the table is a ScreenGui of that name under the
-- player's own PlayerGui: if the game already authored one there, this uses it, and if it did not, this
-- makes an empty one. Inside it, a Frame named `Screen` is the rectangle, transparent and borderless, and
-- the game's own UI goes in that Frame. So a game keeps designing its screens in StarterGui the way it
-- always did, and this only decides which of them is shown, where, and in front of what.
--
-- Showing is `ScreenGui.Enabled`, the order is `ScreenGui.DisplayOrder`, and the rectangle is the Frame's
-- Position and Size in offsets, because the controller already turned the shares into pixels against the
-- viewport this reported. `IgnoreGuiInset` and everything else on the ScreenGui is left alone: those are
-- the game's, set once wherever the game authored the screen.
--
-- The services are fetched inside `build` rather than at the top, because Players is the client's and this
-- module is required wherever Beef is.

local FRAME = "Screen" -- the rectangle inside each ScreenGui; a game's own UI is parented into it

local guis: { [string]: any } = {}
local frames: { [string]: any } = {}
local built = false

local Engine = {
	viewport = function(): (number, number)
		local camera = workspace.CurrentCamera
		if camera == nil then
			return 0, 0
		end
		local size = camera.ViewportSize
		return size.X, size.Y
	end,

	-- built once, at the phase's boot, and every screen starts hidden so nothing flashes up before the
	-- first frame has said what is open
	build = function(declared: { any })
		local Players = game:GetService("Players")
		local RunService = game:GetService("RunService")
		assert(RunService:IsClient(), "Screens: the stock screens controller is a client controller")
		assert(not built, "Screens: the engine is built once; a second Screens controller needs its own driver")
		built = true

		local where = Players.LocalPlayer:WaitForChild("PlayerGui")
		for _, one in declared do
			local gui = where:FindFirstChild(one.name)
			if gui == nil then
				gui = Instance.new("ScreenGui")
				gui.Name = one.name
				gui.ResetOnSpawn = false
				gui.Parent = where
			end
			gui.Enabled = false

			local frame = gui:FindFirstChild(FRAME)
			if frame == nil then
				frame = Instance.new("Frame")
				frame.Name = FRAME
				frame.BackgroundTransparency = 1
				frame.BorderSizePixel = 0
				frame.Parent = gui
			end

			guis[one.name] = gui
			frames[one.name] = frame
		end
	end,

	-- called again for a screen already up when its rectangle changed, which is what a resized window is
	show = function(name: string, at: any)
		local gui = guis[name]
		if gui == nil then
			return
		end
		gui.DisplayOrder = at.order
		local frame = frames[name]
		frame.Position = UDim2.fromOffset(at.x, at.y)
		frame.Size = UDim2.fromOffset(at.width, at.height)
		gui.Enabled = true
	end,

	hide = function(name: string)
		local gui = guis[name]
		if gui ~= nil then
			gui.Enabled = false
		end
	end,
}

return Engine
