# Beef.Cue

**Authored content, compiled and run.** You declare your game's vocabulary: its types, keys,
anchors and primitives. Content is plain tables written in that vocabulary. Cue checks everything
when it loads, folds what it can, and runs what subscribed when you tell it something happened.

```lua
local Beef = require(path.to.Beef)
local cue = Beef.Cue.new():defaults()
```

`defaults()` gives you a working vocabulary out of the box: `amount`, `place`, `direction`,
`entity`, the keys `to`/`by`/`at`/`damage`/`over`/`per`, anchors like `Hit` and `Equip`,
`otherwise`/`as`, `after`/`every`, and the `sequence` and `grant` primitives, so you can author
content immediately. Every default is an ordinary registration made through the same public calls
you use, with no special access. Skip `defaults()` and declare everything yourself, override
nothing or extend freely. The *core* owns no names, which is why you can.

## Setup

Cue does not reach into your storage and it does not own a loop. It is a controller in a Phase,
and everything it touches is an ordinary Beef part: entities are handles on kinds, the one number
it keeps per entity is a Component, a field is a column, and every verb is an Event somebody else
answers.

```lua
local Phase = Beef.Phase

local phase = Phase.new("world", {
    cue:entry(),              -- the Cue.Runner controller and every buffer it reads
    { Hurting, Hurt },        -- your controller, answering the `hurt` primitive
    { Sounding, Sound },
})

phase.dt = dt
phase.run()
```

`cue:entry()` is the whole seam on cue's side. It returns a Phase entry whose factory is
`Cue.Runner` and whose arguments are every buffer the runner reads: each anchor bound to an Event,
and each primitive's `done` and `refused`. The runner's loop resolves what those pushes answered
and its `pre` moves cue's clock by the phase's `dt`, which is also what steps the schedule queue.
Build the entry after you have declared everything; a Phase takes its cursors where the buffers
stand when it is built.

### An entity

An entity is a Beef handle, but a handle is unique only inside its kind, so cue carries the kind
with it:

```lua
local e = Beef.Cue.entity(Player, Player.spawn("ana"))   -- pack: one number, no allocation

Beef.Cue.kind(e)        -- the kind it came from
Beef.Cue.handle(e)      -- the handle, for kind.at / despawn / anything Beef
Beef.Cue.alive(e)       -- false once it is despawned
Beef.Cue.read(e, Hp)    -- the dense column if the kind has one, else the component's slot map
```

The packing is one multiply-add: the kind's slot times 2^32 plus the handle. It compares by value
and costs a floor divide and a modulo to take apart, so an entity can sit in a table key, a
Component or an Event column. An entity column is untyped or `f64`; it will not fit in a `u32`.

### The one number cue keeps

```lua
Beef.Cue.Attached    -- the Component holding an entity's interned subscription set
```

That is the whole per-entity footprint, and it is yours to read: `Cue.read(e, Cue.Attached)` is
the set number, `nil` when the entity holds none. Nothing else is keyed on entities.

## Declaring your game

Everything in this section is what `defaults()` already did for the common cases, shown so you
know how to add your own, and because your game's real vocabulary (its stats, its moments, its
verbs) is yours to declare on top.

### Operators: how values combine

```lua
cue:operator("times",  { stage = 2, commutes = true,  means = "multiply" })
cue:operator("divide", { stage = 2, commutes = true,  means = "divide" })
cue:operator("min",    { stage = 3, commutes = false, means = "at least" })
cue:operator("max",    { stage = 3, commutes = false, means = "at most" })
```

The stage number is the order they apply in: everything at stage 2 before anything at stage 3.

### Types: what a value is

```lua
cue:type("amount", {
    is = "number",
    zero = 0,
    operators = {
        ["+"]  = { amount = function(a, b) return a + b end },
        times  = function(v, s) return v * s end,
        divide = function(v, s) if s == 0 then return nil end return v / s end,
        min    = function(v, b) return math.max(v, b) end,
        max    = function(v, b) return math.min(v, b) end,
    },
    means = "a magnitude",
})
```

- `is` names what a value of this type actually is: a `typeof` string or your own predicate.
- `operators` lists which of the declared operators this type implements. `["+"]` is a table keyed by
  the type being added, so `place + direction` can exist while `place + place` does not.
