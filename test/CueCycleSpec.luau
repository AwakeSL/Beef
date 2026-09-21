--!strict

local Fixture = require("../test/CueFixture")

return function(T: any)
	local fx = Fixture.game(T.load(), function(cue: any, _f: any)
		-- a verb that answers where it stands and fires while it is there: nothing on the wire can
		-- re-enter cue inside one invocation, so the guard needs a `perform` to test it
		cue:primitive("trigger", {
			takes = { to = "whose anchor" },
			refuses = {},
			perform = function(args: any, actx: any)
				actx.cue:fire(args.to, "Hit", { victim = args.to })
				return true, nil, nil
			end,
			means = "fire an anchor from inside an effect",
		})
	end)
	local cue = fx.cue
	local world = fx.world

	T.case("a fire cycle trips the guard instead of hanging", function()
		local loop = cue:define({ events = {
			{ anchor = "Hit", { primitive = "trigger", to = "self" } },
		} }, "loop")
		local ouro = fx.entity("ouroboros")
		cue:attach(ouro, loop)
		cue:fire(ouro, "Hit")
		fx.frame()
		local s = cue:stats()
		T.ok(s.runner.depthHits >= 1, "a fire cycle trips the guard and is counted")
		T.ok(s.runner.fired.Hit <= 20, "and it stopped instead of hanging")
	end)

	T.case("honest nesting well inside the limit runs fine", function()
		local seq = cue:define({ events = {
			{ anchor = "Begin",
				{ sequence = {
					{ sequence = {
						{ sequence = {
							{ primitive = "sound", id = "deep" },
						} },
					} },
				} } },
		} }, "nested")
		local diver = fx.entity("diver")
		cue:attach(diver, seq)
		cue:fire(diver, "Begin")
		fx.frame()
		T.eq(world.sounds[1], "deep", "honest nesting well inside the limit runs fine")
	end)

	T.case("a chain costs two passes a step, and the phase's budget is the limit", function()
		-- a step is one push and one answer, and a buffer frozen at the top of a pass means the
		-- answer arrives a pass after the ask: twelve immediate steps is twenty-four passes, well
		-- inside the phase's cap of thirty-two
		local steps: { any } = {}
		for i = 1, 12 do
			table.insert(steps, { primitive = "sound", id = ("step%d"):format(i) })
		end
		local marathon = cue:define({ events = {
			{ anchor = "Begin", { sequence = steps } },
		} }, "marathon")
		local walker = fx.entity("walker")
		cue:attach(walker, marathon)
		cue:fire(walker, "Begin")
		fx.frame()
		T.eq(fx.sounds("step12"), 1, "a twelve step chain resolves inside one frame")
		T.eq(cue.runner.stats.inflight, 0, "and nothing is left in flight")
		T.ok(fx.phase().passes >= 24, "it took two passes a step to get there")
	end)

	T.case("a chain longer than the pass budget continues on the next frame", function()
		-- twenty immediate steps is forty passes, past the phase's cap of thirty-two: the cap cuts
		-- the chain off mid frame, and what it could not deliver carries to the next frame's first
		-- pass instead of being lost, so the chain finishes there rather than stalling
		local steps: { any } = {}
		for i = 1, 20 do
			table.insert(steps, { primitive = "sound", id = ("step%d"):format(i) })
		end
		local marathon = cue:define({ events = {
			{ anchor = "Begin", { sequence = steps } },
		} }, "marathon")
		local walker = fx.entity("walker")
		cue:attach(walker, marathon)
		cue:fire(walker, "Begin")
		fx.frame()
		T.eq(fx.phase().passes, 32, "the frame hit the pass cap")
		T.eq(fx.sounds("step20"), 0, "the chain did not finish inside the capped frame")
		fx.frame()
		T.eq(fx.sounds("step20"), 1, "and it continues, finishing on the next frame")
		T.eq(cue.runner.stats.inflight, 0, "nothing is left in flight")
	end)

	T.case("repeated identical grants intern a handful of sets, not a flood", function()
		local granter = cue:define({ events = {
			{ anchor = "Hit",
				{ primitive = "grant", to = "victim",
					{ anchor = "Hit", { primitive = "sound", id = "spreading" } } } },
		} }, "granter")
		local patientZero = fx.entity("patientZero")
		cue:attach(patientZero, granter)
		local other = fx.entity("other")
		cue:fire(patientZero, "Hit", { victim = other })
		cue:fire(patientZero, "Hit", { victim = other })
		cue:fire(patientZero, "Hit", { victim = other })
		fx.frame()
		local s = cue:stats()
		T.ok(s.grantsTotal >= 3, "grants are counted toward the rate window")
		T.ok(s.intern.setsInterned < 20, "and repeated identical grants intern a handful of sets")
	end)
end
