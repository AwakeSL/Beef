--!strict
--!optimize 2
-- the unpacking end of a stream: what Send packed arrives here and is pushed into the same event types, column
-- by column, before any phase on the signal runs. Payloads land whenever the engine hands them over and wait
-- in a list; the `pre` stage drains it, so a push crosses once and lands in one frame.

local Wire = require(script.Parent.Parent.Wire)
local Remotes = require(script.Parent.Remotes)

type Buffer = { name: string, columns: { string }, wire: { [string]: string }, push: (...any) -> () }
type Named = { [string]: any }

return function(linkName: string, link: Remotes.Link, into: { [string]: Buffer }, named: Named)
	local pending: { buffer } = {}
	link.receive(function(payload: buffer)
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
	local complained: { [string]: boolean } = {}

	local self: { [string]: any }
	self = {
		name = "Receive",
		link = linkName,
		writes = writes,
		received = 0,
		pushes = 0,
		bytes = 0,
		dropped = 0,
		pre = function()
			for _, b in pending do
				self.received += 1
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
					if not target then
						-- the two ends were given different tables. nothing here knows how wide this event type
						-- is, so the rest of the payload cannot be walked past it: say so once and drop it
						if not complained[name] then
							complained[name] = true
							warn(("Replicate %s: nothing here reads %s; the boot table differs across the two sides"):format(linkName, name))
						end
						self.dropped += 1
						break
					end
					local columns = target.columns
					local width = #columns
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
					for i = 1, count do
						for c = 1, width do
							args[c] = columnValues[c][i]
						end
						target.push(table.unpack(args, 1, width))
					end
					self.pushes += count
				end
			end
			table.clear(pending)
		end,
	}
	return self
end