- Returning `nil` from an operator refuses the value: `divide` by zero refuses rather than
  producing infinity.

A type can also declare **words** (names content may use) and **constructors** (making a value
from named arguments). A word is a constant, a read from the moment, or (with `takes`/`make`)
a name that accepts a value, where *you* define what applying it means:

```lua
cue:type("direction", {
    is = "Vector3",
    zero = Vector3.zero,
    words = {
        up   = { takes = "amount", make = function(n) return Vector3.new(0, n, 0) end },
        away = { takes = "amount", make = function(n) return Vector3.new(0, 0, -n) end },
    },
    operators = {
        ["+"] = { direction = function(a, b) return a + b end },
        times = { operand = "amount", fn = function(v, s) return v * s end },
    },
})

cue:type("place", {
    is = "Vector3",
    words = {
        origin = Vector3.zero,                       -- a constant
        here   = function(ctx) return ctx.here end,  -- read from the moment
    },
    constructors = {
        place = {
            args = {
                x = { type = "amount", default = 0 },
                y = { type = "amount", default = 0 },
                z = { type = "amount", default = 0 },
            },
            make = function(a) return Vector3.new(a.x, a.y, a.z) end,
        },
    },
    operators = {
        ["+"] = { direction = function(a, b) return a + b end },
    },
})
```

Exactly one type is the **entity type**: the one whose words name participants. Its `is` is cue's
own entity test, because an entity is a packed handle rather than a table you own:

```lua
cue:type("entity", {
    entity = true,
    is = Beef.Cue.is,                             -- a packed handle, which `defaults()` wires for you
    words = {
        self     = function(ctx) return ctx.self end,
        victim   = function(ctx) return ctx.victim end,
        attacker = function(ctx) return ctx.attacker end,
    },
})
```

The functions read from the context of the firing, so you decide what a firing carries and what
each word means.

### Keys and fields

A key is the left side of `=` in an effect. It has one type, everywhere, forever:

```lua
cue:key("to",     { type = "entity", means = "the participant acted on" })
cue:key("by",     { type = "entity", means = "the participant doing it" })
cue:key("damage", { type = "amount", means = "how much harm the blow carries" })
cue:key("at",     { type = "place",  means = "where the effect happens" })
```

A field is entity state content can read with a dot. It names the **Component** it reads, so
`self.damage` compiles to one column index and costs a dense read on the entity's kind:

```lua
cue:field("damage", { type = "amount", component = Damage, means = "how much harm this thing does" })
cue:field("hp",     { type = "amount", component = Hp,     means = "life" })
```

Reading is Beef's; typing is cue's. Without the declaration, `at = "self.damage"` (a `<place>`
reading a number) would pass silently.

### Anchors: the named moments

```lua
cue:anchor("Hit",     { means = "a strike landed" })
cue:anchor("Equip",   { means = "it was taken up" })
cue:anchor("Release", { means = "the input was let go" })
```

Your game fires these; content subscribes to them. An anchor can also be **bound to an Event**,
and then every push on that Event is a firing:

```lua
local Hit = Events.new("hit", "self", "victim", "attacker", "marker")

cue:anchor("Hit", { event = Hit, self = "self" })   -- a meaning declares, its absence binds

Hit.push(sword, target, nil, "sweep")               -- one push, one firing
```

`self` names the column holding the entity fired on. Every other column is the firing's context,
so the words `victim` and `attacker` and the gate `marker` read straight off the push. A game that
already pushes its hits does not have to call `fire` at all.

`cue:fire(entity, anchor, data, scope)` stays, for everything that is not on a wire yet.

### Primitives: the verbs

A primitive declares the Event it asks on. Cue creates that Event's two answers when you declare
it, `<event>.done` and `<event>.refused`, and an invocation is one push carrying a `seq` column:

```lua
local Hurt = Events.new("hurt", "to", "by", "damage", "over", "per", "seq:u32")

cue:primitive("hurt", {
    takes = { to = "the body harmed", by = "who deals it", damage = "the harm",
              over = "spread across this span", per = "this much each period" },
    refuses = { "to", "damage" },
    event = Hurt,
    means = "take life from a body",
})
```

