--!strict
-- The fleet end to end: two whole Beefs, one each server, booted from the same table, with a relay between them
-- that holds where a subject lives and who owns it and never reads a payload. Everything a live game would
-- prove against a running relay is proved here in memory, because the relay is bytes in and bytes out.

return function(T)
	local Framing = T.module("Replicate/Fleet/Framing")
	local eq, ok = T.eq, T.ok

	local ID_TABLE, ID_PLACE, ID_RELEASE, ID_WANT = 240, 241, 242, 243
	local ID_BLOCK_REQUEST, ID_BLOCK_GRANT = 244, 245
	local ID_CLAIM, ID_CLAIM_RESULT, ID_ADOPT, ID_DISOWN, ID_TICK = 246, 247, 248, 249, 250

	local PROTOCOL: { [number]: number } = {
		[ID_TABLE] = 0,
		[ID_PLACE] = 0,
		[ID_RELEASE] = 5,
		[ID_WANT] = 0,
		[ID_BLOCK_REQUEST] = 5,
		[ID_BLOCK_GRANT] = 10,
		[ID_CLAIM] = 9,
		[ID_CLAIM_RESULT] = 10,
		[ID_ADOPT] = 0,
		[ID_DISOWN] = 5,
		[ID_TICK] = 13,
	}

	local function envelope(subject: number, age: number, extra: number): buffer
		local b = buffer.create(5 + extra)
		buffer.writeu16(b, 0, subject % 65536)
		buffer.writeu8(b, 2, subject // 65536)
		buffer.writeu16(b, 3, age)
		return b
	end

	-- the other implementation. It learns how wide each message is from the table the servers send it, walks a
	-- batch without decoding one entry, and moves entries by where the subject lives and who owns it. It is the
	-- whole of what the relay in Tether's repo does, in the same bytes, small enough to read.
	local function relay(): any
		local net: any = {
			clock = 0,
			strides = table.clone(PROTOCOL),
			routing = {} :: { [number]: string },
			servers = {} :: { [string]: any },
			where = {} :: { [number]: string },
			owner = {} :: { [number]: string },
			adopts = {} :: { [number]: { key: string, body: string } },
			nextBase = 4096,
			posts = 0,
		}

		local function serverAt(identity: string): any
			local found = net.servers[identity]
			if not found then
				found = { identity = identity, want = {}, queue = {} }
				net.servers[identity] = found
			end
			return found
		end

		local function copyOf(b: buffer, at: number, len: number): buffer
			local out = buffer.create(len)
			buffer.copy(out, 0, b, at, len)
			return out
		end

		local function queue(to: any, id: number, payload: buffer)
			table.insert(to.queue, { id = id, payload = payload, at = net.clock })
		end

		-- who hears a subject: every other server that asked for the key it lives under, or the one server
		-- that owns it when the message routes by owner
		local function targets(from: any, id: number, subject: number): { any }
			local out = {}
			if net.routing[id] == "owner" then
				local held = net.owner[subject]
				if held ~= nil and held ~= from.identity then
					table.insert(out, serverAt(held))
				end
				return out
			end
			local key = net.where[subject]
			if key == nil then
				return out
			end
			for _, server in net.servers do
				if server ~= from and server.want[key] then
					table.insert(out, server)
				end
			end
			return out
		end

		local function announce(from: any, key: string, id: number, payload: buffer)
			for _, server in net.servers do
				if server ~= from and server.want[key] then
					queue(server, id, copyOf(payload, 0, buffer.len(payload)))
				end
			end
		end

		-- the relay's own walk. The message table is the one block whose entries are bare rather than framed,
		-- because it is what teaches the walk how wide everything else is.
		local function walk(b: buffer): { any }?
			local size = buffer.len(b)
			if size < 1 or buffer.readu8(b, 0) ~= Framing.VERSION then
				return nil
			end
			local out = {}
			local at = 1
			while at < size do
				if at + 2 > size then
					return nil
				end
				local id = buffer.readu8(b, at)
				local count = buffer.readu8(b, at + 1)
				at += 2
				if id == ID_TABLE then
					for _ = 1, count do
						local mid = buffer.readu8(b, at)
						local flags = buffer.readu8(b, at + 1)
						net.strides[mid] = buffer.readu16(b, at + 2)
						net.routing[mid] = if bit32.band(flags, 1) == 1 then "owner" else "key"
						at += 4
					end
					continue
				end
				local stride = net.strides[id]
				if stride == nil then
					return nil
				end
				for _ = 1, count do
					local len = stride
					if stride == 0 then
						len = buffer.readu16(b, at)
						at += 2
					end
					if len < 5 or at + len > size then
						return nil
					end
					table.insert(out, { id = id, at = at, len = len })
					at += len
				end
			end
			return out
		end

		net.http = function(_url: string, headers: { [string]: string }, body: string): (boolean, number, string)
			net.posts += 1
			local from = serverAt(headers["x-tether-id"])
			local b = buffer.fromstring(body)
			local slices = walk(b)
			if slices == nil then
				return true, 400, ""
			end

			for _, slice in slices do
				local id, at, len = slice.id, slice.at, slice.len
				local subject = buffer.readu16(b, at) + buffer.readu8(b, at + 2) * 65536

				if id == ID_PLACE then
					local klen = buffer.readu8(b, at + 5)
					net.where[subject] = buffer.readstring(b, at + 6, klen)
				elseif id == ID_RELEASE then
					local key = net.where[subject]
					net.where[subject] = nil
					net.owner[subject] = nil
					net.adopts[subject] = nil
					if key ~= nil then
						announce(from, key, ID_RELEASE, envelope(subject, 0, 0))
					end
				elseif id == ID_WANT then
					local count = buffer.readu16(b, at + 5)
					local keys = {}
					local walked = at + 7
					for _ = 1, count do
						local klen = buffer.readu8(b, walked)
						keys[buffer.readstring(b, walked + 1, klen)] = true
						walked += 1 + klen
					end
					from.want = keys
				elseif id == ID_BLOCK_REQUEST then
					local grant = envelope(0, 0, 5)
					buffer.writeu16(grant, 5, net.nextBase % 65536)
					buffer.writeu8(grant, 7, net.nextBase // 65536)
					buffer.writeu16(grant, 8, 512)
					net.nextBase += 512
					queue(from, ID_BLOCK_GRANT, grant)
				elseif id == ID_CLAIM then
					local won = net.adopts[subject] ~= nil and net.owner[subject] == nil
					if won then
						net.owner[subject] = from.identity
					end
					local result = envelope(subject, 0, 5)
					buffer.writeu8(result, 5, if won then 1 else 0)
					queue(from, ID_CLAIM_RESULT, result)
				elseif id == ID_ADOPT then
					local klen = buffer.readu8(b, at + 5)
					local key = buffer.readstring(b, at + 6, klen)
					net.adopts[subject] = { key = key, body = buffer.readstring(b, at + 6 + klen, len - 6 - klen) }
					announce(from, key, ID_ADOPT, copyOf(b, at, len))
				elseif id == ID_DISOWN then
					net.adopts[subject] = nil
					net.owner[subject] = nil
				elseif id < ID_TABLE then
					for _, to in targets(from, id, subject) do
						queue(to, id, copyOf(b, at, len))
					end
				end
			end

			-- the answer: everything waiting for this server, with the hold it spent here added to its age, and
			-- the tick that tells it how early it reached the deadline it posted on
			local w = Framing.writer()
			local waiting = from.queue
			from.queue = {}
			local i = 1
			while i <= #waiting do
				local id = waiting[i].id
				local entries = {}
				while i <= #waiting and waiting[i].id == id do
					local held = waiting[i]
					local age = buffer.readu16(held.payload, 3) + (net.clock - held.at)
					buffer.writeu16(held.payload, 3, math.clamp(math.round(age), 0, 65535))
					table.insert(entries, held.payload)
					i += 1
				end
				Framing.addBlock(w, { id = id, stride = if net.strides[id] == 0 then nil else net.strides[id] }, entries)
			end
			local tick = envelope(0, 0, 8)
			buffer.writei16(tick, 5, 20)
			buffer.writeu16(tick, 7, 0)
			buffer.writeu32(tick, 9, net.posts)
			Framing.addBlock(w, { id = ID_TICK, stride = PROTOCOL[ID_TICK] }, { tick })

			return true, 200, buffer.tostring(Framing.finish(w))
		end

		net.driverFor = function(identity: string): any
			return {
				isServer = function(): boolean
					return true
				end,
				now = function(): number
					return net.clock / 1000
				end,
				link = function(): any
					return {
						send = function() end,
						receive = function() end,
					}
				end,
				joining = function() end,
				http = function(url: string, _headers: { [string]: string }, body: string)
					return net.http(url, { ["x-tether-id"] = identity }, body)
				end,
				-- the answer lands inside the post, so a case that steps a server sees the effect at once
				spawn = function(fn: () -> ())
					fn()
				end,
				clock = function(): number
					return net.clock
				end,
			}
		end

		return net
	end

	-- one game, declared once, booted twice: the same function builds both servers, and nothing in a case is
	-- allowed to reach from one into the other
	local function world(net: any, identity: string, mirrors: boolean): any
		local Beef = T.load()
		local Position = Beef.Components.new("position", { wire = "vector3" })
		local Health = Beef.Components.new("health", { wire = "u16" })
		local Creature = Beef.Kinds.new("creature", Position, Health)
		-- a mirror carries another server's fleet id, so it is a kind of its own and outside `fleet.kinds`:
		-- nothing mints for it and nothing releases when it goes
		local Mirror = Beef.Kinds.new("mirror", Position, Health)
		local Damage = Beef.Events.new("damage", "target:u32", "amount:i32", "age:f32", { entity = "target" })
		local Landed = Beef.Events.new("landed", "who:u32", "what:kind", "age:f32", { entity = "who" })

		Beef.Replicate.driver(net.driverFor(identity))
		local wiring = Beef.Replicate({
			fleet = {
				url = "http://relay/publish",
				identity = identity,
				interval = 0,
				budget = 100000,
				kinds = { Creature },
				events = {
					{ Damage, route = "key" },
					{ Landed, route = "key" },
				},
				publish = { { Creature, Position } },
			},
		})

		local self = {
			Beef = Beef,
			id = identity,
			Position = Position,
			Health = Health,
			Creature = Creature,
			Mirror = Mirror,
			Damage = Damage,
			Landed = Landed,
			wiring = wiring,
			mirrors = mirrors,
		}

		-- one frame of this server: what arrived lands, the phases would run here, and what they pushed goes
		self.frame = function()
			wiring.deliver()
			wiring.pack()
			Beef.Events.lap(net.clock / 1000)
			Beef.Kinds.lap()
		end

		self.fleetIdOf = function(kind: any, handle: number): number?
			return Beef.Replicate.fleet.get(kind, kind.at(handle))
		end

		-- bind a mirror here to a subject over there. A game does this itself, because only it knows which
		-- entity here stands for which entity there.
		self.mirror = function(subject: number): number
			local handle = Mirror.spawn(Vector3.zero, 0)
			Beef.Replicate.fleet.add(Mirror, Mirror.at(handle), subject)
			return handle
		end

		return self
	end

	local function pair(): (any, any, any)
		local net = relay()
		return net, world(net, "one", false), world(net, "two", true)
	end

	-- a post is made after that frame's arrivals have already been delivered, so what came back in the answer is
	-- read at the top of the next frame: one frame fetches, the next lands it
	local function land(to: any)
		to.frame()
		to.frame()
	end

	-- the first frame is the handshake: the table goes up, the block of ids comes back, and each side says
	-- which keys it wants
	local function settle(net: any, a: any, b: any)
		a.Beef.Replicate.want({ "zone:1" })
		b.Beef.Replicate.want({ "zone:1" })
		a.frame()
		b.frame()
		net.clock += 16
	end

	-- ------------------------------------------------------------- the seam

	T.case("a spawn mints an id out of the relay's block and a despawn gives it back", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		local id = a.fleetIdOf(a.Creature, handle)
		ok(id ~= nil, "a spawn of a fleet kind did not mint")
		eq(id, 4096, "the first id is not the base of the first block")

		a.frame()
		net.clock += 16
		a.Creature.despawn(handle)
		a.frame()
		eq(net.where[id :: number], nil, "a despawned subject was left placed on the relay")
		eq(b.id, "two", "the other server is untouched")
	end)

	T.case("a push on one server crosses to the other with its age and lands in the same buffer", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		local id = a.fleetIdOf(a.Creature, handle) :: number
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()

		local mirror = b.mirror(id)
		a.Damage.push(handle, 12)
		a.frame()
		net.clock += 40
		land(b)

		eq(b.Damage.count, 1, "the hit did not cross")
		eq(b.Damage.target[1], mirror, "the hit landed on the wrong entity here")
		eq(b.Damage.amount[1], 12, "the amount did not survive")
		ok(b.Damage.age[1] > 0, "the hit arrived with no age on it")
		ok(b.Damage.age[1] < 1, "the age is not in seconds")
		eq(a.Damage.count, 1, "the local push left the local buffer")
	end)

	T.case("a kind column crosses as a kind and comes back as the kind on the other side", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		local id = a.fleetIdOf(a.Creature, handle) :: number
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()
		b.mirror(id)

		a.Landed.push(handle, a.Creature)
		a.frame()
		net.clock += 16
		land(b)

		eq(b.Landed.count, 1, "the landing did not cross")
		eq(b.Landed.what[1], b.Creature, "the kind did not resolve to the one on this side")
	end)

	T.case("a push about an entity nobody here carries is counted, not pushed", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()

		a.Damage.push(handle, 5)
		a.frame()
		net.clock += 16
		land(b)

		eq(b.Damage.count, 0, "a hit about nothing was pushed anyway")
		eq((b.Beef.Replicate.stats().fleet :: any).unmatched, 1, "the drop was not counted")
	end)

	-- ------------------------------------------------------------ the column

	T.case("a placed entity's column crosses on change and is not sent again unchanged", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		local id = a.fleetIdOf(a.Creature, handle) :: number
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()
		local mirror = b.mirror(id)

		a.frame()
		net.clock += 16
		land(b)
		eq(b.Position.get(b.Mirror, b.Mirror.at(mirror)), Vector3.new(1, 2, 3), "the column never crossed")

		local before = (a.Beef.Replicate.stats().fleet :: any).appended
		a.frame()
		a.frame()
		eq((a.Beef.Replicate.stats().fleet :: any).appended, before, "a column that did not move was sent again")
		ok((a.Beef.Replicate.stats().fleet :: any).unchanged > 0, "the unchanged offers were not counted")

		a.Position.add(a.Creature, a.Creature.at(handle), Vector3.new(9, 9, 9))
		a.frame()
		net.clock += 16
		land(b)
		eq(b.Position.get(b.Mirror, b.Mirror.at(mirror)), Vector3.new(9, 9, 9), "the move never crossed")
	end)

	T.case("a value for an entity this side has not made yet is held, not dropped", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(4, 5, 6), 100)
		local id = a.fleetIdOf(a.Creature, handle) :: number
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()

		a.frame()
		net.clock += 16
		b.frame()
		eq((b.Beef.Replicate.stats().fleet :: any).waiting, 1, "the value was dropped rather than held")

		local mirror = b.mirror(id)
		b.frame()
		eq(b.Position.get(b.Mirror, b.Mirror.at(mirror)), Vector3.new(4, 5, 6), "the held value never went in")
		eq((b.Beef.Replicate.stats().fleet :: any).waiting, 0, "the hold was not let go")
	end)

	T.case("a server hears nothing about a key it did not ask for", function()
		local net, a, b = pair()
		a.Beef.Replicate.want({ "zone:1" })
		b.Beef.Replicate.want({ "zone:9" })
		a.frame()
		b.frame()
		net.clock += 16

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		local id = a.fleetIdOf(a.Creature, handle) :: number
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()
		b.mirror(id)

		a.Damage.push(handle, 7)
		a.frame()
		net.clock += 16
		b.frame()
		eq(b.Damage.count, 0, "a server was told about a key it never asked for")
	end)

	-- ---------------------------------------------------------- who owns it

	T.case("a release crosses as a push into Replicate.released", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		local id = a.fleetIdOf(a.Creature, handle) :: number
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()

		a.Creature.despawn(handle)
		a.frame()
		net.clock += 25
		land(b)

		eq(b.Beef.Replicate.released.count, 1, "the release did not cross")
		eq(b.Beef.Replicate.released.id[1], id, "the wrong subject was released")
		ok(b.Beef.Replicate.released.age[1] > 0, "the release arrived with no age")
	end)

	T.case("an adopt reaches the other server and a claim comes back as a push", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		local id = a.fleetIdOf(a.Creature, handle) :: number
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()

		a.Beef.Replicate.adopt(id, nil, "a creature worth taking")
		a.frame()
		net.clock += 16
		land(b)

		eq(b.Beef.Replicate.adopted.count, 1, "the offer never reached the other server")
		eq(b.Beef.Replicate.adopted.id[1], id, "the wrong subject was offered")
		eq(b.Beef.Replicate.adopted.server[1], "a creature worth taking", "the body of the offer was lost")

		b.Beef.Replicate.claim(id)
		b.frame()
		net.clock += 16
		b.frame()
		eq(b.Beef.Replicate.claimed.count, 1, "the claim was never answered")
		eq(b.Beef.Replicate.claimed.server[1], "two", "a won claim did not name the server that won it")
		eq(net.owner[id], "two", "the relay did not move the owner")
	end)

	T.case("a claim on a subject nobody put up is refused", function()
		local net, a, b = pair()
		settle(net, a, b)

		b.Beef.Replicate.claim(99)
		b.frame()
		net.clock += 16
		b.frame()
		eq(b.Beef.Replicate.claimed.count, 1, "the claim was never answered")
		eq(b.Beef.Replicate.claimed.server[1], "", "a lost claim named a winner")
		eq(a.id, "one", "the other server was reached over")
	end)

	T.case("a disowned subject cannot be claimed", function()
		local net, a, b = pair()
		settle(net, a, b)

		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		local id = a.fleetIdOf(a.Creature, handle) :: number
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		a.Beef.Replicate.adopt(id, nil, "one")
		a.frame()
		net.clock += 16
		a.Beef.Replicate.disown(id)
		a.frame()
		net.clock += 16

		b.Beef.Replicate.claim(id)
		b.frame()
		net.clock += 16
		b.frame()
		eq(b.Beef.Replicate.claimed.server[1], "", "a disowned subject was handed over")
	end)

	-- ------------------------------------------------------------ the table

	T.case("an event type with no entity column is refused at boot", function()
		local Beef = T.load()
		local Creature = Beef.Kinds.new("creature")
		local Loose = Beef.Events.new("loose", "who:u32")
		T.throws(function()
			Beef.Replicate({
				fleet = { url = "http://relay", kinds = { Creature }, events = { { Loose } } },
			})
		end, "needs an entity column")
	end)

	T.case("an entry naming a subject kind outside fleet.kinds is refused", function()
		local Beef = T.load()
		local Creature = Beef.Kinds.new("creature")
		local Rock = Beef.Kinds.new("rock")
		local Hit = Beef.Events.new("hit", "who:u32", { entity = "who" })
		T.throws(function()
			Beef.Replicate({
				fleet = { url = "http://relay", kinds = { Creature }, events = { { Hit, subject = Rock } } },
			})
		end, "not in fleet.kinds")
	end)

	T.case("two entries with the same subject and more than one fleet kind must say which", function()
		local Beef = T.load()
		local Creature = Beef.Kinds.new("creature")
		local Rock = Beef.Kinds.new("rock")
		local Hit = Beef.Events.new("hit", "who:u32", { entity = "who" })
		T.throws(function()
			Beef.Replicate({
				fleet = { url = "http://relay", kinds = { Creature, Rock }, events = { { Hit } } },
			})
		end, "needs subject")
	end)

	T.case("an option that is not an option here is refused, and so is a bad route", function()
		local Beef = T.load()
		local Creature = Beef.Kinds.new("creature")
		local Hit = Beef.Events.new("hit", "who:u32", { entity = "who" })
		T.throws(function()
			Beef.Replicate({
				fleet = { url = "http://relay", kinds = { Creature }, events = { { Hit, every = 2 } } },
			})
		end, "not an option here")

		local Other = T.load()
		local Kind = Other.Kinds.new("creature")
		local Event = Other.Events.new("hit", "who:u32", { entity = "who" })
		T.throws(function()
			Other.Replicate({
				fleet = { url = "http://relay", kinds = { Kind }, events = { { Event, route = "sideways" } } },
			})
		end, "route is key or owner")
	end)

	T.case("a publish entry for a kind with no fleet id is refused", function()
		local Beef = T.load()
		local Position = Beef.Components.new("position", { wire = "vector3" })
		local Rock = Beef.Kinds.new("rock", Position)
		local Creature = Beef.Kinds.new("creature")
		T.throws(function()
			Beef.Replicate({
				fleet = { url = "http://relay", kinds = { Creature }, publish = { { Rock, Position } } },
			})
		end, "not in fleet.kinds")
	end)

	T.case("a call into a fleet that was never declared says so", function()
		local Beef = T.load()
		local Creature = Beef.Kinds.new("creature")
		Beef.Replicate({})
		T.throws(function()
			Beef.Replicate.place(Creature, 1, "zone:1")
		end, "no fleet was declared")
	end)

	T.case("stats cover the fleet side and are nil when there is none", function()
		local net, a, b = pair()
		settle(net, a, b)
		local handle = a.Creature.spawn(Vector3.new(1, 2, 3), 100)
		a.Beef.Replicate.place(a.Creature, handle, "zone:1")
		a.frame()
		net.clock += 16
		b.frame()

		local stats = a.Beef.Replicate.stats().fleet :: any
		ok(stats.sent > 0, "no posts were counted")
		ok(stats.okCount > 0, "no answers were counted")
		eq(stats.minted, 1, "the mint was not counted")
		ok(stats.granted > 0, "the block grant was not counted")
		ok(stats.ticks > 0, "the relay's tick was not counted")

		local Bare = T.load()
		Bare.Replicate({})
		eq(Bare.Replicate.stats().fleet, nil, "a game with no fleet was given fleet stats")
	end)
end
