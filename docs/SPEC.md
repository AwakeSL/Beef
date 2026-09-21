# Beef core: records, shared state, replication, cue, and the stock controllers

What Beef becomes after this change, and the order it is built in. Nothing here is built yet.
Written 2026-09-21 from the design conversation; the decisions are the owner's, the wording is
not, so where the wording is wrong the decision still stands.

## The line

Beef has two kinds of thing in it.

**Core** is what every game needs and does one way. The ECS is core because two controllers
written by two people must share one entity framework or they cannot be used together. Events
are core for the same reason. After this change, so are persistence, cross-server live state,
replication, and authored content, because every game has them and there is nothing
game-specific in how a table is saved, a push is sent, or a content table is checked and run.

**Stock** is a default most games take and any game can replace: input, movement, camera,
sound, screens, music. Each is a controller, `{ name, boot, pre, loop, post, reads }`, reading
and writing Beef Events and Components and nothing else, so a game that writes its own against
the same Events and Components drops it in where the stock one was.

Today `Beef.Stock` holds `Send`, `Receive`, `Publish`, `Apply`. Those are replication, which is
not optional, so they move into core under `Replicate`, and `Stock` becomes the controllers.

Core after this: `Kinds`, `Components`, `Events`, `Phase`, `Drivers`, `Wire`, `Replicate`,
`Records`, `Shared`, `Cue`. Tether and Cue are the two libraries that move in; nothing else
from before Beef is ported. Declarations stay pure: an Event is a name and columns, a Component is a
column, and neither says where it goes or whether it is saved. Where it goes is one table at
boot. Whether it is saved is a record, a separate thing from the ECS.

## Records

Durable state, per key, DataStore behind it.

### Declaring

```luau
local Profile = Beef.Records.new("profile", {
	version = 3,
	shape = { coins = 0, settings = { music = 0.8 }, unlocked = {} },
	migrate = {
		[2] = function(r) r.settings = { music = 0.8 } end,
		[3] = function(r) r.unlocked = {} end,
	},
})
```

`shape` is the record a new key starts with and what a write is checked against. `version` is
what stored data claims to be; `migrate[n]` takes a record at version `n - 1` to `n`, and a load
runs them in order from the stored version to the declared one. Stored data newer than the code
refuses to load, since the code cannot know what it would be overwriting.

`Profile.load(key)` takes the lock and loads; `Profile.release(key)` saves and lets go. That is
the whole lifecycle, the same for every key. `Beef.Records.players(Profile)` is the one
convenience: it connects `PlayerAdded` to `load(userId)` and `PlayerRemoving` to
`release(userId)` for that record and nothing more. Whether a player whose load failed stays is
the game's, read off `Profile.failed`.

### Keys

A key is a string and is not tied to players. Three shapes of key:

- **A player**: the user id.
- **A thing**: a GUID the game gives it when it is born, kept on the entity as a Component so the
  entity can find its record. Entity handles are session numbers and die with the server; the
  Component value is what outlives them.
- **A place**: a name, `"harbour"`. What a scene remembers between servers.

### Reading and writing

`Profile.of(key)` is the record, a plain table. Reads are table reads, writes are table
writes, the way every library in use does it, and a position that changes every frame is
written every frame; the timer picks up what is there. A game that wants to announce a change
pushes its own typed Event about it, `Coins`, `Unlocked`, from the controller that made the
change, since that controller already knows. Records has no change event of its own. The
record is checked against `shape` once at save, and Roblox types (CFrame, Vector3, Color3, and
the rest `Wire` knows) are packed to numbers there and rebuilt at load.

### Loading, the lock, saving

Load takes the session lock first. The lock is a MemoryStore hash map, `beef:lock:<record>`,
key to `{ server, at }`, with a TTL of the refresh interval plus thirty seconds, refreshed while
held. A server that dies stops refreshing and its locks vanish for every other server at the
same moment, so nothing waits on a wall clock and no DataStore request is spent on locking. A
key another live server holds is waited for; a load that fails outright fires `failed` with the
reason and loads nothing, because playing without a record and then saving over it is how
data is lost.

A held record is saved whole through `UpdateAsync`: on a timer (thirty seconds), on release,
and in `BindToClose`. The save checks the lock is still this server's before writing. A lock
that was lost makes the record read-only, fires `lost` once, and logs once.

