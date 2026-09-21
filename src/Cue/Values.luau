--!strict
--!optimize 2

local Registry = require(script.Parent.Registry)

local Values = {}
Values.__index = Values

export type Term = {
	kind: "word" | "it" | "field" | "binding" | "construct" | "lit" | "wordapp",
	value: any?,
	argCV: CV?,
	tname: string,
	name: string?,
	fn: any?,
	subject: string?,
	field: string?,
	component: any?,
	prim: string?,
	bind: string?,
	path: string?,
	cname: string?,
	args: { [string]: CV }?,
	make: any?,
	check: any?,
}

export type Mod = { op: string, stage: number, operand: CV }

export type CV = {
	t: string,
	const: any?,
	terms: { Term },
	mods: { Mod },
	elseValue: any?,
}

export type Resolver = {
	ctx: any,
	it: any?,
	field: (subject: string, component: any) -> any?,
	binding: (prim: string, bind: string, component: any?) -> any?,
}

local function fail(site: string, message: string): never
	error(("[cue] %s: %s"):format(site, message), 0)
end

function Values.new(registry: Registry.Registry)
	local self = setmetatable({}, Values)
	self.registry = registry
	return self
end

export type Values = typeof(Values.new(Registry.new()))

local function constCV(tname: string, value: any): CV
	return table.freeze({ t = tname, const = value, terms = table.freeze({}), mods = table.freeze({}) })
end

local function plusImpl(t: Registry.TypeDecl, rhsType: string, site: string): (any, any) -> any
	local plus = t.operators["+"]
	if typeof(plus) ~= "table" then
		fail(site, ("%q declares no `+`, so it cannot sum"):format(t.name))
	end
	local impl = plus[rhsType]
	if impl == nil then
		fail(site, ("%q + %q is not declared"):format(t.name, rhsType))
	end
	return impl
end

local function opImpl(t: Registry.TypeDecl, op: string): ((any, any) -> any?, string)
	local impl = t.operators[op]
	if typeof(impl) == "table" then
		return impl.fn, impl.operand or t.name
	end
	return impl, t.name
end

local compileValue

local function parseString(self: Values, s: string, tname: string, site: string, allowIt: boolean?): CV
	local reg = self.registry
	local t = reg.types[tname] :: Registry.TypeDecl

	if s == "it" then
		if allowIt ~= true then
			fail(site, "`it` is the value in flight and only a transform rewrite has one")
		end
		local term: Term = table.freeze({ kind = "it" :: "it", tname = tname }) :: any
		return table.freeze({ t = tname, const = nil, terms = table.freeze({ term }), mods = table.freeze({}) })
	end

	local prim, bind = s:match("^([%w_]+):([%w_]+)$")
	local path: string? = nil
	if prim == nil then
		local p3, b3, f3 = s:match("^([%w_]+):([%w_]+)%.([%w_]+)$")
		prim, bind, path = p3, b3, f3
	end
	if prim ~= nil then
		local pdecl = reg.primitives[prim :: string]
		if pdecl == nil then
			fail(site, ("%q binds through %q, a primitive nobody declared"):format(s, prim :: string))
		end
		if pdecl.returns == nil then
			fail(site, ("%q reads a binding, but %q returns nothing"):format(s, prim :: string))
		end
		local btype = pdecl.returns :: string
		local pathComponent: any = nil
		if path ~= nil then
			local fdecl = reg.fields[path]
			if fdecl == nil then
				fail(site, ("%q reads field %q, which nobody declared"):format(s, path))
			end
			btype = fdecl.type
			pathComponent = fdecl.component
		end
		if btype ~= tname then
			fail(site, ("%q is a %q and this position wants a %q"):format(s, btype, tname))
		end
		local term: Term = table.freeze({
			kind = "binding" :: "binding", tname = btype,
			prim = prim, bind = bind, path = path, component = pathComponent,
		}) :: any
		return table.freeze({ t = tname, const = nil, terms = table.freeze({ term }), mods = table.freeze({}) })
	end

	local subject, field = s:match("^([%w_]+)%.([%w_]+)$")
	if subject ~= nil then
		local etype = reg.entityType
		if etype == nil then
			fail(site, ("%q reads a field, and no entity type is declared"):format(s))
		end
		local et = reg.types[etype :: string] :: Registry.TypeDecl
		if et.words[subject :: string] == nil then
			fail(site, ("%q reads through %q, which is not a %q word"):format(s, subject :: string, etype :: string))
		end
		local fdecl = reg.fields[field :: string]
		if fdecl == nil then
			fail(site, ("%q reads field %q, which nobody declared"):format(s, field :: string))
		end
		if fdecl.type ~= tname then
			fail(site, ("%q is a %q and this position wants a %q"):format(s, fdecl.type, tname))
		end
		local term: Term = table.freeze({
			kind = "field" :: "field", tname = fdecl.type,
			subject = subject, field = field, component = fdecl.component,
		}) :: any
		return table.freeze({ t = tname, const = nil, terms = table.freeze({ term }), mods = table.freeze({}) })
	end

	local word = t.words[s]
	if word == nil then
		fail(site, ("%q is not a %q word"):format(s, tname))
	end
	if typeof(word) == "table" and typeof((word :: any).make) == "function" then
		fail(site, ("word %q takes a value: { %s = ... }"):format(s, s))
	end
	if typeof(word) == "function" then
		local term: Term = table.freeze({
			kind = "word" :: "word", tname = tname, name = s, fn = word, check = t.is,
		}) :: any
		return table.freeze({ t = tname, const = nil, terms = table.freeze({ term }), mods = table.freeze({}) })
	end
	if not t.is(word) then
		fail(site, ("word %q resolves to something that is not a %q"):format(s, tname))
	end
	return constCV(tname, word)
