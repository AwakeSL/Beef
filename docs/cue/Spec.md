# Cue: the build spec

> **This is the SPEC cue is built to, not its user documentation.** It is written in constraints
> and rulings because it exists to keep the build honest. User docs are written after the thing
> exists, from what it does; the API reference is GENERATED from the declarations (§9 reflection).
> Every ruling here was argued out and measured before it was written down; this is the record.
>
> A cue is the mechanic: the moment arrives, the thing waiting on it happens.
>
> **Cue is part of Beef.** The seam that used to be four adapter functions is now the framework
> itself: an entity is a handle, state is a Component, a moment is an Event, an invocation is a
> push, and the runner is a controller in a Phase. Where this spec used to say *the host*, read
> *the loop*.

---

## 1 · The whole model

```
a game DECLARES types, keys, primitives, anchors, and handlers.
content AUTHORS tables using only those names.
the compiler CHECKS them at load, folds constants, and flattens the nesting.
the game FIRES anchors;  the system runs what subscribed;
  primitives ASK on their events, and the controllers reading them answer.
```

A content file is **initial state**: the components, stores and subscriptions a thing starts with.
Every part of it can also be changed at runtime by a primitive. There are no classes.

---

## 2 · Values

Everything on the right of an `=`.

```lua
40                                  a literal
"self"                              a word
{ place = { x = 0, y = 100 } }      a constructor    -- named arguments
{ 40, "self", { … } }               a SUM            -- the array part
{ 40, times = "charge:draw" }       a sum, modified  -- the named part
```

**The array part is the PLURAL OF WHAT THE POSITION HOLDS.** Sum terms in a value position,
effects in a hook position, steps in a sequence. **The disambiguator is position, not shape.** The
named part is modifiers or arguments, and it coexists with the array part (`{ 260, times = "draw" }`
is both at once); the one illegal mix is constructor arguments beside terms, which is why a
constructed value sits in its own braces.

### Operators

| | | |
|---|---|---|
| `+` | the array part | not a word; it's what a bare list *means* |
| `times` | `{ 260, times = "draw" }` | multiply |
| `divide` | `{ 260, divide = "armour" }` | divide. Refuses on zero and is counted |
| `min` `max` | `{ 260, max = 200 }` | clamp |

Registered **per type with a signature**, so `place + direction → place` exists and `place + place`
does not. `who = { "victim", "attacker" }` errors because `<entity>` declares no `+`.

No subtraction: a negative literal subtracts (`{ 260, -100 }`), `times = -1` negates an expression.

### Types

A type declares three things:

```lua
cue:type("place", {
    is           = Vector3,
    words        = { up = Vector3.new(0,1,0), self = <read>, aim = <read> },
    constructors = { place = { x = 0, y = 0, z = 0 } },
    operators    = { "+", "times", "divide" },
})
```

`<place>` · `<direction>` · `<entity>` · `<amount>` · `<length>` · `<angle>` · `<duration>` ·
`<condition>` · `<tag>` · `<status>` · `<anchor>` · `<primitive>`

`<place>` and `<direction>` are **separate types**. If something takes a place, you pass a place.

`<entity>` is a **Beef handle with its kind folded in**: the kind's slot times 2^32 plus the
handle, one f64, exact and value-comparable. A handle alone is unique only inside its kind, and
cue has to reach `Cue.Attached`, a field's component and liveness from a value content hands it,
so the kind travels with it. One multiply-add to make, a floor divide and a modulo to take apart,
no allocation and no table keyed on entities. It does not fit a `u32`: an entity column is
untyped or `f64`.

### Bindings

A step names its result with `as`; later steps read it as `<primitive>:<name>`.

```lua
{ primitive = "take",   ammo = "arrow", as = "shaft" }   -- take:shaft   <entity>
{ primitive = "charge", as = "draw" }                    -- charge:draw  <amount>
```

The type comes from the primitive's `returns`, so `who = "take:shaft"` checks and
`who = "charge:draw"` is a type error. A field may follow: `take:shaft.source`.

The value is whatever the answering controller pushed beside the seq on `<event>.done`, so the
binding lands when the answer arrives, not when the step was asked.

### Fields: reading entity state

**Dot crosses into the world's state; colon does not.**

```lua
self.damage      -- a FIELD on an entity. One column read on the entity's kind.
charge:draw      -- a BINDING. cue's own invocation scope.
```

