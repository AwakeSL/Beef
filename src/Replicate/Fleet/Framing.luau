--!strict
--!optimize 2
-- the envelope every batch to and from the relay wears. A batch is a version byte then blocks, and a block is
-- `[message u8][count u8][ entry x count ]`: the message byte is paid once a block rather than once a push.
-- An entry of a fixed-width message is written bare; a message whose width depends on its values carries a u16
-- length in front of each entry, which is what lets `walk` split a batch it cannot decode.
--
-- The relay walks a batch exactly this way and reads nothing inside an entry past the subject, so these bytes
-- are the contract between Beef and a machine that has never heard of an Event.

local Framing = {}

Framing.VERSION = 1

export type Writer = { parts: { buffer }, size: number }

function Framing.writer(): Writer
	local head = buffer.create(1)
	buffer.writeu8(head, 0, Framing.VERSION)
	return { parts = { head }, size = 1 }
end

-- one block per call, split at 255 entries because the count is one byte
function Framing.addBlock(w: Writer, message: { id: number, stride: number? }, entries: { buffer })
	local at = 1
	repeat
		local n = math.min(#entries - at + 1, 255)
		local head = buffer.create(2)
		buffer.writeu8(head, 0, message.id)
		buffer.writeu8(head, 1, n)
		table.insert(w.parts, head)
		w.size += 2

		for i = at, at + n - 1 do
			local entry = entries[i]
			if message.stride == nil then
				local len = buffer.create(2)
				buffer.writeu16(len, 0, buffer.len(entry))
				table.insert(w.parts, len)
				w.size += 2
			end
			table.insert(w.parts, entry)
			w.size += buffer.len(entry)
		end
		at += n
	until at > #entries
end

function Framing.finish(w: Writer): buffer
	local out = buffer.create(w.size)
	local at = 0
	for _, part in w.parts do
		buffer.copy(out, at, part)
		at += buffer.len(part)
	end
	return out
end

export type Slice = { id: number, at: number, len: number, subject: number }

-- split a batch into entries without decoding one: the stride table says how wide each message is, 0 meaning the
-- entry carries its own length. A batch that does not walk is refused whole, because nothing here knows how wide
-- an unknown message is and so cannot skip past it.
function Framing.walk(b: buffer, strideOf: { [number]: number }): ({ Slice }?, string?)
	local size = buffer.len(b)
	if size < 1 then
		return nil, "empty"
	end
	if buffer.readu8(b, 0) ~= Framing.VERSION then
		return nil, ("version %d, expected %d"):format(buffer.readu8(b, 0), Framing.VERSION)
	end

	local slices: { Slice } = {}
	local at = 1
	while at < size do
		if at + 2 > size then
			return nil, "truncated block header"
		end
		local id = buffer.readu8(b, at)
		local count = buffer.readu8(b, at + 1)
		at += 2
		local stride = strideOf[id]
		if stride == nil then
			return nil, ("unknown message %d"):format(id)
		end

		for _ = 1, count do
			local len = stride
			if stride == 0 then
				if at + 2 > size then
					return nil, "truncated entry length"
				end
				len = buffer.readu16(b, at)
				at += 2
			end
			if len < 5 or at + len > size then
				return nil, "entry over remaining bytes"
			end
			table.insert(slices, {
				id = id,
				at = at,
				len = len,
				subject = buffer.readu16(b, at) + buffer.readu8(b, at + 2) * 65536,
			})
			at += len
		end
	end

	return slices, nil
end

return Framing
