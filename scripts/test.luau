--!strict
-- Headless suite under Lune: `lune run scripts/test [SpecName ...]`.
--
-- A spec is `test/<Name>Spec.luau` returning `function(T)`. T has `case`, `eq`, `ok`, `throws`, `load()` for a
-- fresh Beef, `module(path)` for one file under src, and `roblox` for datatypes. The loading itself is
-- `scripts/loader`, which the live rig uses too.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Loader = require("./loader")

local ROOT = process.cwd:gsub("[/\\]+$", "")
local TEST = ROOT .. "/test"

-- the harness a spec is handed
local failures: { string } = {}
local cases = 0
local current = "?"

local T: any = {}
T.roblox = roblox
T.load = Loader.load
T.module = Loader.module
T.case = function(name: string, body: () -> ())
	cases += 1
	local okRun, err = pcall(body)
	if not okRun then
		table.insert(failures, ("%s / %s: %s"):format(current, name, tostring(err)))
	end
end
T.eq = function(got: any, want: any, what: string?)
	if got ~= want then
		error(("%s: got %s, want %s"):format(what or "eq", tostring(got), tostring(want)), 2)
	end
end
T.ok = function(cond: any, what: string?)
	if not cond then
		error(what or "expected truthy", 2)
	end
end
T.throws = function(fn: () -> (), pattern: string?, what: string?)
	local okRun, err = pcall(fn)
	if okRun then
		error((what or "expected an error") .. ": nothing was thrown", 2)
	end
	if pattern ~= nil and not tostring(err):find(pattern) then
		error(("%s: error %q does not match %q"):format(what or "throws", tostring(err), pattern), 2)
	end
end

-- which specs
local wanted: { [string]: boolean }? = nil
if #process.args > 0 then
	wanted = {}
	for _, a in process.args do
		(wanted :: any)[a:gsub("Spec$", "") .. "Spec"] = true
	end
end

local names: { string } = {}
for _, entry in fs.readDir(TEST) do
	local name = entry:match("^(.+Spec)%.luau$")
	if name ~= nil and (wanted == nil or wanted[name]) then
		table.insert(names, name)
	end
end
table.sort(names)

for _, name in names do
	current = name
	local source = fs.readFile(TEST .. "/" .. name .. ".luau")
	local fn = luau.load(source, {
		debugName = "test/" .. name .. ".luau",
		environment = {
			require = function(target: any)
				if type(target) == "string" then
					return require(target)
				end
				error("[test] a spec requires by path string only", 2)
			end,
			Vector3 = roblox.Vector3,
			Vector2 = roblox.Vector2,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
		},
		injectGlobals = true,
			codegenEnabled = false,
	})
	local okLoad, spec = pcall(fn)
	if not okLoad then
		table.insert(failures, ("%s: failed to load: %s"):format(name, tostring(spec)))
		continue
	end
	local okRun, err = pcall(spec, T)
	if not okRun then
		table.insert(failures, ("%s: threw outside a case: %s"):format(name, tostring(err)))
	end
end

if #failures > 0 then
	print(("[Beef] %d case(s) in %d spec(s), %d FAILURE(S):"):format(cases, #names, #failures))
	for _, f in failures do
		print("  - " .. f)
	end
	process.exit(1)
else
	print(("[Beef] %d case(s) in %d spec(s), all green"):format(cases, #names))
end
