--!strict
--!optimize 2
local Kinds = require(game:GetService("ReplicatedStorage").Beef).Kinds
local Components = script.Parent.Parent.Components

return Kinds.new("drop", require(Components.Position), require(Components.Velocity))
