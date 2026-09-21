# Stock Movement

The second stock controller, and the first that reads what Input wrote. It turns the frame's
`Beef.Stock.Action` pushes into a velocity on every body the game marked as controlled, and that
is all of it.

It ships no physics opinion. It never touches a Humanoid, a part, or the engine, so gravity, the
ground, standing on a moving platform and anything that pushes back are the game's. It writes a
number into a Component and stops there; what that number does to a body is decided by whatever
the game puts after it.

```luau
local Beef = require(ReplicatedStorage:WaitForChild("Beef"))
local Stock = Beef.Stock

local Body     = Beef.Components.new("body")
local Velocity = Beef.Components.new("velocity", { wire = "vector3" })
local Walker   = Beef.Kinds.new("walker", Body, Velocity)

local moves = {
	walk   = { action = "Move",   speed = 16, accelerate = 90 },
	sprint = { action = "Sprint", speed = 24 },
	crouch = { action = "Crouch", speed = 6 },
	jump   = { action = "Jump",   power = 50 },
	dash   = { action = "Dash",   speed = 60, lasts = 0.18 },
}

local heartbeat = Beef.Phase.new("Heartbeat", {
	{ Stock.Input, Stock.Action, bindings },
	{ Stock.Movement, Stock.Action, Body, Velocity, moves },
	{ Applying, Walker, Body, Velocity },
})
```

`Applying` is the game's, and it is where the engine comes back in: it reads `Velocity` and does
whatever that game does with a velocity, whether that is a Humanoid, a LinearVelocity, an
AlignPosition or its own integrator. Beef does not care which, and neither does this controller.

## What it reads

`Beef.Stock.Action`, and the `Body` Component. Nothing else, so the whole of it runs headless.

The Action Event carries no entity, because Input runs on the client for one player. So the
frame's pushes go to every body carrying both `Body` and `Velocity`, whatever Kind it is on. On a
client that is the one body the player drives. A game driving several bodies from one set of
actions gives `Body` only to the one being driven, or takes a move away from the rest.

## What it writes

`Velocity`, a `Vector3`, on every body it reads. X and Z are its answer every frame. Y is the
body's own, carried through untouched, except on the frame a jump begins.

That split is the whole of the no-physics rule. A jump is a Y written once and never taken back,
because taking it back is gravity and gravity is an opinion. A body that may not jump right now is
a body whose `granted.jump` is false, set by whoever does know about the ground.

It also writes two fields back into the `Body` value while a dash is running, and those are
described below.

## The moves table

A table of move names. Each entry names the action it reads, by the name the bindings table gave
it, and then its numbers.

| move     | what it does                                                                 |
| -------- | ---------------------------------------------------------------------------- |
| `walk`   | the steer. Its action's direction, turned into the world, at `speed`          |
| `sprint` | while its action is down, `walk` goes at this speed instead                   |
| `crouch` | the same, slower, and it takes precedence over `sprint`                        |
| `jump`   | on the press, Y becomes `power`                                                |
| `dash`   | on the press, a burst at `speed` for `lasts` seconds, along the current steer   |

Those five and no more. A sixth means a controller of the game's own, written against the same
Action and the same Components, dropped in where this one was.

`walk` has to be there. It is where the steer comes from, and every other move is measured against
it: without it there is nothing to go faster than, nothing to slow, and nothing for a dash to
point along.

### Options

| option       | on                                    | what it is                                             |
| ------------ | ------------------------------------- | ------------------------------------------------------ |
| `action`     | every move                            | the action name, as the bindings table spelled it       |
| `speed`      | `walk`, `sprint`, `crouch`, `dash`    | studs a second                                          |
| `power`      | `jump`                                | what Y becomes on the press                             |
| `lasts`      | `dash`                                | seconds the burst runs for                              |
| `accelerate` | `walk`                                | studs a second, a second, toward the wanted speed       |

Every number is above zero. Anything else in an entry is refused at the factory, by name, with
what would have been allowed. Two moves may name the same action.

Without `accelerate`, the ground speed snaps to what the steer asks for. With it, it moves toward
that by at most `accelerate` times the frame time each frame, in both directions, so letting go
slides to a stop. A dash is not accelerated into: it is a burst, and it snaps.

## What the Body holds

The `Body` Component's value is a table. Two fields are the game's:

