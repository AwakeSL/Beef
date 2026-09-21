# Stock Input

The first stock controller and the only one that touches the engine. A game says what its actions
are called and what triggers them, once, in the bindings table; every controller after this one
reads `Beef.Stock.Action` pushes and never asks the engine anything.

It runs on the client. It holds nothing about the game and decides nothing about what an action
means: a chord does not silence its members, a buffered press is not consumed by anyone, a hold
does not cancel the release that follows it. Whoever reads the pushes makes every one of those
calls.

```luau
local Beef = require(ReplicatedStorage:WaitForChild("Beef"))
local Stock = Beef.Stock

local bindings = {
	Crouch = { keys = { Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonB } },
	Jump   = { keys = { Enum.KeyCode.Space, Enum.KeyCode.ButtonA }, buffer = 0.15 },
	Open   = { keys = { Enum.KeyCode.E }, hold = 0.8 },
	Shoot  = { keys = { Enum.KeyCode.ButtonR2 }, press = 0.5, release = 0.4 },
	Move   = { move = {
		forward = Enum.KeyCode.W, back = Enum.KeyCode.S,
		left = Enum.KeyCode.A, right = Enum.KeyCode.D,
		stick = Enum.KeyCode.Thumbstick1,
	} },
	Slide    = { chord = { "Crouch", "Jump" } },
	Hadouken = { sequence = { "Down", "Forward", "Punch" }, within = 0.4 },
}

local heartbeat = Beef.Phase.new("Heartbeat", {
	{ Stock.Input, Stock.Action, bindings },
	{ Jumping, Stock.Action, Body, Velocity },
})
```

## What it reads

The engine, and nothing else. It is in no phase's `reads`, because what it reads is not an Event.
Everything it touches goes through a driver, so the whole of holds, buffers, chords and sequences
runs with no Roblox in the loop.

Live, the driver builds one `InputContext` named `Beef` under the player's own `PlayerScripts`,
with an `InputAction` per entry and an `InputBinding` per key. A game that wants `Sink` on, a
different `Priority`, or the whole context off for a while finds it by that name and sets the
property itself.

## What it writes

`Beef.Stock.Action`, and nothing else. One Event, six columns, one push per thing an action did.

| column   | wire     | what it holds                                                                    |
| -------- | -------- | -------------------------------------------------------------------------------- |
| `action` | `string` | what the game called it, the name it gave in the bindings table                    |
| `phase`  | `u8`     | one of `Beef.Stock.Phases`                                                         |
| `value`  | `f32`    | the scalar: 1 or 0 for a button, the amount for an analog, the magnitude of a direction |
| `x`, `y` | `f32`    | the vector; for anything flatter than two dimensions it is the scalar on `x`       |
| `device` | `u8`     | one of `Beef.Stock.Devices`                                                        |

The column is `action` and not `name` because every Event already answers to `name`: that field is
the Event's own name, which `Phase.describe` and `Replicate` both read.

### Phases

`Beef.Stock.Phases`:

| phase      | when                                                                           |
| ---------- | ------------------------------------------------------------------------------ |
| `Began`    | the action went down, or a chord's last member did                              |
| `Changed`  | an analog or a direction moved                                                  |
| `Ended`    | it came up, or a chord lost a member                                            |
| `Held`     | once, when a press declaring `hold` has been down that long                     |
| `Buffered` | every frame a press declaring `buffer` is still worth remembering                |
| `Fired`    | once, when a sequence completed; a sequence has nothing to end                   |

### Devices

`Beef.Stock.Devices`: `Unknown`, `KeyboardAndMouse`, `Gamepad`, `Touch`. Read off
`UserInputService.PreferredInput`. A MicroGamepad is a `Gamepad` here, because a reader is asking
whether it is holding a stick or a key and a TV remote is not a keyboard.

## The bindings table

A table of action names. Each entry names exactly one trigger and then its options.

### Triggers

| trigger    | what it is                                                                          |
| ---------- | ----------------------------------------------------------------------------------- |
| `keys`     | a list of `Enum.KeyCode` values and on-screen `GuiButton`s; any one of them fires it  |
| `axis`     | the same list, read as an amount rather than down or up: a trigger pedal, a zoom      |
| `move`     | `forward`, `back`, `left`, `right` and `stick`, any of them, composed into one direction |
| `chord`    | two or more other action names, all down at once                                      |
| `sequence` | two or more other action names, beginning in that order                               |

