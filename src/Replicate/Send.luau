--!strict
--!optimize 2
-- the packing end of a stream: every event type on one link, packed once a frame and sent across.
-- a payload is the kind dictionary, then how many event types are in it, then for each of those its name, how
-- many pushes it carries, and its columns one after another. `limit` caps a payload: a reliable link has none,
-- an unreliable one has what the engine will carry, so a frame too big for it goes as several payloads instead
-- of one the engine throws away. `skip` names, per event type, a column that stays home: the other side
-- fills it itself, so nothing this side says about it would be believed anyway.

local Wire = require(script.Parent.Parent.Wire)
local Remotes = require(script.Parent.Remotes)

type Buffer = { name: string, columns: { string }, wire: { [string]: string }, from: number, last: number, [string]: any }

return function(linkName: string, link: Remotes.Link, buffers: { Buffer }, limit: number, skip: { [string]: string }?)
	assert(#buffers > 0, ("Send %s: nothing to send"):format(linkName))
	assert(#buffers < 256, ("Send %s: a link carries at most 255 event types"):format(linkName))

	-- the columns that cross, per event type: every column but the one the other side fills
	local crossing: { [Buffer]: { string } } = {}
	for _, buffer_ in buffers do
		local stays = if skip ~= nil then skip[buffer_.name] else nil
		local columns: { string } = {}
		for _, column in buffer_.columns do
			if column ~= stays then
				table.insert(columns, column)
			end
		end
		crossing[buffer_] = columns
	end

	-- every column has to have a wire type to cross, and the fixed-width ones are priced once here rather than
	-- per push: only a kind or a string column costs something that depends on the value
	local fixed: { [Buffer]: number } = {}
	local special: { [Buffer]: { string } } = {}
	for _, buffer_ in buffers do
		local bytes = 0
		local odd: { string } = {}
		for _, column in crossing[buffer_] do
			local kind = buffer_.wire[column]
			assert(kind, ("Send %s: event %s column %s has no wire type"):format(linkName, buffer_.name, column))
			assert(Wire.known(kind), ("Send %s: event %s column %s has unknown wire type %s"):format(linkName, buffer_.name, column, kind))
			if kind == "kind" or kind == "string" then
				table.insert(odd, column)
			else
				bytes += Wire.sizeOf(kind, nil)
			end
		end
		fixed[buffer_] = bytes
		special[buffer_] = odd
	end

	local write = Wire.write

	-- the payload being planned: which slice of which event type is in it, and the kind names it has named
	local sliceBuffer: { Buffer } = {}
	local sliceFrom: { number } = {}
	local sliceLast: { number } = {}
	local slices = 0
	local total = 2
	local dictNames: { string } = {}
	local dictIndex: { [string]: number } = {}
	local pendingNames: { string } = {}
	local pending: { [string]: boolean } = {}

	local self: { [string]: any }

	-- what one push adds to the payload: its column bytes, plus any kind name it is the first here to need.
	-- the names it would add are left in `pending` for `keepNames` to commit once the push is in.
	local function priceOf(buffer_: Buffer, i: number): number
		for k = #pendingNames, 1, -1 do
			pending[pendingNames[k]] = nil
			pendingNames[k] = nil
		end
		local cost = fixed[buffer_]
		for _, column in special[buffer_] do
			local kind = buffer_.wire[column]
			if kind == "kind" then
				cost += 1
				local name = buffer_[column][i].name
				if not dictIndex[name] and not pending[name] then
					pending[name] = true
					table.insert(pendingNames, name)
					cost += 1 + #name
				end
			else
				cost += 2 + #buffer_[column][i]
			end
		end
		return cost
	end

	local function keepNames()
		for _, name in pendingNames do
			table.insert(dictNames, name)
			dictIndex[name] = #dictNames
		end
	end

	local function emit()
		if slices == 0 then
			return
		end
		assert(#dictNames < 256, ("Send %s: a payload names at most 255 kinds"):format(linkName))
		local b = buffer.create(total)
		local at = 0
		buffer.writeu8(b, at, #dictNames)
		at += 1
		for _, name in dictNames do
			buffer.writeu8(b, at, #name)
			buffer.writestring(b, at + 1, name)
			at += 1 + #name
		end
		buffer.writeu8(b, at, slices)
		at += 1
		for s = 1, slices do
			local buffer_ = sliceBuffer[s]
			local from, last = sliceFrom[s], sliceLast[s]
			at = write.string(b, at, buffer_.name)
			buffer.writeu32(b, at, last - from + 1)
			at += 4
			for _, column in crossing[buffer_] do
				local kind = buffer_.wire[column]
				local values = buffer_[column]
				if kind == "kind" then
					for i = from, last do
						buffer.writeu8(b, at, dictIndex[values[i].name])
						at += 1
					end
				else
					local writer = write[kind]
					for i = from, last do
						at = writer(b, at, values[i])
					end
				end
			end
			self.pushes += last - from + 1
		end
		if total > limit then
			-- one push on its own does not fit the link; it goes anyway and is counted, because silently
			-- holding it back would be a push that never crossed and never said so
			self.oversize += 1
		end
		self.sent += 1
		self.bytes += total
		slices = 0
		total = 2
		table.clear(dictNames)
		table.clear(dictIndex)
		link.send(b)
	end

	self = {
		name = "Send",
		link = linkName,
		reads = buffers,
		sent = 0,
		pushes = 0,
		bytes = 0,
		oversize = 0,
		post = function()
			-- fill a payload with whole pushes until the next one would pass the limit, then start another
			for _, buffer_ in buffers do
				local from, last = buffer_.from, buffer_.last
				if last < from then
					continue
				end
				local header = 2 + #buffer_.name + 4
				local open = 0
				for i = from, last do
					local cost = priceOf(buffer_, i)
					if slices > 0 and total + cost + (if open == 0 then header else 0) > limit then
						emit()
						open = 0
						-- the dictionary left with that payload, so this push pays for its kind names again
						cost = priceOf(buffer_, i)
					end
					if open == 0 then
						slices += 1
						open = slices
						sliceBuffer[open] = buffer_
						sliceFrom[open] = i
						total += header
					end
					sliceLast[open] = i
					total += cost
					keepNames()
				end
			end
			emit()
		end,
	}
	return self
end