Reading is Beef's; **typing is cue's**, so a field is declared like a key, and it names the
Component it reads:

```lua
cue:field("damage", { type = "amount", component = Damage, means = "how much harm this thing does" })
```

Without that, `at = "self.damage"` (a `<place>` reading a number) passes silently. With it, the
read compiles to **one column index**: the kind's dense column when the kind has one, the
component's slot map otherwise, and nothing between cue and the memory.

Two different `damage`s, in different slots and **not even the same type**:

```lua
damage = 14                                   -- a FIELD on the bow: an <amount> Beef holds
{ primitive = "applyDamage", damage = 40 }    -- a KEY on an effect: the game's <damage> type,
                                              --   a list of tagged terms
```

**A missing field does not resolve, so the effect refuses and is counted.** Never zero, never a
default, the same rule as an unresolvable charge. Nothing is pushed for an effect that did not
resolve.

---

## 3 · Effects

```lua
{ primitive = "applyDamage", who = "victim", damage = 40 }
```

**A key owns its type globally. A primitive owns what it means locally.** `at` is a `<place>` in
every primitive forever; `spawn`'s `at` is where the thing appears, `playSound`'s is where it's
heard.

A key is declared once and handled in **one of four slots**:

| slot | acts | examples |
|---|---|---|
| **gate** | before: can it run at all? | `when` `detector` `marker` `because` |
| **schedule** | around: when does it run? | `after` `every` `once` |
| **primitive** | during: do the work | `applyDamage` `spawn` `playSound` |
| **outcome** | after: what came back? | `otherwise` `as` |

A primitive's keys are also its **columns**: it declares the Event it asks on, every key it takes
must be a column of that Event, and the Event carries a `seq` the answer names. The push order is
fixed at declaration, so an invocation is one `push` of already-resolved values with no table
built for it.

### Scheduling is an ordered list

```lua
schedule = { { after = 1 }, { once = "landed" } }    -- arm for a second, then watch
schedule = { { once = "landed" }, { after = 1 } }    -- a fuse, started by impact
```

Order matters and is written, not declared: `after` and `once` do not commute.

### `over` and `per` belong to the primitive

They change what the `<amount>` keys **mean**, so each primitive decides. They are ordinary
columns: cue resolves them, puts them on the push, and the controller reading the event spreads
them against the phase's `dt`.

```lua
{ primitive = "applyDamage", damage = 8,  over = 2 }   -- 8 total, spread across 2s
{ primitive = "applyDamage", damage = 0.35, per = 1 }  -- 0.35 per second
{ primitive = "teleport",  … , over = 2 }              -- load error: teleport declares no `over`
```

The remainder a spread carries lives with the controller doing the landing, which is where the
work is. Cue holds no accumulator and no tick of its own.

---

## 4 · Subscriptions

A hook is `{ anchor, gates…, effects… }`. **`events` is a list**, so two subscriptions to one anchor
are legal:

```lua
events = {
  { anchor = "HitBody", detector = "attacker.server", { primitive = "accumulate", … } },
  { anchor = "HitBody", detector = "defender.server", { primitive = "accumulate", … } },
}
```

`anchor` is required: it's the attachment point, not a filter. A list means *any of*
(`anchor = { "Hit", "HitBody" }`). Every other gate is optional and omitting one means *don't filter
on this*.

### An anchor may be bound to an Event

```lua
cue:anchor("Hit", { event = Hit, self = "self" })
```

Then **every push is a firing**: `self` names the column holding the entity fired on, and every
other column is the firing's context, read by the entity words and the gates exactly as a `fire`
data table would be. A game that already pushes its hits subscribes content to them without
calling anything. `cue:fire` stays for moments that are not on a wire.

An anchor is declared by its meaning and bound by the absence of one, so the binding is a second
call on a name the vocabulary already has, and a name cannot be bound twice.

### Lifetime

Subscription keys split two ways: **gates** ask *does this firing match*, **lifetime** asks *is this
subscription still alive*.

```lua
ends  = <condition>    remove when this becomes true
limit = <count>        remove after N firings
lasts = <duration>     remove after this long
```

Whichever comes first, and `revoke` removes one explicitly, the inverse of `grant`. A grenade's
`Impact` hook is `limit = 1`.

### `grant`: hooks at runtime

