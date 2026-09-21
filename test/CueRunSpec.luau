--!strict

local Fixture = require("../test/CueFixture")

return function(T: any)
	local fx = Fixture.game(T.load())
	local cue = fx.cue
	local world = fx.world

	T.case("run dispatches a definition without attaching it", function()
		local def = cue:define({ events = {
			{ anchor = "Hit", { primitive = "sound", id = "ding" } },
			{ anchor = "Hit", marker = "sweep", { primitive = "sound", id = "swept" } },
		} }, "runnable")
		local blade = fx.entity("blade")

		T.eq(cue:run(def, "Hit", nil, nil, blade), 1, "run dispatches a definition without attaching")
		fx.frame()
		T.eq(world.sounds[1], "ding", "and its effects ran")
		T.eq(fx.held(blade), nil, "the self entity was not subscribed to anything")
		T.eq(cue:run(def, "Hit", { marker = "sweep" }, nil, blade), 2, "gates read the run's data")
		T.eq(cue:run(def, "Unequip", nil, nil, blade), 0, "an anchor the definition lacks runs nothing")
		T.throws(function()
			cue:run(def, "Sneeze", nil, nil, blade)
		end, "anchor nobody declared", "an undeclared anchor is loud on run too")
		fx.frame()
	end)

	T.case("self and the scope resolve on a run", function()
		local damaging = cue:define({ events = {
			{ anchor = "Hit", { primitive = "hurt", to = "victim", damage = "self.damage" } },
		} }, "selfReads")
		local sword = fx.entity("sword", { damage = 7 })
		local victim = fx.entity("victim", { hp = 20 })
		cue:run(damaging, "Hit", { victim = victim }, nil, sword)
		fx.frame()
		T.eq(fx.get(victim, fx.Hp), 13, "self on a run binds to the asSelf entity")

		local scoped = cue:define({ events = {
			{ anchor = "Hit", { primitive = "hurt", to = "victim", damage = { "charge:draw", times = 10 } } },
		} }, "scopeReads")
		cue:run(scoped, "Hit", { victim = victim }, { ["charge:draw"] = 0.5 }, sword)
		fx.frame()
		T.eq(fx.get(victim, fx.Hp), 8, "run resolves bindings from the scope table")
	end)

	T.case("attach and detach are a multiset", function()
		local attached = cue:define({ events = {
			{ anchor = "Hit", { primitive = "sound", id = "worn" } },
		} }, "worn")
		local body = fx.entity("body")
		cue:attach(body, attached)
		T.eq(cue:responds(body, "Hit"), true, "responds sees a subscribed anchor")
		T.eq(cue:responds(body, "Unequip"), false, "and not an absent one")
		T.eq(cue:responds(fx.entity("bare"), "Hit"), false, "an entity with no set responds to nothing")

		cue:detach(body, attached)
		T.eq(cue:responds(body, "Hit"), false, "detach removes what attach added")
		cue:attach(body, attached)
		cue:attach(body, attached)
		cue:detach(body, attached)
		T.eq(cue:responds(body, "Hit"), true, "detach removes one attach's worth, multiset-style")
		cue:detach(body, attached)
	end)

	T.case("a granted hook dies with the entity it runs as", function()
		local granter = fx.entity("granter")
		local wearer = fx.entity("wearer")
		local grantDef = cue:define({ events = {
			{ anchor = "Equip",
				{ primitive = "grant", to = "victim", context = "self",
					{ anchor = "Hit", { primitive = "sound", id = "granted" } } } },
		} }, "granting")
		cue:attach(granter, grantDef)
		cue:fire(granter, "Equip", { victim = wearer })
		fx.frame()
		local before = fx.sounds("granted")
		cue:fire(wearer, "Hit")
		fx.frame()
		T.eq(fx.sounds("granted"), before + 1, "the granted hook runs while its context entity lives")
		fx.kill(granter)
		cue:fire(wearer, "Hit")
		fx.frame()
		T.eq(fx.sounds("granted"), before + 1, "a granted hook with a dead context entity is dropped, not run")
		T.eq(cue.runner.stats.deadContextDrops, 1, "and counted")
		T.eq(cue:responds(wearer, "Hit"), false, "the dead grant was torn out of the wearer's set")
	end)
end
