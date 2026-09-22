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
	who: ((from: any) -> any)?, -- the id a `from` column carries for this sender; the sender itself when absent
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

	-- what a `from` column carries: the UserId, which is the one thing about a player a client cannot forge
	who = function(from: any): any
		return from.UserId
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
						-- a client can fire anything at a remote; only a buffer is a payload
						if typeof(payload) == "buffer" then
							handler(payload, player)
						end
					end)
				else
					remote.OnClientEvent:Connect(function(payload: any)
						if typeof(payload) == "buffer" then
							handler(payload, nil)
						end
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
