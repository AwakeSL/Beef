--!strict
--!optimize 2
local Beef = require(game:GetService("ReplicatedStorage").Beef)

return Beef.Components.new("origin", { index = true } :: Beef.ComponentOptions) :: Beef.Component<number>
