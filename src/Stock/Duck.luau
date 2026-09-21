--!strict
--!optimize 2
-- The one seam between Sound and Music, and the whole of it. A sound that should quiet the music says so
-- here, as a push, and Music reads it. Neither controller knows the other exists: Sound is handed no music
-- and Music is handed no sounds, so a game that replaces either one keeps the seam by pushing or reading
-- this Event.
--
-- It is an ask, not an order. The push says how far the music should drop and for how long; what the music
-- does about it, how fast it gets there and what happens when two asks overlap are Music's, because only
-- Music knows what is playing.
--
--   amount   how far the music drops, 0 for nothing and 1 for silence
--   lasts    how many seconds it stays down before it is back where it was
--
-- A map entry with a `duck` option pushes one of these on the frame its sound plays. A game with its own
-- reason to duck pushes one itself; nothing about this Event is Sound's.

local Events = require(script.Parent.Parent.Events)

return Events.new("duck", "amount:f32", "lasts:f32")