- `takes` names which keys it accepts, and what each means *here*. Any other key on this primitive is
  a load error. The keys it takes and the Event's columns are the same list, `seq` aside: a key
  with no column and a column that is not a key are both load errors, so the push is the
  invocation exactly, and `seq` is what an answer names it by.
- `refuses` lists the labels it can fail with.
- Two primitives cannot share one Event, and a column named after one of an Event's own fields
  (`count`, `from`, `last`, `push`, and the rest) is a load error rather than a puzzle a frame later.

The controller that reads the Event does the work and answers, in the pass it reads the push:

```lua
local function Hurting(event)
    return {
        name = "Hurting",
        reads = { event },
        writes = { event.done, event.refused },
        loop = function()
            for i = event.from, event.last do
                local to = event.to[i]
                if not Beef.Cue.alive(to) then
                    event.refused.push(event.seq[i], "to")
                    continue
                end
                land(to, event.damage[i])
                event.done.push(event.seq[i])
            end
        end,
    }
end
```

`done` carries the seq, and a `result` beside it when the primitive declares `returns`.
`refused` carries the seq and a `because` label, which must be one the primitive declared.
Answer in your own time: a charge that takes half a second simply holds the seq and pushes `done`
when it is ready. Nothing about a chain unwinds while it waits.

### Gates, schedules, outcomes

```lua
cue:gate("marker", {
    test = function(value, firing) return firing.data.marker == value end,
    means = "only when the clip crossed this marker",
})
cue:gate("because", {
    test = function(value, outcome) return outcome.because == value end,
    means = "only for this failure",
})

cue:schedule("after", { kind = "delay",  type = "duration", means = "wait this long first" })
cue:schedule("every", { kind = "repeat", type = "duration", means = "how long between repeats" })
cue:schedule("once",  { kind = "await",  ready = function(value, entity, now)
    return somethingHappened(value)
end, means = "wait until this happens" })

cue:outcome("otherwise", { kind = "branch", means = "if it was refused, do this" })
cue:outcome("as",        { kind = "bind",   means = "name the result for later steps" })
```

## Authoring content

A definition is a table of subscriptions. `cue:define` compiles it (every name checked, every
constant folded) and returns an id:

```lua
local sting = cue:define({
    events = {
        { anchor = "Hit",
            { primitive = "hurt", to = "victim", damage = { 10, "self.damage" } } },
    },
}, "sting")
```

Attach it to an entity, fire the anchor, and it runs:

```lua
cue:attach(wasp, sting)
cue:fire(wasp, "Hit", { victim = you })
```

The context table you pass to `fire` is what the entity words read: here `victim` resolves to
`you`, and `self` is always the entity fired on.

Anything invalid is an error **at define**, naming the file and what went wrong: an unknown key, a
key the primitive doesn't take, a value outside its type, an unknown constructor argument, a gate
on an effect.

## Values

Everything on the right of `=`:

```lua
damage = 40                              -- a literal
damage = "self.damage"                   -- a field read
damage = { 10, "self.damage" }           -- a sum
damage = { 40, times = "charge:draw" }   -- a sum with modifiers
at     = "here"                          -- a word
at     = { place = { y = 100 } }         -- a constructor
at     = { "here", { up = 60 } }         -- a place plus a direction
```

`{ up = 60 }` calls the word's own `make`: the meaning of applying `up` to 60 is the
declaration's, and the value may be a full expression: `{ up = "self.hp" }`.

The array part of a table adds. The named part is modifiers (`times`, `divide`, `min`, `max`) or
constructor arguments. Whatever is constant folds once, at define: `{ 40, times = 2 }` is `80`
before anything ever runs.

A value that cannot resolve (a missing field, a divide by zero, an unbound reference) **refuses
the whole effect**. Nothing ever quietly becomes zero, and nothing is ever pushed for it.

## Refusals

A primitive that fails says why, and content branches on it:

```lua
{ primitive = "spend", to = "self", stamina = 3,
    otherwise = { { primitive = "sound", id = "wheeze" } } }

{ primitive = "launch", to = "take:shaft", at = "here", speed = "charge:draw",
    otherwise = {
        { because = "speed", primitive = "stow",  to = "take:shaft" },
        { because = "to",    primitive = "sound", id = "ui_refuse" },
    } }
```

