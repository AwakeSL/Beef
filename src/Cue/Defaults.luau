--!strict
--!optimize 2

local Entity = require(script.Parent.Entity)

return function(cue: any): any
	cue:operator("times", { stage = 2, commutes = true, means = "multiply" })
	cue:operator("divide", { stage = 2, commutes = true, means = "divide; refuses on zero" })
	cue:operator("min", { stage = 3, commutes = false, means = "at least" })
	cue:operator("max", { stage = 3, commutes = false, means = "at most" })

	local function numberOps(tname: string)
		return {
			["+"] = { [tname] = function(a: number, b: number) return a + b end },
			times = function(v: number, s: number) return v * s end,
			divide = function(v: number, s: number): number?
				if s == 0 then
					return nil
				end
				return v / s
			end,
			min = function(v: number, b: number) return math.max(v, b) end,
			max = function(v: number, b: number) return math.min(v, b) end,
		}
	end

	cue:type("amount", { is = "number", zero = 0, operators = numberOps("amount"),
		means = "a magnitude" })
	cue:type("duration", { is = "number", zero = 0, operators = numberOps("duration"),
		means = "seconds" })
	cue:type("tag", { is = "string", means = "a name" })

	cue:type("direction", {
		is = "Vector3",
		zero = Vector3.zero,
		words = {
			up = { takes = "amount", make = function(n: number) return Vector3.new(0, n, 0) end },
			forward = { takes = "amount", make = function(n: number) return Vector3.new(0, 0, -n) end },
			away = { takes = "amount", make = function(n: number) return Vector3.new(0, 0, -n) end },
			side = { takes = "amount", make = function(n: number) return Vector3.new(n, 0, 0) end },
		},
		operators = {
			["+"] = { direction = function(a: Vector3, b: Vector3) return a + b end },
			times = { operand = "amount", fn = function(v: Vector3, s: number) return v * s end },
		},
		means = "an offset",
	})

	cue:type("place", {
		is = "Vector3",
		words = {
			origin = Vector3.zero,
			here = function(c: any) return c.here end,
		},
		constructors = {
			place = {
				args = {
					x = { type = "amount", default = 0 },
					y = { type = "amount", default = 0 },
					z = { type = "amount", default = 0 },
				},
				make = function(a: any) return Vector3.new(a.x, a.y, a.z) end,
			},
		},
		operators = {
			["+"] = { direction = function(a: Vector3, b: Vector3) return a + b end },
		},
		means = "a world position",
	})

	cue:type("entity", {
		entity = true,
		is = Entity.is,
		words = {
			self = function(c: any) return c.self end,
			victim = function(c: any) return c.victim end,
			attacker = function(c: any) return c.attacker end,
			holder = function(c: any) return c.holder end,
		},
		means = "a thing in the world",
	})

	cue:key("to", { type = "entity", means = "the participant acted on" })
	cue:key("by", { type = "entity", means = "the participant doing it" })
	cue:key("context", { type = "entity", means = "who a granted hook runs as" })
	cue:key("at", { type = "place", means = "where the effect happens" })
	cue:key("amount", { type = "amount", means = "how much" })
	cue:key("damage", { type = "amount", means = "how much harm the blow carries" })
	cue:key("count", { type = "amount", means = "how many" })
	cue:key("id", { type = "tag", means = "which asset" })
	cue:key("over", { type = "duration", means = "the span the effect spreads across" })
	cue:key("per", { type = "duration", means = "the period the effect repeats its amounts for" })

	cue:anchor("Begin", { means = "it started" })
	cue:anchor("Release", { means = "the input was let go" })
	cue:anchor("Hit", { means = "a strike landed" })
	cue:anchor("HitBody", { means = "a strike landed on a body" })
	cue:anchor("Equip", { means = "it was taken up" })
	cue:anchor("Unequip", { means = "it was put away" })
	cue:anchor("Impact", { means = "it struck something" })
	cue:anchor("Spawned", { means = "this made something" })

	cue:gate("marker", {
		test = function(value: any, firing: any)
			return firing.data ~= nil and firing.data.marker == value
		end,
		means = "only when the firing carried this marker",
	})
	cue:gate("because", {
		test = function(value: any, outcome: any)
			return outcome.because == value
		end,
		means = "only for this failure",
	})

	cue:schedule("after", { kind = "delay", type = "duration", means = "wait this long first" })
	cue:schedule("every", { kind = "repeat", type = "duration", means = "how long between repeats" })

	cue:outcome("otherwise", { kind = "branch", means = "if it was refused, do this" })
	cue:outcome("as", { kind = "bind", means = "name the result for later steps" })

	-- a chain is the one primitive the runner drives itself: it holds the steps across passes and
	-- pushes the next one only once the answer to the one before it has come back
	cue:primitive("sequence", {
		takes = {},
		refuses = { "step" },
		sugar = "steps",
		stepKeys = { steps = "run in order; stop at the first refusal" },
		chains = true,
		means = "an ordered chain, each step gated on the one before",
	})

	cue:primitive("grant", {
		takes = { to = "who gets the hooks", context = "who they run as" },
		refuses = { "to" },
		takesSubs = true,
		perform = function(args: any, actx: any)
			for _, subId in actx.subs do
				actx.grant(args.to, subId, args.context)
			end
			return true, nil, nil
		end,
		means = "install hooks on an entity, now",
	})

	return cue
end
