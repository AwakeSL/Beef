# Stock Screens

The stock controller that decides which screen has the player's input. It reads the frame's
`Beef.Stock.Action` pushes, keeps the stack of what is open, lays each open screen out on the
viewport, and writes one Component saying which screen has the input and what that takes away from
everyone else.

It draws nothing. A screen here is a name, a rectangle, a claim on input and a list of what that
claim silences. What goes inside the rectangle is the game's own UI, put there by the game's own
code, so this ships no widgets, no theme and no notion of what a menu looks like.

```luau
local Beef = require(ReplicatedStorage:WaitForChild("Beef"))
local Stock = Beef.Stock

local Focus  = Beef.Components.new("focus")
local Player = Beef.Kinds.new("player", Focus)

local screens = {
	Inventory = { opens = "Inventory", closes = "Back", suppresses = { "Move", "Jump", "Sprint" } },
	Map       = { opens = "Map",       closes = "Back", suppresses = { "Move", "Jump", "Sprint" },
	              width = 0.8, height = 0.8 },
	Menu      = { opens = "Menu",      closes = "Back", suppresses = "all" },
	Confirm   = { opens = "Confirm",   closes = "Back", stacks = true, order = 100,
	              width = 0.4, height = 0.25 },
}

local heartbeat = Beef.Phase.new("Heartbeat", {
	{ Stock.Input, Stock.Action, bindings },
	{ Stock.Screens, Stock.Action, Focus, screens },
	{ Stock.Movement, Stock.Action, Body, Velocity, moves },
})

Player.spawn(false)
```

It runs on the client, and it goes straight after Input: Input writes the frame's pushes, Screens
reads them, and everything after it reads a focus that is already this frame's.

## What it reads

`Beef.Stock.Action`, and nothing else. The engine is behind a driver, so the whole of stacking,
suppression and layout runs headless.

It acts on two phases and leaves the other four alone.

| phase      | what it does with it                                                        |
| ---------- | --------------------------------------------------------------------------- |
| `Began`    | opens a screen, or closes the one that has the input                          |
| `Fired`    | the same, so a sequence can be bound to a screen                              |
| `Changed`  | nothing                                                                      |
| `Ended`    | nothing: a release is the same press coming back                              |
| `Held`     | nothing                                                                      |
| `Buffered` | nothing: acting on one would toggle the screen once a frame for the window    |

Nothing else reaches it, which is also how a game opens a screen from its own code: push the
action, exactly what Input would have written.

```luau
Beef.Stock.Action.push("Menu", Beef.Stock.Phases.Began, 1, 1, 0, Beef.Stock.Devices.Unknown)
```

## What it writes

`Focus`, the Component the game named, and nothing else. It never pushes an Event and it never
silences an action it used: an action that opened a screen is still a push every other controller
reads, the same way Input does not silence a chord's members.

The value is a table with four fields.

| field        | what it holds                                                                |
| ------------ | ----------------------------------------------------------------------------- |
| `screen`     | the name of the screen that has the input, or `nil` when none has              |
| `open`       | every open screen, the one with the input last                                 |
| `suppressed` | a set of action names: `suppressed.Jump` is `true` while jumping is silenced   |
| `all`        | `true` when an open screen took every action rather than a list                |

A reader asks one question of it:

```luau
local focus = Focus.get(Player, 1)
local silenced = focus.all or focus.suppressed[name] == true
```

`all` is there because Screens never sees the bindings table. It does not know what actions exist,
so a screen that wants the player's whole attention cannot be turned into a list of names; it is a
flag, and a reader that honours the set honours the flag with it.

### Which entity it goes on

Every entity carrying `Focus`, whatever Kind it is on, the way Movement writes `Velocity` onto
every body carrying both of its Components. The Action pushes carry no entity, because Input runs
on the client for one player, so on a client that is one entity: the player's own. A game that
gives `Focus` to more gives every one of them the same answer.

They share one table. It is rebuilt when the stack changes and put on each entity every frame, so
an entity spawned halfway through has the focus on its next frame and a reader never finds `nil`
after the first one. A reader reads it and never writes into it, because writing into it would be
writing into every other entity's focus at the same time.

### Why a Component and not a call

If a reader asked Screens, every reader would have to hold a reference to it, and a game that threw
this controller away for one of its own would have to keep the same call working. A Component is
what those controllers already read, so the swap stays invisible, which is the rule the whole of
Stock is built on.

## The screens table

A table of screen names. Each entry says what opens it, what closes it, what it silences, whether
it stacks, and where it sits.

| option       | what it is                                                                    |
| ------------ | ------------------------------------------------------------------------------ |
| `opens`      | the action that opens it, as the bindings table spelled it. Every screen has one |
| `closes`     | the action that closes it while it has the input, usually the one back action    |
| `suppresses` | a list of action names, or the word `"all"`                                      |
| `stacks`     | `true` to go over what is open; without it, it takes their place                 |
| `anchor`     | where on the viewport it sits; `"middle"` when it is not said                    |
| `width`      | its share of the viewport's width, above zero and at most one; `1` by default    |
| `height`     | the same down the screen                                                         |
| `order`      | what it sits in front of; its depth in the stack when it is not said             |

Anything else in an entry is refused at the factory, by name, with what would have been allowed. So
is a screen with no `opens`, a share outside its range, an anchor there is no word for, and two
screens naming the same opening action, since one action cannot open two screens.

Back is an action name on each screen rather than a boolean and one reserved name, so that a screen
back does not close is a screen that leaves `closes` out, and nothing has to agree on what the back
action is called. In practice every screen names the same one.

### Opening and closing