Events a record has, its own lifecycle only: `loaded(key)`, `saved(key)`, `lost(key)`,
`failed(key, why)`. All ordinary Beef Events; a controller reads them like any other.

### The driver

One interface, `get`, `update`, `release`. Live it is `DataStoreService` and
`MemoryStoreService`. Under Lune it is two tables in memory, so a controller's tests join,
change, leave, rejoin, and assert the record came back, with no Roblox in the loop.
`Records.driver(x)` swaps it.

### What it is not

Not per entity. Entities are Kinds and last a session; a record lasts across them. A game that
wants a saved thing on an entity copies it into a Component at load and into the record on
change, and that copying is the game's, since only the game knows which Components are worth
saving. Not a lock on a world for a fleet, either: a place key can be held by one server at a
time, Beef reports that, and what a second server does about it is a game decision.

## Shared

Live cross-server state, MemoryStore behind it, gone at its TTL. Roblox says what needs to
survive sessions goes in a DataStore, and this is for what does not: a leaderboard, a
matchmaking queue, a table every server reads and writes at once.

Three declared shapes, matching the service:

```luau
local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 3600 })
local Lobby = Beef.Shared.queue("lobby", { fields = { "userId:u64", "rating:u16" }, ttl = 300 })
local Auction = Beef.Shared.map("auction", { fields = { "price:u32", "holder:u64" }, ttl = 600 })
```

Operations mirror the service (`set`, `get`, `remove`, `range` on a sorted map; `add`, `read`,
`remove` on a queue; `set`, `get`, `update`, `remove` on a map). MemoryStore has no push, so
Beef polls each declared structure on an interval and turns what changed into Events:
`Ranks.changed`, `Lobby.received`, `Auction.changed`. Request units are counted against the
quota Roblox gives (a thousand plus one hundred and twenty per player, a minute); a call over
budget is held and counted in `stats()`, never dropped.

Same driver idea as Records: `MemoryStoreService` live, a table under Lune.

## Replicate

One call at boot is the whole map of a game's traffic. Events and Components declare nothing
about where they go.

```luau
Beef.Replicate({
	toClients = { Damage, Spawned, { Landing, channel = "unreliable" } },
	toServer = { Input },
	publish = { { Transform, every = 2, channel = "unreliable", keyframe = 30 } },
	fleet = {
		url = "https://relay.example/publish",
		identity = token,
		kinds = { Creature, Player },
		events = {
			{ Motion, route = "key", collapse = true, retention = "replace", window = 0.05 },
			{ Damage, route = "owner" },
		},
		publish = { { Transform, window = 0.05 } },
	},
})
```

Every entry in the table is the same shape: the thing, then its options. A bare `Damage` is
`{ Damage }` with defaults.

`toClients` and `toServer` are today's `Send` and `Receive`; `publish` is today's `Publish` and
`Apply` with the same options (`every`, `channel`, `keyframe`, `chunk`). Beef makes the remotes,
packs on the phase edges through `Drivers`, unpacks into the same buffers on the other side.
The four functions become internals and nothing a game calls is named `Stock` for them.

`fleet` is Tether's client, moved in. Its message declarations go: an Event listed under
`fleet.events` is the message, with Tether's `routing`, `collapsible`, `retention` and `window`
as options on the entry, and `Wire` types as the quantisation. A Kind listed under
`fleet.kinds` gets a fleet id column: `spawn` mints, `despawn` releases, `Replicate.place(kind,
handle, key)` and `Replicate.want(keys)` are the interest calls. Things nobody owns are
`Replicate.adopt`, `claim`, `disown`, and every arrival, including `$release`, `$adopt`,
`$claim`, is a Beef Event with the age as a column, so a controller reads cross-server damage
in the same lap and the same loop as local damage. `fleet.publish` sends columns the way
Tether's buffer already works: at the end of each frame the column value of every placed
entity is offered, an unchanged value is skipped, a change within the entry's `window` of the
last replaces what is pending, and what is pending goes at the next transport flush. So a
position crosses when it changes and at most once a window, newest wins; there is no `every`
on the fleet side. The relay stays in the Tether repo; Beef carries the client and the Lune
rig that talks to it.

## Cue

