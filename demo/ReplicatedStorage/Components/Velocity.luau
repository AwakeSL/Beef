--!strict
--!optimize 2
local Beef = require(game:GetService("ReplicatedStorage").Beef)

return Beef.Components.new("velocity", { wire = "vector3" } :: Beef.ComponentOptions) :: Beef.Component<Vector3>