The system owns the subscription registry. There are **two doors into it**: the compiler writes
`events` at load, and `grant` writes at runtime. Neither is more fundamental than the other.

```lua
{ primitive = "grant", to = "self",
  { anchor = "Impact", { primitive = "spawn", spawn = blast, at = "self" } } }
```

A grenade has no `Impact` hook until it's thrown.

| | listens to | runs as |
|---|---|---|
| `to = X` | X | X |
| `to = X, context = "self"` | X | **me**, the old `chain` |

### There is one carrier

`events` is the only list. What used to be separate carriers are ordinary subscriptions:

```lua
events = {
  { anchor = "Equip", … },                                        -- on me
  { to = "holder", anchor = "Hit", … },                           -- was `grants`
  { anchor = "Spawned",                                           -- was `chain`
    { primitive = "grant", to = "…", context = "self", … } },
}
```

*"Install a hook on everything I create"* is not a target you can name at load: the thing does
not exist yet. It is a **subscription that grants**: hook `Spawned`, and grant to whatever appeared.

---

## 5 · Sequences

`sequence` is a **primitive**, not machinery: the system only has to let a primitive invoke
sub-effects and see their outcomes. `race`, `all`, `retry` and `firstOf` are then ordinary
primitives beside it, and `{ sequence = { … } }` is shorthand for
`{ primitive = "sequence", steps = { … } }`.

A bare list runs everything, ungated. `sequence` runs in order and **stops at the first refusal**:

```lua
{ sequence = {
    { primitive = "occupy", who = "attacker", region = "body" },
    { primitive = "take", ammo = "arrow", as = "shaft",
      otherwise = { { primitive = "playSound", id = "quiver_empty" } } },
    { primitive = "charge", as = "draw", minMs = 180, maxMs = 900 },
} }
```

The continuation **is** the granted branch, so only refusals need writing. The two forms alternate
as you nest, which is what keeps them unambiguous.

`otherwise` handles a refusal. `because` narrows it to one failure mode:

```lua
otherwise = {
  { because = "speed", primitive = "stow",      who = "take:shaft" },
  { because = "who",   primitive = "playSound", id = "ui_refuse" },
}
```

A chain does not go on the wire. What goes on the wire is each step, and the chain is what the
runner holds against the seq it is waiting on (§7).

---

## 6 · Transforms: changing something before it runs

A reaction is indexed by **anchor**: *this happened, do something.* A transform is indexed by
**primitive**: *this is about to run, change it.* That is what lets armour work without knowing
anything about hits, moments or weapons.

```lua
transforms = {
  { when = { primitive = "applyDamage", to = "holder" },

    damage = { "it", times = 0.7 },                     -- named part: REWRITES

    { primitive = "playSound", id = "block_clang" },    -- array part: EFFECTS
    { primitive = "spend", who = "holder", stamina = 4 } },
}
```

`it` is **the value in flight**, so a rewrite is an ordinary value expression: sums, `times`, `min`,
constructors, all of it:

```lua
damage = { "it", times = 0.7 }          -- resistance: scales every term
damage = { "it", -5 }                   -- flat armour: one subtraction on the whole
damage = { "it", without = "burn" }     -- fire immunity: drops the burn terms
damage = { }                            -- full block: nothing left
```

**Transforms run before the push.** What reaches the wire is the value that survived them, and a
refused invocation is never pushed at all, so the controller answering `applyDamage` never hears
about a blow that was parried. That is not a new rule, it is the old one seen from the other side:
transforms are part of resolving the invocation, and the push is what resolving produced.

**`refuse` refuses the INVOCATION and takes no scope.** A parry refuses; an immunity does not
refuse anything, it removes terms with `without` and lets the rest land. *Whole blow or part* is which
**operator** you used, never a refusal policy. `without` is a registered operator on the game's own
`<damage>` type, a list of tagged terms, which is what `applyDamage` carries.

**A transform runs effects as well as rewriting, and it has to.** If you refuse a blow there is no
`applyDamage` left to react to: the block prevented the very thing whose reaction would have made
the noise. Mitigating, spending the stamina and playing the clang are one decision, and splitting
them across a transform and a reaction would let them drift.

`when` picks which participant it is about: `to = "holder"` is armour, `by = "holder"` is a bonus on
blows you deal.

**`to` and `by` are ordinary ruled keys, not a third namespace.** Every primitive names its target
with the key `to`, so one name carries one meaning everywhere:

```lua
cue:primitive("applyDamage", { takes = { to = ..., by = ... }, event = Damaged, ... })
```

One name globally is what lets armour match `to = "holder"` against `applyDamage` and `applyBurn`
without knowing either one's key names, which is the point of transforms. A `when` filters on any
entity-typed key the primitive takes; filtering on one it does not take is a **load error**, same
table as the rest.

**A transform's effects run as the transform runs**, not after the chain settles. They are
consequences of *the transform*, not of the outcome: your armour did mitigate, so the clang is
honest even if a later ward refuses the blow outright. **"When the blow actually landed" is a
reaction**, and keeping them apart is what stops effects being buffered mid-resolution.

### Order

A transform declares a **stage**, like an operator. The game says what the stages mean: block
before armour before thorns.

**Two at the same stage break the tie on the interned subscription id**, which is content-derived
and therefore identical on every machine. The order is arbitrary but **consistent**; genuinely
unordered would be nondeterministic across machines, which would throw away the cross-server
agreement §7 buys. A counter reports same-stage collisions, and **two same-stage rewrites of ONE
key with non-commuting operators are refused at INTERN time**, not merely counted. The combination cannot be
seen at load (it happens by grant), but **interning is the load step of combinations**: the edge walk
is where both subscriptions first coexist in one set, so that is where the tie-break would silently
pick between two different answers, and where it is refused instead.

### Storage

Reactions and transforms are both *hooks I carry*, so they live in the same interned set and an
entity still holds **one int**, in one Component:

```
Cue.Attached[entity] = 42
  anchorMask     which anchors wake me        -> reactions,  keyed by anchor
  primitiveMask  which primitives I transform -> transforms, keyed by primitive
```

Granting a transform is the same edge walk as granting a reaction. The cost at invocation is **one
bit test per participant**: cue has already resolved the victim, attacker and weapon, so it checks
those masks and does nothing further for the overwhelming majority of things, which transform
nothing.

Both masks are a **compile-time representation choice**, not a fixed width. And cue only ever
tests entities the invocation *names*: if it had to test everything in range this would stop being
cheap, and nothing in the design asks for that.

---

## 7 · Execution

**An invocation is a push, and its outcome is a push back.** The primitive names the Event it asks
on; cue resolves the effect, runs its transforms, and pushes one entry carrying the resolved
values and a `seq`. The controller reading that Event does the work and answers on `<event>.done`
or `<event>.refused`, naming the seq. The runner reads the answers and carries on.

This is the one ruling the port changed, and the loop is what made it changeable. A chain used to
have to be a synchronous call, because a queued step would either break the chain or spread one
attack across five frames. **A pass is not a frame.** A Phase passes until nothing moved, a
buffer is frozen at the top of a pass, so an answer pushed in one pass is read in the next: a step
costs **two passes**, and a chain of a dozen steps resolves inside the same frame it started in.
What genuinely has to wait, a charge or a cast or a window for an input, waits for as many frames
as it likes without holding a stack or blocking anything else.

```
ASK      a push on the primitive's event        everything, by default
ANSWER   a push on done or refused              the controller that reads it, in its own time
QUEUE    the effect becomes a thing             only when scheduled (after / every / once),
                                                or crossing to another machine
```

That is also why a queued effect is serializable and a running one is not: the queued form is
exactly the one that had to leave the stack.

### What the runner holds

An in-flight invocation is a record in a hash keyed by seq: the compiled effect, the invocation
context, and the chain it is a step of, if any. **The decisions the spec left open, and what they
cost:**

- **the seq** is a `u32` counter that wraps at 4.29e9. It names the answer and nothing else.
- **an in-flight record is pooled.** A chain of twenty steps allocates one record and hands it
  back twenty times, so a frame of heavy content allocates nothing per step.
- **a chain shares one context across its steps.** The steps of one sequence differ in nothing but
  which step they are, so the chain holds a single step context and an index, which is one table
  per chain rather than one per step.
- **an answer that names a seq nobody holds is counted, not an error.** A controller that answers
  twice, or answers after cue has dropped the chain, is content to fix rather than a crash, and
  `strayAnswers` is where it shows.
- **`cue:fire` outside the loop dispatches where it stands**, which resolves the effect, runs its
  transforms and pushes the ask. Only the answer waits for the loop. A fire is therefore as cheap
  to call from a signal handler as from a controller, and costs the caller no pass.

