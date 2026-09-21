# Stock Sound

The stock controller that owns every Sound instance on the client. A game pushes the Events it
already pushes, and this turns them into audio, so the thing that fires an Event never touches a
Sound, a volume or a distance.

One table at boot is the whole of it, the way `Replicate` takes the whole map of a game's traffic
in one call. An entry is the Event then its options, and the map itself is that same shape one size
up: the list part is the entries, the hash part is the options that belong to no single entry.

```luau
local Beef = require(ReplicatedStorage:WaitForChild("Beef"))
local Stock = Beef.Stock

local Transform = Beef.Components.new("transform", { wire = "vector3" })

local Fired   = Beef.Events.new("fired",   "at:vector3")
local Broke   = Beef.Events.new("broke",   "kind:kind", "handle:u32")
local Clicked = Beef.Events.new("clicked", "what:string")

local mix = { effects = 0.8, world = 1, ui = 0.6 }

local sounds = {
	{ Fired,   asset = "rbxassetid://1", group = "effects", carries = 220, duck = { amount = 0.5, lasts = 1.2 } },
	{ Broke,   asset = "rbxassetid://2", group = "world",   carries = 90, volume = 0.7 },
	{ Clicked, asset = "rbxassetid://3", group = "ui",      volume = 0.5 },
	groups = mix,
	transform = Transform,
	voices = 24,
}

local heartbeat = Beef.Phase.new("Heartbeat", {
	{ Shooting, Fired, Transform },
	{ Stock.Sound, sounds },
})
```

`Shooting` is the game's, and it pushes `Fired` because a shot happened. It says nothing about
audio, and it goes on saying nothing when the sound changes, when the sound is taken away, and when
a game swaps this controller for its own.

## What it reads

Every Event in the map, and nothing else. It runs on the client.

Its Events arrive inside the map rather than as arguments to the phase entry, and the controller
lists every one of them in `reads`, so the phase freezes a window over each the way it does for a
controller handed its Event. It reads `from` to `last` like anything else, and `phase.describe()`
names the Events it listens to.

## What it writes

Into Beef, one thing and only when asked for: `Beef.Stock.Duck`, the ask that quiets the music. An
entry with no `duck` option writes nothing at all, and a map with no ducking entry declares no
`writes`.

Everything else it writes is a Sound instance, and those are the driver's.

## The map

### Entries

An entry is the Event, then its options. `{ Fired, asset = "..." }`. A bare `Fired` is the same
entry with no options, which is refused, because a sound with no asset is not a sound.

| option    | what it is                                                                      |
| --------- | -------------------------------------------------------------------------------- |
| `asset`   | the sound it plays, a content string. Every entry has one                          |
| `group`   | which mixing group it is in, by name. One of the map's `groups`                    |
| `volume`  | its own volume before its group's, nothing or more. 1 when it is not said          |
| `pitch`   | what the engine multiplies the playback speed by, above zero. 1 when it is not said |
| `carries` | how far it reaches, in studs. Heard anywhere when it is not said                   |
| `duck`    | `{ amount = , lasts = }`, the ask pushed into `Beef.Stock.Duck` when it plays        |

Anything else in an entry is refused at the factory, by name, with what would have been allowed.
Two entries may not name the same Event: one Event makes one sound, and a game wanting a push to
make two pushes two Events.

### The map's own keys

| key         | what it is                                                                      |
| ----------- | -------------------------------------------------------------------------------- |
| `groups`    | group names and how loud each one is. The game's table, read every frame           |
| `transform` | the Component a placed entity keeps its position in. Needed only by an entity entry |
| `voices`    | how many sounds run at once. 24 when it is not said                                |

## Where a sound is

Off the Event's own columns, read once at boot and never guessed at afterwards.

| the Event has                       | where the sound is                                    |
| ----------------------------------- | ------------------------------------------------------ |
| a column named `at`                 | there. A `Vector3`, or the position of a `CFrame`       |
| columns named `kind` and `handle`   | where that entity's `transform` is                      |
| neither                             | everywhere, at one volume, which is what a click wants   |

An Event with both is placed by `at`, since the push went to the trouble of saying so.

`kind` and `handle` are the pair `Beef.Kinds.died` already carries and `Replicate` already crosses,
so an Event that names an entity for anything else names it for this too, and nothing new had to be
invented to point a sound at a thing.

A sound is placed once, where the push says, and stays there. A push is a moment and the position
is that moment's. A sound that follows something around is that thing's, not this controller's, and
a game that wants one parents its own Sound to the thing.

An entity that is gone has no position, so its push is not heard. An entity that died this frame is
still where it was, and its last sound lands there, because the sound of a thing breaking belongs
where the thing was.

## Who is told

`carries` is how far a sound reaches, in studs. A push further from the listener than that is not
heard at all: no voice is spent on it, no Sound is made, and nothing is asked of the engine. Within
it, the same number goes to the engine as the distance the fall reaches nothing at, so what the
listener hears and what this controller refused agree on one number.

Where the listener is comes from the driver, not from a Component. Live that is
`SoundService:GetListener()`, so a game that moved its listener is asked rather than assumed at.
Headless it is wherever the spec said to listen.

A sound with no `carries` is heard wherever it happens and takes the engine's own fall with
distance.

## What is in the way

One ray, listener to sound, asked through the driver. Blocked, the volume is multiplied by 0.35.

