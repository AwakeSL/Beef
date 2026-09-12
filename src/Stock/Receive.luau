--!strict
--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Wire = require(script.Parent.Parent.Wire)

type Buffer = { name: string, columns: { string }, wire: { [string]: string }, push: (...any) -> () }
type Named = { [string]: any }

return function(remoteName: string, into: { [string]: Buffer }, named: Named)
	local pending: { buffer } = {}
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild(remoteName) :: RemoteEvent
	remote.OnClientEvent:Connect(function(payload: buffer)
		table.insert(pending, payload)
	end)

	local writes = {}
	for _, buffer_ in into do
		table.insert(writes, buffer_)
	end

	local read = Wire.read
	local kindNames: { string } = {}
	local columnValues: { { any } } = {}
	local args = {}

	local self: { [string]: any }
	self = {
		name = "Receive",
		writes = writes,
		bytes = 0,
		pre = function()
			for _, b in pending do
				self.bytes += buffer.len(b)
				local at = 0
				table.clear(kindNames)
				local nKinds = buffer.readu8(b, at)
				at += 1
				for i = 1, nKinds do
					local n = buffer.readu8(b, at)
					kindNames[i] = buffer.readstring(b, at + 1, n)
					at += 1 + n
				end
				local live = buffer.readu8(b, at)
				at += 1
				for _ = 1, live do
					local name
					name, at = read.string(b, at)
					local count = buffer.readu32(b, at)
					at += 4
					local target = into[name]
					local columns = target and target.columns
					local width = columns and #columns or 0
					for c = 1, width do
						local kind = target.wire[columns[c]]
						local values = columnValues[c] or {}
						columnValues[c] = values
						if kind == "kind" then
							for i = 1, count do
								values[i] = named[kindNames[buffer.readu8(b, at)]]
								at += 1
							end
						else
							local reader = read[kind]
							for i = 1, count do
								values[i], at = reader(b, at)
							end
						end
					end
					if target then
						for i = 1, count do
							for c = 1, width do
								args[c] = columnValues[c][i]
							end
							target.push(table.unpack(args, 1, width))
						end
					end
				end
			end
			table.clear(pending)
		end,
	}
	return self
end
