--!strict
--!optimize 2
local Component = require(game:GetService("ReplicatedStorage").Beef.Components)

return Component.new("velocity", { wire = "vector3" } :: Component.Options) :: Component.Component<Vector3>
