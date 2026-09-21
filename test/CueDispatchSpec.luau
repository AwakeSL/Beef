--!strict

local Fixture = require("../test/CueFixture")

return function(T: any)
	local fx = Fixture.game(T.load())
	local cue = fx.cue
	local world = fx.world

	T.case("firing reaches what subscribed, and nothing else", function()
		T.throws(function()
			cue:fire(fx.entity("x"), "Sneeze")
		end, "anchor nobody declared", "firing an undeclared anchor is a bug, loudly")

		T.eq(cue:fire(fx.entity("silent"), "Hit"), 0, "an entity with no set runs nothing")

		local dinger = cue:define({ events = {
			{ anchor = "Hit", { primitive = "sound", id = "ding" } },
		} }, "dinger")
		local bell = fx.entity("bell")
		cue:attach(bell, dinger)
		cue:fire(bell, "Hit")
		fx.frame()
		T.eq(#world.sounds, 1, "an attached subscription runs on fire")
		T.eq(world.sounds[1], "ding", "and it ran the authored effect")

		cue:fire(bell, "HitBody")
		fx.frame()
		T.eq(#world.sounds, 1, "an anchor it does not subscribe to runs nothing")
	end)

	T.case("a gate reads the firing", function()
		local marked = cue:define({ events = {
			{ anchor = "Hit", marker = "sweep", { primitive = "sound", id = "swept" } },
		} }, "marked")
		local blade = fx.entity("blade")
		cue:attach(blade, marked)
		cue:fire(blade, "Hit", { marker = "recovery" })
		fx.frame()
		T.eq(fx.sounds("swept"), 0, "a gate that does not match skips the subscription")
		cue:fire(blade, "Hit", { marker = "sweep" })
		fx.frame()
		T.eq(fx.sounds("swept"), 1, "a gate that matches lets it run")
	end)

	T.case("a bound anchor turns every push into a firing", function()
		local d = cue:define({ events = {
			{ anchor = "Hit", { primitive = "sound", id = "pushed" } },
			{ anchor = "Hit", marker = "sweep", { primitive = "sound", id = "pushedSweep" } },
		} }, "pushed")
		local bell = fx.entity("pushbell")
		cue:attach(bell, d)
		fx.Hit.push(bell)
		fx.Hit.push(bell, nil, nil, nil, "sweep")
		fx.frame()
		T.eq(fx.sounds("pushed"), 2, "two pushes on the anchor's event, two firings")
		T.eq(fx.sounds("pushedSweep"), 1, "and the columns beside self are the firing's context")
	end)

	T.case("an anchor list means any of", function()
		local both = cue:define({ events = {
			{ anchor = { "Hit", "HitBody" }, { primitive = "sound", id = "either" } },
		} }, "both")
		local club = fx.entity("club")
		cue:attach(club, both)
		cue:fire(club, "Hit")
		cue:fire(club, "HitBody")
		fx.frame()
		T.eq(fx.sounds("either"), 2, "an anchor list means any of")
	end)

	T.case("limit spends a subscription", function()
		local once = cue:define({ events = {
			{ anchor = "Impact", limit = 1, { primitive = "sound", id = "boom" } },
		} }, "grenade")
		local grenade = fx.entity("grenade")
		cue:attach(grenade, once)
		cue:fire(grenade, "Impact")
		cue:fire(grenade, "Impact")
		cue:fire(grenade, "Impact")
		fx.frame()
		T.eq(fx.sounds("boom"), 1, "limit = 1 fires exactly once and revokes itself")
		T.eq(fx.held(grenade), nil, "and the set walks back to empty")

		local thrice = cue:define({ events = {
			{ anchor = "Impact", limit = 3, { primitive = "sound", id = "tick" } },
		} }, "thrice")
		local clicker = fx.entity("clicker")
		cue:attach(clicker, thrice)
		for _ = 1, 5 do
			cue:fire(clicker, "Impact")
		end
		fx.frame()
		T.eq(fx.sounds("tick"), 3, "limit = 3 fires exactly three times across five firings")
	end)

	T.case("a set is a multiset", function()
		local charmDef = cue:define({ events = {
			{ anchor = "Hit", { primitive = "sound", id = "charm" } },
		} }, "charm")
		local wearer = fx.entity("wearer")
		local charmSub = cue.compiler:definition(charmDef).baseSetId
		local charmSubId = cue.intern:info(charmSub).entries[1].id
		cue:grantTo(wearer, charmSubId)
		cue:grantTo(wearer, charmSubId)
		cue:fire(wearer, "Hit")
		fx.frame()
		T.eq(fx.sounds("charm"), 2, "granted twice is held twice and fires twice")
		cue:revokeFrom(wearer, charmSubId)
		cue:fire(wearer, "Hit")
		fx.frame()
		T.eq(fx.sounds("charm"), 3, "revoking one leaves the other")
	end)

	T.case("ends removes a subscription the moment it holds", function()
		local ender = cue:define({ events = {
			{ anchor = "Hit", ends = "sated", { primitive = "sound", id = "thirsty" } },
		} }, "ender")
		local drinker = fx.entity("drinker")
		cue:attach(drinker, ender)
		cue:fire(drinker, "Hit")
		world.flags.sated = true
		cue:fire(drinker, "Hit")
		cue:fire(drinker, "Hit")
		fx.frame()
		T.eq(fx.sounds("thirsty"), 1, "ends removes the subscription the moment its condition holds")
		T.eq(fx.held(drinker), nil, "and the set is empty after")
	end)

	T.case("grant installs hooks at runtime", function()
		local bowDef = cue:define({ events = {
			{ anchor = "Release",
				{ primitive = "grant", to = "victim", context = "self",
					{ anchor = "HitBody", { primitive = "sound", id = "myArrowHit" } } } },
		} }, "bow")
		local bow = fx.entity("bow")
		local arrow = fx.entity("arrow")
		cue:attach(bow, bowDef)
		cue:fire(bow, "Release", { victim = arrow })
		local held = fx.held(arrow)
		T.ok(held ~= nil and held ~= 0, "grant installed a hook on the arrow at runtime")
		cue:fire(arrow, "HitBody")
		fx.frame()
		T.eq(world.sounds[#world.sounds], "myArrowHit", "the granted hook fires on the arrow's anchor")
		T.ok(cue:stats().intern.mintedSubs >= 1, "a context grant mints a wrapped sub")
	end)

	T.case("stats counts what fired and what never did", function()
		local s = cue:stats()
		T.ok(s.runner.fired.Hit ~= nil, "stats counts firings per anchor")

		local lonely = cue:define({ events = {
			{ anchor = "Equip", { primitive = "sound", id = "never" } },
		} }, "lonely")
		cue:attach(fx.entity("shelf"), lonely)
		local found = false
		for _, name in cue:stats().subscribedNeverFired :: { string } do
			if name == "Equip" then
				found = true
			end
		end
		T.ok(found, "an anchor with subscribers that has never fired is counted, not errored")
	end)
end