end

local function parseConstructor(self: Values, cname: string, given: any, tname: string, site: string, allowIt: boolean?): CV
	local reg = self.registry
	local t = reg.types[tname] :: Registry.TypeDecl
	local spec = t.constructors[cname]
	local make = t.construct[cname]
	if typeof(given) ~= "table" then
		fail(site, ("constructor %q takes a table of named arguments"):format(cname))
	end
	if #given > 0 then
		fail(site, ("constructor %q takes named arguments, not a list"):format(cname))
	end
	local argCVs: { [string]: CV } = {}
	local allConst = true
	local givenArgs = given :: { [string]: any }
	for argName, argValue in givenArgs do
		local argSpec = spec[argName]
		if argSpec == nil then
			fail(site, ("constructor %q has no argument %q"):format(cname, argName))
		end
		local argSite = ("%s (argument %q of %q)"):format(site, argName, cname)
		local cv: CV
		if typeof(argSpec) == "table" then
			cv = compileValue(self, argValue, argSpec.type, argSite, allowIt)
		else
			if typeof(argValue) ~= typeof(argSpec) then
				fail(argSite, ("takes a %s literal; declare a type on the argument to accept expressions")
					:format(typeof(argSpec)))
			end
			cv = constCV(tname, argValue)
		end
		argCVs[argName] = cv
		if cv.const == nil or #cv.terms > 0 or #cv.mods > 0 then
			allConst = false
		end
	end
	if allConst then
		local args: { [string]: any } = {}
		for argName, argSpec in spec do
			args[argName] = if typeof(argSpec) == "table" then argSpec.default else argSpec
		end
		for argName, cv in argCVs do
			args[argName] = cv.const
		end
		local value = make(args)
		if not t.is(value) then
			fail(site, ("constructor %q made something that is not a %q"):format(cname, tname))
		end
		return constCV(tname, value)
	end
	local term: Term = table.freeze({
		kind = "construct" :: "construct", tname = tname,
		cname = cname, args = table.freeze(argCVs), make = make, check = t.is,
	}) :: any
	return table.freeze({ t = tname, const = nil, terms = table.freeze({ term }), mods = table.freeze({}) })
end

