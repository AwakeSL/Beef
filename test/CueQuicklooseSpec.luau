--!strict

-- the whole bow, end to end: one act spanning two firings, its bindings carried in the scope the
-- game hands both, every step resolved through the loop, and the refusals routed by name.

local Fixture = require("../test/CueFixture")

return function(T: any)
	local Stow: any
	local fx = Fixture.game(T.load(), function(cue: any, f: any)
		Stow = f.Beef.Events.new("stow", "to", "seq:u32")
		cue:primitive("stow", {
			takes = { to = "what goes back" },
			refuses = { "to" },
			event = Stow,
			means = "put it back where it came from",
		})
		f.answer("Stowing", Stow, function(e: any, i: number)
			table.insert(f.world.log, "stowed " .. tostring(f.get(e.to[i], f.Name)))
			e.done.push(e.seq[i])
		end)
	end)
	local cue = fx.cue
	local world = fx.world

	local quickloose = cue:define({
		events = {
			{ anchor = "Equip",
				{ primitive = "sound", id = "bow_ready" } },

			{ anchor = "Begin",
				{ sequence = {
					{ primitive = "occupy", to = "self" },
					{ primitive = "take", to = "self", ammo = "arrow", as = "shaft",
						otherwise = { { primitive = "sound", id = "quiver_empty" } } },
					{ primitive = "spend", to = "self", stamina = 3,
						otherwise = { { primitive = "sound", id = "draw_fail" } } },
					{
						{ primitive = "charge", minMs = 180, maxMs = 900, as = "draw" },
						{ primitive = "sound", id = "bow_draw" },
					},
				} } },

			{ anchor = "Release",
				{ sequence = {
					{ primitive = "launch", to = "take:shaft", at = "here",
						speed = { 40, { "charge:draw", times = 90 } },
						otherwise = {
							{ because = "speed", primitive = "stow", to = "take:shaft" },
							{ because = "to", primitive = "sound", id = "ui_refuse" },
						} },
					{ primitive = "sound", id = "string_thrum" },
				} } },
		},
	}, "Quickloose")

	local archer = fx.entity("archer", { stamina = 10 })
	cue:attach(archer, quickloose)
	local act: { [string]: any } = {}
	local aim = Vector3.new(0, 0, -100)

	T.case("a full draw and loose", function()
		cue:fire(archer, "Equip")
		fx.frame()
		T.eq(world.sounds[1], "bow_ready", "equipping rings")

		local arrow = fx.entity("arrow", { damage = 6 })
		table.insert(fx.quiver(archer), arrow)

		world.flags.chargeHeldMs = 900
		cue:fire(archer, "Begin", nil, act)
		fx.frame()
		T.eq(world.sounds[2], "bow_draw", "a full draw begins")
		T.eq(fx.get(archer, fx.Stamina), 7, "and costs its wind")
		T.eq(#fx.quiver(archer), 0, "and the arrow left the quiver")

		cue:fire(archer, "Release", { here = aim }, act)
		fx.frame()
		T.eq(#world.launches, 1, "release looses the arrow")
		T.eq(world.launches[1].what, arrow, "the arrow the draw bound is the arrow that flies")
		T.eq(world.launches[1].speed, 130, "a full draw is the full 40 + 90")
		T.eq(world.launches[1].at, aim, "toward the aim the moment gave")
		T.eq(world.sounds[3], "string_thrum", "and the string sings after the loose")
	end)

	T.case("an empty quiver refuses the draw", function()
		world.flags.bodyBusy = false
		act = {}
		cue:fire(archer, "Begin", nil, act)
		fx.frame()
		T.eq(world.sounds[4], "quiver_empty", "an empty quiver refuses the draw")
		T.eq(fx.get(archer, fx.Stamina), 7, "and the refused draw cost nothing")
	end)

	T.case("too winded to draw", function()
		world.flags.bodyBusy = false
		act = {}
		table.insert(fx.quiver(archer), fx.entity("arrow2"))
		fx.set(archer, fx.Stamina, 1)
		cue:fire(archer, "Begin", nil, act)
		fx.frame()
		T.eq(world.sounds[5], "draw_fail", "too winded to draw")
	end)

	T.case("a tap puts the arrow back and never sings", function()
		world.flags.bodyBusy = false
		act = {}
		fx.set(archer, fx.Stamina, 10)
		table.insert(fx.quiver(archer), fx.entity("arrow3"))
		world.flags.chargeHeldMs = 90
		cue:fire(archer, "Begin", nil, act)
		fx.frame()
		T.eq(#world.launches, 1, "a tap looses nothing")

		cue:fire(archer, "Release", { here = aim }, act)
		fx.frame()
		T.eq(#world.launches, 1, "still nothing: under minMs there is no charge value at all")
		local lastLog = world.log[#world.log]
		T.ok(lastLog ~= nil and lastLog:find("stowed") ~= nil,
			"the undrawn arrow went back, by the because branch")
		T.eq(fx.sounds("string_thrum"), 1, "and the string never sang for it")
	end)

	T.case("the reference documents declarations, and the counts add up", function()
		local report = cue:reference()
		T.ok(report:find("## Primitives") ~= nil, "the reference generates")
		T.ok(report:find("string_thrum") == nil, "and it documents declarations, not content")
		T.ok(report:find("stow") ~= nil, "a primitive registered after load is in it")

		local s = cue:stats()
		T.eq(s.runner.depthHits, 0, "nothing spiralled")
		T.ok(s.runner.granted > 0 and s.runner.refused > 0, "both outcomes happened and were counted")
	end)
end
