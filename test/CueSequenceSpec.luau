--!strict

local Fixture = require("../test/CueFixture")

return function(T: any)
	local fx = Fixture.game(T.load())
	local cue = fx.cue
	local world = fx.world

	T.case("a chain stops at the first refusal", function()
		local act = cue:define({ events = {
			{ anchor = "Begin",
				{ sequence = {
					{ primitive = "occupy", to = "self" },
					{ primitive = "spend", to = "self", stamina = 3,
						otherwise = { { primitive = "sound", id = "wheeze" } } },
					{ primitive = "sound", id = "go" },
				} } },
		} }, "act")
		local body = fx.entity("body", { stamina = 10 })
		cue:attach(body, act)

		cue:fire(body, "Begin")
		fx.frame()
		T.eq(world.sounds[1], "go", "a sequence runs to its end when every step grants")
		T.eq(fx.get(body, fx.Stamina), 7, "and the paid step paid")

		world.flags.bodyBusy = false
		fx.set(body, fx.Stamina, 1)
		cue:fire(body, "Begin")
		fx.frame()
		T.eq(world.sounds[2], "wheeze", "a refused step runs its otherwise")
		T.eq(#world.sounds, 2, "and the sequence stops: no go after a refusal")
		T.eq(fx.get(body, fx.Stamina), 1, "the refused spend took nothing")

		world.flags.bodyBusy = true
		fx.set(body, fx.Stamina, 10)
		cue:fire(body, "Begin")
		fx.frame()
		T.eq(#world.sounds, 2, "a refusal at step one runs nothing further")
		T.eq(fx.get(body, fx.Stamina), 10, "and later steps never paid")
		world.flags.bodyBusy = false
	end)

	T.case("a bare list inside steps is a group", function()
		local grouped = cue:define({ events = {
			{ anchor = "Begin",
				{ sequence = {
					{ primitive = "occupy", to = "self" },
					{
						{ primitive = "sound", id = "clang" },
						{ primitive = "sound", id = "flash" },
					},
					{ primitive = "sound", id = "done" },
				} } },
		} }, "grouped")
		local dancer = fx.entity("dancer")
		cue:attach(dancer, grouped)
		cue:fire(dancer, "Begin")
		fx.frame()
		T.eq(world.sounds[3], "clang", "a bare list inside steps is a group")
		T.eq(world.sounds[4], "flash", "and everything in it runs")
		T.eq(world.sounds[5], "done", "a group member failing stops nothing, and the chain continues")
		world.flags.bodyBusy = false
	end)

	T.case("a step binds its result for the steps after it", function()
		local drawDef = cue:define({ events = {
			{ anchor = "Begin",
				{ sequence = {
					{ primitive = "take", to = "self", ammo = "arrow", as = "shaft",
						otherwise = { { primitive = "sound", id = "quiver_empty" } } },
					{ primitive = "charge", minMs = 180, maxMs = 900, as = "draw",
						otherwise = { { primitive = "sound", id = "tap" } } },
					{ primitive = "launch", to = "take:shaft", at = { place = { y = 10 } },
						speed = { 40, { "charge:draw", times = 90 } } },
				} } },
		} }, "draw")
		local archer = fx.entity("archer")
		local arrowA = fx.entity("arrowA", { damage = 6 })
		table.insert(fx.quiver(archer), arrowA)
		cue:attach(archer, drawDef)

		world.flags.chargeHeldMs = 540
		cue:fire(archer, "Begin")
		fx.frame()
		T.eq(#world.launches, 1, "the chain drew, charged and loosed")
		T.eq(world.launches[1].what, arrowA, "to = take:shaft names the entity the step bound")
		T.eq(world.launches[1].speed, 85, "speed = 40 + draw x 90 at half charge")
		T.eq(world.launches[1].at, Vector3.new(0, 10, 0), "the place constructor reached the primitive")

		cue:fire(archer, "Begin")
		fx.frame()
		T.eq(world.sounds[#world.sounds], "quiver_empty", "an empty quiver refuses on ammo")
		T.eq(#world.launches, 1, "and nothing flew")

		table.insert(fx.quiver(archer), fx.entity("arrowB"))
		world.flags.chargeHeldMs = 90
		cue:fire(archer, "Begin")
		fx.frame()
		T.eq(world.sounds[#world.sounds], "tap", "under minMs there is no value, and the charge refuses")
		T.eq(#world.launches, 1, "a tap looses nothing, never a slow arrow")
	end)

	T.case("because routes the right branch", function()
		local branching = cue:define({ events = {
			{ anchor = "Begin",
				{ primitive = "launch", to = "take:shaft", at = "origin", speed = 10,
					otherwise = {
						{ because = "to", primitive = "sound", id = "nothing_to_throw" },
						{ because = "speed", primitive = "sound", id = "impossible" },
					} } },
		} }, "branching")
		local thrower = fx.entity("thrower")
		cue:attach(thrower, branching)
		cue:fire(thrower, "Begin")
		fx.frame()
		T.eq(world.sounds[#world.sounds], "nothing_to_throw", "because routes the right branch")
		T.eq(fx.sounds("impossible"), 0, "and only that branch")
	end)
end
