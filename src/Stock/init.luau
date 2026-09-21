--!strict
--!optimize 2
-- Stock: the defaults most games take and any game replaces. Each is a controller reading and writing Beef
-- Events and Components and nothing else, so a game that writes its own against the same ones drops it in
-- where the stock one was. `Action` is the vocabulary they share; the controllers hang off it.
--
-- Input and Movement are here. Camera, Sound, Screens and Music are the tickets after them and land
-- beside them, one file or one folder each, added to the table at the bottom and to nothing else.

local Action = require(script.Action)
local Camera = require(script.Camera)
local Input = require(script.Input)
local Movement = require(script.Movement)
local Screens = require(script.Screens)
local Feed = require(script.Input.Feed)
local Shown = require(script.Screens.Shown)
local Music = require(script.Music)
local Tape = require(script.Music.Tape)
local Film = require(script.Camera.Film)
local Duck = require(script.Duck)
local Sound = require(script.Sound)
local Speaker = require(script.Sound.Speaker)

export type Declared = Input.Declared
export type Edge = Input.Edge
export type InputDriver = Input.Driver

return {
	Action = Action.Action,
	Phases = Action.Phases,
	Devices = Action.Devices,
	Edges = Action.Edges,

	Camera = Camera,
	Input = Input,
	Movement = Movement,
	Screens = Screens,
	Music = Music,
	Sound = Sound,

	-- the one seam between Sound and Music: how far the music drops and for how long. A map entry with a
	-- `duck` option pushes it; Music takes it as an argument and reads it.
	Duck = Duck,

	-- an input driver with a clock a test moves and keys it presses, handed to `Input` in place of the
	-- engine. A spec of Beef's own uses it, and so does a game testing its own controllers headless.
	feed = Feed.new,

	-- a screens driver that writes down what it was shown, handed to `Screens` in place of the engine,
	-- so a spec reads back which screen is up and where it landed.
	shown = Shown.new,
	-- a music driver that plays nothing and writes down every call, handed to `Music` in place of the
	-- engine, so a fade is a list of numbers a spec walks
	tape = Tape.new,
	-- a camera driver that records every write instead of making one, handed to `Camera` in place of the
	-- engine, so a spec asserts on where the camera was put.
	film = Film.new,
	-- and a sound driver that plays nothing and writes down everything, handed to `Sound` in place of the
	-- engine, so a spec reads back every play, stop, position and volume.
	speaker = Speaker.new,
}
