--!strict
-- Replicate headless: the boot table is read, the options are honoured, and what one side packs comes out of
-- the other side's buffers. The remotes are the engine edge, so a pair of in-memory links stands in for them
-- and every byte between them is the same Wire packing the live ones carry.

return function(T)
	-- the stand-in: one link by name with the handlers each side registered on it. A send is queued, and
	-- `deliver` hands it across, so a payload crosses exactly when a case says so and a case can drop one the
	-- way an unreliable remote does.
	local function network(): any
		local net: any = { links = {}, queue = {}, joining = {}, clock = 0, dropped = 0 }

		net.endpoint = function(isServer: boolean): any
			return {
				isServer = function(): boolean
					return isServer
				end,
				now = function(): number
					return net.clock
				end,
				link = function(name: string, unreliable: boolean): any
					local made = net.links[name]
					if not made then
						made = { name = name, unreliable = unreliable, server = {}, client = {} }
						net.links[name] = made
					end
					return {
						send = function(payload: buffer, to: any?)
							table.insert(net.queue, { link = made, fromServer = isServer, payload = payload, to = to })
						end,
						receive = function(handler: (buffer, any?) -> ())
							table.insert(if isServer then made.server else made.client, handler)
						end,
					}
				end,
				joining = function(arrived: (any) -> ())
					table.insert(net.joining, arrived)
				end,
			}
		end

		net.join = function(who: any)
			for _, arrived in net.joining do
				arrived(who)
			end
		end

		net.deliver = function(keep: ((any) -> boolean)?)
			local queue = net.queue
			net.queue = {}
			for _, message in queue do
				if keep and not keep(message) then
					net.dropped += 1
					continue
				end
				local handlers = if message.fromServer then message.link.client else message.link.server
				for _, handler in handlers do
					handler(message.payload, if message.fromServer then nil else "client")
				end
			end
		end

		return net
	end

	-- two whole Beefs, one each side, declared by the same function and booted with the same table: that is
	-- what a live game has, and nothing in a case is allowed to reach across from one to the other
	local function pair(declare: (any, boolean) -> any): (any, any, any)
		local net = network()
		local made = {}
		for i, isServer in { true, false } do
			local Beef = T.load()
			Beef.Replicate.driver(net.endpoint(isServer))
			local side = declare(Beef, isServer)
			side.Beef = Beef
			side.wiring = Beef.Replicate(side.map)
			made[i] = side
		end
		return net, made[1], made[2]
	end

	local function crosses(net: any, from: any, to: any)
		from.wiring.pack()
		net.deliver()
		to.wiring.deliver()
	end

	-- ------------------------------------------------------------------ the surface

	T.case("Beef exports Replicate and no longer holds the four under Stock", function()
		local Beef = T.load()
		T.ok(Beef.Replicate ~= nil, "Beef.Replicate")
		T.eq(Beef.Stock, nil, "Beef.Stock is gone")
		T.eq(type(Beef.Replicate.driver), "function", "Replicate.driver")
		T.eq(type(Beef.Replicate.stats), "function", "Replicate.stats")
	end)

	T.case("the four are internals under Replicate", function()
		for _, name in { "Replicate/Send", "Replicate/Receive", "Replicate/Publish", "Replicate/Apply" } do
			T.eq(type(T.module(name)), "function", name)
		end
	end)

	T.case("stats before anything crossed is every count at zero", function()
		local Beef = T.load()
		local stats = Beef.Replicate.stats()
		T.eq(stats.sent, 0)
		T.eq(stats.received, 0)
		T.eq(stats.bytesOut, 0)
		T.eq(stats.pushesIn, 0)
	end)

	-- ------------------------------------------------------------------ toClients

	T.case("a push on the server comes out of the same event type on the client", function()
		local net, server, client = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32", "amount:f32")
			return { Damage = Damage, map = { toClients = { Damage } } }
		end)

		server.Damage.push(11, 3.5)
		server.Damage.push(12, 1.25)
		crosses(net, server, client)

		T.eq(client.Damage.count, 2, "both pushes landed")
		T.eq(client.Damage.who[1], 11)
		T.eq(client.Damage.amount[2], 1.25)
		T.eq(server.Beef.Replicate.stats().pushesOut, 2, "counted out")
		T.eq(client.Beef.Replicate.stats().pushesIn, 2, "counted in")
	end)

	T.case("several event types share one payload on one link", function()
		local net, server, client = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32")
			local Spawned = Beef.Events.new("spawned", "who:u32", "at:vector3")
			return { Damage = Damage, Spawned = Spawned, map = { toClients = { Damage, Spawned } } }
		end)

		server.Damage.push(7)
		server.Spawned.push(7, Vector3.new(1, 2, 3))
		crosses(net, server, client)

		T.eq(client.Damage.count, 1)
		T.eq(client.Spawned.at[1].Y, 2)
		T.eq(server.Beef.Replicate.stats().sent, 1, "one payload for both")
	end)

	T.case("a kind column crosses by name and arrives as this side's kind", function()
		local net, server, client = pair(function(Beef)
			local Position = Beef.Components.new("position", { wire = "vector3" })
			local Drop = Beef.Kinds.new("drop", Position)
			local Rained = Beef.Events.new("rained", "kind:kind", "handle:u32")
			return { Drop = Drop, Rained = Rained, map = { toClients = { Rained } } }
		end)

		server.Rained.push(server.Drop, 42)
		crosses(net, server, client)

		T.eq(client.Rained.count, 1)
		T.ok(client.Rained.kind[1] == client.Drop, "the client's own drop")
		T.ok(client.Rained.kind[1] ~= server.Drop, "not the server's")
		T.eq(client.Rained.handle[1], 42)
	end)

	T.case("a bare entry and a one-thing list declare the same traffic", function()
		local net, server, client = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32")
			return { Damage = Damage, map = { toClients = { { Damage } } } }
		end)

		server.Damage.push(3)
		crosses(net, server, client)
		T.eq(client.Damage.count, 1, "a list of one is the bare thing")
	end)

	T.case("channel unreliable puts an event type on its own link", function()
		local net, server, _ = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32")
			local Landing = Beef.Events.new("landing", "who:u32")
			return { Damage = Damage, Landing = Landing, map = { toClients = { Damage, { Landing, channel = "unreliable" } } } }
		end)

		T.ok(net.links["Beef.toClients"] ~= nil, "the reliable link")
		T.ok(net.links["Beef.toClients.unreliable"] ~= nil, "the unreliable link")
		T.eq(net.links["Beef.toClients.unreliable"].unreliable, true, "and it asked for unreliable")
		T.eq(server.Beef.Replicate.stats().links["Beef.toClients"].role, "Send")
	end)

	T.case("an unreliable stream splits a frame too big for one payload", function()
		local net, server, client = pair(function(Beef)
			local Note = Beef.Events.new("note", "who:u32", "text:string")
			return { Note = Note, map = { toClients = { { Note, channel = "unreliable" } } } }
		end)

		local text = string.rep("x", 100)
		for i = 1, 20 do
			server.Note.push(i, text)
		end
		server.wiring.pack()

		local stats = server.Beef.Replicate.stats()
		T.ok(stats.sent >= 3, "several payloads, got " .. tostring(stats.sent))
		T.eq(stats.oversize, 0, "none of them over the limit")
		for _, message in net.queue do
			T.ok(buffer.len(message.payload) <= 900, "a payload of " .. tostring(buffer.len(message.payload)) .. " bytes")
		end

		net.deliver()
		client.wiring.deliver()
		T.eq(client.Note.count, 20, "and every push still landed")
		T.eq(client.Note.who[20], 20)
		T.eq(client.Note.text[7], text)
	end)

	T.case("a reliable stream packs a frame into one payload however big it is", function()
		local net, server, client = pair(function(Beef)
			local Note = Beef.Events.new("note", "who:u32", "text:string")
			return { Note = Note, map = { toClients = { Note } } }
		end)

		local text = string.rep("x", 100)
		for i = 1, 20 do
			server.Note.push(i, text)
		end
		crosses(net, server, client)

		T.eq(server.Beef.Replicate.stats().sent, 1, "one payload")
		T.eq(client.Note.count, 20)
	end)

	T.case("a frame with nothing pushed sends nothing", function()
		local net, server, client = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32")
			return { Damage = Damage, map = { toClients = { Damage } } }
		end)

		crosses(net, server, client)
		T.eq(server.Beef.Replicate.stats().sent, 0, "quiet")
		T.eq(client.Damage.count, 0)
	end)

	T.case("only what was pushed since the last pack crosses", function()
		local net, server, client = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32")
			return { Damage = Damage, map = { toClients = { Damage } } }
		end)

		server.Damage.push(1)
		crosses(net, server, client)
		server.Beef.Events.lap()
		client.Beef.Events.lap()
		server.Damage.push(2)
		crosses(net, server, client)

		T.eq(server.Beef.Replicate.stats().pushesOut, 2, "one each frame, not one then two")
		T.eq(client.Damage.count, 2, "one push, then the other, never the first one twice")
		T.eq(client.Damage.who[1], 1)
		T.eq(client.Damage.who[2], 2)
	end)

	-- ------------------------------------------------------------------ toServer

	T.case("toServer runs the same stream the other way", function()
		local net, server, client = pair(function(Beef)
			local Input = Beef.Events.new("input", "action:u8", "value:f32")
			return { Input = Input, map = { toServer = { Input } } }
		end)

		client.Input.push(3, 0.5)
		crosses(net, client, server)

		T.eq(server.Input.count, 1, "the server read it")
		T.eq(server.Input.action[1], 3)
		T.eq(client.Beef.Replicate.stats().pushesOut, 1, "the client packed it")
		T.eq(server.Beef.Replicate.stats().pushesIn, 1)
		T.ok(net.links["Beef.toServer"] ~= nil, "its own link")
	end)

	T.case("both directions run at once off one table", function()
		local net, server, client = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32")
			local Input = Beef.Events.new("input", "action:u8")
			return { Damage = Damage, Input = Input, map = { toClients = { Damage }, toServer = { Input } } }
		end)

		server.Damage.push(9)
		client.Input.push(2)
		server.wiring.pack()
		client.wiring.pack()
		net.deliver()
		server.wiring.deliver()
		client.wiring.deliver()

		T.eq(client.Damage.count, 1, "down")
		T.eq(server.Input.count, 1, "up")
	end)

	-- ------------------------------------------------------------------ publish

	local function drops(Beef: any, isServer: boolean): any
		local Position = Beef.Components.new("position", { wire = "vector3" })
		local Origin = Beef.Components.new("origin", { index = true })
		local Drop = Beef.Kinds.new("drop", Position)
		return {
			Position = Position,
			Origin = Origin,
			Drop = Drop,
			isServer = isServer,
			map = { publish = { { Drop, Position, origin = Origin } } },
		}
	end

	T.case("a changed column crosses and lands on the entity carrying the sender's handle", function()
		local net, server, client = pair(drops)

		local handle = server.Drop.spawn(Vector3.new(0, 10, 0))
		local mine = client.Drop.spawn(Vector3.zero)
		client.Origin.add(client.Drop, client.Drop.at(mine), handle)

		net.clock = 1
		crosses(net, server, client)

		T.eq(client.Position.of(client.Drop).value[client.Drop.at(mine)].Y, 10, "the server's height")
		T.eq(client.Beef.Replicate.stats().applied, 1)
		T.eq(server.Beef.Replicate.stats().entities, 1)
	end)

	T.case("a column that did not change is not sent again", function()
		local net, server, client = pair(drops)

		local handle = server.Drop.spawn(Vector3.new(0, 10, 0))
		local mine = client.Drop.spawn(Vector3.zero)
		client.Origin.add(client.Drop, client.Drop.at(mine), handle)

		net.clock = 1
		crosses(net, server, client)
		local after = server.Beef.Replicate.stats().sent
		net.clock = 2
		crosses(net, server, client)
		T.eq(server.Beef.Replicate.stats().sent, after, "nothing moved, nothing sent")

		net.clock = 3
		server.Position.of(server.Drop).value[server.Drop.at(handle)] = Vector3.new(0, 4, 0)
		crosses(net, server, client)
		T.eq(server.Beef.Replicate.stats().sent, after + 1, "it moved, so it went")
		T.eq(client.Position.of(client.Drop).value[client.Drop.at(mine)].Y, 4)
	end)

	T.case("a value for an entity this side has not spawned yet is held, not dropped", function()
		local net, server, client = pair(drops)

		local handle = server.Drop.spawn(Vector3.new(0, 10, 0))
		net.clock = 1
		crosses(net, server, client)
		T.eq(client.Beef.Replicate.stats().waiting, 1, "held for an entity that is not here")
		T.eq(client.Beef.Replicate.stats().applied, 0)

		local mine = client.Drop.spawn(Vector3.zero)
		client.Origin.add(client.Drop, client.Drop.at(mine), handle)
		client.wiring.deliver()

		T.eq(client.Beef.Replicate.stats().waiting, 0, "and let go once it is")
		T.eq(client.Beef.Replicate.stats().applied, 1)
		T.eq(client.Position.of(client.Drop).value[client.Drop.at(mine)].Y, 10)
	end)

	T.case("a value stamped before one already seen is refused", function()
		local net, server, client = pair(drops)

		local handle = server.Drop.spawn(Vector3.new(0, 10, 0))
		local mine = client.Drop.spawn(Vector3.zero)
		client.Origin.add(client.Drop, client.Drop.at(mine), handle)

		net.clock = 10
		crosses(net, server, client)
		net.clock = 5
		server.Position.of(server.Drop).value[server.Drop.at(handle)] = Vector3.new(0, 99, 0)
		crosses(net, server, client)

		T.eq(client.Beef.Replicate.stats().refused, 1, "the late one")
		T.eq(client.Position.of(client.Drop).value[client.Drop.at(mine)].Y, 10, "and the height did not walk back")
	end)

	T.case("every option a publish entry takes is honoured", function()
		local net, server, client = pair(function(Beef, isServer)
			local made = drops(Beef, isServer)
			made.map = { publish = { { made.Drop, made.Position, every = 3, channel = "unreliable", keyframe = 2, chunk = 1, origin = made.Origin } } }
			return made
		end)

		T.eq(net.links["Beef.publish.drop.position"].unreliable, true, "on the unreliable link")

		local first = server.Drop.spawn(Vector3.new(0, 1, 0))
		local second = server.Drop.spawn(Vector3.new(0, 2, 0))
		local a = client.Drop.spawn(Vector3.zero)
		local b = client.Drop.spawn(Vector3.zero)
		client.Origin.add(client.Drop, client.Drop.at(a), first)
		client.Origin.add(client.Drop, client.Drop.at(b), second)

		net.clock = 1
		crosses(net, server, client)
		T.eq(server.Beef.Replicate.stats().sent, 0, "every = 3 holds the first two frames")
		crosses(net, server, client)
		T.eq(server.Beef.Replicate.stats().sent, 0)
		crosses(net, server, client)
		T.eq(server.Beef.Replicate.stats().sent, 2, "on the third, and chunk = 1 splits the two entities")
		T.eq(client.Position.of(client.Drop).value[client.Drop.at(b)].Y, 2)
	end)

	T.case("a keyframe resends a column nothing changed about", function()
		local net, server, client = pair(function(Beef, isServer)
			local made = drops(Beef, isServer)
			made.map = { publish = { { made.Drop, made.Position, channel = "unreliable", keyframe = 2, origin = made.Origin } } }
			return made
		end)

		local handle = server.Drop.spawn(Vector3.new(0, 10, 0))
		local mine = client.Drop.spawn(Vector3.zero)
		client.Origin.add(client.Drop, client.Drop.at(mine), handle)

		-- the first frame sends it because it changed, and the second is the keyframe, which sends it anyway
		net.clock = 1
		server.wiring.pack()
		net.deliver(function()
			return false
		end)
		T.eq(client.Position.of(client.Drop).value[client.Drop.at(mine)].Y, 0, "the first one was dropped")

		net.clock = 2
		crosses(net, server, client)
		T.eq(client.Position.of(client.Drop).value[client.Drop.at(mine)].Y, 10, "the keyframe put it right")
	end)

	T.case("someone who just arrived is sent every entity, changed or not", function()
		local net, server, client = pair(drops)

		local handle = server.Drop.spawn(Vector3.new(0, 10, 0))
		local mine = client.Drop.spawn(Vector3.zero)
		client.Origin.add(client.Drop, client.Drop.at(mine), handle)

		net.clock = 1
		crosses(net, server, client)
		net.clock = 2
		net.join("someone")
		server.wiring.pack()
		T.eq(#net.queue, 1, "a full sweep for them")
		T.eq(net.queue[1].to, "someone", "aimed at them and nobody else")
	end)

	T.case("a bare column names its kind when one kind carries it", function()
		local net, server, client = pair(function(Beef, isServer)
			local made = drops(Beef, isServer)
			made.map = { publish = { { made.Position, origin = made.Origin } } }
			return made
		end)

		local handle = server.Drop.spawn(Vector3.new(0, 7, 0))
		local mine = client.Drop.spawn(Vector3.zero)
		client.Origin.add(client.Drop, client.Drop.at(mine), handle)

		net.clock = 1
		crosses(net, server, client)
		T.ok(net.links["Beef.publish.drop.position"] ~= nil, "it found the drop")
		T.eq(client.Position.of(client.Drop).value[client.Drop.at(mine)].Y, 7)
	end)

	T.case("a bare column with two kinds carrying it asks the entry to name one", function()
		local Beef = T.load()
		local Position = Beef.Components.new("position", { wire = "vector3" })
		local Origin = Beef.Components.new("origin", { index = true })
		Beef.Kinds.new("drop", Position)
		Beef.Kinds.new("spark", Position)
		T.throws(function()
			Beef.Replicate({ publish = { { Position, origin = Origin } } })
		end, "name the kind first", "two kinds carry it")
	end)

	-- ------------------------------------------------------------------ what the table refuses

	T.case("an option the part does not take is named and refused", function()
		local Beef = T.load()
		local Damage = Beef.Events.new("damage", "who:u32")
		T.throws(function()
			Beef.Replicate({ toClients = { { Damage, window = 0.05 } } })
		end, "not an option here")
	end)

	T.case("a channel that is neither reliable nor unreliable is refused", function()
		local Beef = T.load()
		local Damage = Beef.Events.new("damage", "who:u32")
		T.throws(function()
			Beef.Replicate({ toClients = { { Damage, channel = "fast" } } })
		end, "reliable or unreliable")
	end)

	T.case("a key that is not part of the table is refused, and fleet says which ticket it is", function()
		local Beef = T.load()
		T.throws(function()
			Beef.Replicate({ toCleints = {} })
		end, "not a key of the boot table")

		local Other = T.load()
		T.throws(function()
			Other.Replicate({ fleet = { url = "https://relay.example/publish" } })
		end, "fleet is not built yet")
	end)

	T.case("a publish entry without an origin is refused", function()
		local Beef = T.load()
		local Position = Beef.Components.new("position", { wire = "vector3" })
		local Drop = Beef.Kinds.new("drop", Position)
		T.throws(function()
			Beef.Replicate({ publish = { { Drop, Position } } })
		end, "needs origin")
	end)

	T.case("an event type with a column that cannot cross is refused", function()
		local Beef = T.load()
		Beef.Replicate.driver(network().endpoint(true))
		local Loose = Beef.Events.new("loose", "who")
		T.throws(function()
			Beef.Replicate({ toClients = { Loose } })
		end, "no wire type")
	end)

	T.case("the boot table is given once and the driver is chosen before it", function()
		local Beef = T.load()
		local Damage = Beef.Events.new("damage", "who:u32")
		local net = network()
		Beef.Replicate.driver(net.endpoint(true))
		Beef.Replicate({ toClients = { Damage } })
		T.throws(function()
			Beef.Replicate({ toClients = { Damage } })
		end, "given once")
		T.throws(function()
			Beef.Replicate.driver(net.endpoint(true))
		end, "before the boot call")
	end)

	-- ------------------------------------------------------------------ stats

	T.case("stats reports what crossed, in total and per link", function()
		local net, server, client = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32")
			local Landing = Beef.Events.new("landing", "who:u32")
			return { Damage = Damage, Landing = Landing, map = { toClients = { Damage, { Landing, channel = "unreliable" } } } }
		end)

		server.Damage.push(1)
		server.Damage.push(2)
		server.Landing.push(3)
		crosses(net, server, client)

		local out = server.Beef.Replicate.stats()
		T.eq(out.sent, 2, "one payload a link")
		T.eq(out.pushesOut, 3)
		T.ok(out.bytesOut > 0, "bytes counted")
		T.eq(out.links["Beef.toClients"].pushes, 2)
		T.eq(out.links["Beef.toClients.unreliable"].pushes, 1)

		local into = client.Beef.Replicate.stats()
		T.eq(into.received, 2)
		T.eq(into.pushesIn, 3)
		T.eq(into.bytesIn, out.bytesOut, "the same bytes came out as went in")
		T.eq(into.links["Beef.toClients"].role, "Receive")
	end)

	T.case("the signal the edges hang off is the table's to name", function()
		local Beef = T.load()
		local net = network()
		Beef.Replicate.driver(net.endpoint(true))
		local Damage = Beef.Events.new("damage", "who:u32")
		local wiring = Beef.Replicate({ signal = "PreSimulation", toClients = { Damage } })
		T.eq(#wiring.controllers, 1, "booted on another signal all the same")
	end)

	T.case("the wiring hands back the controllers it made", function()
		local _, server, client = pair(function(Beef)
			local Damage = Beef.Events.new("damage", "who:u32")
			return { Damage = Damage, map = { toClients = { Damage } } }
		end)
		T.eq(#server.wiring.controllers, 1)
		T.eq(server.wiring.controllers[1].name, "Send")
		T.eq(client.wiring.controllers[1].name, "Receive")
	end)
end
