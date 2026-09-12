--!strict
--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Wire = require(script.Parent.Parent.Wire)

type Kind = { name: string, count: number, handle: { number } }
type Component = { name: string, wire: string?, of: (Kind) -> { value: { any } } }
type Options = { every: number?, channel: ("reliable" | "unreliable")?, keyframe: number?, chunk: number? }

local HEADER = 8 + 1 + 4

local function remoteFolder(): Folder
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
		remotes = folder
	end
	return remotes :: Folder
end

return function(remoteName: string, kind: Kind, ...: any)
	local args = { ... }
	local options: Options = {}
	if type(args[#args]) == "table" and args[#args].name == nil then
		options = table.remove(args) :: Options
	end
	local components = args :: { Component }
	local width = #components
	local every = options.every or 1
	local unreliable = options.channel == "unreliable"
	local keyframe = options.keyframe or 60

	local rowBytes = 4
	local writers = {}
	for i, component in components do
		local wire = component.wire
		assert(wire, ("Publish: component %s has no wire type"):format(component.name))
		assert(wire ~= "string" and wire ~= "kind" and Wire.known(wire), ("Publish: component %s cannot publish as %s"):format(component.name, wire))
		rowBytes += Wire.sizeOf(wire, nil)
		writers[i] = Wire.write[wire]
	end
	local chunk = options.chunk or (if unreliable then math.floor((900 - HEADER) / rowBytes) else math.huge)

	-- the two remote classes share every call made here; typed as one so the calls resolve
	local remote: RemoteEvent = if unreliable then Instance.new("UnreliableRemoteEvent") :: any else Instance.new("RemoteEvent")
	remote.Name = remoteName
	remote.Parent = remoteFolder()

	local lastSent: { { [number]: any } } = {}
	for i = 1, width do
		lastSent[i] = {}
	end

	local laps = 0
	local publishes = 0
	local joining: { Player } = {}
	for _, player in Players:GetPlayers() do
		table.insert(joining, player)
	end
	Players.PlayerAdded:Connect(function(player)
		table.insert(joining, player)
	end)

	local outHandles: { number } = {}
	local outPositions: { number } = {}

	local function pack(now: number, full: boolean, first: number, last: number, columns: { { any } }): buffer
		local n = last - first + 1
		local b = buffer.create(HEADER + n * rowBytes)
		buffer.writef64(b, 0, now)
		buffer.writeu8(b, 8, if full then 1 else 0)
		buffer.writeu32(b, 9, n)
		local at = HEADER
		for i = first, last do
			buffer.writeu32(b, at, outHandles[i])
			at += 4
		end
		for c = 1, width do
			local writer = writers[c]
			local values = columns[c]
			for i = first, last do
				at = writer(b, at, values[outPositions[i]])
			end
		end
		return b
	end

	local self: { [string]: any }
	self = {
		name = "Publish",
		sent = 0,
		entities = 0,
		bytes = 0,
		post = function()
			local columns: { { any } } = {}
			for i = 1, width do
				columns[i] = components[i].of(kind).value
			end
			local handles = kind.handle

			if #joining > 0 then
				local count = kind.count
				for position = 1, count do
					outHandles[position] = handles[position]
					outPositions[position] = position
				end
				local now = workspace:GetServerTimeNow()
				local start = 1
				repeat
					local stop = math.min(start + chunk - 1, count)
					local full = pack(now, true, start, math.max(stop, start - 1), columns)
					for _, player in joining do
						remote:FireClient(player, full)
						self.sent += 1
						self.bytes += buffer.len(full)
					end
					start = stop + 1
				until start > count
				table.clear(joining)
			end

			laps += 1
			if laps % every ~= 0 then
				return
			end
			publishes += 1
			local all = unreliable and publishes % keyframe == 0
			local now = workspace:GetServerTimeNow()

			local n = 0
			for position = 1, kind.count do
				local handle = handles[position]
				local changed = all
				if not changed then
					for i = 1, width do
						if lastSent[i][handle] ~= columns[i][position] then
							changed = true
							break
						end
					end
				end
				if changed then
					n += 1
					outHandles[n] = handle
					outPositions[n] = position
					for i = 1, width do
						lastSent[i][handle] = columns[i][position]
					end
				end
			end
			self.entities += n

			local start = 1
			repeat
				local stop = math.min(start + chunk - 1, n)
				local b = pack(now, false, start, math.max(stop, start - 1), columns)
				remote:FireAllClients(b)
				self.sent += 1
				self.bytes += buffer.len(b)
				start = stop + 1
			until start > n
		end,
	}
	return self
end
