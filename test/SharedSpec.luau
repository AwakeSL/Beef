--!strict
-- Beef.Shared under Lune: the table driver stands in for MemoryStore and the test holds its
-- clock, so a poll, a TTL, a held call and a throttle all land where the case puts them. Two
-- Beefs on one driver are two servers on one memory store.

local function rig(T: any): (any, any)
	local Beef = T.load()
	local mem = Beef.Shared.tables()
	Beef.Shared.driver(mem)
	return Beef, mem
end

return function(T)
	T.case("a structure declares its events over the fields it was given", function()
		local Beef, _ = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 3600, poll = 5 })
		local Lobby = Beef.Shared.queue("lobby", { fields = { "userId:u64", "rating:u16" }, ttl = 300, poll = 1 })
		local Auction = Beef.Shared.map("auction", { fields = { "price:u32", "holder:u64" }, ttl = 600, poll = 2 })

		T.eq(Ranks.changed.name, "ranks.changed")
		T.eq(table.concat(Ranks.changed.columns, ","), "key,value")
		T.eq(Ranks.changed.wire.value, "u32")
		T.eq(table.concat(Ranks.removed.columns, ","), "key")
		T.eq(table.concat(Lobby.received.columns, ","), "id,userId,rating")
		T.eq(Lobby.received.wire.userId, "u64")
		T.eq(table.concat(Auction.changed.columns, ","), "key,price,holder")
		T.eq(Auction.changed.wire.holder, "u64")
	end)

	T.case("a field is a wire column a memory store can hold", function()
		local Beef, _ = rig(T)
		T.throws(function()
			Beef.Shared.sorted("a", { value = "u128", ttl = 60 })
		end, "not a wire type")
		T.throws(function()
			Beef.Shared.sorted("b", { value = "vector3", ttl = 60 })
		end, "cannot go in a memory store")
		T.throws(function()
			Beef.Shared.queue("c", { fields = { "userId" }, ttl = 60 })
		end, "needs a wire type")
		T.throws(function()
			Beef.Shared.map("d", { fields = { "at:cframe" }, ttl = 60 })
		end, "not a wire type")
	end)

	T.case("a ttl is required, bounded, and a name is declared once", function()
		local Beef, _ = rig(T)
		T.throws(function()
			Beef.Shared.sorted("a", { value = "u32" })
		end, "needs a ttl")
		T.throws(function()
			Beef.Shared.sorted("b", { value = "u32", ttl = 4000000 })
		end, "at most")
		Beef.Shared.sorted("twice", { value = "u32", ttl = 60 })
		T.throws(function()
			Beef.Shared.map("twice", { fields = { "price:u32" }, ttl = 60 })
		end, "declared twice")
	end)

	T.case("headless, a structure declared with no driver in says so", function()
		local Beef = T.load()
		T.throws(function()
			Beef.Shared.sorted("ranks", { value = "u32", ttl = 60 })
		end, "no driver")
	end)

	T.case("nothing reaches the service from the caller's thread", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 5, count = 8 })
		Ranks.set("zoe", 40)
		T.eq(mem.sizeOf("ranks"), 0, "the set is waiting on the pump")
		T.eq(Beef.Shared.stats().held, 1, "and it is counted as waiting")
		mem.advance(0.2)
		T.eq(mem.sizeOf("ranks"), 1, "the pump made the call")
		T.eq(Beef.Shared.stats().held, 0)
	end)

	T.case("a set this server made is announced when it lands", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 5, count = 8 })
		Ranks.set("zoe", 40)
		mem.advance(0.2)
		T.eq(Ranks.changed.count, 1)
		T.eq(Ranks.changed.key[1], "zoe")
		T.eq(Ranks.changed.value[1], 40)
		T.eq(Ranks.get("zoe"), 40, "and the mirror holds it")

		-- the poll finds nothing new in what this server already knows
		mem.advance(5.5)
		T.eq(Ranks.changed.count, 1)
	end)

	T.case("another server's set arrives at the next poll", function()
		local one = T.load()
		local two = T.load()
		local mem = one.Shared.tables()
		one.Shared.driver(mem)
		two.Shared.driver(mem)
		local here = one.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 5, count = 8 })
		local there = two.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 5, count = 8 })

		here.set("zoe", 40)
		mem.advance(0.3)
		T.eq(here.changed.count, 1, "the server that set it hears at once")
		T.eq(there.changed.count, 0, "the other one has not polled")

		mem.advance(5)
		T.eq(there.changed.count, 1, "and hears it on the poll")
		T.eq(there.changed.key[1], "zoe")
		T.eq(there.changed.value[1], 40)
		T.eq(there.get("zoe"), 40)
	end)

	T.case("a value gone at its ttl is a removal", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 3, poll = 1, count = 8 })
		Ranks.set("zoe", 40)
		mem.advance(0.2)
		T.eq(mem.sizeOf("ranks"), 1)
		mem.advance(2.9)
		T.eq(Ranks.removed.count, 0, "still inside the ttl")
		mem.advance(1.2)
		T.eq(mem.sizeOf("ranks"), 0, "gone from the store")
		T.eq(Ranks.removed.count, 1)
		T.eq(Ranks.removed.key[1], "zoe")
		T.eq(Ranks.get("zoe"), nil, "and gone from the mirror")
	end)

	T.case("a key this server removed is a removal too", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 5, count = 8 })
		Ranks.set("zoe", 40)
		mem.advance(0.2)
		Ranks.remove("zoe")
		mem.advance(0.2)
		T.eq(Ranks.removed.count, 1)
		T.eq(Ranks.removed.key[1], "zoe")
		T.eq(mem.sizeOf("ranks"), 0)
	end)

	T.case("a controller reads the ladder over the columns in its loop", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 5, count = 8 })

		local best, top = "", 0
		local walked = 0
		local function Ladder(changed)
			return {
				name = "Ladder",
				reads = { changed },
				loop = function()
					for i = changed.from, changed.last do
						walked += 1
						if changed.value[i] > top then
							best, top = changed.key[i], changed.value[i]
						end
					end
				end,
			}
		end
		local phase = Beef.Phase.new("Ladder", { { Ladder, Ranks.changed } })

		Ranks.set("zoe", 40)
		Ranks.set("ada", 70)
		Ranks.set("ben", 10)
		mem.advance(0.2)
		phase.run()
		T.eq(walked, 3, "one push a set")
		T.eq(best, "ada")
		T.eq(top, 70)

		Beef.Events.lap()
		phase.run()
		T.eq(walked, 3, "nothing new to walk")
	end)

	T.case("range reads the last window and spends nothing", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 1, count = 8 })
		for name, score in { zoe = 40, ada = 70, ben = 10, cid = 55 } do
			Ranks.set(name, score)
		end
		mem.advance(1.2)

		local before = Beef.Shared.stats().spent
		local top = Ranks.range(nil, nil, 2)
		T.eq(Beef.Shared.stats().spent, before, "reading the window costs nothing")
		T.eq(#top, 2)
		T.eq(top[1].key, "ada", "the highest first")
		T.eq(top[1].value, 70)
		T.eq(top[2].key, "cid")

		local middle = Ranks.range(20, 60)
		T.eq(#middle, 2)
		T.eq(middle[1].key, "cid")
		T.eq(middle[2].key, "zoe")
	end)

	T.case("a queue push reaches every server that reads it", function()
		local Beef, mem = rig(T)
		local Lobby = Beef.Shared.queue("lobby", {
			fields = { "userId:u64", "rating:u16" },
			ttl = 300,
			poll = 1,
			count = 4,
			invisibility = 30,
		})
		Lobby.add(8123456789, 1200)
		mem.advance(0.2)
		T.eq(mem.sizeOf("lobby"), 1)

		mem.advance(1)
		T.eq(Lobby.received.count, 1)
		T.eq(Lobby.received.userId[1], 8123456789, "a user id past what u32 holds")
		T.eq(Lobby.received.rating[1], 1200)

		Lobby.remove(Lobby.received.id[1])
		mem.advance(0.2)
		T.eq(mem.sizeOf("lobby"), 0, "the batch the id names is accepted")
	end)

	T.case("a queue push nobody removes comes round again", function()
		local Beef, mem = rig(T)
		local Lobby = Beef.Shared.queue("lobby", {
			fields = { "userId:u64" },
			ttl = 300,
			poll = 1,
			count = 4,
			invisibility = 3,
		})
		Lobby.add(7)
		mem.advance(1.3)
		T.eq(Lobby.received.count, 1)
		mem.advance(1.5)
		T.eq(Lobby.received.count, 1, "hidden while the invisibility window runs")
		mem.advance(2.5)
		T.eq(Lobby.received.count, 2, "and offered again when it ends")
		T.eq(Lobby.received.userId[2], 7)
	end)

	T.case("a map carries typed fields and an update transforms them", function()
		local Beef, mem = rig(T)
		local Auction = Beef.Shared.map("auction", { fields = { "price:u32", "holder:u64" }, ttl = 600, poll = 2, count = 8 })

		Auction.set("sword", 100, 42)
		mem.advance(0.2)
		local price, holder = Auction.get("sword")
		T.eq(price, 100)
		T.eq(holder, 42)
		T.eq(Auction.changed.count, 1)
		T.eq(Auction.changed.key[1], "sword")
		T.eq(Auction.changed.price[1], 100)
		T.eq(Auction.changed.holder[1], 42)

		Auction.update("sword", function(was, who)
			return was + 50, who
		end)
		mem.advance(0.2)
		T.eq(Auction.get("sword"), 150)
		T.eq(Auction.changed.count, 2)
		T.eq(Auction.changed.price[2], 150)

		-- an update that answers with nothing leaves the key as it was
		Auction.update("sword", function() end)
		mem.advance(0.2)
		T.eq(Auction.get("sword"), 150)
		T.eq(Auction.changed.count, 2)

		Auction.remove("sword")
		mem.advance(0.2)
		T.eq(Auction.removed.count, 1)
		T.eq(Auction.removed.key[1], "sword")
		T.eq(Auction.get("sword"), nil)
	end)

	T.case("an update on a key nothing holds starts from nothing", function()
		local Beef, mem = rig(T)
		local Auction = Beef.Shared.map("auction", { fields = { "price:u32", "holder:u64" }, ttl = 600, poll = 2, count = 8 })
		Auction.update("shield", function(was, who)
			T.eq(was, nil)
			T.eq(who, nil)
			return 5, 1
		end)
		mem.advance(0.2)
		T.eq(Auction.get("shield"), 5)
		T.eq(Auction.changed.count, 1)
	end)

	T.case("request units are counted the way the service charges", function()
		local Beef, mem = rig(T)
		local Auction = Beef.Shared.map("auction", { fields = { "price:u32" }, ttl = 600, poll = 100, count = 8 })
		Auction.set("a", 1)
		Auction.set("b", 2)
		mem.advance(0.2)
		T.eq(Beef.Shared.stats().spent, 2, "a set is one unit")

		Auction.update("a", function(was)
			return was + 1
		end)
		mem.advance(0.2)
		T.eq(Beef.Shared.stats().spent, 4, "an update is two")

		-- a listing reserves the count it asked for and corrects to the items it found plus one
		-- for the partitions it walked
		Auction.refresh()
		mem.advance(0.2)
		T.eq(Beef.Shared.stats().spent, 7)
		T.eq(Beef.Shared.stats().units, 7, "all of it inside the minute")
	end)

	T.case("the budget is the quota Roblox gives, per player", function()
		local Beef, mem = rig(T)
		T.eq(Beef.Shared.stats().budget, 1000, "an empty server")
		mem.playing(10)
		T.eq(Beef.Shared.stats().budget, 2200, "a thousand and a hundred and twenty each")
	end)

	T.case("a call over budget is held, and goes when the minute makes room", function()
		local Beef = T.load()
		Beef.Shared.budget({ base = 4, per = 0 })
		local mem = Beef.Shared.tables()
		Beef.Shared.driver(mem)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 1000, count = 2 })

		for i = 1, 6 do
			Ranks.set("k" .. i, i)
		end
		mem.advance(0.3)
		local held = Beef.Shared.stats()
		T.eq(held.calls, 4, "the budget stopped the fifth")
		T.eq(held.units, 4)
		T.eq(held.held, 2)
		T.eq(mem.sizeOf("ranks"), 4)

		mem.advance(61)
		local after = Beef.Shared.stats()
		T.eq(after.held, 0, "the minute rolled and the rest went")
		T.eq(after.calls, 6)
		T.eq(after.failed, 0, "nothing was dropped")
		T.eq(mem.sizeOf("ranks"), 6)
	end)

	T.case("a call the service throws at is tried again", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 1000, count = 8 })
		mem.refuse(1)
		Ranks.set("zoe", 40)
		mem.advance(0.15)
		local first = Beef.Shared.stats()
		T.eq(first.throttled, 1)
		T.eq(first.held, 1, "back on the head of the queue")
		T.eq(mem.sizeOf("ranks"), 0)

		mem.advance(0.2)
		T.eq(Beef.Shared.stats().held, 0)
		T.eq(Beef.Shared.stats().failed, 0)
		T.eq(Ranks.get("zoe"), 40)
	end)

	T.case("a call that keeps throwing is given up on and counted", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 1000, count = 8 })
		mem.refuse(9)
		Ranks.set("zoe", 40)
		Ranks.set("ada", 70)
		mem.advance(1)
		local s = Beef.Shared.stats()
		T.eq(s.failed, 2, "three tries each, then counted")
		T.eq(s.throttled, 6)
		T.eq(s.held, 0, "and out of the way of what comes next")
	end)

	T.case("a held call keeps its place in the order", function()
		local Beef = T.load()
		Beef.Shared.budget({ base = 2, per = 0 })
		local mem = Beef.Shared.tables()
		Beef.Shared.driver(mem)
		local Auction = Beef.Shared.map("auction", { fields = { "price:u32" }, ttl = 600, poll = 1000, count = 2 })

		Auction.set("sword", 1)
		Auction.set("sword", 2)
		Auction.set("sword", 3)
		mem.advance(0.3)
		T.eq(Auction.get("sword"), 2, "two went, the third is waiting")
		mem.advance(61)
		T.eq(Auction.get("sword"), 3, "and it lands last, as it was made")
	end)

	T.case("a new driver is a new world", function()
		local Beef, mem = rig(T)
		local Ranks = Beef.Shared.sorted("ranks", { value = "u32", ttl = 600, poll = 5, count = 8 })
		Ranks.set("zoe", 40)
		mem.advance(0.2)
		T.eq(Ranks.get("zoe"), 40)

		local fresh = Beef.Shared.tables()
		Beef.Shared.driver(fresh)
		T.eq(Ranks.get("zoe"), nil, "the mirror was emptied with the swap")
		T.eq(Beef.Shared.stats().calls, 0)
		Ranks.set("ada", 70)
		fresh.advance(0.2)
		T.eq(fresh.sizeOf("ranks"), 1, "and writes go to the new one")
		T.eq(mem.sizeOf("ranks"), 1, "the old one is left as it was")
	end)

	T.case("a push takes the fields that were declared, and none of them nil", function()
		local Beef, mem = rig(T)
		local Lobby = Beef.Shared.queue("lobby", { fields = { "userId:u64", "rating:u16" }, ttl = 300, poll = 1000 })
		T.throws(function()
			Lobby.add(7)
		end, "takes userId:u64, rating:u16, got 1")
		T.throws(function()
			Lobby.add(7, nil)
		end, "rating:u16 is nil")

		local Auction = Beef.Shared.map("auction", { fields = { "price:u32" }, ttl = 600, poll = 1000 })
		T.throws(function()
			Auction.set("sword", 1, 2)
		end, "got 2")
		T.throws(function()
			Auction.set("", 1)
		end, "a key is a string")
		T.throws(function()
			Auction.set(("k"):rep(129), 1)
		end, "at most 128 characters")

		-- an update that answers with the wrong width is the same mistake, found where it runs
		Auction.set("sword", 1)
		Auction.update("sword", function(was)
			return was, was
		end)
		mem.advance(1)
		T.eq(Beef.Shared.stats().failed, 1, "given up on and counted")
		T.eq(Auction.get("sword"), 1, "the key is as it was")
	end)

	T.case("Wire packs a u64 round trip", function()
		local Wire = T.module("Wire")
		T.ok(Wire.known("u64"))
		T.eq(Wire.sizeOf("u64", nil), 8)
		local b = buffer.create(8)
		Wire.write.u64(b, 0, 8123456789)
		T.eq(Wire.read.u64(b, 0), 8123456789)
	end)
end