local function parseWordApps(self: Values, named: { [string]: any }, tname: string, site: string, allowIt: boolean?): CV
	local t = (self.registry :: Registry.Registry).types[tname] :: Registry.TypeDecl
	local const: any = nil
	local terms: { Term } = {}
	for wordName, given in named do
		local decl = t.words[wordName]
		if typeof(decl) ~= "table" or typeof((decl :: any).make) ~= "function" then
			fail(site, ("word %q takes no value; write %q"):format(wordName, wordName))
		end
		local argType = (decl :: any).takes
		if typeof(argType) ~= "string" then
			fail(site, ("word %q declares no `takes` type for its value"):format(wordName))
		end
		local argCV = compileValue(self, given, argType, ("%s (value of %q)"):format(site, wordName), allowIt)
		if argCV.const ~= nil and #argCV.terms == 0 and #argCV.mods == 0 then
			local made = (decl :: any).make(argCV.const)
			if made == nil or not t.is(made) then
				fail(site, ("word %q made something that is not a %q"):format(wordName, tname))
			end
			if const == nil then
				const = made
			else
				const = plusImpl(t, tname, site)(const, made)
			end
		else
			local term: Term = table.freeze({
				kind = "wordapp" :: "wordapp", tname = tname, name = wordName,
				make = (decl :: any).make, check = t.is, argCV = argCV,
			}) :: any
			table.insert(terms, term)
		end
	end
	local count = 0
	for _ in named do
		count += 1
	end
	if count > 1 then
		plusImpl(t, tname, site)
	end
	if #terms == 0 then
		return constCV(tname, const)
	end
	return table.freeze({ t = tname, const = const, terms = table.freeze(terms), mods = table.freeze({}) })
end

local function compileTerm(self: Values, element: any, tname: string, site: string, allowIt: boolean?): CV
	local reg = self.registry
	local t = reg.types[tname] :: Registry.TypeDecl
	local ok, cv = pcall(compileValue, self, element, tname, site, allowIt)
	if ok then
		return cv
	end
	local plus = t.operators["+"]
	if typeof(plus) == "table" then
		local plusTable = plus :: { [string]: any }
		for rhsType in plusTable do
			if rhsType ~= tname and reg.types[rhsType] ~= nil then
				local ok2, cv2 = pcall(compileValue, self, element, rhsType, site, allowIt)
				if ok2 then
					return cv2
				end
			end
		end
	end
	error(cv, 0)
end

