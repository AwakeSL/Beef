--!strict
--!optimize 2
-- The engine edge of Sound, and the only file in Beef that knows what a Sound instance is. Everything
-- above it is positions, numbers and a clock, so the whole of placement, occlusion, mixing and the budget
-- runs headless.
--
-- Read off the class pages for Sound, SoundService, Attachment and WorldRoot:
--
--   * a Sound parented to a BasePart or an Attachment is emitted from there and falls off with distance;
--     parented anywhere else it is heard everywhere at one volume. So a placed sound gets an Attachment of
--     its own on Terrain, which is a BasePart every place has, and an unplaced one goes under SoundService.
--   * RollOffMaxDistance is where the fall reaches nothing, and RollOffMode says the shape of it. A sound
--     that says how far it carries gets that distance and the tapered shape, so what the engine does with
--     the distance matches the cutoff the controller applies at the same number.
--   * Ended fires when a sound reaches its end and Stopped when something stops it. Either one frees the
--     voice. A SoundId that never loads fires neither, so a sound still not loaded after a few seconds
--     gives its voice back rather than holding it for the session.
--   * SoundService:GetListener() says where the ears are: a camera, a CFrame, or an instance. Beef asks
--     rather than assuming the camera, because a game that moved its listener meant it.
--
-- The services are fetched inside `start` rather than at the top, because they are the client's and this
-- module is required wherever Beef is.

local PATIENCE = 5 -- seconds a sound has to load before its voice is given back
local FOLDER = "Beef" -- where the unplaced sounds sit, so a game can find them

local one: { number } = {}
local two: { number } = {}
local queue = one

local sounds: { [number]: any } = {}
local holders: { [number]: any } = {}

local service: any = nil
local world: any = nil
local player: any = nil
local into: any = nil
local rays: any = nil

local function finish(voice: number)
	local sound = sounds[voice]
	if sound == nil then
		return
	end
	sounds[voice] = nil
	local holder = holders[voice]
	holders[voice] = nil
	table.insert(queue, voice)
	sound:Destroy()
	if holder ~= nil then
		holder:Destroy()
	end
end

local Engine = {
	-- built once, at the phase's boot
	start = function()
		local RunService = game:GetService("RunService")
		assert(RunService:IsClient(), "Sound: the stock sound controller is a client controller")
		assert(service == nil, "Sound: the engine is taken once; a second Sound controller needs its own driver")
		service = game:GetService("SoundService")
		world = game:GetService("Workspace")
		player = game:GetService("Players").LocalPlayer

		into = Instance.new("Folder")
		into.Name = FOLDER
		into.Parent = service

		rays = RaycastParams.new()
		rays.FilterType = Enum.RaycastFilterType.Exclude
		rays.IgnoreWater = true
	end,

	listener = function(): Vector3
		local _, target = service:GetListener()
		if typeof(target) == "CFrame" then
			return target.Position
		elseif typeof(target) == "Instance" then
			if target:IsA("Attachment") then
				return target.WorldPosition
			elseif target:IsA("BasePart") then
				return target.Position
			end
		end
		local camera = world.CurrentCamera
		return if camera then camera.CFrame.Position else Vector3.zero
	end,

	-- one ray, listener to sound. The player's own body is not what a game means by something in the way.
	blocked = function(from: Vector3, to: Vector3): boolean
		local character = player.Character
		rays.FilterDescendantsInstances = if character then { character } else {}
		return world:Raycast(from, to - from, rays) ~= nil
	end,

	play = function(voice: number, asset: string, at: Vector3?, volume: number, pitch: number, carries: number?)
		local sound = Instance.new("Sound")
		sound.Name = tostring(voice)
		sound.SoundId = asset
		sound.Volume = volume
		sound.PlaybackSpeed = pitch
		if carries ~= nil then
			sound.RollOffMode = Enum.RollOffMode.InverseTapered
			sound.RollOffMaxDistance = carries
		end
		if at ~= nil then
			local holder = Instance.new("Attachment")
			holder.Name = FOLDER .. tostring(voice)
			holder.WorldPosition = at
			holder.Parent = world.Terrain
			holders[voice] = holder
			sound.Parent = holder
		else
			sound.Parent = into
		end
		sounds[voice] = sound
		sound.Ended:Connect(function()
			finish(voice)
		end)
		sound.Stopped:Connect(function()
			finish(voice)
		end)
		sound:Play()
		task.delay(PATIENCE, function()
			if sounds[voice] == sound and not sound.IsLoaded then
				finish(voice)
			end
		end)
	end,

	volume = function(voice: number, volume: number)
		local sound = sounds[voice]
		if sound ~= nil then
			sound.Volume = volume
		end
	end,

	-- the controller has already forgotten this voice, so the stop is not reported back to it
	stop = function(voice: number)
		local sound = sounds[voice]
		if sound == nil then
			return
		end
		sounds[voice] = nil
		local holder = holders[voice]
		holders[voice] = nil
		sound:Stop()
		sound:Destroy()
		if holder ~= nil then
			holder:Destroy()
		end
	end,

	ended = function(): { number }
		local out = queue
		queue = if queue == one then two else one
		table.clear(queue)
		return out
	end,
}

return Engine