A `chord` and a `sequence` name actions the engine drives, never each other and never raw keys.
That is what makes a chord work the same on a gamepad as on a keyboard: the keys are declared once,
in the member's own entry, and the chord is about the actions.

### Options

| option    | on              | what it does                                                              |
| --------- | --------------- | ------------------------------------------------------------------------- |
| `buffer`  | `keys`, `chord` | seconds a press stays pending, pushing `Buffered` every frame              |
| `hold`    | `keys`, `chord` | seconds down before one `Held`                                             |
| `within`  | `sequence`      | seconds a step has to follow the one before it; 0.5 when it is not said    |
| `press`   | `keys`          | how far an analog trigger travels before it counts as down                 |
| `release` | `keys`          | and how far back before it counts as up again                              |
| `scale`   | `axis`, `move`  | what the engine multiplies the reading by                                  |

Anything else in an entry is refused at the factory, by name, with what would have been allowed.

## The four things it adds

The Input Action System has no notion of time. These four are what this controller is, and they
are all it is.

**A hold** pushes `Began` on the press and `Held` once, at the threshold, if it is still down. Let
go before then and there is a `Began` and an `Ended` and nothing between them. A second press starts
the clock over.

**A buffer** pushes `Began` on the press and then `Buffered` every frame until the window closes.
The window outlives the release, which is the whole point of one: a reader that was busy on the
press frame still sees the press when it is ready, and a reader that acts on the first one it can
use ignores the rest. Nobody consumes a buffered press; it simply stops being pushed.

**A chord** is on while every member is. The completing press pushes `Began` for the member and
`Began` for the chord, in that order, and the first member to lift pushes `Ended` for both. Members
are pushed either way: suppressing them is a decision, and this controller does not make it.

**A sequence** fires when its steps begin in order, each within `within` of the one before. A step
out of order drops it back to the start, or to one if that step is the first. An action the sequence
never mentions goes straight past it. It pushes `Fired` and resets, so it can run again.

## An example

Jumping with a buffer, read by a controller that only jumps when the body is on the ground.

```luau
local function Jumping(action, body, grounded)
	local Phases = Beef.Stock.Phases
	return {
		name = "Jumping",
		reads = { action },
		loop = function()
			for i = action.from, action.last do
				if action.action[i] ~= "Jump" then
					continue
				end
				local phase = action.phase[i]
				if phase ~= Phases.Began and phase ~= Phases.Buffered then
					continue
				end
				for n = 1, body.count do
					if grounded.of(body).value[n] then
						-- jump; the frames of Buffered left over land on a body that is no longer grounded
					end
				end
			end
		end,
	}
end
```

## Testing against it

`Beef.Stock.feed()` is an input driver with a clock a test moves and actions it presses, handed to
`Input` in place of the engine as a third argument. Beef's own suite runs the whole of holds,
buffers, chords and sequences through it; a game testing its own controllers does the same.

```luau
local feed = Beef.Stock.feed()
local phase = Beef.Phase.new("Test", {
	{ Beef.Stock.Input, Beef.Stock.Action, bindings, feed },
	{ Jumping, Beef.Stock.Action, Body, Grounded },
})

feed.press("Open")
phase.run()             -- Open:Began
feed.advance(0.8)
phase.run()             -- Open:Held
```

It takes `press(name, amount)`, `release(name)`, `tap(name)`, `change(name, x, y)`,
`advance(seconds)`, `using(device)`, `at()` and `declared()`, the last being what the controller
asked the engine for.

## Writing another driver

A driver is five functions. `now` is the clock the holds and windows run against, `device` is what
the player is holding, `active(name)` is whether that action is down right now, `bind(declared)` is
called once at the phase's boot with every engine-driven entry, and `drain()` hands back the edges
since the last call. An edge is `{ action, edge, value, x, y, device }` where `edge` is one of
`Beef.Stock.Edges`: `Pressed`, `Released` or `Changed`. `drain` may hand back the same table again
next frame, so a caller reads it before draining again.

## What it does not do

`Enum.InputActionType.Direction3D` and `ViewportPosition` are not bound. Neither is
`InputBinding.PrimaryModifier`: a two-key chord could be one, but a chord built out of declared
actions takes three members as easily as two and works where modifiers do not, so chords are
composed here rather than handed down.
