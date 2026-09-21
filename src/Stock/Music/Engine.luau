--!strict
--!optimize 2
-- The engine edge of Music, and the only file in it that knows what a Sound is. Everything above it is
-- names, numbers and a clock, so the whole of the crossfade and the duck runs headless.
--
-- Read off the Sound and SoundService class pages:
--
--   * a Sound parented to SoundService plays flat, with no position in the world and no attenuation, which
--     is what a music stream is. A Sound parented to a part or an attachment is the other kind, and that
--     kind is Sound's, not this controller's.
--   * SoundId is the asset, Volume is the level, Looped says whether it starts again at the end, and
--     Playing is whether it is running. Play and Stop are the two calls; Stop also puts TimePosition back
--     to the start, which is what this wants, since a stream that is faded out is finished with.
--   * a SoundGroup is the one knob over a set of Sounds. This builds one named `BeefMusic` and puts both
--     streams in it, so a game with a settings menu has somewhere to put the music slider without knowing
--     anything about this controller, and so a mixer of the game's own has one thing to reach for.
--
-- Two Sounds, because a crossfade is two things playing at once. They are built at the phase's boot rather
-- than at the top of the file, because SoundService is the client's and this module is required wherever
-- Beef is.

local NAME = "BeefMusic"

local sounds: { any } = {}
local group: any = nil

local Engine = {
	bind = function()
		local RunService = game:GetService("RunService")
		assert(RunService:IsClient(), "Music: the stock music controller is a client controller")
		assert(#sounds == 0, "Music: the two streams are built once; a second Music controller needs its own driver")
		local SoundService = game:GetService("SoundService")

		group = Instance.new("SoundGroup")
		group.Name = NAME
		group.Parent = SoundService

		for i = 1, 2 do
			local sound = Instance.new("Sound")
			sound.Name = NAME .. i
			sound.Volume = 0
			sound.SoundGroup = group
			sound.Parent = SoundService
			sounds[i] = sound
		end
	end,

	play = function(slot: number, asset: string, looped: boolean)
		local sound = sounds[slot]
		if sound == nil then
			return
		end
		sound.Looped = looped
		-- a stream started again on the asset it last held keeps the sound it already loaded, and
		-- TimePosition is what actually puts it back to the beginning
		if sound.SoundId ~= asset then
			sound.SoundId = asset
		end
		sound.TimePosition = 0
		sound:Play()
	end,

	stop = function(slot: number)
		local sound = sounds[slot]
		if sound ~= nil then
			sound:Stop()
		end
	end,

	volume = function(slot: number, level: number)
		local sound = sounds[slot]
		if sound ~= nil then
			sound.Volume = level
		end
	end,
}

return Engine
