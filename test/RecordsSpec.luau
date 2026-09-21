--!strict
-- Records headless: the lock, the load, the migrations, the shape, the timer, and two servers
-- over one key. Each server is its own Beef on the same world, and the clock only moves where a
-- case moves it.

return function(T)
	local function options(over: any?): any
		local shape = { coins = 0, settings = { music = 0.8 }, unlocked = {} }
		local base: any = { version = 1, shape = shape, save = 1, lock = 2 }
		for key, value in (over or {}) :: any do
			base[key] = value
		end
		return base
	end

	-- one server: its own Beef, its own driver, the same world as everyone else on it
	local function join(world: any, name: string, over: any?): (any, any, any)
		local Beef = T.load()
		local made = world or Beef.Records.world()
		Beef.Records.driver(Beef.Records.memory(made, name))
		local Profile = Beef.Records.new("profile", options(over))
		return made, Beef, Profile
	end

	local function stored(world: any, key: string): any
		local store = world.data.profile
		return if store then store[key] else nil
	end

	T.case("a new key starts as the shape and of is a plain table", function()
		local world, _, Profile = join(nil, "A")
		T.eq(Profile.of("1"), nil, "nothing is held yet")
		T.eq(Profile.held("1"), false, "and nothing is held")

		local record = Profile.load("1")
		T.eq(record.coins, 0, "coins")
		T.eq(record.settings.music, 0.8, "a table in the shape is copied, not shared")
		T.eq(type(record.unlocked), "table", "an open table")
		T.eq(Profile.of("1"), record, "of is the same table")
		T.eq(Profile.held("1"), true, "held")
		T.eq(Profile.loaded.count, 1, "loaded fired once")
		T.eq(Profile.loaded.key[1], "1", "with the key")
		T.eq(#Profile.keys(), 1, "one key held")
		T.eq(world.locks.profile["1"].server, "A", "and the lock is this server's")

		record.coins = 3
		T.eq(Profile.load("1").coins, 3, "a second load of a held key is the record it already has")
	end)

	T.case("a record survives release and load", function()
		local world, _, Profile = join(nil, "A")
		local record = Profile.load("1")
		record.coins = 12
		record.settings.music = 0.25
		record.unlocked = { "bow", "raft" }
		Profile.release("1")

		T.eq(Profile.of("1"), nil, "released")
		T.eq(Profile.held("1"), false, "and not held")
		T.eq(Profile.saved.count, 1, "release saved once")
		T.eq(world.locks.profile["1"], nil, "and let the lock go")

		local again = Profile.load("1")
		T.eq(again.coins, 12, "coins came back")
		T.eq(again.settings.music, 0.25, "and the nested table")
		T.eq(again.unlocked[2], "raft", "and the open one")
	end)

	T.case("the timer saves on its own", function()
		local world, Beef, Profile = join(nil, "A")
		local record = Profile.load("1")
		record.coins = 5

		Beef.Records.step()
		T.eq(Profile.saved.count, 0, "nothing is due yet")
		T.eq(stored(world, "1"), nil, "so nothing is down")

		world.advance(1.5)
		Beef.Records.step()
		T.eq(Profile.saved.count, 1, "the save came due")
		T.eq(stored(world, "1").data.coins, 5, "and went down")
		T.eq(stored(world, "1").version, 1, "stamped with the version")

		record.coins = 6
		Beef.Records.step()
		T.eq(Profile.saved.count, 1, "the timer waits again")
		world.advance(1.5)
		Beef.Records.step()
		T.eq(stored(world, "1").data.coins, 6, "then takes what is there")
	end)

	T.case("flush saves every held record", function()
		local world, Beef, Profile = join(nil, "A")
		Profile.load("1").coins = 1
		Profile.load("2").coins = 2
		Beef.Records.flush()
		T.eq(stored(world, "1").data.coins, 1, "one")
		T.eq(stored(world, "2").data.coins, 2, "two")
		T.eq(Profile.saved.count, 2, "saved fired for both")
	end)

	T.case("a second server picks a key up once the first lets go", function()
		local world, _, A = join(nil, "A")
		A.load("42").coins = 9
		A.release("42")

		local _, _, B = join(world, "B")
		T.eq(B.load("42").coins, 9, "B has what A left")
		T.eq(world.locks.profile["42"].server, "B", "and the lock")
	end)

	T.case("a key a live server holds is waited for and then refused", function()
		local world, keeper, A = join(nil, "A")
		A.load("42")
		local _, _, B = join(world, "B")
		-- while B waits, A is still up and keeps its lock alive
		world.onWait = function()
			keeper.Records.step()
		end

		local record = B.load("42")
		world.onWait = nil
		T.eq(record, nil, "B loaded nothing")
		T.eq(B.held("42"), false, "and holds nothing")
		T.eq(B.failed.count, 1, "failed fired once")
		T.ok(B.failed.why[1]:find("held by A"), "the reason names the holder: " .. tostring(B.failed.why[1]))
		T.eq(world.locks.profile["42"].server, "A", "and A still has the lock")
	end)

	T.case("a lock that lapses lets the next server in with the last save", function()
		local world, keeper, A = join(nil, "A")
		A.load("42").coins = 7
		world.advance(1.5)
		keeper.Records.step()
		T.eq(A.saved.count, 1, "A saved before it went")

		-- A dies here: it stops stepping, so its lock stops being refreshed and runs out
		world.advance(40)

		local _, _, B = join(world, "B")
		local record = B.load("42")
		T.ok(record ~= nil, "B got in")
		T.eq(record.coins, 7, "with what A last saved")
		T.eq(B.failed.count, 0, "and nothing failed")
	end)

	T.case("a lost lock makes the copy read-only and fires lost once", function()
		local world, keeper, A = join(nil, "A")
		A.load("42").coins = 7
		world.advance(1.5)
		keeper.Records.step()
		world.advance(40)
		local _, _, B = join(world, "B")
		B.load("42")

		keeper.Records.step()
		T.eq(A.lost.count, 1, "lost fired")
		T.eq(A.lost.key[1], "42", "for the key")
		T.eq(A.held("42"), false, "A no longer holds it")
		T.ok(A.of("42") ~= nil, "but the copy is still readable")

		A.of("42").coins = 999
		T.eq(A.save("42"), false, "a save is refused")
		world.advance(10)
		keeper.Records.step()
		T.eq(A.lost.count, 1, "lost fires once, not every turn")
		T.eq(stored(world, "42").data.coins, 7, "and nothing of A's reached the store")

		A.release("42")
		T.eq(stored(world, "42").data.coins, 7, "not even on the way out")
		T.eq(world.locks.profile["42"].server, "B", "and B keeps the lock")
	end)

	T.case("migrations run in order from the stored version", function()
		local world = T.load().Records.world()
		world.data.profile = { ["1"] = { version = 1, at = 0, data = { coins = 4 } } }
		local order = {}
		local _, _, Profile = join(world, "A", {
			version = 3,
			migrate = {
				[2] = function(record: any)
					table.insert(order, 2)
					record.settings = { music = 0.8 }
				end,
				[3] = function(record: any)
					table.insert(order, 3)
					record.unlocked = {}
				end,
			},
		})

		local record = Profile.load("1")
		T.ok(record ~= nil, "loaded: " .. tostring(Profile.failed.why[1]))
		T.eq(record.coins, 4, "what was there stayed")
		T.eq(record.settings.music, 0.8, "what version 2 added")
		T.eq(#order, 2, "two steps ran")
		T.eq(order[1], 2, "the older one first")

		Profile.save("1")
		T.eq(stored(world, "1").version, 3, "and it goes down at the version the code knows")
	end)

	T.case("stored data newer than the code refuses to load", function()
		local world = T.load().Records.world()
		world.data.profile = { ["1"] = { version = 9, at = 0, data = { coins = 4 } } }
		local _, _, Profile = join(world, "A")

		T.eq(Profile.load("1"), nil, "nothing loaded")
		T.eq(Profile.failed.count, 1, "failed fired")
		T.ok(Profile.failed.why[1]:find("version 9"), "and says why: " .. tostring(Profile.failed.why[1]))
		T.eq(world.locks.profile["1"], nil, "the lock was handed back")
		T.eq(stored(world, "1").data.coins, 4, "and what was there is untouched")
	end)

	T.case("a load that fails fires failed and holds nothing", function()
		local world, _, Profile = join(nil, "A")
		world.faults["1"] = "the store is not answering"

		T.eq(Profile.load("1"), nil, "nothing loaded")
		T.eq(Profile.held("1"), false, "nothing held")
		T.eq(Profile.loaded.count, 0, "loaded did not fire")
		T.eq(Profile.failed.count, 1, "failed did")
		T.ok(Profile.failed.why[1]:find("not answering"), "with the reason")
		T.eq(world.locks.profile["1"], nil, "and the lock went back")
	end)

	T.case("a record that does not match its shape is not saved", function()
		local world, _, Profile = join(nil, "A")
		local record = Profile.load("1")
		record.coins = "lots"

		T.eq(Profile.save("1"), false, "refused")
		T.eq(stored(world, "1"), nil, "nothing went down")
		T.eq(Profile.failed.count, 1, "failed fired")
		T.ok(Profile.failed.why[1]:find("coins"), "naming the field: " .. tostring(Profile.failed.why[1]))

		record.coins = 1
		record.gold = 3
		T.eq(Profile.save("1"), false, "a field the shape does not name is refused too")
		record.gold = nil
		record.unlocked = { [1] = "bow", [3] = "raft" }
		T.eq(Profile.save("1"), false, "and a list with holes in it")
		record.unlocked = { "bow" }
		T.eq(Profile.save("1"), true, "put right, it saves")
	end)

	T.case("Roblox datatypes go down as numbers and come back", function()
		local datatypes = { shape = { spot = Vector3.new(0, 0, 0), tint = Color3.new(0, 0, 0), pose = CFrame.new() } }
		local world, _, A = join(nil, "A", datatypes)
		local record = A.load("1")
		record.spot = Vector3.new(1, 2, 3)
		record.tint = Color3.new(0.25, 0.5, 1)
		record.pose = CFrame.new(4, 5, 6)
		A.release("1")

		local function leaves(value: any, path: string)
			if type(value) == "table" then
				for key, inner in value do
					leaves(inner, path .. "." .. tostring(key))
				end
				return
			end
			local kind = type(value)
			T.ok(kind == "number" or kind == "string" or kind == "boolean", path .. " went down as a " .. kind)
		end
		leaves(stored(world, "1"), "stored")
		T.eq(stored(world, "1").data.spot["$"], "vector3", "a vector3 is named where it lies")
		T.eq(stored(world, "1").data.spot.n[1], 1, "and is numbers")

		local _, _, B = join(world, "B", datatypes)
		local back = B.load("1")
		T.ok(back ~= nil, "it loaded: " .. tostring(B.failed.why[1]))
		T.eq(typeof(back.spot), "Vector3", "it came back a Vector3")
		T.eq(back.spot.Y, 2, "with its numbers")
		T.eq(typeof(back.tint), "Color3", "and a Color3")
		T.ok(math.abs(back.tint.B - 1) < 1e-6, "with its channels")
		T.eq(typeof(back.pose), "CFrame", "and a CFrame")
		T.eq(back.pose.Position.Z, 6, "with its position")
	end)

	T.case("a controller reads the lifecycle events in its loop", function()
		local _, Beef, Profile = join(nil, "A")
		local seen: { string } = {}
		local function Watch(loaded: any)
			return {
				name = "Watch",
				reads = { loaded },
				loop = function()
					for i = loaded.from, loaded.last do
						table.insert(seen, loaded.key[i])
					end
				end,
			}
		end
		local phase = Beef.Phase.new("Records", { { Watch, Profile.loaded } })

		Profile.load("1")
		Profile.load("2")
		Beef.Events.lap()
		phase.run()
		T.eq(#seen, 2, "both loads arrived as pushes")
		T.eq(seen[1], "1", "in order")

		phase.run()
		T.eq(#seen, 2, "and a pass with nothing new reads nothing")
	end)

	T.case("a shape that cannot be stored is refused where it is declared", function()
		local Beef = T.load()
		Beef.Records.driver(Beef.Records.memory(nil, "A"))
		T.throws(function()
			Beef.Records.new("bad", { version = 1, shape = { at = function() end } })
		end, "does not store", "a function in the shape")
		T.throws(function()
			Beef.Records.new("worse", { version = 1, shape = { tag = { ["$"] = "mine" } } })
		end, "keeps for packed values", "the key Beef packs with")
		T.throws(function()
			Beef.Records.new("older", { version = 2, shape = { coins = 0 }, migrate = { [7] = function() end } })
		end, "outside 2 to 2", "a migration for a version that is not there")
	end)

	T.case("players wires the player signals", function()
		local _, Beef, Profile = join(nil, "A")
		Beef.Records.players(Profile)
		T.eq(Profile.failed.count, 0, "nothing failed on the way")
	end)
end
