--!strict

-- what `cue:observe` used to hand a callback is now on the wire: an invocation is a push on the
-- primitive's event, and its outcome is a push on that event's `done` or `refused`. A controller
-- that only wants to know reads both and writes nothing.

local Fixture = require("../test/CueFixture")

return function(T: any)
	local seen: { any } = {}
	local pending: { [number]: any } = {}
	local sighs = 0
	local sorrows: { string } = {}

	local fx = Fixture.game(T.load(), function(_cue: any, f: any)
		f.watch("WatchHurt", { f.Hurt, f.Hurt.done }, function()
			local hurt = f.Hurt
			for i = hurt.from, hurt.last do
				pending[hurt.seq[i]] = { to = hurt.to[i], damage = hurt.damage[i], self = hurt.by[i] }
			end
			local done = hurt.done
			for i = done.from, done.last do
				local ask = pending[done.seq[i]]
				if ask ~= nil then
					pending[done.seq[i]] = nil
					table.insert(seen, ask)
				end
			end
		end)
		f.watch("WatchSpend", { f.Spend.done, f.Spend.refused }, function()
			local done = f.Spend.done
			for _ = done.from, done.last do
				sighs += 1
			end
			local refused = f.Spend.refused
			for i = refused.from, refused.last do
				table.insert(sorrows, refused.because[i])
			end
		end)
	end)
	local cue = fx.cue
	local world = fx.world

	T.case("a primitive nobody can answer is loud at declaration", function()
		T.throws(function()
			cue:primitive("glow", { takes = {}, refuses = {}, means = "shine" })
		end, "no implementation", "a primitive with no event to ask on is a load error")
		T.throws(function()
			cue:primitive("glimmer", { takes = {}, refuses = {}, event = fx.Sound, means = "shine" })
		end, "already answers for another primitive", "and two primitives cannot share one ask")
	end)

	T.case("the ask carries what was resolved, the answer says it landed", function()
		local strike = cue:define({ events = {
			{ anchor = "Hit", { primitive = "hurt", to = "victim", by = "self", damage = 25 } },
		} }, "strike")
		local blade = fx.entity("blade")
		cue:attach(blade, strike)
		local target = fx.entity("target", { hp = 100 })
		cue:fire(blade, "Hit", { victim = target })
		fx.frame()

		T.eq(#seen, 1, "one granted invocation, one push heard")
		T.eq(seen[1].to, target, "with the resolved participant")
		T.eq(seen[1].damage, 25, "and the post-transform amount")
		T.eq(seen[1].self, blade, "and who ran it, because the effect authored `by`")
	end)

	T.case("the value on the wire is the one that landed", function()
		local mail = cue:define({ transforms = {
			{ when = { primitive = "hurt", to = "holder" }, damage = { "it", times = 0.5 } },
		} }, "obsMail")
		local blade = fx.entity("blade2")
		cue:attach(blade, cue:define({ events = {
			{ anchor = "Hit", { primitive = "hurt", to = "victim", by = "self", damage = 25 } },
		} }, "strike2"))
		local target = fx.entity("target2", { hp = 100 })
		cue:attach(target, mail)
		cue:fire(blade, "Hit", { victim = target, holder = target })
		fx.frame()
		T.eq(seen[2].damage, 12.5, "a controller reads the value that actually landed, after transforms")
	end)

	T.case("a refused invocation is answered, not granted", function()
		world.flags.chargeHeldMs = 0
		local drain = cue:define({ events = {
			{ anchor = "Begin", { primitive = "spend", to = "self", stamina = 99 } },
		} }, "drain")
		local tired = fx.entity("tired", { stamina = 1 })
		cue:attach(tired, drain)
		cue:fire(tired, "Begin")
		fx.frame()
		T.eq(sighs, 0, "nothing was spent, so nothing was answered done")
		T.eq(sorrows[#sorrows], "stamina", "the refusal says which key it could not meet")
		T.eq(fx.get(tired, fx.Stamina), 1, "and the wind is still there")
	end)
end
