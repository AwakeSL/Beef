# beef

**Buffered ECS and Event Framework.**

Kinds hold their entities as columns. Events are rows pushed into a buffer and read back as a
window. Controllers are plain tables with a stage or two, handed the buffers they read and write,
and a phase runs them in passes on the RunService signal you name. One frame, a handful of
passes, thousands of rows.

```lua
local Beef = require(ReplicatedStorage.Beef)
local Kinds, Components, Events, Phase, Drivers = Beef.Kinds, Beef.Components, Beef.Events, Beef.Phase, Beef.Drivers

local Position = Components.new("position", { wire = "vector3" })
local Velocity = Components.new("velocity", { wire = "vector3" })
local Drop = Kinds.new("drop", Position, Velocity)
local Landing = Events.new("landing", "handle:u32", "x:f32", "y:f32", "z:f32")

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

local heartbeat = Phase.new("Heartbeat", {
    { Fall, Drop, Position, Velocity },
    { Land, Landing, Drop },
})
Drivers.events({ Heartbeat = heartbeat })
```

- **One require.** `require(Beef)` is the whole interface: `Kinds`, `Components`, `Events`,
  `Phase`, `Drivers`, `Wire` and `Stock`, with the types (`Beef.Kind`, `Beef.Buffer`,
  `Beef.Controller`, ...) exported on the same name.
- **Columns, not objects.** A required component is the kind's own array, indexed by position.
  An optional one is packed, with a slot per position. A loop over a kind is a loop over arrays.
- **Events are windows.** A row is pushed with `push(...)` and read back between `from` and
  `last`. A lap closes the window each frame; nothing is allocated per row.
- **Passes, not ordering.** A phase runs every loop controller once, then re-runs only those
  that read a buffer another controller moved. An integrator with no reads runs once a frame.
- **The driver owns the signal.** One connection per RunService signal: parallel collects,
  then the phases, then parallel sends. Creation order never matters.
- **No side assumed.** The same controller runs on the server, the client, or inside an Actor.
  Prediction is a per-kind history option, not a rule.

## The rain

`rain.project.json` is the demo place. The server spawns a thousand drops a second, casts each
along its motion in four Actors, and ships births and landings to the client over one remote.
The client runs the same fall itself and draws every live drop with one adornment.

```
rojo build rain.project.json -o Rain.rbxl
```

Open it, press Play, and the output prints the phase description and the client's draw cost:
around 1,600 drops on screen at 1.4 ms a frame in Studio.

## Shapes

**Kind.** `Kinds.new(name, ...components, options?)`. `spawn(...)` takes the required
components' values in order and returns a handle that is never reused. `despawn(handle)` marks
the entity and `Kinds.lap()` removes it, pushing a row into `Kinds.died`. `at(handle)` is the
entity's position this frame, `dying(handle)` whether it is marked. `count`, `handle` and every
required column line up by position. `options.history` keeps a ring of snapshots of the wired
columns for rewind and replay.

**Component.** `Components.new(name, options?)`. `of(kind)` is the bucket: `value` and `has`.
`add`, `remove`, `get`, `has` work on any kind. `index = true` gives `find(value)` in return
for a lookup per write. `wire` names the type that crosses the network or an Actor boundary:
`u8 u16 u32 i32 f32 f64 bool color3 vector3 string kind`. `Components.group(name, ...)` is a
component with no value that an entity is in while it holds every member.

**Event.** `Events.new(name, "column:wire", ..., options?)`. `push(...)` one row. `from` to
`last` is this lap's window. `options.keep` retains closed laps for replay; `options.entity`
names the column that identifies the entity for per-entity stepping.

**Controller.** A function taking what the phase entry lists and returning a table:

| field | when |
| --- | --- |
| `boot` | once, in order, before the first frame |
| `pre` | once per frame, sees every row pushed since the previous frame's pre |
| `loop` | every pass on the first pass, then only when a buffer it reads has moved |
| `post` | once per frame, after the passes |
| `reads`, `writes` | the buffers it touches; what the pass rule and the description use |

The phase sets `self.phase`, and `self.phase.dt` is the frame time on the driver's signal.

**Phase.** `Phase.new(name, entries)`. An entry is `{ controller, ...arguments }`; strings and
plain option tables pass through. `describe()` prints every controller, its stages, and the
buffers it reads and writes. `replay(kind, handle, from, to)` rewinds one entity and re-runs
the loop stage over the retained laps.

**Drivers.** `Drivers.events({ Heartbeat = phase, ... })` runs phases on RunService signals.
`Drivers.step(phases, frequency)` runs them on the simulation step. `Drivers.parallel({ name,
workers, phase, ship, back })` packs a kind once into a SharedTable, hands each Actor a slice,
and delivers what the workers pushed into `back` before the next frame's phases.

**Stock.** Four controllers under `Beef.Stock`, used as phase entries. `Send(remote, ...events)`
and `Receive(remote, { name = event }, Kinds.named)` carry event rows server to client in one
buffer a frame. `Publish(remote, kind, ...components, options?)` and `Apply(remote, kind,
origin, ...components)` carry a kind's columns, with `every`, `channel`, `keyframe` and `chunk`
options.

```lua
local heartbeat = Phase.new("Heartbeat", {
    { Beef.Stock.Receive, "World", { rained = Rained, landing = Landing }, Kinds.named },
    { Rain, Rained, Landing, Drop, Origin },
})
```

Lap the store once a frame before the phases run:

```lua
RunService.PreAnimation:Connect(function()
    Events.lap()
    Kinds.lap()
end)
```

## The fast form and the simple form

The controllers in the demo loop over `kind.count` and the bucket arrays directly. That is the
fast form and it is what you should write. There is also a simple form, `for kind, n in
c.each()` with `c.get`, `c.add`, `c.has` and `c.join`, and `scripts/inline.luau` rewrites it
into the fast form on disk, hoisting the buckets once per kind:

```
lune run scripts/inline path/to/Controllers        # writes path/to/Built/Controllers
```

Your files are never touched; require the Built copies. `plugin/Inline.luau` is the same
rewrite as a Studio toolbar button for a place that is not on Rojo: tag a folder `Inline` and
it builds into a `Built` folder beside it.

## Drawing many things

Measured in Studio's client with a thousand moving drops, frame cost above the empty baseline:

| method | script per part | frame |
| --- | --- | --- |
| `SphereHandleAdornment.CFrame` | 0.9 µs | +0.8 ms |
| `Bone.CFrame` (set cost only) | 1.15 µs | +1.2 ms |
| `EditableMesh` vertices | 1.12 µs | +1.5 ms |
| `BulkMoveTo` | 2.6 µs | +3.2 ms |
| `Beam` per drop | 2.3 µs | +2.8 ms |
| `BillboardGui` per drop | 1.15 µs | +3.1 ms |
| `Part.CFrame` | 4.4 µs | +5.1 ms |
| `Part.Position` / `PivotTo` | 4.6 µs | +5.2 ms |
| unanchored parts, engine gravity | 0 | +3.4 ms |
| one `ParticleEmitter` | 0 | +0 ms (no per-drop control) |

The demo draws with adornments.

## Development

```
rojo serve rain.project.json     # sync the package and the demo into a place
selene src demo                  # lint
```
