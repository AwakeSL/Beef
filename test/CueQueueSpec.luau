--!strict

local Fixture = require("../test/CueFixture")

return function(T: any)
	local fx = Fixture.game(T.load())
	local cue = fx.cue
	local world = fx.world

	-- the queue runs against the phase's clock, so a spec moves time by running frames
	fx.frame()

	T.case("a delay holds the values it was queued with", function()
		local delayed = cue:define({ events = {
			{ anchor = "Hit",
				{ primitive = "hurt", to = "victim", damage = { 10, "self.damage" }, after = 2 } },
		} }, "delayed")
		local axe = fx.entity("axe", { damage = 5 })
		cue:attach(axe, delayed)
		local victim = fx.entity("victim", { hp = 100 })
		cue:fire(axe, "Hit", { victim = victim })
		fx.frame(0)
		T.eq(fx.get(victim, fx.Hp), 100, "a delayed effect does nothing at fire time")
		fx.seconds(1)
		T.eq(fx.get(victim, fx.Hp), 100, "nor before its time")
		fx.set(axe, fx.Damage, 999)
		fx.seconds(1.3)
		T.eq(fx.get(victim, fx.Hp), 85, "it lands after the delay, with values captured when queued")
	end)

	T.case("every firing is its own occurrence", function()
		local dot = cue:define({ events = {
			{ anchor = "Hit",
				{ primitive = "hurt", to = "victim", damage = { 1, "self.damage" },
					schedule = { { every = 1 } } } },
		} }, "dot")
		local brand = fx.entity("brand", { damage = 1 })
		cue:attach(brand, dot)
		local burned = fx.entity("burned", { hp = 100 })
		cue:fire(brand, "Hit", { victim = burned })
		fx.seconds(1.1)
		T.eq(fx.get(burned, fx.Hp), 98, "a repeating effect fires on its period")
		fx.set(brand, fx.Damage, 3)
		fx.seconds(1.1)
		T.eq(fx.get(burned, fx.Hp), 94, "and re-resolves per firing: each firing is its own occurrence")
	end)

	T.case("after then once: the wait runs first", function()
		local armed = cue:define({ events = {
			{ anchor = "Hit",
				{ primitive = "sound", id = "armedBeep",
					schedule = { { after = 1 }, { once = "landedA" } } } },
		} }, "armed")
		local gA = fx.entity("gA")
		cue:attach(gA, armed)
		cue:fire(gA, "Hit")
		world.flags.landedA = true
		fx.seconds(0.5)
		T.eq(fx.sounds("armedBeep"), 0, "landing during the arming delay does nothing")
		fx.seconds(0.8)
		T.eq(fx.sounds("armedBeep"), 1, "and it fires once armed, because the landing already happened")
	end)

	T.case("once then after: the fuse runs from the landing", function()
		local fused = cue:define({ events = {
			{ anchor = "Hit",
				{ primitive = "sound", id = "fuseBoom",
					schedule = { { once = "landedB" }, { after = 1 } } } },
		} }, "fused")
		local gB = fx.entity("gB")
		cue:attach(gB, fused)
		cue:fire(gB, "Hit")
		fx.seconds(5)
		T.eq(fx.sounds("fuseBoom"), 0, "no landing, no fuse, however long you wait")
		world.flags.landedB = true
		fx.frame(0)
		fx.seconds(0.5)
		T.eq(fx.sounds("fuseBoom"), 0, "the fuse runs from the landing, not from the firing")
		fx.seconds(0.8)
		T.eq(fx.sounds("fuseBoom"), 1, "and burns for its own second")
	end)

	T.case("over is a column the reading controller spreads", function()
		local spread = cue:define({ events = {
			{ anchor = "Hit", { primitive = "hurt", to = "victim", damage = 8, over = 2 } },
		} }, "spreadDef")
		local ember = fx.entity("ember")
		cue:attach(ember, spread)
		local coals = fx.entity("coals", { hp = 100 })
		cue:fire(ember, "Hit", { victim = coals })
		fx.frame(0)
		T.eq(fx.get(coals, fx.Hp), 100, "a spread effect lands nothing at fire time")
		fx.seconds(2)
		T.ok(math.abs(fx.get(coals, fx.Hp) - 92) < 0.01,
			"the authored total lands across the span, no more and no less")
		fx.seconds(1)
		T.ok(math.abs(fx.get(coals, fx.Hp) - 92) < 0.01, "and stops when the span ends")
	end)

	T.case("a transform runs once on the authored value, not per slice", function()
		local mailDef = cue:define({ transforms = {
			{ when = { primitive = "hurt", to = "holder" }, damage = { "it", -4 } },
		} }, "flatMail")
		local knight = fx.entity("knight", { hp = 100 })
		cue:attach(knight, mailDef)
		local ember = fx.entity("ember2")
		cue:attach(ember, cue:define({ events = {
			{ anchor = "Hit", { primitive = "hurt", to = "victim", damage = 8, over = 2 } },
		} }, "spread2"))
		cue:fire(ember, "Hit", { victim = knight, holder = knight })
		fx.frame(0)
		fx.seconds(2)
		T.ok(math.abs(fx.get(knight, fx.Hp) - 96) < 0.01,
			"flat mitigation ran ONCE on the authored 8, not per slice")
	end)

	T.case("every never makes a fraction of a countable thing", function()
		local rate = cue:define({ events = {
			{ anchor = "Hit", { primitive = "stack", to = "victim", stacks = 1, every = 1 } },
		} }, "rate")
		local hex = fx.entity("hex")
		cue:attach(hex, rate)
		local marked = fx.entity("marked")
		cue:fire(hex, "Hit", { victim = marked })
		fx.seconds(2.5)
		T.eq(fx.get(marked, fx.Stacks), 2, "a countable thing repeats discretely")
	end)

	T.case("per is the primitive's own rate", function()
		local leech = cue:define({ events = {
			{ anchor = "Hit", { primitive = "hurt", to = "victim", damage = 1, per = 1 } },
		} }, "leech")
		local tick = fx.entity("tick")
		cue:attach(tick, leech)
		local host = fx.entity("host", { hp = 100 })
		cue:fire(tick, "Hit", { victim = host })
		fx.frame(0)
		fx.seconds(2.5)
		T.ok(math.abs(fx.get(host, fx.Hp) - 97.5) < 0.01, "1 per second, smoothly, unbounded")
	end)

	T.case("a queued effect whose entity died is dropped", function()
		local mortal = cue:define({ events = {
			{ anchor = "Hit", { primitive = "sound", id = "ghost", after = 1 } },
		} }, "mortal")
		local dying = fx.entity("dying")
		cue:attach(dying, mortal)
		cue:fire(dying, "Hit")
		fx.kill(dying)
		fx.seconds(2)
		T.eq(fx.sounds("ghost"), 0, "a queued effect whose entity died is dropped, counted, never applied")
		T.ok(cue:stats().queue.deadDrops >= 1, "and the drop is counted")
	end)

	T.case("lasts removes the subscription after its time", function()
		local fading = cue:define({ events = {
			{ anchor = "Hit", lasts = 1, { primitive = "sound", id = "echo" } },
		} }, "fading")
		local wall = fx.entity("wall")
		cue:attach(wall, fading)
		cue:fire(wall, "Hit")
		fx.seconds(0.5)
		cue:fire(wall, "Hit")
		fx.seconds(0.8)
		cue:fire(wall, "Hit")
		fx.frame()
		T.eq(fx.sounds("echo"), 2, "lasts removes the subscription after its time")
	end)
end
