# Beef core: records, shared state, replication, and the stock controllers

What Beef becomes after this change, and the order it is built in. Nothing here is built yet.
Written 2026-09-21 from the design conversation; the decisions are the owner's, the wording is
not, so where the wording is wrong the decision still stands.

## The line

Beef has two kinds of thing in it.

**Core** is what every game needs and does one way. The ECS is core because two controllers
written by two people must share one entity framework or they cannot be used together. Events
are core for the same reason. After this change, so are persistence, cross-server live state,
and replication, because every game has them and there is nothing game-specific in how a table
is saved or a row is sent.

**Stock** is a default most games take and any game can replace: input, movement, camera,
sound, screens, music. Each is a controller, `{ name, boot, pre, loop, post, reads }`, reading
and writing Beef Events and Components and nothing else, so a game that writes its own against
the same Events and Components drops it in where the stock one was.

Today `Beef.Stock` holds `Send`, `Receive`, `Publish`, `Apply`. Those are replication, which is
not optional, so they move into core under `Replicate`, and `Stock` becomes the controllers.

Core after this: `Kinds`, `Components`, `Events`, `Phase`, `Drivers`, `Wire`, `Replicate`,
`Records`, `Shared`. Declarations stay pure: an Event is a name and columns, a Component is a
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
the whole lifecycle, the same for every key. A game loads a player's record from its own join
code and releases it on leave, and decides for itself whether a player whose load failed stays.

### Keys

A key is a string and is not tied to players. Three shapes of key:

- **A player**: the user id.
- **A thing**: a GUID the game gives it when it is born, kept on the entity as a Component so the
  entity can find its record. Entity handles are session numbers and die with the server; the
  Component value is what outlives them.
- **A place**: a name, `"harbour"`. What a scene remembers between servers.

### Reading and writing

`Profile.of(key)` is the record, a plain table. Reads are table reads. Writes are table writes
and save, the way every library in use does it. Two calls exist for writes that want to be
announced:

```luau
Profile.set(key, "coins", 5)
Profile.change(key, function(r) r.coins += 5; r.unlocked[id] = true end)
```

Both check the write against `shape`, pack Roblox types (CFrame, Vector3, Color3, and the rest
`Wire` knows) into numbers, and push `Profile.changed` with the key and the path. A silent
direct write still saves; it just tells nobody.

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

Events a record has: `loaded(key)`, `changed(key, path)`, `saved(key)`, `lost(key)`,
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
	publish = { Transform = { every = 2, channel = "unreliable", keyframe = 30 } },
	fleet = {
		url = "https://relay.example/publish",
		identity = token,
		events = {
			Motion = { route = "key", collapse = true, retention = "replace", window = 0.05 },
			Damage = { route = "owner" },
		},
		kinds = { Creature, Player },
	},
})
```

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
in the same lap and the same loop as local damage. The relay stays in the Tether repo; Beef
carries the client and the Lune rig that talks to it.

## Stock

`src/Stock/<name>.luau`, each a controller with a headless suite and a page in `docs/`. Each
exists already as its own library from before Beef; bringing one into controller shape means
it reads and writes Beef Events and Components and holds no state of its own outside them.
What each reads and writes is fixed here; how it does it is the ticket's.

- **Input**, from Nerve. Reads the engine. Writes `Action` events: name, phase, value, device.
  Buffers, sequences, holds and chords on top of the Input Action System.
- **Movement**, from Tread. Reads `Action` and a body's granted moves. Writes velocity into the
  Components a game names. Ships no physics opinion.
- **Camera**, from Lens. Reads a Transform and the effects a game pushes as Events. Writes the
  camera. Modes, per-mode constraints, effects on top, aim readable underneath.
- **Sound**, from Muffle. Reads the Events a game maps to sounds, in a table given at boot the
  way `Replicate` is. Writes nothing back; it owns every Sound instance on the client, spatial
  placement, occlusion, mixing, the voice budget, and who is told a sound happened. The thing
  that fires the Event never touches audio.
- **Screens**, from Stage. Reads `Action` for focus and back. Writes which screen holds input
  and what that suppresses, as Components, and lays a declared screen out on the viewport.
- **Music**, new. One stream with states, crossfade, ducking when Sound asks. Reads the state
  changes a game pushes; writes nothing.

## Tests

Every core piece runs headless under Lune through its driver, and the Studio suite covers the
engine edge only: a real DataStore round trip, a real remote, a real relay through the live
rig. A test that needs Studio for something Lune could have covered is a driver with a gap.

## Order

1. **Records.** Declaration, keys, lock, load, migrate, write, save, driver, events.
2. **Shared.** The three shapes, polling into events, budget, driver.
3. **Replicate.** The boot table over today's four functions; `Stock` emptied of them.
4. **Fleet.** Tether's client under `Replicate`, its declarations folded into the table, the
   Lune rig brought across. Tether's repo keeps the relay.
5. **Stock.** Input first, then Movement, since it reads Actions; Camera, Sound, Screens and
   Music in parallel after those two show the shape.

Each is one ticket, one worktree, one branch into `master`, built by an agent that reads this
file and the code and decides the rest.

## Still open

- **A place key across a fleet.** One server holds `"harbour"`. Whether another server runs its
  own copy, reads without writing, or waits is answered per game, and the first game that has
  the problem answers it.
- **The relay's authentication.** Tether's `x-tether-id` is an unverified string. Moving the
  client in does not change that; it is the relay's issue, tracked there.
