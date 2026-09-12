<div align="center">

# BEEF

**Buffered ECS and Event Framework**

<a href="https://github.com/AwakeSL/Beef/releases"><img alt="version" src="https://img.shields.io/badge/version-0.1.0-%231FD67F"></a>
<a href="https://wally.run/package/awakesl/beef"><img alt="wally" src="https://img.shields.io/badge/wally-awakesl%2Fbeef-white"></a>
<a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-white"></a>

</div>

Just a fast frame engine for Roblox. Entities live in columns, events live in buffers, and your
controllers run over both in passes on whatever RunService signal you name.

- **Columns, not objects.** A kind's required components are plain arrays indexed by position.
  A loop over a kind is a loop over arrays, nothing to look up.
- **Events are windows.** Push a row, read it back between `from` and `last`, and the lap
  closes the window each frame. Nothing is allocated per row.
- **Passes, not ordering.** A phase runs every controller once, then re-runs only the ones
  that read a buffer another controller moved. You never sort systems by hand.
- **Same code on every side.** A controller runs on the server, the client, or inside an
  Actor unchanged. Beef never assumes server authority.
- **One buffer a frame across the wire.** Events and columns cross the network as typed
  `buffer`s, reliable or unreliable, with keyframes.
- **0.8 µs to despawn and respawn an entity**, 1.9 µs with five optional components on it.
- **Type-safe [Luau](https://luau-lang.org/) API**, one require, zero dependencies.

## The rain

The demo place. The server spawns a thousand drops a second, casts each one along its motion in
four Actors, and ships births and landings to the client in one remote. The client runs the same
fall itself and draws every live drop with one adornment.

```
rojo build rain.project.json -o Rain.rbxl
```

Open it, press Play, and the output prints both phases and the client's draw cost: about 1,600
drops on screen at 1.4 ms a frame in Studio.

## Get started

**Wally.** Add it to `wally.toml` and run `wally install`.

```toml
[dependencies]
Beef = "awakesl/beef@0.1.0"
```

**Model file.** Grab `Beef.rbxm` from the [releases](https://github.com/AwakeSL/Beef/releases),
right click in Studio's explorer, Insert From File, and drop it in ReplicatedStorage.

**Clone it.** For the demo place and the tools.

```bash
git clone https://github.com/AwakeSL/Beef.git
```

Then require it once. Everything hangs off that one table, and the types ride on the same name.

```luau
local Beef = require(ReplicatedStorage.Beef)
local Kinds, Components, Events, Phase, Drivers = Beef.Kinds, Beef.Components, Beef.Events, Beef.Phase, Beef.Drivers
```

## Usage

### Components and kinds

A component is a named column. A kind is a set of components an entity is born with.

```luau
local Position = Components.new("position", { wire = "vector3" }) :: Beef.Component<Vector3>
local Velocity = Components.new("velocity", { wire = "vector3" }) :: Beef.Component<Vector3>
local Burning = Components.new("burning") :: Beef.Component<number>  -- optional on any kind

local Drop = Kinds.new("drop", Position, Velocity)

local handle = Drop.spawn(Vector3.new(0, 80, 0), Vector3.zero)  -- required values, in order
Burning.add(Drop, Drop.at(handle), 3)                            -- optional ones are added
Drop.despawn(handle)                                             -- marked now, removed at the lap
```

- `handle` is never reused. `kind.at(handle)` is the entity's position this frame, `nil` once
  it is gone.
- `kind.count`, `kind.handle` and every required column line up by position.
- `wire` names the type that crosses the network or an Actor: `u8 u16 u32 i32 f32 f64 bool
  color3 vector3 string kind`.
- `index = true` gives `component.find(value)` in return for a lookup per write.
- `Components.group(name, A, B)` is a component with no value that an entity is in while it
  holds every member.

### Events

An event type is a buffer of rows with typed columns. Push rows, read the window.

```luau
local Landing = Events.new("landing", "handle:u32", "x:f32", "y:f32", "z:f32")

Landing.push(handle, hit.X, hit.Y, hit.Z)

for i = Landing.from, Landing.last do
    print(Landing.handle[i], Landing.x[i])
end
```

`options.keep` retains closed laps for replay; `options.entity` names the column that
identifies the entity so a replay can step one entity at a time.

### Controllers

A controller is a function that takes what the phase hands it and returns a table with a stage
or two. No require, no base class. The phase fills in `self.phase`, and `self.phase.dt` is the
frame time.

```luau
local GRAVITY = Vector3.new(0, -50, 0)

local function Fall(drop, position, velocity)
    local self
    self = {
        name = "Fall",
        loop = function()
            local dt = self.phase.dt
            local p, v = position.of(drop).value, velocity.of(drop).value
            for n = 1, drop.count do        -- the fast form: two arrays, one loop
                local vn = v[n] + GRAVITY * dt
                v[n] = vn
                p[n] = p[n] + vn * dt
            end
        end,
    }
    return self
end

local function Land(landing, drop)
    return {
        name = "Land",
        reads = { landing },                -- tells the pass rule when to re-run this
        loop = function()
            for i = landing.from, landing.last do
                local h = landing.handle[i]
                if drop.at(h) and not drop.dying(h) then
                    drop.despawn(h)
                end
            end
        end,
    }
end
```

| stage | runs |
| --- | --- |
| `boot` | once, in order, before the first frame |
| `pre` | once a frame, sees every row pushed since the previous frame's `pre` |
| `loop` | on the first pass, then only while a buffer in `reads` has moved |
| `post` | once a frame, after the passes |

A controller that pushes rows every frame belongs in `pre`. A reader that must react to rows
pushed earlier this frame belongs in `loop`.

### Phases and drivers

A phase is an ordered list of entries, `{ controller, ...arguments }`. A driver runs phases on
a RunService signal and owns the connection, so the order within a frame is fixed: parallel
collects, then the phases, then parallel sends.

```luau
local heartbeat = Phase.new("Heartbeat", {
    { Ground },
    { Drip, Drop, Rained },
    { Land, Landing, Drop },
    { Fall, Drop, Position, Velocity },
    { Beef.Stock.Send, "World", Kinds.died, Rained, Landing },
})

print(heartbeat.describe())   -- every controller, its stages, what it reads and writes

RunService.PreAnimation:Connect(function()  -- lap the store once a frame, before the phases
    Events.lap()
    Kinds.lap()
end)
Drivers.events({ Heartbeat = heartbeat })
```

`Drivers.step(phases, frequency)` runs phases on the simulation step instead.
`phase.replay(kind, handle, from, to)` rewinds one entity through its kept history and re-runs
the loop stage over the retained laps.

### Parallel

Ship a kind into Actors, get events back, without writing a worker.

```luau
Drivers.parallel({
    name = "Rain",
    workers = 4,
    phase = ReplicatedStorage.Rain.Parallel.RainCast,  -- a module returning the worker-side phase
    ship = { Drop, Position, Velocity },               -- packed once into a SharedTable
    back = { Landing },                                -- delivered here before the next frame's phases
})
```

The kind is packed once on `PreSimulation`, each worker is told its slice, and what the workers
pushed lands in this side's event types on `Heartbeat`.

### Wire

Four stock controllers, used as phase entries.

```luau
-- server: this lap's rows of these events, one buffer, one remote
{ Beef.Stock.Send, "World", Kinds.died, Rained, Landing }
-- client: the same rows into local event types, delivered in pre
{ Beef.Stock.Receive, "World", { died = Kinds.died, rained = Rained, landing = Landing }, Kinds.named }

-- server: a kind's columns, only what changed, every 6th frame, keyframes on the unreliable channel
{ Beef.Stock.Publish, "Cubes", Cube, Color, Position, { every = 6, channel = "unreliable" } }
-- client: apply them to the local copies, matched through an indexed origin component
{ Beef.Stock.Apply, "Cubes", Cube, Origin, Color, Position }
```

Instances never cross. Pair a client copy to its server entity with an indexed `origin`
component holding the server's handle, the way the rain does.

## The simple form

The loops above walk `kind.count` and the bucket arrays directly. That is the fast form and it
is what you should write. There is also a simple form for the cases where a component may be
optional on some kinds:

```luau
for kind, n in Burning.each() do
    local left = Burning.get(kind, n) - dt
    Burning.add(kind, n, left)
end
```

`scripts/inline.luau` rewrites it into the fast form on disk, hoisting the buckets once per
kind. Your files are never touched; require the copies in `Built`.

```
lune run scripts/inline path/to/Controllers        # writes path/to/Built/Controllers
```

`plugin/Inline.luau` is the same rewrite as a Studio toolbar button for a place that is not on
Rojo. Tag a folder `Inline` and it builds into a `Built` folder beside it.

## Benchmarks

Studio, server side, per entity:

| | Beef | jecs |
| --- | --- | --- |
| despawn and respawn | 0.83 µs | 1.3 µs |
| despawn and respawn with 5 optional components | 1.9 µs | 1.3 µs |

Studio's client, a thousand drops moving every frame, frame cost above the empty baseline.
This is how the rain picked adornments:

| method | script per drop | frame |
| --- | --- | --- |
| `SphereHandleAdornment.CFrame` | 0.9 µs | +0.8 ms |
| `Bone.CFrame` (set cost only) | 1.15 µs | +1.2 ms |
| `EditableMesh` vertices | 1.12 µs | +1.5 ms |
| `Beam` per drop | 2.3 µs | +2.8 ms |
| `BillboardGui` per drop | 1.15 µs | +3.1 ms |
| `BulkMoveTo` | 2.6 µs | +3.2 ms |
| unanchored parts, engine gravity | 0 | +3.4 ms |
| `Part.CFrame` | 4.4 µs | +5.1 ms |
| `Part.Position` / `PivotTo` | 4.6 µs | +5.2 ms |

Studio's frame time is Studio's. Real client numbers will differ, and usually for the better.

## Development

```
rojo serve rain.project.json     # sync the package and the demo into a place
selene src demo                  # lint
lune run scripts/inline demo/ReplicatedStorage/Controllers
```

## Contributing

Found a bug, or built something on it? Open an [issue](https://github.com/AwakeSL/Beef/issues)
or a [pull request](https://github.com/AwakeSL/Beef/pulls). Benchmarks welcome. Numbers beat
opinions here.
