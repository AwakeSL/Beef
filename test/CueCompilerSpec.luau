--!strict

local Fixture = require("../test/CueFixture")

return function(T: any)
	local fx = Fixture.game(T.load())
	local cue = fx.cue

	local function effect(authored: any)
		return cue:effect(authored, "spec")
	end
	local function define(def: any)
		return cue:define(def, "spec")
	end

	T.case("an effect is checked key by key", function()
		T.ok(effect({ primitive = "hurt", to = "victim", damage = 40 }) ~= nil, "a plain effect compiles")
		T.throws(function()
			effect({ primitive = "glow", to = "victim" })
		end, "nobody declared", "an unknown primitive names itself")
		T.throws(function()
			effect({ primitive = "sound", id = "clang", damage = 40 })
		end, 'does not take "damage"', "a key the primitive does not take is refused by name")
		T.throws(function()
			effect({ primitive = "hurt", to = "victim", glow = 3 })
		end, "key nobody declared", "an undeclared key is refused")
		T.throws(function()
			effect({ primitive = "hurt", to = "victim", damage = 40, marker = "sweep" })
		end, "gates sit on subscriptions", "a gate on an effect is refused")
	end)

	T.case("outcomes are checked against the primitive", function()
		T.throws(function()
			effect({ primitive = "sound", id = "clang", as = "noise" })
		end, "returns nothing", "as on a returnless primitive is refused")
		T.throws(function()
			effect({ primitive = "take", to = "self", ammo = "arrow", as = 5 })
		end, "takes a string", "as takes a name")
		T.throws(function()
			effect({ primitive = "spend", to = "self", stamina = 3,
				otherwise = { { because = "speed", primitive = "sound", id = "x" } } })
		end, "cannot fail on", "because naming an impossible field is a load error")
		T.ok(effect({ primitive = "spend", to = "self", stamina = 3,
			otherwise = { { because = "stamina", primitive = "sound", id = "x" } } }) ~= nil,
			"because naming a declared refusal compiles")
	end)

	T.case("a schedule with more than one step is written in order", function()
		T.throws(function()
			effect({ primitive = "hurt", to = "victim", damage = 1, after = 1, every = 0.5 })
		end, "order is written", "two bare schedule keys demand the list form")
		T.ok(effect({ primitive = "hurt", to = "victim", damage = 1,
			schedule = { { after = 1 }, { every = 0.5 } } }) ~= nil, "the ordered schedule list compiles")
		T.throws(function()
			effect({ primitive = "hurt", to = "victim", damage = 1,
				schedule = { { after = 1, every = 0.5 } } })
		end, "exactly one", "a schedule step holds one key")
	end)

	T.case("sugar expands to its primitive", function()
		local ok = effect({ sequence = {
			{ primitive = "occupy", to = "self" },
			{ primitive = "sound", id = "go" },
		} })
		T.ok(ok ~= nil and ok.prim.name == "sequence", "sugar expands a single-key table to its primitive")
	end)

	T.case("a definition names its anchors", function()
		T.throws(function()
			define({ events = { { { primitive = "sound", id = "x" } } } })
		end, "names its anchor", "a subscription without an anchor is refused, not defaulted")
		T.throws(function()
			define({ events = { { anchor = "Sneeze", { primitive = "sound", id = "x" } } } })
		end, "anchor nobody declared", "an unknown anchor is refused")
		T.ok(define({ events = {
			{ anchor = { "Hit", "HitBody" }, { primitive = "sound", id = "either" } },
		} }) ~= nil, "an anchor list compiles")
		T.ok(define({ events = {
			{ anchor = "Hit", { primitive = "sound", id = "a" } },
			{ anchor = "Hit", marker = "sweep", { primitive = "sound", id = "b" } },
		} }) ~= nil, "two subscriptions to one anchor are ordinary list entries")
		T.throws(function()
			define({ stuff = {} })
		end, "not part of a definition", "an unknown definition key is refused")
		T.throws(function()
			define({ events = {
				{ anchor = "Hit", context = "self", { primitive = "sound", id = "x" } },
			} })
		end, "without `to`", "context without to is refused")
	end)

	T.case("a transform is checked against what its primitive takes", function()
		T.throws(function()
			define({ transforms = {
				{ when = { primitive = "sound", to = "holder" }, id = "x" },
			} })
		end, "does not take", "a when filtering on an entity key the primitive does not take is a load error")
		T.ok(define({ transforms = {
			{ when = { primitive = "hurt", to = "holder" }, damage = { "it", times = 0.5 } },
		} }) ~= nil, "a transform on a bound role compiles")
		T.throws(function()
			define({ transforms = {
				{ when = { primitive = "sound" }, damage = { "it", times = 0.5 } },
			} })
		end, "cannot rewrite", "a transform rewriting a key its primitive does not take is refused")
		T.throws(function()
			effect({ primitive = "hurt", to = "victim", damage = "it" })
		end, "value in flight", "`it` outside a transform is refused at the effect level too")
	end)

	T.case("rewrites at one stage have to commute", function()
		local def = define({ transforms = {
			{ when = { primitive = "hurt", to = "holder" }, stage = 1, damage = { "it", times = 0.7 } },
			{ when = { primitive = "hurt", to = "holder" }, stage = 1, damage = { "it", times = 0.5 } },
		} })
		local wearer = fx.entity("wearer")
		cue:attach(wearer, def)
		local held = fx.held(wearer)
		T.ok(held ~= nil and held ~= 0, "two commuting same-stage rewrites intern fine")

		T.throws(function()
			local bad = define({ transforms = {
				{ when = { primitive = "hurt", to = "holder" }, stage = 2, damage = { "it", times = 0.7 } },
				{ when = { primitive = "hurt", to = "holder" }, stage = 2, damage = { "it", -5 } },
			} })
			cue:attach(fx.entity("clad"), bad)
		end, "do not commute", "a multiplier and a subtraction at one stage are refused at intern time")
	end)
end
