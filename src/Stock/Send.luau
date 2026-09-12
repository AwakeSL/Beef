--!strict
--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Wire = require(script.Parent.Parent.Wire)

type Buffer = { name: string, columns: { string }, wire: { [string]: string }, from: number, last: number, [string]: any }

return function(remoteName: string, ...: Buffer)
	local buffers = { ... }
	for _, buffer in buffers do
		for _, column in buffer.columns do
			local kind = buffer.wire[column]
			assert(kind, ("Send: event %s column %s has no wire type"):format(buffer.name, column))
			assert(Wire.known(kind), ("Send: event %s column %s has unknown wire type %s"):format(buffer.name, column, kind))
		end
	end

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
		remotes = folder
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = remoteName
	remote.Parent = remotes

	local write = Wire.write
	local kindIndex: { [string]: number } = {}
	local kindNames: { string } = {}

	local self: { [string]: any }
	self = {
		name = "Send",
		reads = buffers,
		bytes = 0,
		post = function()
			table.clear(kindIndex)
			table.clear(kindNames)
			local total = 1
			local live = 0
			for _, buffer in buffers do
				local from, last = buffer.from, buffer.last
				if last < from then
					continue
				end
				live += 1
				total += 2 + #buffer.name + 4
				for _, column in buffer.columns do
					local kind = buffer.wire[column]
					local values = buffer[column]
					if kind == "kind" then
						for i = from, last do
							local name = values[i].name
							if not kindIndex[name] then
								table.insert(kindNames, name)
								kindIndex[name] = #kindNames
							end
						end
						total += last - from + 1
					elseif kind == "string" then
						for i = from, last do
							total += 2 + #values[i]
						end
					else
						total += Wire.sizeOf(kind, nil) * (last - from + 1)
					end
				end
			end
			if live == 0 then
				return
			end
			total += 1
			for _, name in kindNames do
				total += 1 + #name
			end

			local b = buffer.create(total)
			local at = 0
			buffer.writeu8(b, at, #kindNames)
			at += 1
			for _, name in kindNames do
				buffer.writeu8(b, at, #name)
				buffer.writestring(b, at + 1, name)
				at += 1 + #name
			end
			buffer.writeu8(b, at, live)
			at += 1
			for _, buffer_ in buffers do
				local from, last = buffer_.from, buffer_.last
				if last < from then
					continue
				end
				at = write.string(b, at, buffer_.name)
				buffer.writeu32(b, at, last - from + 1)
				at += 4
				for _, column in buffer_.columns do
					local kind = buffer_.wire[column]
					local values = buffer_[column]
					if kind == "kind" then
						for i = from, last do
							buffer.writeu8(b, at, kindIndex[values[i].name])
							at += 1
						end
					else
						local writer = write[kind]
						for i = from, last do
							at = writer(b, at, values[i])
						end
					end
				end
			end
			self.bytes += total
			remote:FireAllClients(b)
		end,
	}
	return self
end
