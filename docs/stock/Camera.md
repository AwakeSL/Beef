# Stock Camera

The third stock controller. It puts the client's one camera where the mode says, lays the effects
the game pushed on top of that, and leaves the aim underneath readable, so whatever wants to know
where the player is looking reads a Component instead of the engine.

It runs on the client. Writing the camera touches the engine, so that goes through a driver, the
way Input's engine edge does: live it is `workspace.CurrentCamera` and a raycast, headless it is
`Beef.Stock.film()`, which records every write.

```luau
local Beef = require(ReplicatedStorage:WaitForChild("Beef"))
local Stock = Beef.Stock

local Transform = Beef.Components.new("transform")   -- a CFrame, the body the camera follows
local View      = Beef.Components.new("view")        -- what the camera is doing, and its aim
local Effect    = Beef.Events.new("effect", "effect:string", "amount:f32", "x:f32", "y:f32", "lasts:f32")
local Walker    = Beef.Kinds.new("walker", Transform, View)

local modes = {
	follow = { distance = 12, offset = Vector3.new(0, 2, 0), pitch = { -70, 70 }, collide = true },
	orbit  = { distance = 18, offset = Vector3.new(0, 3, 0), pitch = { -20, 75 } },
	first  = { offset = Vector3.new(0, 1.5, 0), pitch = { -80, 80 }, fov = 100 },
	fixed  = { at = CFrame.new(0, 40, 80), fov = 60 },
}

local render = Beef.Phase.new("Render", {
	{ Stock.Input, Stock.Action, bindings },
	{ Turning, Stock.Action, View },
	{ Stock.Camera, Transform, Effect, View, modes },
})
```

`Turning` is the game's, and it is where input comes back in: it reads the `Look` action's pushes
and adds them to `View`'s `yaw` and `pitch`. Turning a camera is input, and Input owns input, so
this controller never touches `Action`. That is six lines of a game's own and it is what keeps the
mouse, the stick, the sensitivity and the inversion out of here.

## What it reads

`Effect`, the Event the game pushes camera effects into, and two Components: `Transform` and
`View`. Nothing else, so the whole of it runs headless.

`Transform` is a `CFrame` and not a position, because a follow camera swings around behind the body
as the body turns, and a position cannot say which way that is.

## What it writes

The camera, through the driver: a CFrame and a field of view, once a frame.

And `at` in the `View` value, a `CFrame`: the aim, where the camera points with none of the effects
in it. It also writes `pitch` back, clamped, which is described below.

The aim is in a Component rather than a field on the controller because a phase builds its
controllers itself and hands them to nobody, so a field on one is not readable from another. It
goes on the body rather than anywhere global for the same reason Movement's dash does: it dies with
the entity.

That is what Movement's `facing` is written from. One line in the game's own controller copies
`View.at.LookVector` into `Body.facing`, and the body walks where the camera looks.

## Which body

The one carrying `View`. There is one camera, so the first body found carrying it is the subject,
and a client gives `View` to exactly one body. Nothing carrying it means nothing is written to the
camera at all, which is what a client sees before its character has loaded.

`Transform` is read off that same body. A body carrying `View` and no `Transform` is a camera with
nothing to follow, which only `fixed` has any use for.

## The modes table

A table of mode names. Each entry is the mode's constraints.

| mode     | where it puts the camera                                                          |
| -------- | --------------------------------------------------------------------------------- |
| `follow` | `distance` behind the body, turning with it, and with the player's turn on top      |
| `orbit`  | the same, except the body's own turn is left out, so the body turns underneath it   |
| `first`  | at the body plus `offset`, looking where the player turned                          |
| `fixed`  | at the CFrame it was given, watching the body                                       |

Those four and no more. A fifth means a controller of the game's own, written against the same
Components and the same Effect, dropped in where this one was.

`follow` and `orbit` differ in one thing and it is the thing that matters: whether the camera is
tied to which way the body faces. A follow camera ends up behind the body however the body turns; an
orbit camera stays where the player put it and the body spins under it.

### Options

| option     | on                                | what it is                                             |
| ---------- | --------------------------------- | ------------------------------------------------------ |
| `distance` | `follow`, `orbit`                 | studs from the pivot back to the camera                  |
| `offset`   | every mode                        | a `Vector3` from the body to the point it is about       |
| `pitch`    | `follow`, `orbit`, `first`        | how far down and how far up it may look, in degrees      |
| `collide`  | `follow`, `orbit`                 | pull in when something is in the way                     |
| `fov`      | every mode                        | how many degrees of the world are across the screen      |
| `at`       | `fixed`                           | the `CFrame` the camera sits at                          |

A `follow` and an `orbit` need `distance`; a `fixed` needs `at`; a `first` needs nothing. Anything
else in an entry is refused at the factory, by name, with what would have been allowed.

`offset` is what the camera is about, not where it is. On `follow` and `orbit` it lifts the point
the camera orbits and looks at; on `first` it is where the eyes are; on `fixed` it moves the point
it watches.

`pitch` is a pair, down first and up second, and both stay inside 89 degrees of level, since a
camera looking straight up has no way left to turn around. Left out, it is `{ -80, 80 }`.

`fov` is how much of the world is across the screen, and it is left out at 90. Roblox wants the
angle up the screen instead, and which is which depends on how wide the window is, so the driver's
viewport is read and the conversion happens here. On a square window the two are the same number;
on a 16 by 9 one, 90 across is about 59 up.

## What the View holds

The `View` Component's value is a table. Three fields are the game's:

| field   | what it is                                                                    |
| ------- | ----------------------------------------------------------------------------- |
| `mode`  | which mode this camera is in, by the name the modes table gave it               |
| `yaw`   | radians, where the player has turned the camera                                 |
| `pitch` | radians, how far up or down, written back clamped                               |