Cue moves in whole, as `Beef.Cue`. It is the content layer: the game declares a vocabulary
(types, keys, fields, anchors, primitives, gates, schedules, outcomes), content is plain tables
written in that vocabulary, `define` checks every name and folds every constant at load,
`attach` puts a definition on an entity, and firing an anchor runs what subscribed. Values,
refusals, sequences, transforms, scheduling, granting, `stats`, and `reference` are unchanged;
its guide and spec come across under `docs/cue/`, and nothing about how content is written
changes.

What changes is the seam, because Beef is the storage Cue was built to plug into:

- The adapter goes. An entity is a Beef handle. A field names its column,
  `cue:field("hp", { type = "amount", component = Health })`, so `self.hp` compiles at `define`
  to one index into that column. The number Cue keeps per entity is `Cue.Attached`, a
  Component added to any Kind that carries content. `alive` is whether the handle is live.
- An anchor can be an Event. `cue:anchor("Hit", { event = Hit, self = "self" })` binds the name
  to a declared Event whose columns are the context; every push to `Hit` is a firing on the
  handle in the named column. `cue:fire` stays for a firing the game makes directly with a
  scope, the way it does today.
- A primitive is an Event with two answers. `cue:primitive("take", { takes = { ... }, event =
  Take, returns = "entity" })` declares `Take`, `Take.done`, and `Take.refused`. An invocation,
  resolved and transformed, is one push to `Take`, and the runner never reads a column to
  make it. The controller with `Take` in `reads` does the work over every push at once and
  answers each one: `done` with the result columns when there is a `returns`, or `refused`
  with the label. There is no `apply`, no `refuse`, and no `observe`: whatever wants to know a
  take happened reads `Take.done`.
- A sequence runs in the loop. Every push to a primitive carries a `seq` column, and so does
  its answer. The runner pushes the first step; the step's controller answers in the same
  pass or the next; the runner reads the answer, binds `as` from a `done`, and pushes the
  next step, or on a `refused` pushes the `otherwise` and stops. The passes keep going while
  something moved, so a whole sequence resolves inside one frame with no step running before
  the one before it answered, and nothing walked by hand. A bare list pushes every step at
  once.
- Cue's runner is a controller. `cue:entry()` is the Phase entry: `Cue.Runner`, the cue, and
  every bound anchor and every primitive's answers, so the Phase knows the buffers to freeze. Its loop walks each anchor's pushes: read
  `Cue.Attached` on `self`, resolve the subscribed effects, apply the transforms found on the
  participants, push. Scheduling (`after`, `every`, `once`, `lasts`) is the runner's queue
  stepped in that loop against the phase's clock; `over` and `per` are columns the reading
  controller spreads, so `tick` goes. `start` goes; `Phase` is the clock.
- The suite comes across and runs headless under Lune with `Vector3` from `@lune/roblox`,
  since with the adapter gone there is nothing else Roblox in it.

## Stock

`src/Stock/<name>.luau`, each a controller with a headless suite and a page in `docs/`, written
against Beef from the start: it reads and writes Beef Events and Components and holds no state
of its own outside them. What each reads and writes is fixed here; how it does it is the
ticket's.

- **Input**. Reads the engine. Writes `Action` pushes: action, phase, value, x, y, device.
  Buffers, sequences, holds and chords on top of the Input Action System.
- **Movement**. Reads `Action` and a body's granted moves. Writes velocity into the
  Components a game names. Ships no physics opinion.
- **Camera**. Reads a Transform and the effects a game pushes as Events. Writes the
  camera. Modes, per-mode constraints, effects on top, aim readable underneath.
- **Sound**. Reads the Events a game maps to sounds, in a table given at boot the
  way `Replicate` is. Writes nothing back; it owns every Sound instance on the client, spatial
  placement, occlusion, mixing, the voice budget, and who is told a sound happened. The thing
  that fires the Event never touches audio.
- **Screens**. Reads `Action` for focus and back. Writes which screen holds input
  and what that suppresses, as Components, and lays a declared screen out on the viewport.
- **Music**. One stream with states, crossfade, ducking when Sound asks. Reads the state
  changes a game pushes; writes nothing.

## API

The whole surface as built. `Kinds`, `Components`, `Events`, `Phase`, `Drivers`, and `Wire` are
as they were, with `Wire` gaining `u64`, `nameOf`, `flatten`, and `rebuild`, `Drivers` gaining
`before` and `after`, and `Events.new` refusing a column named after one of a buffer's own
fields. Every controller that touches the engine does so through a driver, and a headless
driver for each is exported beside it, so a game tests its own controllers against these with
no Roblox in the loop.

