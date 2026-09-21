--!strict
-- Beef under Lune, loaded the way Roblox loads it: `scripts/test` and `scripts/live` both come through here.
--
-- Beef's modules require each other through `script`, so this loads them with a stand-in `script` whose
-- children are files: `script.Parent.Wire` is `src/Wire.luau`, `script.Stock.Send` is `src/Stock/Send.luau`,
-- and a folder with `init.luau` is a module with children. Roblox datatypes come from `@lune/roblox`; `game`
-- and every service it hands out are inert stand-ins that accept any call and connect any signal, so a module
-- loads even where it touches the engine at the top. What a run needs to be real, it makes real through the
-- driver.
--
-- `load()` is a whole fresh Beef and `module(path)` is one file under src; two calls are two Beefs that share
-- nothing, which is what lets a spec stand two servers side by side.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local ROOT = process.cwd:gsub("[/\\]+$", "")
local SRC = ROOT .. "/src"

-- an object that accepts anything: any field is itself, any call returns itself, any signal connects
local anything: any
anything = setmetatable({}, {
	__index = function(_, key)
		if key == "Name" then
			return "stub"
		end
		return anything
	end,
	__call = function()
		return anything
	end,
	__tostring = function()
		return "<stub>"
	end,
	__newindex = function() end,
})

local function stubGame(): any
	return anything
end

-- a stand-in for `script`: a file or folder under src, indexable by child name
type Node = { path: string, isModule: boolean, dir: string?, name: string }

-- everything under src is scanned and read before any module runs: a loaded chunk cannot yield,
-- and Lune's filesystem calls do
local files: { [string]: boolean } = {}
local dirs: { [string]: boolean } = {}
local sources: { [string]: string } = {}

local function scan(dir: string)
	dirs[dir] = true
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			scan(path)
		elseif entry:match("%.luau$") then
			files[path] = true
			sources[path] = fs.readFile(path)
		end
	end
end
scan(SRC)

local function nodeFor(dir: string, name: string): Node?
	local file = dir .. "/" .. name .. ".luau"
	if files[file] then
		return { path = file, isModule = true, dir = nil, name = name }
	end
	local folder = dir .. "/" .. name
	if dirs[folder] then
		local init = folder .. "/init.luau"
		return { path = init, isModule = files[init] == true, dir = folder, name = name }
	end
	return nil
end

local function childDir(node: Node): string
	return if node.dir ~= nil then node.dir else node.path:gsub("/[^/]+$", "")
end

local function parentOf(node: Node): Node
	local dir = childDir(node)
	if node.dir == nil then
		-- a file's parent is its folder, which is a module if it has init.luau
		local parentName = dir:match("([^/]+)$") :: string
		local grand = dir:gsub("/[^/]+$", "")
		return nodeFor(grand, parentName) or { path = dir .. "/init.luau", isModule = false, dir = dir, name = parentName }
	end
	local grand = dir:gsub("/[^/]+$", "")
	local parentName = grand:match("([^/]+)$") :: string
	local great = grand:gsub("/[^/]+$", "")
	return nodeFor(great, parentName) or { path = grand .. "/init.luau", isModule = false, dir = grand, name = parentName }
end

local function makeLoader()
	local cache: { [string]: any } = {}
	local proxies: { [string]: any } = {}
	local requireNode: (Node) -> any

	local function proxyFor(node: Node): any
		local key = node.path .. (if node.dir then "/" else "")
		local found = proxies[key]
		if found ~= nil then
			return found
		end
		local proxy = setmetatable({}, {
			__index = function(_, field: any)
				if field == "Parent" then
					return proxyFor(parentOf(node))
				elseif field == "Name" then
					return node.name
				elseif field == "__node" then
					return node
				elseif field == "WaitForChild" or field == "FindFirstChild" then
					return function(_, childName: string)
						local child = nodeFor(childDir(node), childName)
						return if child then proxyFor(child) else nil
					end
				end
				local child = nodeFor(childDir(node), field)
				if child == nil then
					error(("[test] %s has no child %s"):format(node.path, tostring(field)), 2)
				end
				return proxyFor(child)
			end,
			__tostring = function()
				return node.path
			end,
		})
		proxies[key] = proxy
		return proxy
	end

	local function requireAny(target: any): any
		if type(target) == "string" then
			return require(target)
		end
		local node = target.__node
		if node == nil then
			error("[test] require of something that is not a module: " .. tostring(target), 2)
		end
		return requireNode(node)
	end

	requireNode = function(node: Node): any
		if not node.isModule then
			error("[test] not a module: " .. node.path, 2)
		end
		local hit = cache[node.path]
		if hit ~= nil then
			return hit
		end
		local source = sources[node.path]
		local env = {
			script = proxyFor(node),
			require = requireAny,
			game = stubGame(),
			workspace = anything,
			Instance = anything,
			Actor = anything,
			SharedTable = anything,
			Vector3 = roblox.Vector3,
			Vector2 = roblox.Vector2,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			UDim2 = roblox.UDim2,
			UDim = roblox.UDim,
			Enum = roblox.Enum,
		}
		local fn = luau.load(source, {
			debugName = node.path:sub(#ROOT + 2),
			environment = env,
			injectGlobals = true,
			codegenEnabled = false,
		})
		local result = fn()
		cache[node.path] = if result == nil then true else result
		return result
	end

	return {
		beef = function(): any
			local init = nodeFor(ROOT, "src") :: Node
			return requireNode(init)
		end,
		module = function(rel: string): any
			local dir, name = rel:match("^(.-)/?([^/]+)$")
			local node = nodeFor(SRC .. (if dir ~= "" then "/" .. dir else ""), name)
			if node == nil then
				error("[test] no module " .. rel, 2)
			end
			return requireNode(node)
		end,
	}
end


return {
	roblox = roblox,
	root = ROOT,
	load = function(): any
		return makeLoader().beef()
	end,
	module = function(rel: string): any
		return makeLoader().module(rel)
	end,
}
