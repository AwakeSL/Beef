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
- Cue's runner is a controller, `{ Cue.Runner, cue }` in a Phase, with every bound anchor and
  every primitive's answers in `reads`. Its loop walks each anchor's pushes: read
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

- **Input**. Reads the engine. Writes `Action` events: name, phase, value, device.
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

The whole surface after this change. `Kinds`, `Components`, `Events`, `Phase`, `Drivers`, and
`Wire` are as they are today.

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
Beef.Records.driver(driver)     -- { get, update, release, lock, refresh, unlock }; Lune tables in tests
Beef.Records.flush()            -- save every held record now; what BindToClose calls
```

### Shared

```luau
local Ranks   = Beef.Shared.sorted("ranks",   { value = "u32", ttl = 3600, poll = 5 })
local Lobby   = Beef.Shared.queue("lobby",    { fields = { "userId:u64", "rating:u16" }, ttl = 300, poll = 1 })
local Auction = Beef.Shared.map("auction",    { fields = { "price:u32", "holder:u64" }, ttl = 600, poll = 2 })

Ranks.set(key, value)  Ranks.get(key)  Ranks.remove(key)  Ranks.range(from, to, count)
Ranks.changed          -- Event: "key:string", "value:u32"

Lobby.add(fields...)   Lobby.read(count)  Lobby.remove(id)
Lobby.received         -- Event: "id:string", then the declared fields

Auction.set(key, fields...)  Auction.get(key)  Auction.update(key, fn)  Auction.remove(key)
Auction.changed        -- Event: "key:string", then the declared fields

Beef.Shared.driver(driver)
Beef.Shared.stats()    -- units used this minute, calls held waiting for budget
```

### Replicate

```luau
Beef.Replicate({
	toClients = { Damage, Spawned, { Landing, channel = "unreliable" } },
	toServer  = { Input },
	publish   = { { Transform, every = 2, channel = "unreliable", keyframe = 30, chunk = 64 } },
	fleet = {
		url = "...", identity = token, interval = 0.125, budget = 480,
		kinds   = { Creature, Player },                       -- get a fleet id column
		events  = {
			{ Motion, route = "key", collapse = true, retention = "replace", window = 0.05 },
			{ Damage, route = "owner" },
		},
		publish = { { Transform, window = 0.05 } },           -- columns, offered on change
	},
})

Beef.Replicate.place(kind, handle, key)   -- which relay key this entity lives under
Beef.Replicate.want(keys)                 -- which keys this server wants to hear
Beef.Replicate.adopt(id)  .claim(id)  .disown(id)

Beef.Replicate.released   -- Events: "id:u32", "age:f32"
Beef.Replicate.adopted    -- "id:u32", "server:string", "age:f32"
Beef.Replicate.claimed    -- "id:u32", "server:string", "age:f32"
Beef.Replicate.stats()
```

### Cue

```luau
local cue = Beef.Cue.new():defaults()
Beef.Cue.Attached                          -- the Component any Kind with content includes

-- vocabulary, as today
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

-- content, as today
local sting = cue:define(table, "sting")      -- checked and folded here; errors name the file
cue:attach(handle, sting)                     -- writes Cue.Attached
cue:detach(handle, sting)
cue:fire(handle, "Begin", ctx, scope)         -- a direct firing; scope carries bindings to Release

-- running
Beef.Cue.Runner                               -- { Cue.Runner, cue } in a Phase
                                              --   reads every bound anchor and every .done/.refused
                                              --   pushes a step, reads its answer, pushes the next

-- looking in, as today
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
				local arrow = q[player.slot(take.to[i])]:pop(take.ammo[i])
				if arrow then take.done.push(take.seq[i], arrow)
				else take.refused.push(take.seq[i], "ammo") end
			end
		end,
	}
end
```

Gone from Cue as it is now: the four adapter functions, `apply`, `observe`, `start`, `step`,
`tick`.

### Stock

```luau
Beef.Stock.Action           -- Event: "name:string", "phase:u8", "value:f32", "device:u8"

Beef.Stock.Input(Action, bindings)
Beef.Stock.Movement(Action, Body, Velocity, moves)
Beef.Stock.Camera(Transform, Effect)
Beef.Stock.Sound(map)
Beef.Stock.Screens(Action, Focus, screens)
Beef.Stock.Music(State, tracks)
```

Each is a factory taking the Events and Components the game names, returning a controller
`{ name, reads, writes, boot, pre, loop, post }` that goes in a Phase like anything the game
wrote.

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

Each is one ticket, one worktree, one branch into `master`, built by an agent that reads this
file and the code and decides the rest.

## Still open

- **A place key across a fleet.** One server holds `"harbour"`. Whether another server runs its
  own copy, reads without writing, or waits is answered per game, and the first game that has
  the problem answers it.
- **The relay's authentication.** Tether's `x-tether-id` is an unverified string. Moving the
  client in does not change that; it is the relay's issue, tracked there.