| field     | what it is                                                                          |
| --------- | ----------------------------------------------------------------------------------- |
| `granted` | a table of move names set to `true`: which moves this body may make right now         |
| `facing`  | a `Vector3`, which way forward is for this body                                       |

A body with no `granted` may make every move the table declares, so a game that never takes a move
away never writes the field. A body that does write it lists every move it still has: `granted = {
walk = true, dash = true }` is a body that cannot jump.

Taking a move away is how the game says no. Airborne, out of stamina, stunned, in a cutscene,
hands full: all of them are one controller setting `granted`, and none of them are this one's.

`facing` is the frame the steer arrives in. The Action's `x` and `y` are a stick or a set of keys,
which mean nothing in the world until something says which way forward points, and the thing that
knows is the camera, which this controller may not touch. So the game writes it: usually the
camera's look vector, once a frame, from whatever controller owns the camera. It is flattened onto
the ground plane here, so a camera looking down does not slow the body. A body that leaves it out
faces `-Z`.

Two more fields are this controller's, and it writes them only while a dash is granted and
running: `dash`, the seconds left, and `way`, a `Vector3` of where that dash is going. They live on
the body rather than in the controller so they die with the entity.

## Which phases it acts on

| phase      | what it does with it                                                         |
| ---------- | ---------------------------------------------------------------------------- |
| `Began`    | the move's action is down. `jump` and `dash` begin here                       |
| `Changed`  | `walk` takes `x` and `y` as the steer; any other move is down while `value` is not zero |
| `Ended`    | the move's action is up, and `walk`'s steer goes to nothing                   |
| `Fired`    | `jump` and `dash` begin here too, so either can be bound to a sequence         |
| `Held`     | nothing                                                                       |
| `Buffered` | nothing                                                                       |

A buffer is for a reader with a reason to refuse a press and then take it a moment later. This
controller has no notion of the ground, so it has no reason to refuse a jump, and acting on every
`Buffered` frame would jump once a frame for the length of the window. So it takes the press and
leaves the rest alone, exactly as Input says a reader may.

The steer stays where it was last put. A stick held still reports nothing at all, so the last
`Changed` is the reading until the next one, or until `Ended`.

A dash begun is not begun again until it is over, and while it runs the steer does not turn it.

## Where the time comes from

`phase.dt`, the frame time Beef already hands every controller that integrates. Acceleration and
the length of a dash are the only two things that need it. Input takes a clock through its driver
because its clock is the engine's; this one does not touch the engine at all, so a second clock
would be a second thing to set up in a test for nothing. Headless, a spec sets `phase.dt` and runs
frames.

## Testing against it

No driver, no feed, no engine. Push `Beef.Stock.Action` and run the phase.

```luau
local phase = Beef.Phase.new("Move", {
	{ Beef.Stock.Movement, Beef.Stock.Action, Body, Velocity, moves },
})
phase.dt = 1 / 60

Walker.spawn({}, Vector3.zero)

Beef.Stock.Action.push("Move", Beef.Stock.Phases.Changed, 1, 0, 1, 1)
phase.run()
-- Velocity.of(Walker).value[1] is now Vector3.new(0, 0, -16)
```

With `Beef.Stock.feed()` and Input in front of it, the same phase runs off keys instead, which is
what Beef's own suite does for the end of it.

## Where it goes in a phase

It is one `post`, run once a frame after every pass of the loop. That is what makes the frame time
count down once instead of once a pass, and it means the Action window it reads is the whole
frame's pushes, however many controllers wrote them.

So whatever applies the velocity to a body goes after this: later in the same phase's `post`, or
in a later phase. A controller reading `Velocity` in the loop sees the previous frame's.

## What it does not do

It does not decide whether a move is allowed. It reads `granted` and does what it is told, so
stamina, cooldowns, stuns, being in the air and being in a cutscene all live in the controller that
knows about them.

It does not touch Y except on a jump, does not clamp a body to the ground, does not slow it in the
air differently from on it, does not turn the body to face where it is going, and does not write a
Transform. Every one of those is a physics opinion, and a controller reading `Velocity` and `Body`
can add any of them without this one knowing.

It does not silence an action it used. A jump that made this body jump is still a push every other
controller reads, the same way Input does not silence a chord's members.
