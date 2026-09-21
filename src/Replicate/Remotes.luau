--!strict
--!optimize 2
-- the engine edge of Replicate, and the only part of it that knows what a RemoteEvent is: a link by name, who
-- needs a keyframe because they just arrived, the server clock, and which side this is. Everything above this
-- is buffers, so a spec stands a pair of in-memory links in its place and the packing runs headless.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- one link is one remote, used from both ends: the side that packs calls `send`, the side that unpacks calls
-- `receive`. `to` names one recipient, which only the server has; without it a send goes to everyone on the
-- other side.
export type Link = {
	send: (payload: buffer, to: any?) -> (),
	receive: (handler: (payload: buffer, from: any?) -> ()) -> (),
}

export type Driver = {
	isServer: () -> boolean,
	now: () -> number,
	link: (name: string, unreliable: boolean) -> Link,
	joining: (arrived: (who: any) -> ()) -> (),
}

local function folder(): Folder
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		local made = Instance.new("Folder")
		made.Name = "Remotes"
		made.Parent = ReplicatedStorage
		remotes = made
	end
	return remotes :: Folder
end

local Remotes: Driver = {
	isServer = function(): boolean
		return RunService:IsServer()
	end,

	now = function(): number
		return workspace:GetServerTimeNow()
	end,

	-- the server makes the remote, the client waits for it, so a client boot yields here until the server is up
	link = function(name: string, unreliable: boolean): Link
		local server = RunService:IsServer()
		-- the two remote classes share every call made here; typed as one so the calls resolve
		local remote: RemoteEvent
		if server then
			remote = if unreliable then Instance.new("UnreliableRemoteEvent") :: any else Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder()
		else
			remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild(name) :: any
		end

		return {
			send = function(payload: buffer, to: any?)
				if not server then
					remote:FireServer(payload)
				elseif to then
					remote:FireClient(to, payload)
				else
					remote:FireAllClients(payload)
				end
			end,

			receive = function(handler: (payload: buffer, from: any?) -> ())
				if server then
					remote.OnServerEvent:Connect(function(player: Player, payload: any)
						handler(payload :: buffer, player)
					end)
				else
					remote.OnClientEvent:Connect(function(payload: any)
						handler(payload :: buffer, nil)
					end)
				end
			end,
		}
	end,

	joining = function(arrived: (who: any) -> ())
		for _, player in Players:GetPlayers() do
			arrived(player)
		end
		Players.PlayerAdded:Connect(arrived)
	end,
}

return Remotes
