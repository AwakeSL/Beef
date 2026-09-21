--!strict
--!optimize 2
-- The engine edge of Input, and the only file in Beef that knows what an InputAction is. Everything above
-- it is names, numbers and a clock, so the whole of holds, buffers, chords and sequences runs headless.
--
-- Read off Roblox's Input Action System guide (https://create.roblox.com/docs/input/input-action-system)
-- and the class pages for InputContext, InputAction and InputBinding:
--
--   * an InputContext holds InputActions and has Enabled, Priority and Sink and no bind call of its own,
--     so it is live from the moment it is in the data model, and a context nested in another does nothing.
--     Sink stops the KeyCodes bound under it reaching any context of lower Priority. The guide builds one
--     in ReplicatedStorage at edit time; Beef builds one per client at run time, so it goes under the
--     player's own PlayerScripts and dies with them.
--   * an InputAction takes its Type from Enum.InputActionType, of which Bool, Direction1D and Direction2D
--     are the three used here. It carries the read-only state properties BoolState, Direction1DState and
--     Direction2DState, and the events Pressed, Released and StateChanged. Pressed and Released fire for
--     Bool only; StateChanged fires for every type, and never for a state that did not change.
--   * an InputBinding names its hardware: KeyCode for a key or a button, UIButton for an on-screen
--     GuiButton, and Forward, Backward, Left and Right for a composite direction. PressedThreshold and
--     ReleasedThreshold are where an analog trigger like ButtonR2 counts as pressed and released again on a
--     Bool action; Scale and Vector2Scale multiply what a direction reports.
--   * which device the player is on is UserInputService.PreferredInput, an Enum.PreferredInput of
--     KeyboardAndMouse, Gamepad, Touch or MicroGamepad.
--
-- The services are fetched inside `bind` rather than at the top, because UserInputService is the client's
-- and this module is required wherever Beef is.

local Action = require(script.Parent.Parent.Action)

local Devices = Action.Devices
local PRESSED, RELEASED, CHANGED = Action.Edges.Pressed, Action.Edges.Released, Action.Edges.Changed

local PRIORITY = 2000 -- what the guide recommends for a game's primary context
-- the InputContext this builds, under the player's own PlayerScripts. A game that wants Sink, a different
-- Priority, or the whole context off for a while finds it by that name and sets the property itself.
local NAME = "Beef"

local one: { any } = {}
local two: { any } = {}
local queue = one
local actions: { [string]: any } = {}
local input: any = nil

local function device(): number
	if input == nil then
		return Devices.Unknown
	end
	local preferred = input.PreferredInput
	if preferred == Enum.PreferredInput.Gamepad or preferred == Enum.PreferredInput.MicroGamepad then
		return Devices.Gamepad
	elseif preferred == Enum.PreferredInput.Touch then
		return Devices.Touch
	elseif preferred == Enum.PreferredInput.KeyboardAndMouse then
		return Devices.KeyboardAndMouse
	end
	return Devices.Unknown
end

local function edge(name: string, kind: number, value: number, x: number, y: number)
	table.insert(queue, { action = name, edge = kind, value = value, x = x, y = y, device = device() })
end

-- a KeyCode goes on KeyCode, a GuiButton on UIButton; the bindings table already refused anything else
local function hardware(binding: any, key: any)
	if typeof(key) == "EnumItem" then
		binding.KeyCode = key
	else
		binding.UIButton = key
	end
end

local function bindKeys(action: any, declared: any)
	action.Type = Enum.InputActionType.Bool
	for _, key in declared.keys :: { any } do
		local binding = Instance.new("InputBinding")
		hardware(binding, key)
		if declared.press ~= nil then
			binding.PressedThreshold = declared.press
		end
		if declared.release ~= nil then
			binding.ReleasedThreshold = declared.release
		end
		binding.Parent = action
	end
	local name = declared.name
	action.Pressed:Connect(function()
		edge(name, PRESSED, 1, 1, 0)
	end)
	action.Released:Connect(function()
		edge(name, RELEASED, 0, 0, 0)
	end)
end

local function bindAxis(action: any, declared: any)
	action.Type = Enum.InputActionType.Direction1D
	for _, key in declared.keys :: { any } do
		local binding = Instance.new("InputBinding")
		hardware(binding, key)
		if declared.scale ~= nil then
			binding.Scale = declared.scale
		end
		binding.Parent = action
	end
	local name = declared.name
	action.StateChanged:Connect(function(value: any)
		local amount = tonumber(value) or 0
		edge(name, CHANGED, amount, amount, 0)
	end)
end

local function bindMove(action: any, declared: any)
	action.Type = Enum.InputActionType.Direction2D
	local move = declared.move
	local scale = declared.scale
	if move.forward or move.back or move.left or move.right then
		-- the four keys are one binding, not four: the engine composes them into the one direction
		local keys = Instance.new("InputBinding")
		if move.forward then
			keys.Forward = move.forward
		end
		if move.back then
			keys.Backward = move.back
		end
		if move.left then
			keys.Left = move.left
		end
		if move.right then
			keys.Right = move.right
		end
		if scale ~= nil then
			keys.Vector2Scale = Vector2.new(scale, scale)
		end
		keys.Parent = action
	end
	if move.stick then
		local stick = Instance.new("InputBinding")
		stick.KeyCode = move.stick
		if scale ~= nil then
			stick.Vector2Scale = Vector2.new(scale, scale)
		end
		stick.Parent = action
	end
	local name = declared.name
	action.StateChanged:Connect(function(value: any)
		local x, y = value.X, value.Y
		edge(name, CHANGED, math.sqrt(x * x + y * y), x, y)
	end)
end

local Engine = {
	now = function(): number
		return os.clock()
	end,

	device = device,

	-- which keys are down is the engine's to say, not something this side remembers; a chord asks it here
	active = function(name: string): boolean
		local action = actions[name]
		if action == nil then
			return false
		end
		local kind = action.Type
		if kind == Enum.InputActionType.Bool then
			return action.BoolState
		elseif kind == Enum.InputActionType.Direction1D then
			return action.Direction1DState ~= 0
		end
		return action.Direction2DState.Magnitude ~= 0
	end,

	-- built once, at the phase's boot. The context is parented last so nothing fires into a half-built set.
	bind = function(declared: { any })
		local Players = game:GetService("Players")
		local RunService = game:GetService("RunService")
		assert(RunService:IsClient(), "Input: the stock input controller is a client controller")
		assert(input == nil, "Input: the engine is bound once; a second Input controller needs its own driver")
		input = game:GetService("UserInputService")

		local made = Instance.new("InputContext")
		made.Name = NAME
		made.Priority = PRIORITY
		for _, one_ in declared do
			local action = Instance.new("InputAction")
			action.Name = one_.name
			if one_.shape == "keys" then
				bindKeys(action, one_)
			elseif one_.shape == "axis" then
				bindAxis(action, one_)
			else
				bindMove(action, one_)
			end
			action.Parent = made
			actions[one_.name] = action
		end
		made.Parent = Players.LocalPlayer:WaitForChild("PlayerScripts")
	end,

	drain = function(): { any }
		local out = queue
		queue = if queue == one then two else one
		table.clear(queue)
		return out
	end,
}

return Engine
