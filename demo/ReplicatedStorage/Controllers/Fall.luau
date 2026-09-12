--!strict
--!optimize 2
type Kind = { count: number }
type Bucket<T> = { value: { T } }
type Component<T> = { of: (Kind) -> Bucket<T> }
type Phase = { dt: number }
type Controller = { name: string, loop: () -> (), phase: Phase? }

local GRAVITY = Vector3.new(0, -50, 0)

return function(drop: Kind, position: Component<Vector3>, velocity: Component<Vector3>)
	local self: Controller
	self = {
		name = "Fall",
		loop = function()
			local dt = (self.phase :: Phase).dt
			local p, v = position.of(drop).value, velocity.of(drop).value
			local g = GRAVITY * dt
			for n = 1, drop.count do
				local vn = v[n] + g
				v[n] = vn
				p[n] = p[n] + vn * dt
			end
		end,
	}
	return self
end