local function parseTable(self: Values, tbl: { [any]: any }, tname: string, site: string, allowIt: boolean?): CV
	local reg = self.registry
	local t = reg.types[tname] :: Registry.TypeDecl

	local named: { [string]: any } = {}
	local namedCount = 0
	for k, v in tbl do
		if typeof(k) == "string" then
			named[k] = v
			namedCount += 1
		elseif typeof(k) ~= "number" then
			fail(site, ("a value table's keys are strings or positions, not %s"):format(typeof(k)))
		end
	end
	local arrayCount = #tbl

	if namedCount == 1 and arrayCount == 0 then
		local onlyName = next(named) :: string
		if t.constructors[onlyName] ~= nil then
			return parseConstructor(self, onlyName, named[onlyName], tname, site, allowIt)
		end
	end

	local allWords = namedCount > 0
	for k in named do
		if t.words[k] == nil then
			allWords = false
			break
		end
	end
	if allWords then
		if arrayCount > 0 then
			fail(site, "an applied word sits in its own braces; it cannot share them with terms")
		end
		return parseWordApps(self, named, tname, site, allowIt)
	end

	local elseValue: any? = nil
	if named["else"] ~= nil then
		local given = named["else"]
		named["else"] = nil
		namedCount -= 1
		if not t.is(given) then
			fail(site, ("`else` is the declared fallback and must be a %q constant"):format(tname))
		end
		elseValue = given
	end
	local mods: { Mod } = {}
	for k, v in named do
		local opDecl = reg.operators[k]
		if opDecl == nil or t.operators[k] == nil then
			local what = if t.words[k] ~= nil
				then "a word, and an applied word sits in its own braces"
				else ("not an operator %q declares, a constructor, or a word"):format(tname)
			fail(site, ("%q is %s"):format(k, what))
		end
		local _, operandType = opImpl(t, k)
		local operand = compileValue(self, v, operandType, ("%s (operand of %q)"):format(site, k), allowIt)
		table.insert(mods, { op = k, stage = opDecl.stage, operand = operand })
	end
	table.sort(mods, function(a, b)
		if a.stage ~= b.stage then
			return a.stage < b.stage
		end
		return a.op < b.op
	end)

	local const: any = nil
	local terms: { Term } = {}
	for i = 1, arrayCount do
		local cv = compileTerm(self, tbl[i], tname, ("%s (term %d)"):format(site, i), allowIt)
		if cv.const ~= nil and #cv.terms == 0 and #cv.mods == 0 then
			if cv.t == tname then
				if const == nil then
					const = cv.const
				else
					const = plusImpl(t, tname, site)(const, cv.const)
				end
			else
				local term: Term = table.freeze({ kind = "lit" :: "lit", tname = cv.t, value = cv.const }) :: any
				table.insert(terms, term)
			end
		elseif #cv.mods > 0 or #cv.terms > 1 or (cv.const ~= nil and #cv.terms > 0) then
			local term: Term = table.freeze({ kind = "construct" :: "construct", tname = cv.t,
				cname = nil, args = nil, make = nil, check = nil, cv = cv } :: any) :: any
			table.insert(terms, term)
		else
			table.insert(terms, cv.terms[1])
		end
	end

	if const == nil and #terms == 0 then
		fail(site, "modifiers with nothing to modify")
	end
	for i, term in terms do
		if const ~= nil or i > 1 or term.tname ~= tname then
			plusImpl(t, term.tname, site)
		end
	end
	if const == nil and #terms > 0 then
		local hasOwnTerm = false
		for _, term in terms do
			if term.tname == tname then
				hasOwnTerm = true
				break
			end
		end
		if not hasOwnTerm and t.zero == nil then
			fail(site, ("every term is foreign to %q and it declares no zero to start the sum from"):format(tname))
		end
	end

	local allStatic = true
	for _, term in terms do
		if term.kind ~= "lit" then
			allStatic = false
			break
		end
	end
	if allStatic then
		for _, mod in mods do
			if mod.operand.const == nil or #mod.operand.terms > 0 or #mod.operand.mods > 0 then
				allStatic = false
				break
			end
		end
	end
	if allStatic and elseValue ~= nil then
		allStatic = false
	end
	if allStatic then
		local cv: CV = table.freeze({ t = tname, const = const, terms = table.freeze(terms), mods = table.freeze(mods) })
		local staticResolver: Resolver = {
			ctx = nil,
			field = function(): any?
				return nil
			end,
			binding = function(): any?
				return nil
			end,
		} :: any
		local v, why = Values.resolve(self, cv, staticResolver)
		if v == nil then
			fail(site, ("refuses on these constants (%s)"):format(why or "?"))
		end
		return constCV(tname, v)
	end
	return table.freeze({ t = tname, const = const, terms = table.freeze(terms),
		mods = table.freeze(mods), elseValue = elseValue })
end

compileValue = function(self: Values, authored: any, tname: string, site: string, allowIt: boolean?): CV
	local reg = self.registry :: Registry.Registry
	local t = reg.types[tname]
	if t == nil then
		fail(site, ("no type %q is declared"):format(tname))
	end
	if (t :: Registry.TypeDecl).opaque then
		if not (t :: Registry.TypeDecl).is(authored) then
			fail(site, ("%s is not a %q"):format(tostring(authored), tname))
		end
		return constCV(tname, authored)
	end
	if typeof(authored) == "string" then
		if (t :: Registry.TypeDecl).is(authored) and (t :: Registry.TypeDecl).words[authored] == nil
			and authored ~= "it" and not authored:find("[:.]") then
			return constCV(tname, authored)
		end
		return parseString(self, authored, tname, site, allowIt)
	end
	if typeof(authored) == "table" then
		return parseTable(self, authored :: { [any]: any }, tname, site, allowIt)
	end
	if not (t :: Registry.TypeDecl).is(authored) then
		fail(site, ("%s is not a %q"):format(tostring(authored), tname))
	end
	return constCV(tname, authored)
