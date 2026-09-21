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
local Feed = require(script.Input.Feed)
local Film = require(script.Camera.Film)

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

	-- an input driver with a clock a test moves and keys it presses, handed to `Input` in place of the
	-- engine. A spec of Beef's own uses it, and so does a game testing its own controllers headless.
	feed = Feed.new,

	-- a camera driver that records every write instead of making one, handed to `Camera` in place of the
	-- engine, so a spec asserts on where the camera was put.
	film = Film.new,
}
