--!strict

local Fixture = require("../test/CueFixture")

return function(T: any)
	local Beef = T.load()
	local fx = Fixture.game(Beef)
	local cue = fx.cue
	local values = cue.values

	local function compile(authored: any, tname: string, allowIt: boolean?)
		return values:compile(authored, tname, "spec", allowIt)
	end
	-- the same resolver the runner builds, with the entity words read off a plain context
	local function resolveWith(cv: any, ctx: any, it: any?)
		local resolver = {
			ctx = ctx or {},
			it = it,
			field = function(subject: string, component: any): any?
				local words = cue.registry.types.entity.words
				local w = words[subject]
				local e = if typeof(w) == "function" then w(ctx or {}) else w
				if e == nil then
					return nil
				end
				return Beef.Cue.read(e, component)
			end,
			binding = function(): any?
				return nil
			end,
		}
		return values:resolve(cv, resolver)
	end

	T.case("literals fold at compile", function()
		local cv = compile(40, "amount")
		T.eq(cv.const, 40, "a literal folds to itself")
		T.ok(values:isConst(cv), "a literal is const")

		T.eq(compile({ 40, 10 }, "amount").const, 50, "a sum of literals folds at compile")
		T.eq(compile({ 40, times = 2 }, "amount").const, 80, "a const with a const modifier folds")
		T.eq(compile({ 40, times = 2, max = 60 }, "amount").const, 60, "stages order the fold: times before max")
		T.eq(compile({ 100, min = 120 }, "amount").const, 120, "min is a floor")
		T.throws(function()
			compile({ 40, divide = 0 }, "amount")
		end, "refuses on these constants", "divide by constant zero is a compile error")
	end)

	T.case("words and constructors", function()
		T.eq(compile({ up = 60 }, "direction").const, Vector3.new(0, 60, 0),
			"an applied word folds: the game defined what up = 60 means")
		T.eq(compile({ up = 60, away = 1 }, "direction").const, Vector3.new(0, 60, -1),
			"applied words sum inside one braces")
		T.throws(function()
			compile("up", "direction")
		end, "takes a value", "a word that takes a value refuses bare use")
		T.throws(function()
			compile({ origin = 2 }, "place")
		end, "takes no value", "a word that takes no value refuses application")

		local tall = fx.entity("tall", { hp = 7 })
		T.eq(resolveWith(compile({ up = "self.hp" }, "direction"), { self = tall }), Vector3.new(0, 7, 0),
			"an applied word's value is a full expression")

		T.eq(compile({ place = { y = 100 } }, "place").const, Vector3.new(0, 100, 0),
			"a constructor with defaults folds")
		T.throws(function()
			compile({ place = { height = 3 } }, "place")
		end, "no argument", "an unknown constructor argument names itself")
		T.eq(compile({ "origin", { up = 60 } }, "place").const, Vector3.new(0, 60, 0),
			"place + direction folds when both are const")
	end)

	T.case("a type error names both types", function()
		T.throws(function()
			compile({ "origin", "origin" }, "place")
		end, '"place" %+ "place" is not declared', "two places cannot sum")
		T.throws(function()
			compile({ "origin", up = 60 }, "place")
		end, "not an operator", "an axis of another type beside terms is a plain unknown key")
		T.throws(function()
			compile({ { up = 1 }, up = 60 }, "direction")
		end, "its own braces", "an applied word cannot sit beside terms")
		T.throws(function()
			compile("nowhere", "place")
		end, "not a", "an unknown word names the type it is not part of")
		T.throws(function()
			compile({ 40, "victim" }, "amount")
		end, "not a", "an entity word in an amount slot is a type error")
	end)

	T.case("the value in flight", function()
		T.throws(function()
			compile("it", "amount")
		end, "value in flight", "`it` outside a transform rewrite is refused")
		T.eq(resolveWith(compile("it", "amount", true), {}, 14), 14, "`it` resolves to the value in flight")
		T.eq(resolveWith(compile({ "it", times = 0.5 }, "amount", true), {}, 100), 50, "`it` composes with modifiers")
	end)

	T.case("a field read is one column index", function()
		local sword = fx.entity("sword", { damage = 4 })
		local cv = compile({ 10, "self.damage" }, "amount")
		T.ok(not values:isConst(cv), "a field read cannot fold")
		T.eq(resolveWith(cv, { self = sword }), 14, "const + field read resolves against the component")
		T.eq(resolveWith(cv, { self = fx.entity("bare") }), nil, "a missing field refuses, never zero")

		T.throws(function()
			compile("self.height", "amount")
		end, "nobody declared", "an undeclared field is a compile error")
		T.throws(function()
			compile("self.hp", "place")
		end, "wants a", "a field of the wrong type names both types")

		T.eq(resolveWith(compile({ place = { y = "self.hp" } }, "place"), { self = fx.entity("body", { hp = 25 }) }),
			Vector3.new(0, 25, 0), "a constructor argument accepts a full value")
		T.eq(resolveWith(compile({ "here", { up = 10 } }, "place"), { here = Vector3.new(1, 2, 3) }),
			Vector3.new(1, 12, 3), "a word read sums with a direction at resolve")
	end)

	T.case("a bad expression says what it could have been", function()
		T.throws(function()
			compile({ times = 2 }, "amount")
		end, "nothing to modify", "modifiers alone have no base")
		T.throws(function()
			compile({ 40, glow = 2 }, "amount")
		end, "not an operator", "an unknown named key says what it could have been")
		T.eq(resolveWith(compile({ 100, divide = "self.armour" }, "amount"), { self = fx.entity("clad", { armour = 0 }) }),
			nil, "divide by a resolved zero refuses at runtime")
	end)
end
