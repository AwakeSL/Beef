--!strict
--!optimize 2
-- draws the rain: a pool of adornments on one anchored part, moved from the drop columns (benched at ~0.9 us per drop)
type Kind = { count: number }
type Bucket<T> = { value: { T } }
type Component<T> = { of: (Kind) -> Bucket<T> }

local POOL = 3000

type Controller = { name: string, cost: number, frames: number, boot: () -> (), post: () -> () }

return function(drop: Kind, position: Component<Vector3>)
	local adornments: { SphereHandleAdornment } = {}
	local shown = 0
	local self: Controller
	self = {
		name = "Drops",
		cost = 0,
		frames = 0,
		boot = function()
			local anchor = Instance.new("Part")
			anchor.Name = "Drops"
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.Transparency = 1
			anchor.Size = Vector3.one
			anchor.CFrame = CFrame.identity
			for i = 1, POOL do
				local a = Instance.new("SphereHandleAdornment")
				a.Radius = 0.25
				a.Color3 = Color3.fromRGB(120, 170, 255)
				a.Adornee = anchor
				a.Visible = false
				a.Parent = anchor
				adornments[i] = a
			end
			anchor.Parent = workspace
		end,
		post = function()
			local t = os.clock()
			local p = position.of(drop).value
			local count = math.min(drop.count, POOL)
			-- the adornee sits at the origin, so an adornment's CFrame is the drop's world position
			for i = 1, count do
				adornments[i].CFrame = CFrame.new(p[i])
			end
			-- shown/hidden flips only at the edge, so a drop that stops being drawn costs one write, not one per frame
			for i = shown + 1, count do
				adornments[i].Visible = true
			end
			for i = count + 1, shown do
				adornments[i].Visible = false
			end
			shown = count
			self.cost += os.clock() - t
			self.frames += 1
			if self.frames % 2000 == 0 then
				print(("[drops] %d drawn, %.2f ms per frame over the last 2000"):format(count, self.cost / 2000 * 1e3))
				self.cost = 0
			end
		end,
	}
	return self
end