The action a screen names opens it. The same action pressed again closes it, so an inventory key is
a toggle without anything being declared, and `closes` closes it too.

Only the screen on top answers. An action reaching a screen that something else is covering does
nothing, and an action opening a screen that is already open does nothing either.

A screen that stacks is pushed on top of what is open, and backing out of it lands on the screen
below. A screen that does not stack takes the place of everything open: the stack is emptied and it
is the only one, so backing out of it lands on the game rather than on a pile nobody remembers
opening. Stacking is the exception, so it is the one that is declared.

### What suppression is and is not

Every open screen suppresses, not only the one with the input, and the answer is the union of their
lists. A dialog over the inventory does not hand movement back just because the dialog itself asks
for nothing.

Suppression is advice. Screens writes it and nothing else; every reader decides what to do about
it, the same way every reader decides what a buffered press means. Screens does not act on it
either: it reads the raw pushes, so a screen suppressing every action can still be closed by the
action that opened it.

There are no groups. A word like `"movement"` would be a name Screens and Movement both had to
agree on, and Screens has no idea which actions are movement, so a game that wants one writes the
list once in a local and names it in each screen.

```luau
local MOVING = { "Move", "Jump", "Sprint", "Crouch", "Dash" }
local screens = {
	Inventory = { opens = "Inventory", closes = "Back", suppresses = MOVING },
	Map       = { opens = "Map",       closes = "Back", suppresses = MOVING },
}
```

`"all"` is the one shortcut, for a screen that wants everything.

## Where a screen lands

`width` and `height` are shares of the viewport, and `anchor` is one of nine words: `topLeft`,
`top`, `topRight`, `left`, `middle`, `right`, `bottomLeft`, `bottom`, `bottomRight`. The controller
reads the viewport through the driver, works the share out in whole pixels, and hands the driver a
rectangle: `{ x, y, width, height, order }`, in pixels from the top left. A driver never divides
anything.

A screen filling the viewport lands in the same place whichever anchor it names, which is why the
default is a full screen and the anchor rarely gets written.

`order` is what the screen sits in front of. Without one it is the screen's depth in the stack, so
what was opened last is in front for free; with one it keeps that number whatever the depth, which
is how a toast or a modal stays over everything.

The viewport is read every frame. A player who resized the window, or turned the phone over, is the
same work as a screen that opened: every shown screen whose rectangle changed is laid out again,
and a frame where nothing moved says nothing to the driver at all.

## What the driver does

Live, the driver keeps one `ScreenGui` per declared screen under the player's own `PlayerGui`. If
the game already authored one of that name there, it uses it; if it did not, it makes an empty one.
Inside it, a `Frame` named `Screen` is the rectangle, transparent and borderless, and the game's own
UI goes in that Frame.

So a game keeps designing its screens in `StarterGui` the way it always did, and this controller
only decides which of them is shown, where, and in front of what. Showing is `ScreenGui.Enabled`,
the order is `DisplayOrder`, and the rectangle is the Frame's `Position` and `Size` in offsets.
`IgnoreGuiInset` and everything else on the ScreenGui is left alone: those are the game's, set once
wherever the screen was authored.

## Testing against it

`Beef.Stock.shown()` is a screens driver that writes down what it was told, handed to `Screens` in
place of the engine as a fourth argument. No PlayerGui, no camera, no engine.

```luau
local shown = Beef.Stock.shown()
local phase = Beef.Phase.new("Test", {
	{ Beef.Stock.Screens, Beef.Stock.Action, Focus, screens, shown },
})
Player.spawn(false)

Beef.Stock.Action.push("Map", Beef.Stock.Phases.Began, 1, 1, 0, 0)
phase.run()

shown.trace()            -- "show Map"
shown.at("Map").width    -- 1024, being 0.8 of a 1280 viewport
Focus.get(Player, 1).suppressed.Move   -- true
```

It takes `declared()`, what the controller asked for at boot; `at(name)`, the rectangle and order a
shown screen was last given, or `nil` while it is hidden; `showing()`, every shown screen by name;
`trace()`, every call in order, as `"show Map hide Map"`; `clear()`, to forget the trace; and
`resize(w, h)` and `size()`, for the viewport it reports, which starts at 1280 by 720.

With `Beef.Stock.feed()` and Input in front of it, the same phase runs off keys instead, which is
what Beef's own suite does for the end of it.

## Writing another driver

A driver is four functions. `viewport()` hands back the width and height in pixels, `build(declared)`
is called once at the phase's boot with every declared screen, `show(name, at)` puts one up at that
rectangle, and `hide(name)` takes it down. `show` comes again for a screen already up when its
rectangle changed, which is what a resized window is.

`declared` holds `{ name, anchor, width, height, order }` per screen, in one fixed order so two
clients build the same screens the same way twice. `at` holds `{ x, y, width, height, order }` in
pixels.

## Where it goes in a phase

It is one `loop`, straight after Input. Input writes the frame's pushes in `pre`, so the loop's
first pass is where those pushes can be read, and `post` is after it, so Movement and anything else
integrating at the end of the frame reads a focus that is already this frame's.

## What it does not do

It does not draw a screen's contents, style anything, animate anything, or know what a button is.

It does not stop an action. It writes what is suppressed and every reader decides; a controller that
ignores the focus keeps working exactly as it did.

It does not decide whether a screen may open. Cooldowns, being dead, being in a cutscene and not
owning the map yet all live in the controller that knows about them, and that controller withholds
the push.

It does not remember anything about a screen between openings, does not fade one in, does not
capture the mouse, and does not touch `UserInputService` or the Input context. A game that wants the
Input context sunk while a menu is up finds it by name, which is what the Input page says.