end

function Values.compile(self: Values, authored: any, tname: string, site: string, allowIt: boolean?): CV
	return compileValue(self, authored, tname, site, allowIt)
end

local function resolveTerm(self: Values, term: Term, resolver: Resolver): (any?, string?)
	if term.kind == "lit" then
		return term.value, nil
	end
	if term.kind == "wordapp" then
		local arg, why = Values.resolve(self, term.argCV :: CV, resolver)
		if arg == nil then
			return nil, why
		end
		local made = (term.make :: any)(arg)
		if made == nil or (term.check ~= nil and not (term.check :: any)(made)) then
			return nil, ("word %q made a non-%q"):format(term.name :: string, term.tname)
		end
		return made, nil
	end
	if term.kind == "it" then
		if resolver.it == nil then
			return nil, "no value in flight"
		end
		return resolver.it, nil
	end
	if term.kind == "word" then
		local v = (term.fn :: any)(resolver.ctx)
		if v == nil then
			return nil, ("word %q resolved to nothing"):format(term.name :: string)
		end
		if term.check ~= nil and not (term.check :: any)(v) then
			return nil, ("word %q resolved to a non-%q"):format(term.name :: string, term.tname)
		end
		return v, nil
	end
	if term.kind == "field" then
		local v = resolver.field(term.subject :: string, term.component)
		if v == nil then
			return nil, ("%s.%s is not there"):format(term.subject :: string, term.field :: string)
		end
		return v, nil
	end
	if term.kind == "binding" then
		local v = resolver.binding(term.prim :: string, term.bind :: string, term.component)
		if v == nil then
			return nil, ("%s:%s was never bound"):format(term.prim :: string, term.bind :: string)
		end
		return v, nil
	end
	local nested = (term :: any).cv :: CV?
	if nested ~= nil then
		return Values.resolve(self, nested, resolver)
	end
	local args: { [string]: any } = {}
	local t = (self.registry :: Registry.Registry).types[term.tname] :: Registry.TypeDecl
	local spec = t.constructors[term.cname :: string]
	for argName, argSpec in spec do
		args[argName] = if typeof(argSpec) == "table" then argSpec.default else argSpec
	end
	local termArgs = term.args :: { [string]: CV }
	for argName, cv in termArgs do
		local v, why = Values.resolve(self, cv, resolver)
		if v == nil then
			return nil, why
		end
		args[argName] = v
	end
	local made = (term.make :: any)(args)
	if term.check ~= nil and not (term.check :: any)(made) then
		return nil, ("constructor %q made a non-%q"):format(term.cname :: string, term.tname)
	end
	return made, nil
end

function Values.resolve(self: Values, cv: CV, resolver: Resolver): (any?, string?)
	local reg = self.registry :: Registry.Registry
	local t = reg.types[cv.t] :: Registry.TypeDecl
	local acc: any = cv.const
	for _, term in cv.terms do
		local v, why = resolveTerm(self, term, resolver)
		if v == nil then
			if cv.elseValue ~= nil then
				return cv.elseValue, "else"
			end
			return nil, why
		end
		if acc == nil then
			if term.tname == cv.t then
				acc = v
			else
				acc = plusImpl(t, term.tname, cv.t)(t.zero, v)
			end
		else
			acc = plusImpl(t, term.tname, cv.t)(acc, v)
		end
	end
	if acc == nil then
		return nil, "nothing resolved"
	end
	for _, mod in cv.mods do
		local operand, why = Values.resolve(self, mod.operand, resolver)
		if operand == nil then
			return nil, why
		end
		local implFn = opImpl(t, mod.op)
		acc = implFn(acc, operand)
		if acc == nil then
			return nil, ("%q refused"):format(mod.op)
		end
	end
	return acc, nil
end

function Values.isConst(_self: Values, cv: CV): boolean
	return cv.const ~= nil and #cv.terms == 0 and #cv.mods == 0
end

return Values