### Three properties that fall out of decisions already made

**Re-entrancy is safe by construction.** Subscription sets are immutable interned values, so a
`grant` during dispatch changes the entity's *id*; it does not mutate the array being walked.
Dispatch finishes on the set it started with. No snapshot, no iterator invalidation, nothing to
remember.

**Order is deterministic across machines.** A set is a compiled array built by the same sorted walk
everywhere, so two servers dispatching the same set run the same subscriptions in the same order.
Not a small thing when they have to agree.

**A nested fire is a nested call**, depth-counted. Nothing on the wire can re-enter cue inside one
invocation, so the only way to nest a fire now is a primitive that performs where it stands, and
that is exactly what the depth count guards.

### The authored unit is the occurrence

> **What the author wrote once HAPPENED once, however many times the machinery touched it.**

One rule, and it settles four things that look unrelated:

| | |
|---|---|
| **`over` and hooks** | one authored `applyDamage … over = 2` is **one** occurrence: one push. Hooks fire once; the 120 applications are the reading controller's business. A thirst charm gains one, not 120 |
| **countable amounts** | `stacks = 1 per second` is one stack a second. The fraction accumulates and lands on a whole unit, so you never see 0.4 of a stack, because 0.4 of an authored thing is not an occurrence |
| **additive grants** | two charms each authored a grant, so that is **two** occurrences: held twice, fired twice, and revoking one leaves the other. Two identical rings give double, exactly as two different ones would |
| **transforms** | run **once, on the authored amount**, and the result is what gets pushed |

**That last line is why the rule is load-bearing rather than tidy.** If `8 damage over 2 seconds`
were 120 occurrences, armour would run 120 times. Multiplicative mitigation survives that by luck,
0.7 of each slice is 0.7 of the total. **Flat mitigation does not: -5 applied 120 times is -600
against a blow of 8.** Running transforms once on the authored 8 is the only reading where flat and
multiplicative mitigation can coexist. One occurrence is one push, which is now also the cheapest
thing to build.

Two costs, both accepted: the intern space is a **multiset with counts** rather than a set (which
is the answer to the sizing question), and countable amounts need **accumulator state**, which now
lives in the controller doing the landing rather than in cue.

✅ **The occurrence fires at the START of a spread**, and it is forced rather than chosen:
transforms run once on the authored amount, and that has to happen *before* spreading. *"When the
total has landed"* is a different anchor on the spread completing, not the same occurrence.

**A DELAYED effect resolves its values WHEN QUEUED; a REPEATING one re-resolves per firing.**
`after = 3` captures the causing moment: the values belong to it, the queued form is a flat
serializable value that can cross a machine, and `who = "victim"` three seconds later may name
someone who left. `every = 1` is different because **each firing is its own occurrence**: the author
asked for N happenings, so each resolves at its own moment.

So the two repeat mechanisms differ **on purpose**, and the asymmetry is the occurrence rule
applied twice: `over`/`per` spread ONE occurrence (hooks fire once, transforms run once, values
resolve once, one push), while `every` schedules N occurrences, each of which fires hooks, meets
transforms, resolves fresh and pushes again.

### Cycles: the one thing that needs inventing

A grants B, B fires A. There are **two shapes, and the obvious guard only catches one**:

- **within one dispatch.** A depth limit on nested fire, counted. The easy half, and now a narrow
  one: only a primitive that performs where it stands can nest at all.
- **across frames.** A grants B, B's hook fires next frame and grants A. Depth is 1 every time,
  the limit never trips, and the intern space grows until it reads as a memory leak. **The dangerous
  cycle is the scheduled one**, and it needs a RATE measure, not a stack depth: grants per entity
  per window, and the intern space's growth rate, on the same console line as everything else.

In both, **the counter matters more than the limit**: tripping means content is wrong, and that
has to be visible rather than silently truncated.

A third shape is now bounded by the loop rather than by cue: content that asks and answers
forever within one frame runs the Phase out of passes, which warns and stops. **Work that a frame
cannot finish inside it is carried, not lost**: what a capped pass pushed reaches loop readers on
the next frame's first pass, so a chain long enough to outrun the pass budget carries on next
frame rather than stalling. The budget is 32 passes, so about fifteen immediate steps a frame, and
anything near that is content to look at, not a limit to raise.

