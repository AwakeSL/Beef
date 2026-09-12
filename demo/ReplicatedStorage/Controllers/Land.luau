--!strict
--!optimize 2
type Kind = { at: (number) -> number?, despawn: (number) -> (), dying: (number) -> number? }
type Landing = { from: number, last: number, handle: { number } }

return function(landing: Landing, drop: Kind)
	return {
		name = "Land",
		reads = { landing },
		loop = function()
			for i = landing.from, landing.last do
				local h = landing.handle[i]
				if drop.at(h) and not drop.dying(h) then
					drop.despawn(h)
				end
			end
		end,
	}
end