### Records

```luau
local Profile = Beef.Records.new("profile", {
	version = 3,
	shape = { coins = 0, settings = { music = 0.8 }, unlocked = {} },
	migrate = { [2] = function(r) ... end, [3] = function(r) ... end },
	save = 30,      -- seconds between timed saves, optional
	lock = 60,      -- seconds between lock refreshes, optional
})

Profile.load(key)           -- takes the lock, loads, migrates; fires loaded or failed
Profile.release(key)        -- saves, drops the lock
Profile.of(key)             -- the record, a plain table, or nil if not held
Profile.held(key)           -- true while this server holds it
Profile.save(key)           -- save now, outside the timer

Profile.loaded              -- Events: "key:string"
Profile.saved               -- "key:string"
Profile.lost                -- "key:string"            lock lost, record now read-only
Profile.failed              -- "key:string", "why:string"

Beef.Records.players(Profile)   -- PlayerAdded -> load(userId), PlayerRemoving -> release(userId)
Beef.Records.driver(driver)     -- { get, update, release, lock, refresh, unlock, server, now, wait }
Beef.Records.memory(world)      -- the headless driver: tables and a clock a test moves
Beef.Records.world()            -- a world two memory drivers share, standing for two servers
Beef.Records.live()             -- DataStoreService and MemoryStoreService
Beef.Records.step(now)          -- timed saves and lock refreshes due by now
Beef.Records.flush()            -- save every held record now; what BindToClose calls
```

A record's shape is checked on save, and a record that no longer fits is not saved and fires
`failed` with why. A Roblox datatype in the shape crosses the store flattened, marked with `$`,
and comes back rebuilt.

### Shared

```luau
local Ranks   = Beef.Shared.sorted("ranks",   { value = "u32", ttl = 3600, poll = 5, order = "descending" })
local Lobby   = Beef.Shared.queue("lobby",    { fields = { "userId:u64", "rating:u16" }, ttl = 300, poll = 1 })
local Auction = Beef.Shared.map("auction",    { fields = { "price:u32", "holder:u64" }, ttl = 600, poll = 2 })

Ranks.set(key, value)  Ranks.get(key)  Ranks.remove(key)  Ranks.range(from, to, count)  Ranks.refresh()
Ranks.changed          -- Event: "key:string", "value:u32"
Ranks.removed          -- "key:string"      gone, expired, or fallen out of the poll window

Lobby.add(fields...)   Lobby.read(count)  Lobby.remove(id)
Lobby.received         -- Event: "id:string", then the declared fields; the id is the batch's

Auction.set(key, fields...)  Auction.get(key)  Auction.update(key, fn)  Auction.remove(key)
Auction.changed        -- Event: "key:string", then the declared fields
Auction.removed        -- "key:string"

Beef.Shared.driver(driver)
Beef.Shared.tables()   -- the headless driver: advance, playing, refuse, sizeOf
Beef.Shared.budget({ base = 1000, per = 120, drain = 60 })
Beef.Shared.stats()    -- units used this minute, calls held waiting for budget, calls that failed
```

Nothing here yields the caller: every call goes on a queue a pump drains on its own thread, and
the budget holds the head of that queue rather than dropping anything. `get` and `range` read
the mirror the last poll left, so they cost nothing; a set is visible to `get` as soon as it
lands and to `range` at the next poll. A change this server made and a change another server
made arrive through the same Event. Fields are Wire columns; a Roblox datatype is refused.
Headless, the driver goes in before the first declaration.

### Replicate

```luau
Beef.Replicate({
	toClients = { Damage, Spawned, { Landing, channel = "unreliable" } },
	toServer  = { Input },
	publish   = { { Transform, every = 2, channel = "unreliable", keyframe = 30, chunk = 64, origin = Player } },
	fleet = {
		url = "...", identity = token, interval = 0.125, budget = 480,
		kinds   = { Creature, Player },                       -- get a fleet id, an indexed Component
		events  = {
			{ Motion, route = "key", collapse = true, retention = "replace", window = 0.05, subject = Creature },
			{ Damage, route = "owner", age = "age" },
		},
		publish = { { Transform, window = 0.05 } },           -- columns, offered on change
	},
})

Beef.Replicate.fleet                      -- the id Component; fleet.find(id) -> kind, handle
Beef.Replicate.place(kind, handle, key)   -- which relay key this entity lives under
Beef.Replicate.want(keys)                 -- which keys this server wants to hear
Beef.Replicate.adopt(id)  .claim(id)  .disown(id)

Beef.Replicate.released   -- Events: "id:u32", "age:f32"
Beef.Replicate.adopted    -- "id:u32", "server:string", "age:f32"
Beef.Replicate.claimed    -- "id:u32", "server:string", "age:f32"   server is "" when the claim lost
Beef.Replicate.stats()    -- ends with .fleet
```

