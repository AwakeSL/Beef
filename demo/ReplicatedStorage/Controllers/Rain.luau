--!strict
--!optimize 2
-- the client's rain: a drop is born here when the server says one was born, and dies when the server says it landed
type Kind = { spawn: (...any) -> number, at: (number) -> number?, despawn: (number) -> (), dying: (number) -> number? }
type Rained = { from: number, last: number, handle: { number }, position: { Vector3 }, velocity: { Vector3 } }
type Landing = { from: number, last: number, handle: { number } }
type Origin = { add: (Kind, number, number) -> (), find: (number) -> (Kind?, number?) }

return function(rained: Rained, landing: Landing, drop: Kind, origin: Origin)
	return {
		name = "Rain",
		reads = { rained, landing } :: { any },
		-- loop, not pre: Receive pushes these rows in pre, and the loop's first pass is the first window that holds them
		loop = function()
			for i = rained.from, rained.last do
				local handle = drop.spawn(rained.position[i], rained.velocity[i])
				origin.add(drop, drop.at(handle) :: number, rained.handle[i])
			end
			for i = landing.from, landing.last do
				local kind, handle = origin.find(landing.handle[i])
				if kind == drop and handle and not drop.dying(handle) then
					drop.despawn(handle)
				end
			end
		end,
	}
end
