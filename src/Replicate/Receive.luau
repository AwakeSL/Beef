--!strict
--!optimize 2
-- the unpacking end of a stream: what arrived on one link since the last frame, walked with this side's own
-- columns and pushed into this side's event types. Nothing in a payload is trusted for its shape: the event
-- name picks the columns, the columns say the widths, and a payload that runs out of bytes, names a kind this
-- side has not declared, or names an event type this side does not read is dropped where it broke and
-- counted. The pushes already made whole from it stay.
--
-- on the server every payload has a sender. `fill` names, per event type, the column the server writes the
-- sender's id into instead of reading it off the wire, so who pushed is the engine's word and never the
-- client's. `limits` caps how many pushes of each type one sender gets through in a frame; the rest are
-- dropped and counted as throttled, and the count starts over every frame.

local Wire = require(script.Parent.Parent.Wire)
local Remotes = require(script.Parent.Remotes)

type Buffer = { name: string, columns: { string }, wire: { [string]: string }, push: (...any) -> () }
type Named = { [string]: any }

return function(
	linkName: string,
	link: Remotes.Link,
	driver: Remotes.Driver,
	into: { [string]: Buffer },
	named: Named,
	fill: { [string]: string }?,
	limits: { [string]: number }?
)
	local pending: { buffer } = {}
	local senders: { any } = {}
	link.receive(function(payload: buffer, from: any?)
		table.insert(pending, payload)
		senders[#pending] = from
	end)

	local writes = {}
	for _, buffer_ in into do
		table.insert(writes, buffer_)
	end

	local read = Wire.read
	local who = driver.who
	local kindNames: { string } = {}
	local columnValues: { { any } } = {}
	local args = {}
	local complained: { [string]: boolean } = {}
	-- how many pushes of each type each sender has had this frame
	local spent: { [any]: { [string]: number } } = {}

	local self: { [string]: any }

	-- one payload. anything that does not add up is an error out of here, caught by the frame below
	local function unpack(b: buffer, from: any?)
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

		local id: any = nil
		local budget: { [string]: number }? = nil
		if from ~= nil then
			id = if who ~= nil then who(from) else from
			if limits ~= nil then
				budget = spent[from]
				if budget == nil then
					budget = {}
					spent[from] = budget
				end
			end
		end

		for _ = 1, live do
			local name
			name, at = read.string(b, at)
			local count = buffer.readu32(b, at)
			at += 4
			local target = into[name]
			if not target then
				-- the two ends were given different tables. nothing here knows how wide this event type is,
				-- so the rest of the payload cannot be walked past it: say so once and drop it
				if not complained[name] then
					complained[name] = true
					warn(("Replicate %s: nothing here reads %s; the boot table differs across the two sides"):format(linkName, name))
				end
				self.dropped += 1
				return
			end
			local columns = target.columns
			local width = #columns
			local filled = if fill ~= nil then fill[name] else nil
			for c = 1, width do
				local column = columns[c]
				local values = columnValues[c] or {}
				columnValues[c] = values
				if column == filled then
					for i = 1, count do
						values[i] = id
					end
				else
					local kind = target.wire[column]
					if kind == "kind" then
						for i = 1, count do
							local slot = kindNames[buffer.readu8(b, at)]
							local found = if slot ~= nil then named[slot] else nil
							if found == nil then
								error(("%s names a kind this side has not declared"):format(name))
							end
							values[i] = found
							at += 1
						end
					else
						local reader = read[kind]
						for i = 1, count do
							values[i], at = reader(b, at)
						end
					end
				end
			end

			local allowed = count
			if budget ~= nil then
				local cap = (limits :: { [string]: number })[name]
				if cap ~= nil then
					local used = budget[name] or 0
					allowed = math.clamp(cap - used, 0, count)
					budget[name] = used + allowed
					self.throttled += count - allowed
				end
			end
			for i = 1, allowed do
				for c = 1, width do
					args[c] = columnValues[c][i]
				end
				target.push(table.unpack(args, 1, width))
			end
			self.pushes += allowed
		end
	end

	self = {
		name = "Receive",
		link = linkName,
		writes = writes,
		received = 0,
		pushes = 0,
		bytes = 0,
		dropped = 0,
		throttled = 0,
		malformed = 0,
		pre = function()
			table.clear(spent)
			for i, b in pending do
				self.received += 1
				self.bytes += buffer.len(b)
				local ok, err = pcall(unpack, b, senders[i])
				if not ok then
					self.malformed += 1
					if not complained["\0malformed"] then
						complained["\0malformed"] = true
						warn(("Replicate %s: a payload could not be read and was dropped (%s); more like it are counted, not repeated"):format(linkName, tostring(err)))
					end
				end
			end
			table.clear(pending)
			table.clear(senders)
		end,
	}
	return self
end