The label comes back on `<event>.refused`, and the branch runs when the runner reads it.

## Sequences

A bare list of effects all run. A sequence runs in order and stops at the first refusal:

```lua
{ anchor = "Begin",
    { sequence = {
        { primitive = "occupy", to = "self" },
        { primitive = "take", to = "self", ammo = "arrow", as = "shaft",
            otherwise = { { primitive = "sound", id = "quiver_empty" } } },
        { primitive = "spend", to = "self", stamina = 3 },
        {   -- a bare list inside steps is a group: both run, neither gates
            { primitive = "charge", minMs = 180, maxMs = 900, as = "draw" },
            { primitive = "sound", id = "bow_draw" },
        },
    } } }
```

`as = "shaft"` names a step's result. Later values read it as `take:shaft`, typed by what `take`
returns, so `to = "take:shaft"` checks and `who = "charge:draw"` is a load error.

A sequence is resolved **through the loop**. Each step is a push, and the answer arrives in the
next pass, so a step costs two passes and the whole chain finishes inside one frame as long as it
fits the phase's pass budget. What waits on the world (a charge, a cast, a window for an input)
waits as long as it likes: the runner holds the chain against the seq it is waiting on and nothing
else is blocked meanwhile.

Bindings live for one firing. To carry them across firings (a draw on `Begin` read by the loose on
`Release`) pass the same scope table to both:

```lua
local act = {}
cue:fire(bow, "Begin", nil, act)
-- a frame or several later
cue:fire(bow, "Release", { here = aimPoint }, act)
```

## Transforms: changing something before it runs

A reaction answers *this happened*. A transform answers *this is about to run, change it*:

```lua
local mail = cue:define({
    transforms = {
        { when = { primitive = "hurt", to = "holder" }, stage = 2,
            damage = { "it", times = 0.7 } },
    },
}, "mail")
cue:attach(knight, mail)
```

`to = "holder"` is the same `to` the effect states: a transform matches the keys themselves,
so any primitive whose target is `to` meets this armour, with nothing mapped in between. Whenever
`hurt` runs against whoever carries this, `damage` becomes 70% of what it was. `it` is the
value in flight, and a rewrite is an ordinary value expression:

```lua
damage = { "it", times = 0.7 }     -- resistance
damage = { "it", -5 }              -- flat armour
damage = { "it", max = 20 }        -- capped
damage = { 0 }                     -- immune
```

Transforms run before the push, so what lands on the wire is the value that survived them. A
controller reading `hurt` sees 70, never 100.

A transform can also act and refuse: a parry plays its clang, spends its stamina, and stops the
blow entirely:

```lua
{ when = { primitive = "hurt", to = "holder" }, stage = 0,
    refuse = "parried",
    { primitive = "sound", id = "clang" },
    { primitive = "spend", to = "self", stamina = 4 } }
```

The refusing label reaches the blow's `otherwise` through `because = "parried"`. A refused
invocation is never pushed: the controller never hears about a blow that was parried.

Transforms order by `stage`, and ties break the same way on every machine. Two same-stage rewrites
of one key that don't commute (a multiplier and a subtraction) are refused the moment they meet
on one entity, with both sites named.

## Scheduling

```lua
{ primitive = "hurt", to = "victim", damage = 8, after = 1 }

{ primitive = "hurt", to = "victim", damage = 1, every = 0.5 }

{ primitive = "sound", id = "boom",
    schedule = { { once = "landed" }, { after = 1 } } }   -- a fuse, started by impact
```

One schedule key can sit right on the effect. More than one goes in `schedule = { ... }`, because
the order is yours to write: *arm, then watch* and *watch, then a fuse* are different grenades.

A **delayed** effect resolves its values when queued: it belongs to the moment that caused it. A
**repeating** effect re-resolves every firing: each one is its own occurrence. A countable thing
repeats discretely for free: `stacks = 1, every = 1` is one stack a second, never 0.4 of one.

The clock is the phase's. `Cue.Runner`'s `pre` adds `phase.dt` to cue's own now, and its loop
steps the schedule queue once a frame, on the first pass. There is no `step`, no `start` and no
clock of cue's own to forget to drive.

