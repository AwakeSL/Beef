--!strict
-- The fleet against a running relay: `lune run scripts/live`.
--
-- The relay lives in Tether's repo, not this one. Build it there and start it before this runs:
--
--     cargo build --release --manifest-path <tether>/relay/Cargo.toml
--     TETHER_PORT=47831 <tether>/relay/target/release/tether-relay
--
-- Two whole Beefs stand up here, one for each of two servers of the same game, booted off the same table and
-- talking to that relay over real HTTP. Everything `test/FleetSpec` proves against a relay written in Luau is
-- proved again here against the one a live game would use: ids minted out of a block, a placed entity's column
-- crossing, a push landing in the other server's Event buffer with an age on it, a release, and two servers
-- claiming the same thing with one winner.

local net = require("@lune/net")
local process = require("@lune/process")
local task = require("@lune/task")

local Loader = require("./loader")

local PORT = tonumber(process.env.TETHER_PORT) or 47831
local URL = ("http://127.0.0.1:%d/publish"):format(PORT)
local STATE = ("http://127.0.0.1:%d/state"):format(PORT)

local up = false
for _ = 1, 50 do
	local okPing, response = pcall(net.request, STATE)
	if okPing and response.ok then
		up = true
		break
	end
	task.wait(0.1)
end
assert(up, ("relay never came up on port %d: start it with TETHER_PORT=%d tether-relay"):format(PORT, PORT))

local failures: { string } = {}
local function check(cond: boolean, what: string)
	if not cond then
		table.insert(failures, what)
	end
end

local function http(url: string, headers: { [string]: string }, body: string): (boolean, number, string)
	local okReq, response = pcall(net.request, {
		url = url,
		method = "POST" :: any,
		headers = headers :: any,
		body = body,
	})
	if not okReq then
		return false, 0, ""
	end
	return true, response.statusCode, response.body
end

-- one server: a whole Beef, the same declaration on both sides, and a frame that stands in for the phases
local function server(identity: string): any
	local Beef = Loader.load()
	local roblox = Loader.roblox

	local Position = Beef.Components.new("position", { wire = "vector3" })
	local Health = Beef.Components.new("health", { wire = "u16" })
	local Creature = Beef.Kinds.new("creature", Position, Health)
	local Mirror = Beef.Kinds.new("mirror", Position, Health)
	local Damage = Beef.Events.new("damage", "target:u32", "amount:i32", "age:f32", { entity = "target" })

	Beef.Replicate.driver({
		isServer = function(): boolean
			return true
		end,
		now = function(): number
			return os.clock()
		end,
		link = function(): any
			return { send = function() end, receive = function() end }
		end,
		joining = function() end,
		http = http,
		spawn = function(fn: () -> ())
			task.spawn(fn)
		end,
		clock = function(): number
			return os.clock() * 1000
		end,
	})

	local wiring = Beef.Replicate({
		fleet = {
			url = URL,
			identity = identity,
			-- the relay's own beat is 125 ms, so this is the schedule it aligns posts to, and the window a
			-- moving column collapses over is the same 125 ms: one entry a flush however often it moves
			interval = 0.125,
			budget = 600,
			kinds = { Creature },
			events = { { Damage, route = "key" } },
			publish = { { Creature, Position, window = 0.125 } },
		},
	})

	local self: any = {
		Beef = Beef,
		id = identity,
		Position = Position,
		Health = Health,
		Creature = Creature,
		Mirror = Mirror,
		Damage = Damage,
		wiring = wiring,
		roblox = roblox,
		hits = {} :: { { amount: number, age: number } },
		releases = {} :: { number },
		offers = {} :: { { id: number, body: string } },
		verdicts = {} :: { boolean },
		cursors = {} :: { [any]: number },
	}

	-- what a phase would do: walk every push that landed since the last frame
	local function drain(buffer_: any, each: (number) -> ())
		local cursor = self.cursors[buffer_] or (buffer_.base + buffer_.count + 1)
		local from = math.max(cursor - buffer_.base, 1)
		for i = from, buffer_.count do
			each(i)
		end
		self.cursors[buffer_] = buffer_.base + buffer_.count + 1
	end

	self.frame = function()
		wiring.deliver()

		drain(Damage, function(i)
			table.insert(self.hits, { amount = Damage.amount[i], age = Damage.age[i] })
		end)
		drain(Beef.Replicate.released, function(i)
			table.insert(self.releases, Beef.Replicate.released.id[i])
		end)
		drain(Beef.Replicate.adopted, function(i)
			table.insert(self.offers, { id = Beef.Replicate.adopted.id[i], body = Beef.Replicate.adopted.server[i] })
		end)
		drain(Beef.Replicate.claimed, function(i)
			table.insert(self.verdicts, Beef.Replicate.claimed.server[i] ~= "")
		end)

		wiring.pack()
		Beef.Events.lap(os.clock())
		Beef.Kinds.lap()
	end

	self.fleetId = function(kind: any, handle: number): number?
		return Beef.Replicate.fleet.get(kind, kind.at(handle))
	end

	self.mirror = function(subject: number): number
		local handle = Mirror.spawn(roblox.Vector3.zero, 0)
		Beef.Replicate.fleet.add(Mirror, Mirror.at(handle), subject)
		return handle
	end

	return self
end

local a = server("beef-a")
local b = server("beef-b")

