--!strict
--!optimize 2
local Component = require(game:GetService("ReplicatedStorage").Beef).Components

return Component.new("origin", { index = true } :: Component.Options) :: Component.Component<number>