A view that names no `mode` takes the one declared mode when there is only one, so a game with a
single camera never writes the field. With more than one declared it has to say, since guessing
would put the camera somewhere the game never asked for.

`yaw` and `pitch` are the player's turn, and they are the game's to accumulate from a look action.
`pitch` is clamped to the mode's limits and the clamp is written back, so an accumulator that has
been pushed hard against the limit does not have to unwind a long way before the camera moves
again. `yaw` is left alone; it wraps on its own.

One field is this controller's:

| field | what it is                                                         |
| ----- | ------------------------------------------------------------------ |
| `at`  | a `CFrame`, the aim: where the camera points with no effects in it   |

## The effects

Three, and each one touches a different part of what a camera is, which is why there are three.

| effect  | what it does                                                              |
| ------- | -------------------------------------------------------------------------- |
| `shake` | slides the camera about in its own plane, `amount` studs                     |
| `punch` | turns the view off the aim, `amount` degrees along `x` and `y`               |
| `zoom`  | adds `amount` degrees to the field of view                                   |

Every effect is at its full amount on the frame it was pushed and fades to nothing over `lasts`
seconds. One of each runs at a time: a second push replaces the one running rather than adding to
it, so a shake that lands twice does not turn into something nobody can watch, and a zoom a game
wants held is pushed every frame.

Recoil is a punch. A weapon that climbs pushes one per shot, and how far it climbs and how fast it
settles are numbers the game already has.

An effect this controller has never heard of goes past it, the way an action Movement does not read
goes past that one. So does one with no length in it, since there is no moment for it to happen in.

### The Effect event

The game declares it, with these five columns, and the controller refuses an event missing any of
them:

```luau
local Effect = Beef.Events.new("effect", "effect:string", "amount:f32", "x:f32", "y:f32", "lasts:f32")
```

| column   | what it holds                                                                     |
| -------- | --------------------------------------------------------------------------------- |
| `effect` | which effect: `shake`, `punch` or `zoom`                                           |
| `amount` | studs for a shake, degrees for a punch, degrees of field of view for a zoom         |
| `x`, `y` | which way a punch kicks: `x` right, `y` up. A shake and a zoom leave them at zero   |
| `lasts`  | seconds it runs for                                                                 |

The column is `effect` and not `name` for the reason the Action column is `action`: every Event
already answers to `name`, and that field is the Event's own.

```luau
Effect.push("shake", 1.5, 0, 0, 0.35)    -- something landed nearby
Effect.push("punch", 2.0, 0.2, 1, 0.18)  -- a shot, up and a little right
Effect.push("zoom", -25, 0, 0, 0.12)     -- pushed every frame the sight is up
```

The shake is a pair of sines rather than a random number, so a spec that runs the same frames twice
gets the same camera twice.

## Where the time comes from

`phase.dt`, the frame time Beef already hands every controller that integrates. The length left of
an effect and the clock the shake is a function of are the only two things that need it. Input takes
a clock through its driver because its clock is the engine's; this one gets its time from the phase
the way Movement does. Headless, a spec sets `phase.dt` and runs frames.

An effect runs down whether or not there was a camera to put it on that frame, so a shake does not
sit waiting through a loading screen and then go off.

## Testing against it

`Beef.Stock.film()` is a camera driver that records every write instead of making one, handed to
`Camera` in place of the engine as a fifth argument. It is the other way round from
`Beef.Stock.feed()`: what a spec wants to know about a camera is what was written to it.

```luau
local film = Beef.Stock.film()
local phase = Beef.Phase.new("Render", {
	{ Beef.Stock.Camera, Transform, Effect, View, modes, film },
})
phase.dt = 1 / 60

Walker.spawn(CFrame.new(0, 0, 0), { mode = "follow" })
phase.run()
-- film.at() is now CFrame.new(0, 2, 12), looking back down -Z
```

It takes `sized(width, height)` and `clears(amount)`, the latter being how much of the way out to
the camera is unobstructed, and reads back `at()`, `fov()`, `frames()`, `shots()`, `started()` and
`asked()`, the last being every collision question the modes put to it.

## Writing another driver

A driver is four functions. `start()` is called once at the phase's boot and is where the live one
takes the camera off the default scripts, `viewport()` is how big the window is, `clear(from, to)`
is how much of the way from the pivot out to where the camera wants to sit is unobstructed as a
number from 0 to 1, and `set(at, fov)` is the write, with `fov` already the angle up the screen.

The live one excludes the local player's character from its raycast, since a camera that stops
against the back of the body it is following never leaves it, and it stops a little short of what it
hit, since a camera flush against a wall sees through it. A game that wants different filtering,
or a camera that is not `workspace.CurrentCamera`, writes four functions of its own and hands them
in, exactly as it would for Input.

## Where it goes in a phase

It is one `post`, run once a frame after every pass of the loop, and it goes last: whatever writes
`Transform` has to have written it already, or the camera is a frame behind the body. On a client
that means the phase the game drives from `RenderStepped`, with Camera at the end of it.

## What it does not do

It does not read input. Turning the camera is input, and the game writes the turn into `View`.

It does not lag, ease or smooth. Where the mode says is where the camera is, that frame. Lag is the
kind of feel decision a game replaces a stock controller over, and a game that wants it eases its
own `yaw`, `pitch` and `Transform`, which is the same result with the numbers where the game can see
them.

It does not decide when a mode changes, does not turn the body to face where it is looking, does not
lock or hide the mouse, does not fade anything out when the camera is inside it, and does not own
more than one camera. Every one of those is a game's, and a controller reading `View` can add any of
them without this one knowing.

It does not silence an effect it used. A shake that shook this camera is still a push every other
controller reads, the same way Input does not silence a chord's members.