local function settle(seconds: number)
	local stop = os.clock() + seconds
	while os.clock() < stop do
		a.frame()
		b.frame()
		task.wait(0.005)
	end
end

-- ------------------------------------------------------------- the handshake

a.Beef.Replicate.want({ "zone:1" })
b.Beef.Replicate.want({ "zone:1" })
settle(0.8)

local aStats = a.Beef.Replicate.stats().fleet
check(aStats.okCount > 0, "A never got a 200 out of the relay")
check(aStats.granted > 0, "A never got a block of ids")

-- ---------------------------------------------------------- one entity, two servers

local Vector3 = Loader.roblox.Vector3
local handle = a.Creature.spawn(Vector3.new(0, 0, 0), 100)
local subject = a.fleetId(a.Creature, handle)
check(subject ~= nil, "a spawn of a fleet kind minted nothing")
a.Beef.Replicate.place(a.Creature, handle, "zone:1")
settle(0.6)

local mirror = b.mirror(subject :: number)
settle(0.4)

-- a column that moves every frame: the relay's beat is what sets the rate, not the game
local moves = 0
local stop = os.clock() + 1.5
while os.clock() < stop do
	moves += 1
	a.Position.add(a.Creature, a.Creature.at(handle), Vector3.new(moves * 0.1, 0, 0))
	a.frame()
	b.frame()
	task.wait(0.005)
end
settle(0.6)

local here = b.Position.get(b.Mirror, b.Mirror.at(mirror))
check(here ~= nil, "B's mirror never got a position")
check(here ~= nil and here.X > 0, "B's mirror is still at the origin")
local sent = a.Beef.Replicate.stats().fleet
check(sent.unchanged + sent.replaced > 0, "every offer of the same column went out whole: nothing collapsed")
check(sent.appended < moves, ("%d offers became %d entries: the buffer collapsed nothing"):format(moves, sent.appended))

-- ------------------------------------------------------------------ a push

a.Damage.push(handle, -12)
settle(0.9)
check(#b.hits == 1, ("B read %d hits, wanted 1"):format(#b.hits))
if b.hits[1] then
	check(b.hits[1].amount == -12, "the amount arrived as " .. tostring(b.hits[1].amount))
	check(b.hits[1].age > 0, "the hit arrived with no age on it")
	check(b.hits[1].age < 1, "the age is not in seconds: " .. tostring(b.hits[1].age))
end

-- ---------------------------------------------------------------- a release

a.Creature.despawn(handle)
settle(0.9)
check(#b.releases == 1 and b.releases[1] == subject, ("B heard %d releases, wanted its subject's"):format(#b.releases))

-- ------------------------------------------------------- putting a thing down

local ground = a.Creature.spawn(Vector3.new(5, 0, 5), 1)
local groundId = a.fleetId(a.Creature, ground)
check(groundId ~= nil, "no id for the thing on the ground")
a.Beef.Replicate.place(a.Creature, ground, "zone:1")
settle(0.6)
a.Beef.Replicate.adopt(groundId :: number, nil, "sword|worn")
settle(0.9)

check(#b.offers == 1, ("B saw %d things on the ground, wanted 1"):format(#b.offers))
if b.offers[1] then
	check(b.offers[1].id == groundId, "the offer named the wrong subject")
	check(b.offers[1].body == "sword|worn", "the body arrived as " .. tostring(b.offers[1].body))
end

a.Beef.Replicate.claim(groundId :: number)
b.Beef.Replicate.claim(groundId :: number)
settle(1.2)

local won = 0
for _, list in { a.verdicts, b.verdicts } do
	for _, granted in list do
		if granted then
			won += 1
		end
	end
end
check(#a.verdicts + #b.verdicts == 2, ("%d verdicts, wanted 2"):format(#a.verdicts + #b.verdicts))
check(won == 1, ("%d servers won the same sword"):format(won))

-- ------------------------------------------------------------------- report

print(net.request(STATE).body)

for name, side in { A = a, B = b } do
	local s = side.Beef.Replicate.stats().fleet
	print(
		("%s: posts=%d ok=%d failed=%d | out=%d in=%d applied=%d | unchanged=%d replaced=%d appended=%d | ids left=%d"):format(
			name,
			s.sent,
			s.okCount,
			s.failed,
			s.pushesOut + s.offered,
			s.pushesIn,
			s.applied,
			s.unchanged,
			s.replaced,
			s.appended,
			s.ids
		)
	)
	print(
		("%s tick: lead p50=%d p99=%d (n=%d) missed=%d/%d nudges=%d aim=%.1f"):format(
			name,
			s.lead.p50,
			s.lead.p99,
			s.lead.n,
			s.missed,
			s.ticks,
			s.nudges,
			s.aimMs
		)
	)
	check(s.ticks > 0, name .. " never saw a tick from the relay")
	check(s.failed == 0, ("%s had %d posts fail"):format(name, s.failed))
	check(math.abs(s.lead.p50 - 20) <= 20, ("%s lead p50 %d is off the target"):format(name, s.lead.p50))
end

if #failures > 0 then
	print(("LIVE: %d FAILURE(S):"):format(#failures))
	for _, f in failures do
		print("  - " .. f)
	end
	process.exit(1)
end
print("LIVE: all green. Minted, placed, streamed, hit, released, put down and taken")