---

## 8 · Registering

**Cue is instanced, not a singleton.** One instance serves one world, and a server world and a
client world in the same process each get their own.

```lua
local cue = Beef.Cue.new():defaults()

local phase = Phase.new("world", {
    cue:entry(),
    { Hurting, Hurt },
    …
})
```

`cue:entry()` is the whole seam. It is a Phase entry whose factory is `Cue.Runner` and whose
arguments are every buffer the runner reads: each bound anchor's Event, and each primitive's
`done` and `refused`. Cue learns nothing about storage because there is nothing to learn: an
entity is a handle, a field is a Component, and the one number cue keeps per entity is
`Cue.Attached`, an ordinary Component anyone can read. **Nothing keyed on entities can leak,
because there is no map**: despawn takes the number with the entity.

What cue *does* hold is its **run-queue**: scheduled effects, and its in-flight invocations (§7),
which is per-*occurrence* state with a lifetime rather than a table keyed on entities. **A queued
effect whose entity has died is dropped and counted**; `lasts`/`ends`/`limit` bound the queue from
the other side. This is the one mutable thing in an otherwise immutable design, named here so
nobody discovers it in implementation.

Nine registration points. The system ships **none** of the names on the right.

```lua
-- declare what exists
cue:type     (name, { is, words, constructors, operators })
cue:operator (name, { stage, signatures })
cue:key      (name, { type, means })
cue:field    (name, { type, component, means })   -- what `self.damage` reads
cue:anchor   (name, { means })                    -- and, later, { event, self } to bind it

-- handle a key
cue:gate     (name, code)
cue:schedule (name, code)
cue:primitive(name, { takes, returns, refuses, event })
cue:outcome  (name, code)

-- at runtime
cue:fire(entity, anchor, data, scope)         -- something happened; scope spans anchors
cue:entry()                                   -- the runner's place in a phase
```

`cue:defaults()` registers a starter vocabulary through these same public calls.

Two crossings and nothing else: **the game fires anchors in, by call or by push; primitives ask
out, and whoever reads the event answers.** There is no third path, no callback list and no
`observe`: a system that wants to hear what cue asked for reads the event, like everything else in
a Beef game.

There is no `step` and no `start`. **The clock is the phase's**: the runner's `pre` adds
`phase.dt` to cue's now and its loop steps the schedule queue once a frame. The mode nobody tests
was the one that broke, so there is now only one.

**Ids are per-instance.** Set id 42 in one instance means nothing in another, the same way a
combination id means nothing in another process. And there is deliberately **no module-level default
instance**: it would be a second path, and the one nobody uses in tests is the one that rots.

---

## 9 · Runtime definition

The compiler is a public entry point, not a load step. **Authoring a file is `define` called on it.**

```lua
local id = cue:define(table)     -- validate, compile, intern -> an id
```

One path and one set of error messages, so a generated thing fails exactly where an authored one
would, on the machine that made it.

### Ids

| | |
|---|---|
| **content-derived** | deterministic from a sorted walk. Free: every machine computes the same table |
| **minted** | allocated from a relay-granted block. Stable fleet-wide; the **definition** crosses once |

A third id exists and **must never leave the process**: the interned *combination* id an entity
stores. Machine A reaches `{5,7}` first and calls it 42; machine B reaches `{3,9}` first and calls it
42. It is a cache.

| | what travels |
|---|---|
| memory | the interned combination id |
| wire, one build | the list of content-derived ids |
| disk, across builds | **names**, since indices shift when content is added |

📏 Width: `u32` is one native buffer op and 4.29e9. `f64` is one op and exact to 2^53, the real Luau
ceiling. `bit32` is 32-bit, so any id that is ever **packed or masked** is capped at u32 by the
arithmetic rather than by the field. A seq is a `u32` column; an entity is an f64, because it is
a pack of two u32s and one of them is a kind.

### Reflection, and generated content

The declarations are queryable, which is what makes a **third-party** generator possible: nothing
has to hardcode a vocabulary:

```lua
cue:primitives()  ·  cue:keysOf(prim)  ·  cue:typeOf(key)
cue:wordsOf(type) ·  cue:constructorsOf(type)
```

```
the system supplies VALIDITY   what can be written at all
the game supplies TASTE        eligible primitives, ranges, weights, a power budget
```

Valid is not sensible: nothing stops `applyDamage, who = "self", damage = 9999` from type-checking.

