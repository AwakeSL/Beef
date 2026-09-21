# Stock Music

One stream of music, with states. The game pushes a state change and this crossfades from whatever
was playing to whatever that state plays, over the time the arriving track declared. That is all of
it.

It runs on the client, because music is one player's. It decides nothing about when a state
changes: something else in the game knows the player walked into the boss room, and all that
controller does about the music is push a name. It writes nothing back into Beef, and it touches no
Component at all.

```luau
local Beef = require(ReplicatedStorage:WaitForChild("Beef"))
local Stock = Beef.Stock

local State = Beef.Events.new("music", "state:string")

local tracks = {
	menu     = { asset = "rbxassetid://1841647830", volume = 0.6, crossfade = 1 },
	explore  = { asset = "rbxassetid://1845756489", crossfade = 3 },
	chase    = { asset = "rbxassetid://1843313426", crossfade = 0.4 },
	boss     = { asset = "rbxassetid://1836430904", volume = 0.9, crossfade = 0 },
	cutscene = { asset = false, crossfade = 1.5 },
}

local heartbeat = Beef.Phase.new("Heartbeat", {
	{ Stock.Music, State, tracks, Stock.Duck },
	{ Rooms, State, Body },
})
```

`Rooms` is the game's, and it is the only thing that knows a state changed: it pushes `State` and
never touches a Sound.

## What it reads

Two Events, both the game's, and nothing else. No Component, no Kind, no engine, so the whole of it
runs headless.

**The state Event** needs a column named `state`, holding the name of the state being entered. What
else that Event carries is the game's business; this reads the one column. One column is enough
because the arriving track already declares how it arrives, so there is nothing left for a push to
say.

**The duck Event** is `Beef.Stock.Duck`, declared by Sound, with exactly two columns:

| column   | wire  | what it holds                                  |
| -------- | ----- | ---------------------------------------------- |
| `amount` | `f32` | how far the music drops, 0 to 1                 |
| `lasts`  | `f32` | seconds it stays down                           |

It is the third thing handed to the factory and a game with no Sound in it leaves it out. Sound
declares it as `Beef.Stock.Duck`; a game can pass an Event of its own with those two columns
instead. Music never pushes it: Sound owns that seam and decides which sounds are worth getting
the music out of the way for.

## What it writes

Nothing, into Beef. Out of it, two Sounds: it plays them, stops them, and sets their volume, and
that is the whole of the driver.

## The tracks table

A table of state names. Each entry says what plays in that state.

| option      | on                 | what it is                                                     |
| ----------- | ------------------ | -------------------------------------------------------------- |
| `asset`     | every state        | the sound that plays, or `false` for a state where nothing does  |
| `volume`    | a state that plays | 0 to 1, the level that track climbs to                           |
| `loop`      | a state that plays | whether it starts again at the end; `true` when it is not said   |
| `crossfade` | every state        | seconds the fade into this state takes; 2 when it is not said    |

Anything else in an entry is refused at the factory, by name, with what would have been allowed, and
so is `volume` or `loop` on a state that plays nothing.

`volume` stops at 1 because it is a mix level inside the stream, not a loudness. A game that wants
the music louder or quieter than Beef's idea of full raises or lowers the `BeefMusic` SoundGroup,
which is the one knob over both streams and the obvious place for a settings slider.

### The fade belongs to the state being entered

`crossfade` is declared on the track arriving, not the one leaving, because what a fade is for is
the thing you are about to hear. Getting into a fight is fast and getting out of one is slow, and
both of those are declared on the state you are getting into: `chase` says `0.4` and `explore` says
`3`. A state that declares `0` is a cut.

Both streams move over that one window, and the fade is equal power, not a straight line: each
stream's level is the sine of how far through it is, so the two together are as loud in the middle
of a fade as either is alone at the end of one. A straight line through the middle is where a
crossfade audibly sags.

### Quiet is a state

`asset = false` is a state where nothing plays: a cutscene, a held breath before a boss. It fades
the stream out over its own `crossfade` and starts nothing.

A state name with no entry at all is quiet too, and says so once through `warn`. A name with nothing
behind it is almost always a typo, and music that stops without saying why is hard to go looking
for.

## Ducking

