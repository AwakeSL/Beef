--!strict
--!optimize 2
-- Stock: the defaults most games take and any game replaces. Each is a controller reading and writing Beef
-- Events and Components and nothing else, so a game that writes its own against the same ones drops it in
-- where the stock one was. `Action` is the vocabulary they share; the controllers hang off it.
--
-- Input and Movement are here. Camera, Sound, Screens and Music are the tickets after them and land
-- beside them, one file or one folder each, added to the table at the bottom and to nothing else.

local Action = require(script.Action)
local Input = require(script.Input)
local Movement = require(script.Movement)
local Screens = require(script.Screens)
local Feed = require(script.Input.Feed)
local Shown = require(script.Screens.Shown)
local Music = require(script.Music)
local Tape = require(script.Music.Tape)

export type Declared = Input.Declared
export type Edge = Input.Edge
export type InputDriver = Input.Driver

return {
	Action = Action.Action,
	Phases = Action.Phases,
	Devices = Action.Devices,
	Edges = Action.Edges,

	Input = Input,
	Movement = Movement,
	Screens = Screens,
	Music = Music,

	-- an input driver with a clock a test moves and keys it presses, handed to `Input` in place of the
	-- engine. A spec of Beef's own uses it, and so does a game testing its own controllers headless.
	feed = Feed.new,

	-- a screens driver that writes down what it was shown, handed to `Screens` in place of the engine,
	-- so a spec reads back which screen is up and where it landed.
	shown = Shown.new,
	-- a music driver that plays nothing and writes down every call, handed to `Music` in place of the
	-- engine, so a fade is a list of numbers a spec walks
	tape = Tape.new,
}
