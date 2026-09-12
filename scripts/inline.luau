--!strict
-- Inline, on disk: rewrites every controller in a folder into a Built folder beside it, expanding the simple store
-- calls into the fast form. Your files are never touched.
--
--   lune run scripts/inline demo/ReplicatedStorage/Controllers        -> demo/ReplicatedStorage/Built/Controllers
--   lune run scripts/inline <folder> <out folder>                      -> where you say
--
--   for kind, n in c.each() do ... end     -> nested loop over c.kinds() and c.of(kind).has
--   c.get(kind, n)                          -> column or slot read, buckets hoisted once per kind
--   c.add(kind, n, v)                       -> column or slot write, real add when the entity lacks it
--   c.has(kind, n)                          -> column nil test or slot test
--   local n, p, pi, v, vi = c.join(kind, d) -> the loop that follows is cloned: identity indices substituted away
--
-- Only the shapes above are rewritten, and only where the kind is the loop's own kind variable.
-- Anything else passes through unchanged, so a miss is never wrong, only not faster.

local fs = require("@lune/fs")
local process = require("@lune/process")

-- ---------------------------------------------------------------- lexer

type Token = { kind: string, text: string, from: number, to: number }

local KEYWORDS = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true,
	["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
	["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true,
	["true"] = true, ["until"] = true, ["while"] = true, ["continue"] = true,
}

local function lex(source: string): { Token }
	local tokens: { Token } = {}
	local i = 1
	local n = #source
	local function push(kind: string, from: number, to: number)
		table.insert(tokens, { kind = kind, text = source:sub(from, to), from = from, to = to })
	end
	while i <= n do
		local c = source:sub(i, i)
		if c:match("%s") then
			local _, e = source:find("^%s+", i)
			push("space", i, e :: number)
			i = (e :: number) + 1
		elseif source:sub(i, i + 1) == "--" then
			local eq = source:match("^%-%-%[(=*)%[", i)
			if eq then
				local _, e = source:find("%]" .. eq .. "%]", i)
				e = e or n
				push("comment", i, e)
				i = e + 1
			else
				local e = source:find("\n", i) or n + 1
				push("comment", i, e - 1)
				i = e
			end
		elseif c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = source:sub(j, j)
				if d == "\\" then
					j += 2
				elseif d == c then
					break
				else
					j += 1
				end
			end
			push("string", i, j)
			i = j + 1
		elseif source:match("^%[=*%[", i) then
			local eq = source:match("^%[(=*)%[", i)
			local _, e = source:find("%]" .. eq .. "%]", i)
			e = e or n
			push("string", i, e)
			i = e + 1
		elseif c:match("[%a_]") then
			local _, e = source:find("^[%w_]+", i)
			local text = source:sub(i, e :: number)
			push(if KEYWORDS[text] then "keyword" else "name", i, e :: number)
			i = (e :: number) + 1
		elseif c:match("%d") or (c == "." and source:sub(i + 1, i + 1):match("%d")) then
			local _, e = source:find("^[%w%.]+", i)
			push("number", i, e :: number)
			i = (e :: number) + 1
		else
			local three = source:sub(i, i + 2)
			local two = source:sub(i, i + 1)
			if three == "..." then
				push("symbol", i, i + 2)
				i += 3
			elseif two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." or two == "::" or two == "->" or two == "+=" or two == "-=" or two == "*=" or two == "/=" then
				push("symbol", i, i + 1)
				i += 2
			else
				push("symbol", i, i)
				i += 1
			end
		end
	end
	return tokens
end

-- ---------------------------------------------------------------- helpers over tokens

local OPENERS = { ["do"] = true, ["then"] = true, ["function"] = true, ["repeat"] = true }

local function isSig(t: Token): boolean
	return t.kind ~= "space" and t.kind ~= "comment"
end

-- index of the next significant token at or after i
local function nextSig(tokens: { Token }, i: number): number
	while i <= #tokens and not isSig(tokens[i]) do
		i += 1
	end
	return i
end

-- given the index of a block opener keyword (do/then/function/repeat), the index of its matching end/until
local function blockEnd(tokens: { Token }, i: number): number?
	local depth = 0
	local j = i
	while j <= #tokens do
		local t = tokens[j]
		if t.kind == "keyword" then
			if OPENERS[t.text] then
				depth += 1
			elseif t.text == "end" or t.text == "until" then
				depth -= 1
				if depth == 0 then
					return j
				end
			elseif t.text == "if" or t.text == "for" or t.text == "while" then
				-- these are followed by their own then/do; counted there
			end
		end
		j += 1
	end
	return nil
end

-- from the index just after an opening "(", the index of the matching ")"
local function parenEnd(tokens: { Token }, i: number): number?
	local depth = 1
	local j = i
	while j <= #tokens do
		local t = tokens[j]
		if t.kind == "symbol" then
			if t.text == "(" then
				depth += 1
			elseif t.text == ")" then
				depth -= 1
				if depth == 0 then
					return j
				end
			end
		end
		j += 1
	end
	return nil
end

local function textOf(tokens: { Token }, from: number, to: number): string
	local parts = {}
	for k = from, to do
		table.insert(parts, tokens[k].text)
	end
	return table.concat(parts)
end

-- split a comma-separated argument list (token range) into expression strings at depth 0
local function splitArgs(tokens: { Token }, from: number, to: number): { string }
	local args = {}
	local depth = 0
	local start = from
	for k = from, to do
		local t = tokens[k]
		if t.kind == "symbol" then
			if t.text == "(" or t.text == "{" or t.text == "[" then
				depth += 1
			elseif t.text == ")" or t.text == "}" or t.text == "]" then
				depth -= 1
			elseif t.text == "," and depth == 0 then
				table.insert(args, textOf(tokens, start, k - 1))
				start = k + 1
			end
		end
	end
	if to >= start then
		table.insert(args, textOf(tokens, start, to))
	end
	for k, a in args do
		args[k] = a:gsub("^%s+", ""):gsub("%s+$", "")
	end
	return args
end

-- split an already-expanded argument string at depth-0 commas
local function splitArgText(text: string): { string }
	local args = {}
	local depth = 0
	local start = 1
	local i = 1
	local n = #text
	while i <= n do
		local c = text:sub(i, i)
		if c == '"' or c == "'" then
			local j = i + 1
			while j <= n and text:sub(j, j) ~= c do
				if text:sub(j, j) == "\\" then
					j += 1
				end
				j += 1
			end
			i = j
		elseif c == "(" or c == "{" or c == "[" then
			depth += 1
		elseif c == ")" or c == "}" or c == "]" then
			depth -= 1
		elseif c == "," and depth == 0 then
			table.insert(args, text:sub(start, i - 1))
			start = i + 1
		end
		i += 1
	end
	table.insert(args, text:sub(start))
	for k, arg in args do
		args[k] = arg:gsub("^%s+", ""):gsub("%s+$", "")
	end
	return args
end

-- ---------------------------------------------------------------- the rewrite

type Notes = { string }

-- expand c.get / c.add / c.has calls whose first argument is `kindVar` inside tokens[from..to]
-- mode "dense": every component is required here, values sit at the entity position
-- mode "general": the entity's index into each component was computed once as c__at (only when the second argument is nVar)
-- mode "plain": no per-entity index available, expand each access on its own
local function expandCalls(tokens: { Token }, from: number, to: number, kindVar: string, nVar: string?, mode: string, used: { [string]: boolean }, notes: Notes): string
	local out = {}
	local k = from
	while k <= to do
		local t = tokens[k]
		local handled = false
		if t.kind == "name" then
			local dot = nextSig(tokens, k + 1)
			local fn = nextSig(tokens, dot + 1)
			local paren = nextSig(tokens, fn + 1)
			if dot <= to and tokens[dot].text == "." and tokens[fn].kind == "name" and tokens[paren].text == "("
				and (tokens[fn].text == "get" or tokens[fn].text == "add" or tokens[fn].text == "has") then
				local prev = k - 1
				while prev >= 1 and not isSig(tokens[prev]) do
					prev -= 1
				end
				local prevText = if prev >= 1 then tokens[prev].text else ""
				local close = parenEnd(tokens, paren + 1)
				if prevText ~= "." and prevText ~= ":" and close and close <= to then
					local args = splitArgText(expandCalls(tokens, paren + 1, close - 1, kindVar, nVar, mode, used, notes))
					if args[1] == kindVar then
						local c = t.text
						local which = tokens[fn].text
						local n = args[2]
						local b, v, sl, at = c .. "__b", c .. "__v", c .. "__s", c .. "__at"
						local off = "(" .. n .. " - 1) * 4"
						local recompute = ("if %s then (if %s <= %s.cap then buffer.readu32(%s, %s) else 0) else %s"):format(sl, n, b, sl, off, n)
						local text
						if mode == "dense" then
							if which == "get" and #args == 2 then
								text = ("%s[%s]"):format(v, n)
							elseif which == "has" and #args == 2 then
								text = ("(%s[%s] ~= nil)"):format(v, n)
							elseif which == "add" and #args == 3 then
								text = ("if %s__i then %s.add(%s, %s, %s) else %s[%s] = %s end"):format(c, c, kindVar, n, args[3], v, n, args[3])
							end
						elseif mode == "general" and n == nVar then
							if which == "get" and #args == 2 then
								text = ("%s[%s]"):format(v, at)
							elseif which == "has" and #args == 2 then
								text = ("(%s[%s] ~= nil)"):format(v, at)
							elseif which == "add" and #args == 3 then
								text = ("if %s__i or %s == 0 then %s.add(%s, %s, %s) %s = %s else %s[%s] = %s end"):format(c, at, c, kindVar, n, args[3], at, recompute, v, at, args[3])
							end
						else
							if which == "get" and #args == 2 then
								text = ("(if %s then (if %s <= %s.cap then %s[buffer.readu32(%s, %s)] else nil) else %s[%s])"):format(sl, n, b, v, sl, off, v, n)
							elseif which == "has" and #args == 2 then
								text = ("(if %s then (%s <= %s.cap and buffer.readu32(%s, %s) ~= 0) else %s[%s] ~= nil)"):format(sl, n, b, sl, off, v, n)
							elseif which == "add" and #args == 3 then
								text = ("do local %s__one = %s; if %s__i or %s__one == 0 then %s.add(%s, %s, %s) else %s[%s__one] = %s end end"):format(
									c, recompute, c, c, c, kindVar, n, args[3], v, c, args[3])
							end
						end
						if text then
							table.insert(out, text)
							used[c] = true
							table.insert(notes, which .. " on " .. c)
							k = close + 1
							handled = true
						end
					end
				end
			end
		end
		if not handled then
			table.insert(out, t.text)
			k += 1
		end
	end
	return table.concat(out)
end

local function hoist(used: { [string]: boolean }, kindVar: string, indent: string): string
	local names = {}
	for c in used do
		table.insert(names, c)
	end
	table.sort(names)
	local lines = {}
	for _, c in names do
		table.insert(lines, ("%slocal %s__b = %s.of(%s)\n%slocal %s__v, %s__s, %s__i = %s__b.value, %s__b.slot, %s.indexed\n"):format(
			indent, c, c, kindVar, indent, c, c, c, c, c, c))
	end
	return table.concat(lines)
end

local function indentBefore(source: string, pos: number): string
	local lineStart = pos
	while lineStart > 1 and source:sub(lineStart - 1, lineStart - 1) ~= "\n" do
		lineStart -= 1
	end
	return source:sub(lineStart, pos - 1):match("^%s*") or ""
end

local function rewrite(source: string): (string, Notes)
	local notes: Notes = {}
	local tokens = lex(source)
	local out = {}
	local i = 1
	local n = #tokens

	while i <= n do
		local t = tokens[i]
		local handled = false

		if t.kind == "keyword" and t.text == "for" then
			-- for kind, n in c.each() do ... end
			local a = nextSig(tokens, i + 1)
			local comma = nextSig(tokens, a + 1)
			local b = nextSig(tokens, comma + 1)
			local inKw = nextSig(tokens, b + 1)
			local c = nextSig(tokens, inKw + 1)
			local dot = nextSig(tokens, c + 1)
			local fn = nextSig(tokens, dot + 1)
			local open = nextSig(tokens, fn + 1)
			local close = nextSig(tokens, open + 1)
			local doKw = nextSig(tokens, close + 1)
			if tokens[a] and tokens[a].kind == "name" and tokens[comma] and tokens[comma].text == "," and tokens[b] and tokens[b].kind == "name"
				and tokens[inKw] and tokens[inKw].text == "in" and tokens[c] and tokens[c].kind == "name" and tokens[dot] and tokens[dot].text == "."
				and tokens[fn] and (tokens[fn].text == "each") and tokens[open] and tokens[open].text == "(" and tokens[close] and tokens[close].text == ")"
				and tokens[doKw] and tokens[doKw].text == "do" then
				local finish = blockEnd(tokens, doKw)
				if finish then
					local kindVar, nVar, comp = tokens[a].text, tokens[b].text, tokens[c].text
					local indent = indentBefore(source, t.from)
					local inner = indent .. "\t"
					local used: { [string]: boolean } = { [comp] = true }
					local dense = expandCalls(tokens, doKw + 1, finish - 1, kindVar, nVar, "dense", used, notes)
					local general = expandCalls(tokens, doKw + 1, finish - 1, kindVar, nVar, "general", used, {})
					-- the body was one level inside the for; it now sits three deep (for, if, for)
					dense = dense:gsub("\n" .. indent .. "\t", "\n" .. indent .. "\t\t\t"):gsub("%s+$", "")
					general = general:gsub("\n" .. indent .. "\t", "\n" .. indent .. "\t\t\t"):gsub("%s+$", "")
					local names = {}
					for name in used do
						table.insert(names, name)
					end
					table.sort(names)
					local conds, ats = {}, {}
					for _, name in names do
						table.insert(conds, "not " .. name .. "__s")
						if name == comp then
							-- the driving component: its value sits at the loop index, dense or sparse
							table.insert(ats, ("%slocal %s__at = %s__m"):format(inner .. "\t\t", name, name))
						else
							table.insert(ats, ("%slocal %s__at = if %s__s then (if %s <= %s__b.cap then buffer.readu32(%s__s, (%s - 1) * 4) else 0) else %s"):format(
								inner .. "\t\t", name, name, nVar, name, name, nVar, nVar))
						end
					end
					local has = comp .. "__has"
					local m = comp .. "__m"
					local lines = {
						("for _, %s in %s.kinds() do"):format(kindVar, comp),
						hoist(used, kindVar, inner):gsub("%s+$", ""),
						("%slocal %s = %s__b.has"):format(inner, has, comp),
						("%sif %s then"):format(inner, table.concat(conds, " and ")),
						("%s\tfor %s = 1, #%s do"):format(inner, m, has),
						("%s\t\tlocal %s = %s[%s]"):format(inner, nVar, has, m) .. dense,
						("%s\tend"):format(inner),
						("%selse"):format(inner),
						("%s\tfor %s = 1, #%s do"):format(inner, m, has),
						("%s\t\tlocal %s = %s[%s]"):format(inner, nVar, has, m),
					}
					for _, line in ats do
						table.insert(lines, line)
					end
					table.insert(lines, (general:gsub("^\n", "")))
					table.insert(lines, ("%s\tend"):format(inner))
					table.insert(lines, ("%send"):format(inner))
					table.insert(lines, ("%send"):format(indent))
					local text = table.concat(lines, "\n")
					table.insert(out, text)
					table.insert(notes, "each on " .. comp)
					i = finish + 1
					handled = true
				end
			elseif tokens[a] and tokens[a].kind == "name" and tokens[comma] and tokens[comma].text == "," and tokens[b] and tokens[b].kind == "name"
				and tokens[inKw] and tokens[inKw].text == "in" and tokens[c] and tokens[c].kind == "name" and tokens[dot] and tokens[dot].text == "."
				and tokens[fn] and tokens[fn].text == "kinds" and tokens[open] and tokens[open].text == "(" and tokens[close] and tokens[close].text == ")"
				and tokens[doKw] and tokens[doKw].text == "do" then
				-- for _, kind in c.kinds() do ... end : expand calls on `kind` inside, hoist buckets at the top
				local finish = blockEnd(tokens, doKw)
				if finish then
					local kindVar = tokens[b].text
					local indent = indentBefore(source, t.from)
					local used: { [string]: boolean } = {}
					local body = expandCalls(tokens, doKw + 1, finish - 1, kindVar, nil, "plain", used, notes)
					local head = textOf(tokens, i, doKw)
					local text = head .. "\n" .. hoist(used, kindVar, indent .. "\t") .. body:gsub("^\n", "") .. "end"
					table.insert(out, text)
					i = finish + 1
					handled = true
				end
			end
		elseif t.kind == "keyword" and t.text == "local" then
			-- local n, p, pi, v, vi = c.join(kind, d) followed by for i = 1, n do ... end
			local names = {}
			local k = nextSig(tokens, i + 1)
			while tokens[k] and tokens[k].kind == "name" do
				table.insert(names, tokens[k].text)
				local sep = nextSig(tokens, k + 1)
				if tokens[sep] and tokens[sep].text == "," then
					k = nextSig(tokens, sep + 1)
				else
					k = sep
					break
				end
			end
			local eq = k
			local c = nextSig(tokens, eq + 1)
			local dot = nextSig(tokens, c + 1)
			local fn = nextSig(tokens, dot + 1)
			local open = nextSig(tokens, fn + 1)
			if #names == 5 and tokens[eq] and tokens[eq].text == "=" and tokens[c] and tokens[c].kind == "name" and tokens[dot] and tokens[dot].text == "."
				and tokens[fn] and tokens[fn].text == "join" and tokens[open] and tokens[open].text == "(" then
				local close = parenEnd(tokens, open + 1)
				if close then
					local args = splitArgs(tokens, open + 1, close - 1)
					local forKw = nextSig(tokens, close + 1)
					local iv = nextSig(tokens, forKw + 1)
					local eq2 = nextSig(tokens, iv + 1)
					local one = nextSig(tokens, eq2 + 1)
					local comma = nextSig(tokens, one + 1)
					local lim = nextSig(tokens, comma + 1)
					local doKw = nextSig(tokens, lim + 1)
					if #args == 2 and tokens[forKw] and tokens[forKw].text == "for" and tokens[iv] and tokens[iv].kind == "name" and tokens[eq2] and tokens[eq2].text == "="
						and tokens[one] and tokens[one].text == "1" and tokens[comma] and tokens[comma].text == "," and tokens[lim] and tokens[lim].text == names[1]
						and tokens[doKw] and tokens[doKw].text == "do" then
						local finish = blockEnd(tokens, doKw)
						if finish then
							local kindVar = args[1]
							local loopVar = tokens[iv].text
							local pi, vi = names[3], names[5]
							local indent = indentBefore(source, t.from)
							local general = textOf(tokens, forKw, finish)
							-- identity clone: pi[loopVar] and vi[loopVar] become loopVar
							local identity = general
							for _, idx in { pi, vi } do
								identity = identity:gsub("%f[%w_]" .. idx .. "%s*%[%s*" .. loopVar .. "%s*%]", loopVar)
							end
							local decl = textOf(tokens, i, close)
							local text = ("%s\n%sif %s == %s.has and %s == %s.has then\n%s\t%s\n%selse\n%s\t%s\n%send"):format(
								decl, indent, pi, kindVar, vi, kindVar, indent, identity:gsub("\n", "\n\t"), indent, indent, general:gsub("\n", "\n\t"), indent)
							table.insert(out, text)
							table.insert(notes, "join on " .. tokens[c].text)
							i = finish + 1
							handled = true
						end
					end
				end
			end
		end

		if not handled then
			table.insert(out, t.text)
			i += 1
		end
	end
	return table.concat(out), notes
end

-- ---------------------------------------------------------------- files

local function build(text: string, label: string): string
	local result, notes = rewrite(text)
	local header = ("-- built by Inline from %s"):format(label)
	if #notes > 0 then
		header ..= " (" .. table.concat(notes, ", ") .. ")"
	end
	-- keep the --! directives first: the header goes after them
	local directives = {}
	local rest = result
	while true do
		local line = rest:match("^%-%-!.-\n")
		if not line then
			break
		end
		table.insert(directives, line)
		rest = rest:sub(#line + 1)
	end
	return table.concat(directives) .. header .. "\n" .. rest
end

local from = process.args[1]
if not from then
	print("usage: lune run scripts/inline <folder> [out folder]")
	process.exit(1)
end
from = from:gsub("[/\\]+$", "")
local name = from:match("([^/\\]+)$") :: string
local parent = from:sub(1, #from - #name - 1)
local out = process.args[2] or ((if #parent > 0 then parent .. "/" else "") .. "Built/" .. name)
fs.writeDir(out)

local built, kept = 0, 0
for _, file in fs.readDir(from) do
	if file:match("%.luau$") and fs.isFile(from .. "/" .. file) then
		local text = build(fs.readFile(from .. "/" .. file), name .. "." .. file:gsub("%.luau$", ""))
		local target = out .. "/" .. file
		if fs.isFile(target) and fs.readFile(target) == text then
			kept += 1
		else
			fs.writeFile(target, text)
			built += 1
			print("built " .. target)
		end
	end
end
print(("%d built, %d unchanged -> %s"):format(built, kept, out))
