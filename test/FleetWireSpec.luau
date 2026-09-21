--!strict
-- The fleet's bytes, with no relay and no Beef around them: the envelope a batch wears, one entry in and out
-- over Wire types, what survives the wait in the buffer, and where an id comes from.

return function(T)
	local Framing = T.module("Replicate/Fleet/Framing")
	local Codec = T.module("Replicate/Fleet/Codec")
	local Buffer = T.module("Replicate/Fleet/Buffer")
	local Mint = T.module("Replicate/Fleet/Mint")
	local eq, ok = T.eq, T.ok

	local function message(id: number, ...: string): any
		local columns = {}
		local wire = {}
		for i = 1, select("#", ...) do
			local column, kind = (select(i, ...)):match("^([%w_]+):([%w_]+)$")
			table.insert(columns, column)
			wire[column] = kind
		end
		local made = {
			id = id,
			name = "m" .. id,
			columns = columns,
			wire = wire,
			routing = "key",
			retention = "none",
			collapsible = false,
			window = 0,
		}
		Codec.prepare(made, "spec")
		return made
	end

	local function strides(...: any): { [number]: number }
		local out: { [number]: number } = {}
		for i = 1, select("#", ...) do
			local m = select(i, ...)
			out[m.id] = m.stride or 0
		end
		return out
	end

	-- -------------------------------------------------------------- Framing

	T.case("a batch of fixed-width entries walks back to the entries that went in", function()
		local hit = message(1, "amount:i32", "part:u8")
		local w = Framing.writer()
		Framing.addBlock(w, hit, {
			Codec.encode(hit, 7, 0, { -12, 3 }),
			Codec.encode(hit, 9, 0, { 40, 1 }),
		})
		local slices = assert(Framing.walk(Framing.finish(w), strides(hit)))
		eq(#slices, 2, "two entries went in")
		eq(slices[1].subject, 7, "first subject")
		eq(slices[2].subject, 9, "second subject")
		eq(slices[1].len, hit.stride, "a fixed entry is the stride wide")
	end)

	T.case("a message whose width is the value's carries its length and still walks", function()
		local said = message(2, "who:u32", "line:string")
		eq(said.stride, nil, "a string column leaves the message without a stride")
		local w = Framing.writer()
		Framing.addBlock(w, said, {
			Codec.encode(said, 4, 0, { 11, "hello" }),
			Codec.encode(said, 5, 0, { 12, "a much longer line than that" }),
		})
		local slices = assert(Framing.walk(Framing.finish(w), strides(said)))
		eq(#slices, 2, "two entries")
		ok(slices[2].len > slices[1].len, "the longer line did not make a longer entry")
	end)

	T.case("a batch naming a message this side has never heard of is refused whole", function()
		local hit = message(1, "amount:i32")
		local w = Framing.writer()
		Framing.addBlock(w, hit, { Codec.encode(hit, 7, 0, { 1 }) })
		local slices, why = Framing.walk(Framing.finish(w), {})
		eq(slices, nil, "an unwalkable batch was walked")
		ok(tostring(why):find("unknown message"), "the refusal did not say why")
	end)

	T.case("a batch from another version is refused", function()
		local b = buffer.create(3)
		buffer.writeu8(b, 0, 99)
		local slices, why = Framing.walk(b, {})
		eq(slices, nil, "a batch of the wrong version was walked")
		ok(tostring(why):find("version"), "the refusal did not name the version")
	end)

	T.case("more entries than a count byte holds split into blocks", function()
		local hit = message(1, "amount:u8")
		local entries = {}
		for i = 1, 300 do
			table.insert(entries, Codec.encode(hit, i, 0, { 1 }))
		end
		local w = Framing.writer()
		Framing.addBlock(w, hit, entries)
		local slices = assert(Framing.walk(Framing.finish(w), strides(hit)))
		eq(#slices, 300, "entries were lost at the block edge")
		eq(slices[300].subject, 300, "the last entry is the last one offered")
	end)

	-- ---------------------------------------------------------------- Codec

	T.case("every fixed wire type goes out and comes back", function()
		local all = message(3, "a:u8", "b:u16", "c:u32", "d:i32", "e:f32", "f:bool", "g:vector3", "h:color3")
		local b = Codec.encode(all, 12, 0, { 200, 40000, 70000, -5, 0.5, true, Vector3.new(1, 2, 3), Color3.fromRGB(10, 20, 30) })
		local into = {}
		local subject, age = Codec.decode(all, b, 0, buffer.len(b), into, {})
		eq(subject, 12, "subject")
		eq(age, 0, "age")
		eq(into[1], 200, "u8")
		eq(into[2], 40000, "u16")
		eq(into[3], 70000, "u32")
		eq(into[4], -5, "i32")
		eq(into[5], 0.5, "f32")
		eq(into[6], true, "bool")
		eq(into[7], Vector3.new(1, 2, 3), "vector3")
		eq(into[8].B, Color3.fromRGB(10, 20, 30).B, "color3")
	end)

	T.case("a kind column crosses as its name and comes back as the kind here", function()
		local creature = { name = "creature" }
		local spawned = message(4, "what:kind", "amount:u8")
		local b = Codec.encode(spawned, 3, 0, { creature, 7 })
		local into = {}
		local subject = Codec.decode(spawned, b, 0, buffer.len(b), into, { creature = creature })
		eq(subject, 3, "subject")
		eq(into[1], creature, "the kind did not resolve to the one here")
		eq(into[2], 7, "the column after a kind is misplaced")
	end)

	T.case("a kind the other side does not have refuses the entry and says so", function()
		local creature = { name = "creature" }
		local spawned = message(4, "what:kind")
		local b = Codec.encode(spawned, 3, 0, { creature })
		local subject, _, why = Codec.decode(spawned, b, 0, buffer.len(b), {}, {})
		eq(subject, nil, "an entry naming an unknown kind decoded anyway")
		ok(tostring(why):find("creature"), "the refusal did not name the kind")
	end)

	T.case("the subject and the age ride the envelope, not the columns", function()
		local hit = message(1, "amount:u8")
		local b = Codec.encode(hit, 70000, 0, { 3 })
		buffer.writeu16(b, 3, 125)
		local into = {}
		local subject, age = Codec.decode(hit, b, 0, buffer.len(b), into, {})
		eq(subject, 70000, "a subject over a u16 did not survive")
		eq(age, 125, "the age the buffer wrote at the flush was not read back")
		eq(into[1], 3, "the column moved")
	end)

	T.case("a column with no wire type is refused at boot, not at the first push", function()
		T.throws(function()
			Codec.prepare({ name = "loose", columns = { "who" }, wire = {} }, "spec")
		end, "no wire type")
		T.throws(function()
			Codec.prepare({ name = "odd", columns = { "who" }, wire = { who = "u9" } }, "spec")
		end, "unknown wire type")
	end)

	-- --------------------------------------------------------------- Buffer

	local function payload(n: number): buffer
		local b = buffer.create(6)
		buffer.writeu8(b, 5, n)
		return b
	end

	local function collapsing(window: number): any
		return { id = 1, name = "m", collapsible = true, window = window }
	end

	T.case("an offer whose bytes have not changed is not offered again", function()
		local buf = Buffer.new()
		local m = collapsing(0)
		eq(buf:offer(m, 1, payload(3), 0), "appended", "the first offer")
		eq(buf:offer(m, 1, payload(3), 0), "unchanged", "the same value went out twice")
		buf:flush(0)
		eq(buf:offer(m, 1, payload(3), 10), "unchanged", "a value equal to what last went out was sent again")
		eq(buf:offer(m, 1, payload(4), 10), "appended", "a changed value was dropped")
	end)

	T.case("a change inside the window replaces what is pending rather than queueing behind it", function()
		local buf = Buffer.new()
		local m = collapsing(0.05)
		buf:offer(m, 1, payload(1), 0)
		eq(buf:offer(m, 1, payload(2), 20), "replaced", "a change inside the window queued instead")
		eq(#buf.pending, 1, "the window let two entries for one subject through")
		eq(buf:offer(m, 1, payload(3), 60), "appended", "a change past the window replaced instead of queueing")
		eq(#buf.pending, 2, "the entry past the window was lost")
	end)

	T.case("a message that does not collapse never drops a push", function()
		local buf = Buffer.new()
		local m = { id = 2, name = "hit", collapsible = false, window = 1 }
		buf:offer(m, 1, payload(7), 0)
		buf:offer(m, 1, payload(7), 1)
		buf:offer(m, 1, payload(7), 2)
		eq(#buf.pending, 3, "three hits of the same size became fewer than three")
	end)

	T.case("a full buffer sheds its oldest offer", function()
		local buf = Buffer.new(2)
		local m = { id = 3, name = "m", collapsible = false, window = 0 }
		buf:offer(m, 1, payload(1), 0)
		buf:offer(m, 2, payload(2), 0)
		buf:offer(m, 3, payload(3), 0)
		eq(#buf.pending, 2, "the cap did not hold")
		eq(buf.dropped, 1, "the drop was not counted")
		eq(buf.pending[1].subject, 2, "the newest was shed instead of the oldest")
	end)

	T.case("the age is written when the entry leaves, not when it was offered", function()
		local buf = Buffer.new()
		local m = collapsing(0.05)
		buf:offer(m, 1, payload(1), 100)
		local out = buf:flush(180)
		eq(#out, 1, "nothing flushed")
		eq(buffer.readu16(out[1].payload, 3), 80, "the age is not how long the value waited here")
	end)

	T.case("a batch that did not land comes back, and a newer value for that slot wins", function()
		local buf = Buffer.new()
		local m = collapsing(0)
		buf:offer(m, 1, payload(1), 0)
		buf:offer(m, 2, payload(2), 0)
		local out = buf:flush(0)
		buf:offer(m, 1, payload(9), 10)
		buf:mergeBack(out)
		eq(#buf.pending, 2, "the failed batch was not merged back around what is already pending")
		eq(buffer.readu8(buf.pending[2].payload, 5), 9, "the stale value beat the newer one")
	end)

	-- ----------------------------------------------------------------- Mint

	T.case("ids come out of a granted block in order", function()
		local pool = Mint.new()
		pool:grant(1000, 3)
		eq(pool:mint(), 1000, "first")
		eq(pool:mint(), 1001, "second")
		eq(pool:mint(), 1002, "third")
		eq(pool:mint(), nil, "a spent block kept minting")
		eq(pool.stats.minted, 3, "minted")
		eq(pool.stats.deferred, 1, "the dry mint was not counted")
	end)

	T.case("a block is asked for once, and only when the pool is low", function()
		local pool = Mint.new(2)
		ok(pool:wantsBlock(), "a cold pool did not ask")
		ok(not pool:wantsBlock(), "two asks were in flight at once")
		pool:grant(1, 10)
		ok(not pool:wantsBlock(), "a full pool asked anyway")
		for _ = 1, 8 do
			pool:mint()
		end
		ok(pool:wantsBlock(), "a low pool did not ask")
	end)
end
