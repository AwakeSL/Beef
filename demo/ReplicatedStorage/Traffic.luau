--!strict
--!optimize 2
-- the whole map of the rain's traffic, in one table both boots hand to Beef.Replicate: the server packs these
-- three event types once a frame and the client reads them out of the same three. Nothing else says where a
-- push goes, so there is one place to change when it changes.
local Beef = require(game:GetService("ReplicatedStorage").Beef)
local Rain = script.Parent

return {
	toClients = { Beef.Kinds.died, require(Rain.Events.Rained), require(Rain.Events.Landing) },
} :: Beef.ReplicateMap
