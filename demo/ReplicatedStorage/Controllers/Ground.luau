--!strict
--!optimize 2
-- a field of slabs for the rain to land on

return function()
	return {
		name = "Ground",
		boot = function()
			local rng = Random.new(1)
			local folder = Instance.new("Folder")
			folder.Name = "Ground"
			for _ = 1, 300 do
				local slab = Instance.new("Part")
				slab.Anchored = true
				slab.Size = Vector3.new(rng:NextNumber(4, 16), 1, rng:NextNumber(4, 16))
				slab.Position = Vector3.new(rng:NextNumber(-100, 100), rng:NextNumber(0, 40), rng:NextNumber(-100, 100))
				slab.Parent = folder
			end
			folder.Parent = workspace
		end,
	}
end
