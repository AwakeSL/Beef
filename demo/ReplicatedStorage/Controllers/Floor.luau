--!strict
--!optimize 2
type Kind = { count: number, handle: { number }, despawn: (number) -> (), dying: (number) -> number? }
type Bucket<T> = { value: { T } }
type Component<T> = { of: (Kind) -> Bucket<T> }

local FLOOR = -20

return function(drop: Kind, position: Component<Vector3>)
	return {
		name = "Floor",
		post = function()
			local p, handles = position.of(drop).value, drop.handle
			for n = 1, drop.count do
				if p[n].Y < FLOOR and not drop.dying(handles[n]) then
					drop.despawn(handles[n])
				end
			end
		end,
	}
end