Sound pushes a duck when something has to be heard over the music. Every duck still running counts,
and the largest `amount` among them is how far the stream is down. It drops that far at once,
because a duck that fades in is a duck that arrived too late to be any use, and it climbs back over
0.3 seconds once the last one has run out, which is slow enough not to swell.

A duck arriving under a deeper one that is still running changes nothing until the deeper one
expires, and then the stream climbs only as far as the one still holding it. An `amount` past 1 is
the whole of the music and no more. A duck counts on the frame it arrives, however short it is.

The duck multiplies whatever the fades are doing, so a crossfade under a duck is still equal power,
just quieter.

## Two streams

A crossfade is two things playing at once, so there are two Sounds and no more. What that costs is
a third state arriving while a crossfade is still running: one of the two has to make way, and it
is the one already leaving, since nobody is still listening to it. It is stopped where it stands.

Two cases are worth knowing because they are the ones a game hits by accident:

- A state left and come back to while its track is still fading out turns that track around where it
  is rather than starting it over. Flicking in and out of combat does not restart the combat music.
- Two states that name the same asset do not crossfade it with itself. The track keeps playing and
  only the level it is heading for changes, so `day` and `dusk` on one loop is a volume change.

A track that does not loop and reaches its end simply stops making noise. The controller is not told
and does not care: the stream stays on that state until the game pushes another one. Telling it
would mean a callback in the driver, which is a second seam for very little.

## Which stage it runs in

One `post`, once a frame, plus a `boot` that builds the two Sounds. `post` is where the State window
is the whole frame's pushes, however many controllers wrote them, and where the clock counts down
once rather than once a pass.

The frame's state is the **last** state pushed in it. One stream, so a frame in which the game
changed its mind twice starts one track, not two. Pushing the state that is already playing does
nothing at all, so a game may push its state every frame and nothing restarts.

## Where the time comes from

`phase.dt`, the same as Movement. The length of a fade, the length of a duck and the climb back out
of one are the only things that need a clock, and this controller does not touch the engine, so a
second clock through the driver would be a second thing to set up in a test for nothing.

## Testing against it

`Beef.Stock.tape()` is a music driver that plays nothing and writes down every call, handed to
`Music` as a fourth argument in place of the engine. A fade is then a list of numbers.

```luau
local State = Beef.Events.new("music", "state:string")
local Duck  = Beef.Events.new("duck", "amount:f32", "lasts:f32")
local tape  = Beef.Stock.tape()

local phase = Beef.Phase.new("Test", {
	{ Beef.Stock.Music, State, tracks, Duck, tape },
})
phase.dt = 0.5

State.push("explore")
phase.run()
-- tape.playing(1) is the explore asset, and tape.level(1) is on its way up
```

It takes `log()`, every call in order; `levels(slot)`, every volume written to one stream, which is
the fade curve; `level(slot)`, where that stream is now, or 0 while it is stopped; `playing(slot)`,
the asset on it; `streams()`, both of those as `"1:calm 2:chase"`; `bound()`, whether the phase
booted; and `clear()`, to read one frame on its own.

## Writing another driver

A driver is four functions. `bind()` is called once at the phase's boot and builds whatever the
streams are. `play(slot, asset, looped)` starts one of the two on an asset, `stop(slot)` stops it,
and `volume(slot, level)` sets its level. A slot is 1 or 2.

A volume is only written when it changed, so a track sitting at the top of its fade with no duck on
it costs nothing a frame.

Live, the driver builds a SoundGroup named `BeefMusic` under `SoundService` with two Sounds in it,
`BeefMusic1` and `BeefMusic2`. A Sound parented to SoundService plays flat, with no position in the
world, which is what a music stream is; the other kind is Sound's.

## What it does not do

It does not decide when a state changes, does not read the game's state from anywhere, and does not
know what a room, a fight or a menu is. It pushes nothing, so nothing downstream can depend on it
having played anything.

It does not mix. Where a sound effect sits against the music is Sound's, and the whole of what this
does about it is take the ducks Sound asks for. It does not fade for the game either: a menu slider
belongs on the SoundGroup, not in here.

It does not run more than one stream of music. A game that wants a layered score, with stems coming
in and out on their own, writes a controller of its own against the same Event; this one is the
common case and says so.