**A minted definition may COMPOSE declared vocabulary and may never INTRODUCE any.** Otherwise
minting is shipping code, and the receiver cannot run what it does not have.

`define` is authoritative and mints a fleet-wide id, so it is host-side. It also walks the whole
table, fine on a kill and not fine per frame. Count it.

---

## 10 · What fails at load

| | |
|---|---|
| a key no one declared | unknown field |
| a value outside its type | `at = "victim"`, not a `<place>` word |
| a wrong-typed operand | `at = { "self", 6 }` |
| an unknown constructor argument | `{ place = { height = 3 } }` |
| a key the primitive doesn't take | `damage` on `playSound` |
| `as` on a primitive that returns nothing | |
| `because` naming a field the primitive can't fail on | |
| an operator the type doesn't declare | `who = { "victim", "attacker" }` |
| a declared thing with no implementation | a primitive with no event to ask on, a gate with no code |
| a `when` filtering on an entity key the primitive doesn't take | `to = ...` against a primitive that takes no `to` |
| a field with no component | it would have nothing to read |
| a key the primitive's event has no column for | the push would have nowhere to put it |
| an event column the primitive does not take | nothing would ever fill it |
| a primitive's event with no `seq` column | the answer would have nothing to name |
| two primitives sharing one event | the answers could not be told apart |
| an event column named after one of an event's own fields | `count`, `from`, `push` and the rest: it would shadow the buffer's bookkeeping |
| an anchor bound to an event without naming its `self` column | there would be nobody to fire on |

**Refused at INTERN time.** The load step of combinations: two same-stage rewrites of one key with
non-commuting operators, first visible when the edge walk builds the combined set (§6).

**Counted, not errored:** an anchor with subscribers that has never fired. Firing happens outside the
system, so it can't be a load check, only an instrument. Likewise an answer naming a seq nobody
holds (§7).

---

## 11 · Still open

Nothing structural. What is left are consequences to watch rather than choices to make:

- **cycle control is designed but unsized.** A depth limit needs a number, and the counter matters
  more than the number (§7)
- **the intern space is a multiset**, so it grows with distinct grant combinations rather than with
  entities. Bounded by combinations actually reached, monotonic within a session, and worth a
  console command rather than a bound argued on paper
- **`over` on a primitive that cannot be spread** is a load error only if that primitive declares
  whether it takes `over`, which is the design, and is the kind of declaration that gets skipped
- **a chain longer than the pass budget carries on next frame** rather than stalling (§7). Fifteen
  immediate steps is far past anything content should be doing, so this is an instrument to add
  before it is a mechanism to build

**A standing constraint, not an open question:** interned sets must be **canonical** (sorted), or
interning yields permutations instead of combinations: a factorial blowup that would read as a
memory leak with no obvious cause.

---

## 12 · Settled here, and what forced each

| | |
|---|---|
| an invocation is a **push**, its outcome a push back | a pass is not a frame: the phase passes until nothing moved, so a chain still settles in the frame that started it |
| a step costs **two passes** | a buffer is frozen at the top of a pass, so an answer is read the pass after it is pushed |
| an entity is a **kind packed with a handle** | a handle is unique only inside its kind, and content hands cue a bare value |
| a field names its **Component** | so a read compiles to one column index instead of a call through an adapter |
| the clock is the **phase's** | a second way to drive it is the one nobody tests |
| `observe` is gone | a controller reading the event is the same thing, and it is the thing every other system in the game already is |
| a transform's effects run **as it runs** | they are consequences of the transform, not of the outcome |
| same stage ties break on the **interned id** | arbitrary order would be nondeterministic across machines |
| a queued effect resolves **when queued** | the values belong to the causing moment, and a flat value is what can cross |
| lifetime is `ends` / `limit` / `lasts` + `revoke` | subscription keys split into **gates** and **lifetime** |
| a spread occurrence fires at the **start** | transforms run once on the authored amount, before spreading |
| `context`, not `owner` | `owner` is ambiguous between *whose context* and *who may revoke it*, and those differ once `limit`/`revoke` exist. `for` reads best of all and is a Lua keyword |
| `without = "burn"` rather than a scoped refuse | *whole blow or part* is which **operator** you used |
| **the authored unit is the occurrence** | flat mitigation: -5 applied 120 times is -600 on a blow of 8 |
