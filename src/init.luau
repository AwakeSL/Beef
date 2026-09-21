--!strict
--!optimize 2
-- Beef: Buffered ECS and Event Framework. This is the one require; everything else hangs off it.
local Kinds = require(script.Kinds)
local Components = require(script.Components)
local Events = require(script.Events)
local Phase = require(script.Phase)
local Drivers = require(script.Drivers)
local Wire = require(script.Wire)
local Shared = require(script.Shared)

export type Kind = Kinds.Kind
export type KindOptions = Kinds.Options
export type Component<T> = Components.Component<T>
export type Bucket<T> = Components.Bucket<T>
export type ComponentOptions = Components.Options
export type Buffer = Events.Buffer
export type EventOptions = Events.Options
export type Controller = Phase.Controller
export type Entry = Phase.Entry
export type Phase = Phase.Phase
export type Step = Drivers.Step
export type Parallel = Drivers.Parallel
export type ParallelOptions = Drivers.ParallelOptions
export type SharedSorted = Shared.Sorted
export type SharedQueue = Shared.Queue
export type SharedMap = Shared.Map
export type SharedStats = Shared.Stats

return {
	Kinds = Kinds,
	Components = Components,
	Events = Events,
	Phase = Phase,
	Drivers = Drivers,
	Wire = Wire,
	Shared = Shared,
	Stock = {
		Send = require(script.Stock.Send),
		Receive = require(script.Stock.Receive),
		Publish = require(script.Stock.Publish),
		Apply = require(script.Stock.Apply),
	},
}