Every entry is the thing, then its options. A fleet event needs an `entity` column; `subject`
names the kind those handles belong to and defaults to the one kind in `kinds`. `age` names the
column filled on arrival, in seconds, never sent. Message ids run in declaration order, so both
sides run the same boot table. Spawn mints an id and despawn releases it by wrapping the kind. A
mirror is a kind outside `kinds`, bound by the game writing `Replicate.fleet` itself. An event
for an id nobody carries is dropped and counted; a publish for one is held until it arrives.
`window` defaults to 0, so nothing collapses unless asked.

### Cue

```luau
local cue = Beef.Cue.new():defaults()
Beef.Cue.Attached                          -- the Component any Kind with content includes

-- an entity is one number: the kind's slot and the handle packed together
Beef.Cue.entity(kind, handle)  Beef.Cue.kind(e)  Beef.Cue.handle(e)  Beef.Cue.alive(e)

-- vocabulary, as before
cue:operator(name, { stage, commutes, means })
cue:type(name, { is, zero, words, constructors, operators, entity, means })
cue:key(name, { type, means })
cue:gate(name, { test, means })
cue:schedule(name, { kind, type, ready, means })
cue:outcome(name, { kind, means })

-- the seam
cue:field("hp",   { type = "amount", component = Health })       -- self.hp is one column index
cue:anchor("Hit", { event = Hit, self = "self" })                 -- a push to Hit is a firing
cue:primitive("take", {
	takes = { to = "who takes", ammo = "what kind" },
	returns = "entity",
	refuses = { "ammo" },
	event = Take,
})
-- declares Take         (to, ammo, seq)             the ask
--          Take.done    (seq, result)               the answer, result typed by `returns`
--          Take.refused (seq, because)              the other answer

-- content, as before
local sting = cue:define(table, "sting")      -- checked and folded here; errors name the file
cue:attach(handle, sting)                     -- writes Cue.Attached
cue:detach(handle, sting)
cue:fire(handle, "Begin", ctx, scope)         -- a direct firing; dispatches where it stands

-- running
cue:entry()                                   -- the Phase entry: Cue.Runner, the cue, every bound
                                              --   anchor and every .done/.refused, so the Phase
                                              --   freezes them; asks go in writes

-- looking in, as before
cue:stats()  cue:reference()  cue:primitives()  cue:keysOf(prim)  cue:typeOf(key)
cue:wordsOf(type)  cue:constructorsOf(type)
```

The controller that does a primitive's work reads its Event and answers every push:

```luau
local function Taking(take, player, quiver)
	return {
		name = "Taking",
		reads = { take },
		loop = function()
			local q = quiver.of(player).value
			for i = take.from, take.last do
				local arrow = q[Beef.Cue.handle(take.to[i])]:pop(take.ammo[i])
				if arrow then take.done.push(take.seq[i], arrow)
				else take.refused.push(take.seq[i], "ammo") end
			end
		end,
	}
end
```

A step costs two passes, the ask and the answer, since the Phase freezes cursors at the top of
a pass. A chain longer than the pass budget carries on next frame. Gone from Cue: the four
adapter functions, `apply`, `observe`, `start`, `step`, `tick`; `perform` stays for cue's own
verbs, and `sequence` is `chains = true`.

### Stock

