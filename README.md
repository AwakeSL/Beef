<div align="center">

# BEEF

**Buffered ECS and Event Framework**

<a href="https://github.com/AwakeSL/Beef/releases"><img alt="version" src="https://img.shields.io/badge/version-0.1.0-%231FD67F"></a>
<a href="https://wally.run/package/awakesl/beef"><img alt="wally" src="https://img.shields.io/badge/wally-awakesl%2Fbeef-white"></a>
<a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-white"></a>

</div>

A fast ECS for Roblox. Entities are columns, events are buffers, controllers run over both
every frame. Same code on the server, the client, or in an Actor.

## Install

```toml
[dependencies]
Beef = "awakesl/beef@0.1.0"
```

Or grab `Beef.rbxm` from the [releases](https://github.com/AwakeSL/Beef/releases) and drop it
in ReplicatedStorage.

## Usage

```luau
local Beef = require(ReplicatedStorage.Beef)
local Kinds, Components, Events, Phase, Drivers = Beef.Kinds, Beef.Components, Beef.Events, Beef.Phase, Beef.Drivers

-- components are columns, a kind is what an entity is born with
local Position = Components.new("position", { wire = "vector3" })
local Velocity = Components.new("velocity", { wire = "vector3" })
local Drop = Kinds.new("drop", Position, Velocity)

-- an event is a name and typed columns; a push is one entry across them
local Landing = Events.new("landing", "handle:u32", "x:f32", "y:f32", "z:f32")

-- a controller is a function that returns a table with a stage or two
local function Fall(drop, position, velocity)
    local self
    self = {
        name = "Fall",
        loop = function()
            local dt = self.phase.dt
            local p, v = position.of(drop).value, velocity.of(drop).value
            for n = 1, drop.count do
                v[n] += Vector3.new(0, -50, 0) * dt
                p[n] += v[n] * dt
            end
        end,
    }
    return self
end

local function Land(landing, drop)
    return {
        name = "Land",
        reads = { landing },
        loop = function()
            for i = landing.from, landing.last do
                drop.despawn(landing.handle[i])
            end
        end,
    }
end

-- a phase runs controllers in passes on the signal you name
local heartbeat = Phase.new("Heartbeat", {
    { Fall, Drop, Position, Velocity },
    { Land, Landing, Drop },
})

RunService.PreAnimation:Connect(function()
    Events.lap()
    Kinds.lap()
end)
Drivers.events({ Heartbeat = heartbeat })

Drop.spawn(Vector3.new(0, 80, 0), Vector3.zero)
```

Stages: `boot` once, `pre` once a frame, `loop` every pass while something it reads moved,
`post` once a frame after the passes. `heartbeat.describe()` prints what runs and what it
reads and writes.

One call at boot is the whole map of a game's traffic:

```luau
Beef.Replicate({
    toClients = { Damage, Spawned, { Landing, channel = "unreliable" } },
    toServer = { Input },
    publish = { { Drop, Position, every = 2, channel = "unreliable", origin = Origin } },
})
```

Events and Components say nothing about the network; this table says it, once, and the same
table runs on both sides. Beef makes the remotes, packs what the phases pushed after they have
run, and unpacks into the same event types and columns on the other side. `Replicate.stats()`
says what crossed. `Drivers.parallel` runs a phase across Actors. See the demo for both.

## Records

Durable state, per key, a DataStore behind it. A record is declared with a shape, a version and
its migrations; a key is loaded under a session lock, read and written as a plain table, and
saved on a timer, on release and at close.

```luau
local Profile = Beef.Records.new("profile", {
    version = 2,
    shape = { coins = 0, settings = { music = 0.8 } },
    migrate = { [2] = function(record) record.settings = { music = 0.8 } end },
})

Beef.Records.players(Profile)    -- a player's id is the key, their session is the hold

Profile.of(key).coins += 1       -- a read is a table read, a write is a table write
```

`Profile.loaded`, `.saved`, `.lost` and `.failed` are ordinary Beef Events, so a controller
reads them in its loop like anything else. Everything that leaves the process goes through a
driver: `Beef.Records.memory(world)` is tables in memory with a clock a test moves, which is
how the headless suite runs the lock, a lapsed lock, and two servers over one key.

## Shared

Live cross-server state over MemoryStore, gone at its TTL: a leaderboard, a matchmaking queue, a
table every server reads and writes at once. Three declared shapes matching the service, and what
changes on any of them arrives as an ordinary Event.

```luau
local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 3600, poll = 5 })
local Lobby = Beef.Shared.queue("lobby", { fields = { "userId:u64", "rating:u16" }, ttl = 300, poll = 1 })

Ranks.set(key, score)         -- queued; nothing here yields the caller
Ranks.get(key)                -- what the last poll saw, no request spent
Ranks.range(from, to, count)  -- that window, held to a range of values

-- Ranks.changed   "key:string", "value:u32"   a set here or on another server
-- Ranks.removed   "key:string"                removed, or gone at its TTL
-- Lobby.received  "id:string", then the declared fields; Lobby.remove(id) accepts the batch
```

A call made in a controller goes on a queue that a pump drains on its own thread, so a loop never
waits on the service. Request units are counted against the quota Roblox gives, a thousand plus a
hundred and twenty a player a minute; a call over budget is held and counted in
`Beef.Shared.stats()`, never dropped. `Beef.Shared.driver(Beef.Shared.tables())` puts tables and a
clock the test moves by hand where the service was, so all of it runs headless.

`Beef.Cue` is authored content, compiled and run: a game declares its vocabulary, content is
plain tables written in it, and every verb asks on an Event that one of your controllers
answers. `cue:entry()` is its place in a phase. See `docs/cue/Guide.md`.

## Demo

```
rojo build rain.project.json -o Rain.rbxl
```

A thousand drops a second, cast in four Actors on the server, drawn on the client. About
1,600 on screen at 1.4 ms a frame in Studio.

## Development

```
rojo serve rain.project.json
lune run scripts/test
selene src test demo
```