### Spreading: the reading controller spreads

`over` and `per` are default *keys* (a bounded span, a repeat period), and they are **columns**:
what they mean belongs to whoever answers the primitive. Cue resolves them, puts them on the push,
and is done.

```lua
{ primitive = "hurt", to = "victim", damage = 8, over = 2 }    -- hurt: 8 total, across 2s
{ primitive = "hurt", to = "victim", damage = 1, per = 1 }     -- hurt: 1 per second, until stopped
```

```lua
loop = function()
    for i = event.from, event.last do
        if event.over[i] ~= nil then
            table.insert(spreads, { to = event.to[i], damage = event.damage[i],
                span = event.over[i], left = event.over[i] })
        else
            land(event.to[i], event.damage[i])
        end
        event.done.push(event.seq[i])
    end
end,

pre = function()
    local dt = controller.phase.dt
    for i = #spreads, 1, -1 do
        local s = spreads[i]
        local slice = math.min(dt, s.left)
        land(s.to, s.damage * slice / s.span)
        s.left -= slice
        if s.left <= 0 then
            table.remove(spreads, i)
        end
    end
end,
```

What the author wrote once happened once: the invocation, its transforms and its hooks all ran a
single time on the authored 8, and the slices are the controller's own business. The remainder
lives where the work does, so cue holds no accumulator and keeps no tick of its own. A different
primitive is free to mean something else entirely by `over`, which is the point.

## Granting: hooks at runtime

`events` is what a thing starts with. A grant adds a subscription later, to any entity:

```lua
{ anchor = "Release",
    { primitive = "grant", to = "victim", context = "self",
        { anchor = "HitBody", { primitive = "sound", id = "myArrowHit" } } } }
```

`to` is who listens. `context` is who the hook runs as: with `context = "self"`, the granted
hook's `self` stays the granter, which is how a bow reacts to its own arrow's hit.

Subscriptions can bound their own lives:

```lua
{ anchor = "Impact", limit = 1,  ... }   -- fires once, then removes itself
{ anchor = "Hit",    lasts = 5,  ... }   -- gone after five seconds
{ anchor = "Hit",    ends = "sated", ... }   -- gone when your `ends` gate answers true
```

Granting the same thing twice holds it twice: two identical rings give double, and revoking one
leaves the other.

## Looking in

```lua
cue:stats()      -- counters: firings per anchor, grants, refusals by label, queue depth,
                 -- interned sets, invocations asked, answered and still in flight,
                 -- answers that named nothing, anchors with subscribers that never fired
cue:reference()  -- a markdown API reference generated from your declarations
cue:primitives() · cue:keysOf(prim) · cue:typeOf(key) · cue:wordsOf(type) · cue:constructorsOf(type)
```

`define` is public: a generated item is defined the same way an authored file is, fails the same
way, on the machine that made it:

```lua
local id = cue:define(rolledItemTable, "rolled")
```

## Plugging into an existing game

You never convert your game to cue. The seams run both ways, and both of them are the wire.

**Into your code.** A primitive's Event is read by a controller you write, so it *wraps* what you
already have:

```lua
loop = function()
    for i = event.from, event.last do
        MyCombat.applyDamage(event.to[i], event.damage[i])   -- your existing system, untouched
        event.done.push(event.seq[i])
    end
end,
```

**Out of cue.** Existing systems listen without being rewritten, and without cue knowing they
exist. A controller that reads an invocation's Event and its `done` hears every granted
invocation, with the resolved, post-transform arguments:

```lua
{
    name = "DamageNumbers",
    reads = { Hurt, Hurt.done },     -- reads, writes nothing: it only looks
    loop = function()
        for i = Hurt.from, Hurt.last do
            pending[Hurt.seq[i]] = { to = Hurt.to[i], damage = Hurt.damage[i] }
        end
        for i = Hurt.done.from, Hurt.done.last do
            local ask = pending[Hurt.done.seq[i]]
            pending[Hurt.done.seq[i]] = nil
            MyUI.showDamageNumber(ask.to, ask.damage)        -- your existing UI, untouched
        end
    end,
}
```

Refused invocations never reach `done`: a watcher hears what happened, not what was asked. It can
read `Hurt.refused` too, and be told which key the answer could not meet.