```luau
Beef.Stock.Action     -- Event: "action:string", "phase:u8", "value:f32", "x:f32", "y:f32", "device:u8"
Beef.Stock.Phases     -- Began, Changed, Ended, Held, Buffered, Fired
Beef.Stock.Devices    -- Unknown, KeyboardAndMouse, Gamepad, Touch
Beef.Stock.Duck       -- Event: "amount:f32", "lasts:f32"    the one seam between Sound and Music

Beef.Stock.Input(Action, bindings, driver?)              -- keys, axis, move, chord, sequence; buffer, hold, within
Beef.Stock.Movement(Action, Body, Velocity, moves)       -- walk, sprint, crouch, jump, dash
Beef.Stock.Camera(Transform, Effect, View, modes, driver?)  -- follow, orbit, first, fixed
Beef.Stock.Sound(map, driver?)                           -- { { Fired, asset, group, carries, duck }, groups, transform, voices }
Beef.Stock.Screens(Action, Focus, screens, driver?)      -- opens, closes, suppresses, stacks, layout
Beef.Stock.Music(State, tracks, Duck?, driver?)          -- asset, volume, loop, crossfade

Beef.Stock.feed()     -- Input's headless driver: a clock a test moves and keys it presses
Beef.Stock.film()     -- Camera's: records every write
Beef.Stock.speaker()  -- Sound's: records every play, stop, position and volume
Beef.Stock.shown()    -- Screens': records show, hide, order and layout
Beef.Stock.tape()     -- Music's: records every volume, so a fade is a list of numbers
```

Each is a factory returning a controller `{ name, reads, writes, boot, pre, loop, post }` that
goes in a Phase like anything the game wrote, and each has a page in `docs/stock/`. The column
is `action` and not `name` because every Event answers to `name` already; `x` and `y` are there
because Movement needs a direction. `Body` holds `granted` and `facing` and the game owns them;
`View` holds `mode`, `yaw`, `pitch` from the game and `at`, the aim with no effects in it, from
the camera; `Focus` holds which screen has input and what it suppresses. Movement and Screens
read `Action`; Camera does not, because turning a camera is input and Input owns input, so the
game's own controller adds a look action to `View`. Sound's map entries place a sound by an `at`
column or a `kind, handle` pair; Music ducks by the largest pending amount.

## Tests

The headless suite is `lune run scripts/test [Name ...]`. A spec is `test/<Name>Spec.luau`
returning `function(T)`; `T.load()` is a fresh Beef, `T.module("Stock/Send")` one file, and
`T.case`, `T.eq`, `T.ok`, `T.throws` are the assertions. The loader stands in for `script` and
`game`, and Roblox datatypes come from `@lune/roblox`, so a module loads even where it touches
the engine at the top; what a test needs real, it makes real through the driver. Every ticket
adds its spec there.

Every core piece runs headless under Lune through its driver, and the Studio suite covers the
engine edge only: a real DataStore round trip, a real remote, a real relay through the live
rig. A test that needs Studio for something Lune could have covered is a driver with a gap.

## Order

1. **Records.** Declaration, keys, lock, load, migrate, write, save, driver, events.
2. **Shared.** The three shapes, polling into events, budget, driver.
3. **Replicate.** The boot table over today's four functions; `Stock` emptied of them.
4. **Fleet.** Tether's client under `Replicate`, its declarations folded into the table, the
   Lune rig brought across. Tether's repo keeps the relay.
5. **Cue.** Moved in whole: the adapter replaced by Components, anchors and primitives bound
   to Events, the runner a controller, the suite under Lune. It touches only Kinds, Components
   and Events, so it can be built alongside any of the four above.
6. **Stock.** Input first, then Movement, since it reads Actions; Camera, Sound, Screens and
   Music in parallel after those two show the shape.

Each was one ticket, one worktree, one branch into `spec/core`, built by an agent that read this
file and the code and decided the rest. All six landed; the API section above is what shipped.

## Still open

- **The engine drivers have not run in Studio.** Everything Lune can reach is covered. The
  InputContext, the camera, the Sound instances, the ScreenGui, a real DataStore and a real
  remote are the Studio suite's, and it has not been run.
- **Records and Shared count quota apart.** Each talks to MemoryStore through its own driver, so
  neither counts the other's units. The two drivers are also different shapes.
- **Action carries no entity.** Movement's pushes go to every body carrying `Body` and
  `Velocity`, which on a client is the one body. A server driving many bodies from one Action
  Event writes its own controller.

- **A place key across a fleet.** One server holds `"harbour"`. Whether another server runs its
  own copy, reads without writing, or waits is answered per game, and the first game that has
  the problem answers it.
- **The relay's authentication.** Tether's `x-tether-id` is an unverified string. Moving the
  client in does not change that; it is the relay's issue, tracked there.