The ray is asked when the sound starts and again every quarter second while it plays, because the
listener walks behind a wall while a long sound is still going and the answer cannot be taken once.
A sound heard everywhere is never occluded: nothing can be between the ears and nowhere.

That is the whole rule. A volume rather than a filter, and a rate rather than a ray a frame per
voice, is a rule a game can reason about and afford. A game wanting a real low pass, or materials
that muffle differently, writes a driver of its own and keeps everything else here.

## Mixing

`groups` is the game's table, and it is the mixer. A group's volume is read every frame, so a
settings slider writes a number into the table the game handed in and the next frame is quieter,
including the voices already running. Nothing has to be called and nothing has to be held.

A sound's volume is its own times its group's, and times 0.35 when something is in the way. An
entry naming no group is at its own volume. An entry naming a group the map never declared is
refused at the factory.

## The voice budget

`voices` is how many run at once. When one more would go over:

- the quietest voice running loses its place, and
- a sound quieter than every one of them never starts.

Quietest means what the listener was least able to hear: the sound's own volume, times its group's,
times the muffle, times how much of its `carries` is left at that distance. So the shot across the
map loses to the one in the room, and a budget is never spent on what nobody could hear anyway.

A voice is given back when the engine says that sound ended, or when this controller stopped it to
make room.

## Ducking

`duck = { amount = 0.5, lasts = 1.2 }` on an entry pushes one `Beef.Stock.Duck` on the frame that
sound plays. `amount` is how far the music drops, 0 for nothing and 1 for silence, and `lasts` is
how many seconds it stays down.

```luau
Beef.Stock.Duck        -- Event: "amount:f32", "lasts:f32"
```

It is an ask, not an order. What the music does about it, how fast it gets there and what happens
when two asks overlap are Music's, because only Music knows what is playing. Music takes the Event
as an argument and reads it; neither controller knows the other exists, so a game replacing either
one keeps the seam by pushing or reading the same Event.

A push that was not heard does not duck. It never played, so it never asked.

## Where the time comes from

`phase.dt`, the same place Movement takes it. The only thing here that needs it is the timer
between occlusion checks. Input takes a clock through its driver because its clock is the engine's;
this one does not ask the engine what the hour is.

## Where it goes in a phase

One `post`, run once a frame after every pass of the loop. So the window it reads is the whole
frame's pushes, however many controllers wrote them, and a sound pushed by a controller in the loop
is heard in the same frame rather than the next.

Music reading `Duck` later in the same `post`, or in a later phase, sees the ask on the frame it
was made. Reading it in the loop sees it on the next frame.

## Testing against it

`Beef.Stock.speaker()` is a sound driver that plays nothing and writes down everything, handed to
`Sound` in place of the engine as a second argument. It never ends a sound on its own, which is
what makes the budget testable: fill it, push one more, and read which one lost.

```luau
local speaker = Beef.Stock.speaker()
local phase = Beef.Phase.new("Test", {
	{ Beef.Stock.Sound, sounds, speaker },
})

speaker.listen(Vector3.new(0, 0, 100))
Fired.push(Vector3.new(0, 0, 90))
phase.run()
-- speaker.last() is { voice = 1, asset = "rbxassetid://1", at = ..., volume = 0.8, pitch = 1, carries = 220 }
```

A spec drives it with `listen(at)`, `blocks(on)` and `finish(voice)`, and reads it back with
`played()`, `last()`, `playing()`, `volumeOf(voice)`, `stopped()`, `rays()` and `booted()`.
`volume` on a play is what it started at and `volumeOf` is what it is now, so a group's volume
moving under a running voice is one assertion.

## Writing another driver

A driver is seven functions.

| function                                             | what it does                                   |
| ---------------------------------------------------- | ----------------------------------------------- |
| `start()`                                            | called once at the phase's boot                  |
| `listener()`                                         | where the ears are, a `Vector3`                  |
| `blocked(from, to)`                                  | whether anything is between those two points     |
| `play(voice, asset, at, volume, pitch, carries)`     | start one. `at` is nil for a sound heard everywhere |
| `volume(voice, volume)`                              | that voice is now this loud                      |
| `stop(voice)`                                        | stop it; the controller has already forgotten it |
| `ended()`                                            | the voices that finished since the last call     |

`voice` is a number this controller hands out and never reuses. A driver that hands a voice back
through `ended` after the controller stopped it is harmless; the controller no longer knows that
number.

Live, a placed sound gets an `Attachment` of its own on Terrain and an unplaced one goes in a folder
under `SoundService`. A sound whose asset has not loaded a few seconds after it was told to play
gives its voice back, since `Ended` never comes for an id that does not exist.

## What it does not do

It does not decide when a sound happens. That is a push, and the push was made by whoever knew.

It does not pick between several assets for one Event. Variation is a real thing to want and a real
thing to test, and a controller that rolls a number is a controller whose spec has to hold that
number still. A game that wants it pushes the Event it already pushes and maps a second Event to a
second asset, or writes its own controller against the same Events.

It does not loop a sound and it does not stop one on command. A push is a moment. A sound that runs
until something says stop is a state, and a state with a crossfade and a volume that survives it is
Music.

It does not fade in or out, does not reverb, does not put a sound in a SoundGroup instance, and does
not read a player's saved volume setting. The first three are a driver of the game's own. The last
one is a record, and the game writes what it loaded into the `groups` table.
