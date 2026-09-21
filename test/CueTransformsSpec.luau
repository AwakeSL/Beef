--!strict

local Fixture = require("../test/CueFixture")

return function(T: any)
	local fx = Fixture.game(T.load())
	local cue = fx.cue
	local world = fx.world

	local strike = cue:define({ events = {
		{ anchor = "Hit", { primitive = "hurt", to = "victim", damage = 100 } },
	} }, "strike")
	local sword = fx.entity("sword")
	cue:attach(sword, strike)

	local naked = fx.entity("naked", { hp = 1000 })

	T.case("with no transforms the authored damage lands whole", function()
		cue:fire(sword, "Hit", { victim = naked })
		fx.frame()
		T.eq(fx.get(naked, fx.Hp), 900, "no transforms: the authored damage lands whole")
	end)

	local mail = cue:define({ transforms = {
		{ when = { primitive = "hurt", to = "holder" }, stage = 2,
			damage = { "it", times = 0.7 } },
	} }, "mail")

	T.case("a rewrite scales the value in flight", function()
		local clad = fx.entity("clad", { hp = 1000 })
		cue:attach(clad, mail)
		cue:fire(sword, "Hit", { victim = clad, holder = clad })
		fx.frame()
		T.eq(fx.get(clad, fx.Hp), 930, "a multiplicative transform scales the value in flight")
	end)

	T.case("stages order across owners", function()
		local plate = cue:define({ transforms = {
			{ when = { primitive = "hurt", to = "holder" }, stage = 1,
				damage = { "it", -40 } },
		} }, "plate")
		local knight = fx.entity("knight", { hp = 1000 })
		cue:attach(knight, mail)
		cue:attach(knight, plate)
		cue:fire(sword, "Hit", { victim = knight, holder = knight })
		fx.frame()
		T.eq(fx.get(knight, fx.Hp), 958, "flat at 1 then times at 2 is (100-40)*0.7")
	end)

	T.case("a role filter that does not match stays out of it", function()
		local bystander = fx.entity("bystander", { hp = 1000 })
		cue:attach(bystander, mail)
		cue:fire(sword, "Hit", { victim = naked, holder = bystander })
		fx.frame()
		T.eq(fx.get(naked, fx.Hp), 800, "a transform whose role filter does not match stays out of it")
	end)

	T.case("a refusing transform stops the harm and names its own label", function()
		local ward = cue:define({ transforms = {
			{ when = { primitive = "hurt", to = "holder" }, stage = 0,
				refuse = "warded",
				{ primitive = "sound", id = "ward_flash" } },
		} }, "ward")
		local warded = fx.entity("warded", { hp = 1000 })
		cue:attach(warded, ward)
		local strikeWithBranch = cue:define({ events = {
			{ anchor = "Hit",
				{ primitive = "hurt", to = "victim", damage = 100,
					otherwise = { { because = "warded", primitive = "sound", id = "thud" } } } },
		} }, "strikeWithBranch")
		local club = fx.entity("club")
		cue:attach(club, strikeWithBranch)
		cue:fire(club, "Hit", { victim = warded, holder = warded })
		fx.frame()
		T.eq(fx.get(warded, fx.Hp), 1000, "a refusing transform stops the harm entirely")
		T.eq(world.sounds[1], "ward_flash", "and its own effects ran as it ran")
		T.eq(world.sounds[2], "thud", "and the effect's otherwise branch heard the refusal's label")
		T.ok(cue.registry.primitives.hurt.refuses.warded == nil,
			"the label came from the transform, not the primitive")
	end)

	T.case("a transform's own effects run from inside it", function()
		local spiky = cue:define({ transforms = {
			{ when = { primitive = "hurt", to = "holder" },
				damage = { "it", times = 0.5 },
				{ primitive = "hurt", to = "attacker", damage = 5 } },
		} }, "spiky")
		local hedgehog = fx.entity("hedgehog", { hp = 1000 })
		local attacker = fx.entity("attacker", { hp = 1000 })
		cue:attach(hedgehog, spiky)
		cue:fire(sword, "Hit", { victim = hedgehog, holder = hedgehog, attacker = attacker })
		fx.frame()
		T.eq(fx.get(hedgehog, fx.Hp), 950, "thorns mitigate")
		T.eq(fx.get(attacker, fx.Hp), 995, "and strike back, from inside the transform")
	end)

	T.case("an opaque rewrite replaces the value, and limit spends it", function()
		local once = cue:define({ transforms = {
			{ when = { primitive = "hurt", to = "holder" }, limit = 1, damage = { 0 } },
		} }, "onceShield")
		local shielded = fx.entity("shielded", { hp = 1000 })
		cue:attach(shielded, once)
		cue:fire(sword, "Hit", { victim = shielded, holder = shielded })
		fx.frame()
		T.eq(fx.get(shielded, fx.Hp), 1000, "an opaque rewrite replaces the value outright")
		cue:fire(sword, "Hit", { victim = shielded, holder = shielded })
		fx.frame()
		T.eq(fx.get(shielded, fx.Hp), 900, "and limit = 1 spends the shield on the first blow")

		local s = cue:stats()
		T.ok(s.runner.transformsRun >= 5, "transforms are counted")
		T.ok(s.runner.rewrites >= 4, "rewrites are counted")
	end)
end
