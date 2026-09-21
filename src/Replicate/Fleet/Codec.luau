--!strict
--!optimize 2
-- one entry, in and out. An entry is `[subject u24][age u16]` then the columns of the message in declaration
-- order, and the columns are written with the same `Wire` types every other seam in Beef uses: the quantisation
-- is the wire type on the column, so a message declares nothing of its own about how wide a number is.
--
-- The subject is the fleet id, not a handle: handles are local to a machine and mean nothing across the seam.
-- The age is milliseconds and is filled in at the flush, so what lands here at encode time is a placeholder.
--
-- Values travel as a positional array in column order rather than a keyed table, because a push is already a
-- set of parallel column arrays and walking them by index costs no lookups.

local Wire = require(script.Parent.Parent.Parent.Wire)

local Codec = {}

export type Message = {
	id: number,
	name: string,
	columns: { string },
	wire: { [string]: string },
	fixed: number,
	special: { number },
	stride: number?,
	[string]: any,
}

-- price the message once at boot: everything fixed-width is summed here and never counted again, and only a
-- string or a kind column, whose width is the value's, is left to measure per push. A message with none of
-- those has a stride, which is what lets a batch of it go without a length in front of every entry.
function Codec.prepare(message: Message, where: string)
	local fixed = 5
	local special: { number } = {}
	for c, column in message.columns do
		local kind = message.wire[column]
		assert(kind, ("%s: %s column %s has no wire type"):format(where, message.name, column))
		assert(Wire.known(kind), ("%s: %s column %s has unknown wire type %s"):format(where, message.name, column, kind))
		if kind == "string" or kind == "kind" then
			table.insert(special, c)
		else
			fixed += Wire.sizeOf(kind, nil)
		end
	end
	message.fixed = fixed
	message.special = special
	message.stride = if #special == 0 then fixed else nil
end

local function widthOf(message: Message, values: { any }): number
	local total = message.fixed
	for _, c in message.special do
		local kind = message.wire[message.columns[c]]
		if kind == "kind" then
			total += 1 + #(values[c].name :: string)
		else
			total += 2 + #(values[c] :: string)
		end
	end
	return total
end

function Codec.encode(message: Message, subject: number, ageMs: number, values: { any }): buffer
	local b = buffer.create(message.stride or widthOf(message, values))
	buffer.writeu16(b, 0, subject % 65536)
	buffer.writeu8(b, 2, subject // 65536)
	buffer.writeu16(b, 3, math.clamp(math.round(ageMs), 0, 65535))

	local at = 5
	local write = Wire.write
	local columns = message.columns
	for c = 1, #columns do
		local kind = message.wire[columns[c]]
		if kind == "kind" then
			-- a kind crosses as its name. There is no dictionary here the way there is on a stream, because an
			-- entry has to stand alone: the relay may hold it, drop it, or hand it to a server that never saw
			-- the batch it arrived in.
			local name = values[c].name :: string
			buffer.writeu8(b, at, #name)
			buffer.writestring(b, at + 1, name)
			at += 1 + #name
		else
			at = write[kind](b, at, values[c])
		end
	end
	return b
end

-- read one entry out of `b` at `at`, `len` bytes wide, filling `into` in column order. `named` resolves a kind
-- name to the local Kind. Returns the subject and the age, or nil and why the entry was refused.
function Codec.decode(
	message: Message,
	b: buffer,
	at: number,
	len: number,
	into: { any },
	named: { [string]: any }
): (number?, number?, string?)
	local stop = at + len
	local subject = buffer.readu16(b, at) + buffer.readu8(b, at + 2) * 65536
	local ageMs = buffer.readu16(b, at + 3)
	at += 5

	local read = Wire.read
	local columns = message.columns
	for c = 1, #columns do
		local kind = message.wire[columns[c]]
		if kind == "kind" then
			if at + 1 > stop then
				return nil, nil, "truncated kind name"
			end
			local n = buffer.readu8(b, at)
			if at + 1 + n > stop then
				return nil, nil, "kind name over remaining bytes"
			end
			local name = buffer.readstring(b, at + 1, n)
			local resolved = named[name]
			if resolved == nil then
				-- the two ends were given different kinds. The entry is whole, so it is skipped rather than
				-- refusing the batch behind it
				return nil, nil, ("no kind named %s here"):format(name)
			end
			into[c] = resolved
			at += 1 + n
		elseif kind == "string" then
			if at + 2 > stop then
				return nil, nil, "truncated string length"
			end
			local n = buffer.readu16(b, at)
			if at + 2 + n > stop then
				return nil, nil, "string over remaining bytes"
			end
			into[c] = buffer.readstring(b, at + 2, n)
			at += 2 + n
		else
			into[c], at = read[kind](b, at)
			if at > stop then
				return nil, nil, "column over remaining bytes"
			end
		end
	end

	return subject, ageMs, nil
end

return Codec
