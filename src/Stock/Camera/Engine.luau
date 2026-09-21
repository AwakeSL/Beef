--!strict
--!optimize 2
-- The engine edge of Camera, and the only file here that knows what `workspace.CurrentCamera` is.
-- Everything above it is CFrames, degrees and a clock, so the whole of the modes, the constraints and the
-- effects runs headless.
--
-- What Roblox gives. `workspace.CurrentCamera` is one Camera instance per client. Its CameraType has to be
-- Scriptable before a script may write its CFrame, or the default camera scripts put it back every frame.
-- FieldOfView is the angle up the screen, since FieldOfViewMode is Vertical by default, and ViewportSize is
-- how big the window is in pixels. A raycast through Workspace is what says whether anything is between the
-- body and where the camera wants to sit.
--
-- The camera is fetched inside the calls rather than at the top, because the camera is the client's and
-- this module is required wherever Beef is.

local SKIN = 0.4 -- how far short of what was hit the camera stops, so it does not sit inside the wall
local NOTHING = 1 -- the whole way is clear

local params: RaycastParams? = nil

local function camera(): any
	return workspace.CurrentCamera
end

-- the filter is rebuilt when the character changes, since a camera that raycasts into the body it is
-- following stops dead against the player's own back
local function filter(): RaycastParams
	local Players = game:GetService("Players")
	local player = Players.LocalPlayer
	local made = params
	if made == nil then
		made = RaycastParams.new()
		params = made
	end
	local ready = made :: RaycastParams
	ready.FilterType = Enum.RaycastFilterType.Exclude
	ready.FilterDescendantsInstances = { player.Character }
	return ready
end

local Engine = {
	-- run once, at the phase's boot: the default camera scripts have to be told to let go before anything
	-- written here stays written
	start = function()
		local RunService = game:GetService("RunService")
		assert(RunService:IsClient(), "Camera: the stock camera controller is a client controller")
		local it = camera()
		it.CameraType = Enum.CameraType.Scriptable
	end,

	viewport = function(): Vector2
		return camera().ViewportSize
	end,

	-- how much of the way from the body out to where the camera wants to sit is clear, 1 being nothing in
	-- the way. A hit stops the camera a little short of it rather than on it, since a camera flush against a
	-- wall sees through it.
	clear = function(from: Vector3, to: Vector3): number
		local gap = to - from
		local far = gap.Magnitude
		if far <= 0 then
			return NOTHING
		end
		local hit = workspace:Raycast(from, gap, filter())
		if hit == nil then
			return NOTHING
		end
		local near = (hit.Position - from).Magnitude - SKIN
		if near <= 0 then
			return 0
		end
		return near / far
	end,

	set = function(at: CFrame, fov: number)
		local it = camera()
		if it.CameraType ~= Enum.CameraType.Scriptable then
			-- the default camera scripts take the camera back every time the character spawns, so this
			-- is checked on every write, not remembered from the boot
			it.CameraType = Enum.CameraType.Scriptable
		end
		it.CFrame = at
		it.FieldOfView = fov
	end,
}

return Engine
