--!strict
--!optimize 2
-- The vocabulary every stock controller shares: one Event and the small tables that say what its numbers
-- mean. Input writes it, Movement and Screens read it, and a game that throws any of them away and writes
-- its own pushes the same thing, so the swap is invisible to everything else. This is not a controller; it
-- is the one declaration they all agree on.
--
-- A push is one thing an action did at one moment.
--
--   action   what the game called it, the name it gave in the bindings table
--   phase    which of the six things below happened
--   value    the scalar reading: 1 or 0 for a button, the amount for an analog, the magnitude for a direction
--   x, y     the vector reading; for anything flatter than two dimensions it is the scalar on x
--   device   what the player was holding at the time
--
-- The column is `action` and not `name` because every Event already answers to `name`: that field is the
-- Event's own name, which `Phase.describe` and `Replicate` both read, and a column called `name` would sit
-- on top of it.

local Events = require(script.Parent.Parent.Events)

-- Began and Ended bracket an action that is down. Changed is an analog or a direction moving while it is.
-- Held comes once, when a press declared with `hold` has been down that long. Buffered comes every frame a
-- press declared with `buffer` is still remembered, so a reader that was not ready on the press frame still
-- sees it. Fired comes once, when a sequence completed; a sequence has nothing to end.
local Phases = {
	Began = 1,
	Changed = 2,
	Ended = 3,
	Held = 4,
	Buffered = 5,
	Fired = 6,
}

-- what Roblox's Enum.PreferredInput says, narrowed to what a reader does anything with. A MicroGamepad is a
-- gamepad here: a reader asks whether it is holding a stick or a key, and a TV remote is not a keyboard.
local Devices = {
	Unknown = 0,
	KeyboardAndMouse = 1,
	Gamepad = 2,
	Touch = 3,
}

-- the three things an input driver reports, which are the three the Input Action System fires: an action
-- going down, coming up, and an analog or a direction moving while it is down. Anyone writing a driver of
-- their own speaks these.
local Edges = {
	Pressed = 1,
	Released = 2,
	Changed = 3,
}

return {
	Action = Events.new("action", "action:string", "phase:u8", "value:f32", "x:f32", "y:f32", "device:u8"),
	Phases = Phases,
	Devices = Devices,
	Edges = Edges,
}
