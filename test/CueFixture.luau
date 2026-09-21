--!strict

-- The world every cue spec runs in. One Kind carries the columns content reads, each primitive
-- asks on its own Event, and a controller answers every push on it. A spec declares whatever else
-- it needs, then runs frames: `fx.frame()` is one Phase run, which passes until nothing moved, so
-- a sequence started in it resolves in it.

local Fixture = {}

local FRAME = 1 / 60

-- `extend` runs after the stock vocabulary is declared and before the Phase is built, which is
-- where a spec puts a primitive of its own and the controller that answers it
function Fixture.game(Beef: any, extend: ((any, any) -> ())?): any
	local Cue = Beef.Cue
	local Components = Beef.Components
	local Events = Beef.Events
	local Kinds = Beef.Kinds
	local Phase = Beef.Phase

	local world = {
		sounds = {} :: { string },
		launches = {} :: { any },
		flags = {} :: { [string]: any },
		log = {} :: { string },
		quivers = {} :: { [number]: { number } },
	}

	local Name = Components.new("name")
	local Hp = Components.new("hp")
	local Stamina = Components.new("stamina")
	local Damage = Components.new("damage")
	local Armour = Components.new("armour")
	local Stacks = Components.new("stacks")
	local Thing = Kinds.new("thing", Name, Hp, Stamina, Damage, Armour)

	local function set(e: number, component: any, value: any)
		local kind = Cue.kind(e)
		local n = kind.at(Cue.handle(e))
		if n ~= nil then
			component.add(kind, n, value)
		end
	end

	-- every primitive's ask, its columns exactly the keys it takes plus the seq an answer names
	local Hurt = Events.new("hurt", "to", "by", "damage", "over", "per", "seq:u32")
	-- `count` is one of an Event's own fields, so the stack primitive takes its own key for it
	local Stack = Events.new("stack", "to", "stacks", "seq:u32")
	local Sound = Events.new("sound", "id", "at", "seq:u32")
	local Occupy = Events.new("occupy", "to", "seq:u32")
	local Take = Events.new("take", "to", "ammo", "seq:u32")
	local Spend = Events.new("spend", "to", "stamina", "seq:u32")
	local Charge = Events.new("charge", "minMs", "maxMs", "seq:u32")
	local Launch = Events.new("launch", "to", "at", "speed", "seq:u32")

	-- one bound anchor, so a push is a firing; the columns beside `self` are the firing's context
	local Hit = Events.new("hit", "self", "victim", "attacker", "holder", "marker")

	local cue = Cue.new():defaults()

	cue:key("stamina", { type = "amount", means = "the wind it costs" })
	cue:key("speed", { type = "amount", means = "how fast it leaves" })
	cue:key("minMs", { type = "amount", means = "the shortest legal charge" })
	cue:key("maxMs", { type = "amount", means = "the longest charge" })
	cue:key("ammo", { type = "tag", means = "which ammo to draw" })
	cue:key("stacks", { type = "amount", means = "how many pile on" })

	cue:field("damage", { type = "amount", component = Damage, means = "how much harm this thing does" })
	cue:field("hp", { type = "amount", component = Hp, means = "life" })
	cue:field("stamina", { type = "amount", component = Stamina, means = "wind" })
	cue:field("armour", { type = "amount", component = Armour, means = "how much it turns" })

	cue:anchor("Hit", { event = Hit, self = "self" })

	cue:gate("ends", {
		test = function(value: any)
			return world.flags[value] == true
		end,
		means = "remove when this world flag is set",
	})

	cue:schedule("once", {
		kind = "await",
		ready = function(value: any)
			return world.flags[value] == true
		end,
		means = "wait until this happens",
	})

	cue:primitive("hurt", {
		takes = {
			to = "the body harmed", by = "who is doing the harm", damage = "the harm",
			over = "the harm lands smoothly across this span instead of at once",
			per = "the harm is a rate: this much each period, until stopped",
		},
		refuses = { "to", "damage" },
		event = Hurt,
		means = "take life from a body",
	})

	cue:primitive("stack", {
		takes = { to = "the body stacked", stacks = "how many" },
		refuses = { "to" },
		event = Stack,
		means = "pile something onto a body",
	})

	cue:primitive("sound", {
		takes = { id = "which sound", at = "where it plays" },
		refuses = {},
		event = Sound,
		means = "make a noise",
	})

	cue:primitive("occupy", {
		takes = { to = "whose body" },
		refuses = { "to" },
		event = Occupy,
		means = "claim the body for this act",
	})

	cue:primitive("take", {
		takes = { to = "whose store", ammo = "what kind" },
		returns = "entity",
		refuses = { "ammo" },
		event = Take,
		means = "draw one from a store",
	})

	cue:primitive("spend", {
		takes = { to = "who pays", stamina = "the wind" },
		refuses = { "stamina" },
		event = Spend,
		means = "pay wind for an act",
	})

	cue:primitive("charge", {
		takes = { minMs = "the floor", maxMs = "the cap" },
		returns = "amount",
		refuses = { "minMs" },
		event = Charge,
		means = "read how long the input was held, as a fraction of the legal range",
	})

	cue:primitive("launch", {
		takes = { to = "what flies", at = "toward where", speed = "how fast" },
		refuses = { "to", "speed" },
		event = Launch,
		means = "send a thing flying",
	})

	-- a controller that answers every push on one ask, done or refused, in the pass it reads it
	local function answering(name: string, handle: (any, number) -> ())
		return function(event: any): any
			return {
				name = name,
				reads = { event },
				writes = { event.done, event.refused },
				loop = function()
					for i = event.from, event.last do
						handle(event, i)
					end
				end,
			}
		end
	end

	local function land(to: number, amount: number)
		set(to, Hp, (Cue.read(to, Hp) or 0) - amount)
		table.insert(world.log, ("hurt %s %.3f"):format(tostring(Cue.read(to, Name)), amount))
	end

	-- `over` and `per` are columns this controller spreads: it keeps the remainder itself and
	-- lands a slice a frame against the phase's clock, so cue never holds a tick of its own
	local spreads: { any } = {}
	local function Hurting(event: any): any
		local controller: any
		controller = {
			name = "Hurting",
			reads = { event },
			writes = { event.done, event.refused },
			pre = function()
				local dt = controller.phase.dt
				if dt <= 0 or #spreads == 0 then
					return
				end
				local i = 1
				while i <= #spreads do
					local s = spreads[i]
					local finished = false
					if not Cue.alive(s.to) then
						finished = true
					elseif s.span ~= nil then
						local slice = math.min(dt, s.left)
						land(s.to, s.damage * slice / s.span)
						s.left -= slice
						finished = s.left <= 0
					else
						land(s.to, s.damage * dt / s.period)
					end
					if finished then
						local last = #spreads
						spreads[i] = spreads[last]
						spreads[last] = nil
					else
						i += 1
					end
				end
			end,
			loop = function()
				for i = event.from, event.last do
					local to = event.to[i]
					local damage = event.damage[i]
					local over = event.over[i]
					local per = event.per[i]
					if over ~= nil then
						table.insert(spreads, { to = to, damage = damage, span = over, left = over })
					elseif per ~= nil then
						table.insert(spreads, { to = to, damage = damage, period = per })
					else
						land(to, damage)
					end
					event.done.push(event.seq[i])
				end
			end,
		}
		return controller
	end

	local Stacking = answering("Stacking", function(e: any, i: number)
		local to = e.to[i]
		set(to, Stacks, (Cue.read(to, Stacks) or 0) + e.stacks[i])
		e.done.push(e.seq[i])
	end)

	local Sounding = answering("Sounding", function(e: any, i: number)
		table.insert(world.sounds, e.id[i])
		e.done.push(e.seq[i])
	end)

	local Occupying = answering("Occupying", function(e: any, i: number)
		if world.flags.bodyBusy then
			e.refused.push(e.seq[i], "to")
			return
		end
		world.flags.bodyBusy = true
		e.done.push(e.seq[i])
	end)

	local Taking = answering("Taking", function(e: any, i: number)
		local quiver = world.quivers[e.to[i]]
		if quiver == nil or #quiver == 0 then
			e.refused.push(e.seq[i], "ammo")
			return
		end
		e.done.push(e.seq[i], table.remove(quiver))
	end)

	local Spending = answering("Spending", function(e: any, i: number)
		local to = e.to[i]
		local have = Cue.read(to, Stamina) or 0
		if have < e.stamina[i] then
			e.refused.push(e.seq[i], "stamina")
			return
		end
		set(to, Stamina, have - e.stamina[i])
		e.done.push(e.seq[i])
	end)

	local Charging = answering("Charging", function(e: any, i: number)
		local held = world.flags.chargeHeldMs or 0
		local floor = e.minMs[i]
		if held < floor then
			e.refused.push(e.seq[i], "minMs")
			return
		end
		e.done.push(e.seq[i], math.clamp((held - floor) / (e.maxMs[i] - floor), 0, 1))
	end)

	local Launching = answering("Launching", function(e: any, i: number)
		table.insert(world.launches, { what = e.to[i], at = e.at[i], speed = e.speed[i] })
		e.done.push(e.seq[i])
	end)

	local fx: any = {}
	fx.cue = cue
	fx.world = world
	fx.Beef = Beef
	fx.Thing = Thing
	fx.Name, fx.Hp, fx.Stamina, fx.Damage, fx.Armour, fx.Stacks = Name, Hp, Stamina, Damage, Armour, Stacks
	fx.Hurt, fx.Stack, fx.Sound, fx.Occupy = Hurt, Stack, Sound, Occupy
	fx.Take, fx.Spend, fx.Charge, fx.Launch, fx.Hit = Take, Spend, Charge, Launch, Hit
	fx.set = set

	function fx.entity(name: string, stats: { [string]: number }?): number
		local s = stats or {}
		return Cue.entity(Thing, Thing.spawn(name, s.hp, s.stamina, s.damage, s.armour))
	end

	function fx.kill(e: number)
		Thing.despawn(Cue.handle(e))
	end

	function fx.get(e: number, component: any): any?
		return Cue.read(e, component)
	end

	-- the set number cue keeps on an entity, or nil when it holds none
	function fx.held(e: number): number?
		return Cue.read(e, Cue.Attached)
	end

	function fx.quiver(e: number): { number }
		local held = world.quivers[e]
		if held == nil then
			held = {}
			world.quivers[e] = held
		end
		return held
	end

	local extra: { any } = {}

	-- a spec that declares its own primitive hands in the controller that answers it
	function fx.answer(name: string, event: any, handle: (any, number) -> ())
		table.insert(extra, { answering(name, handle), event })
	end

	if extend ~= nil then
		extend(cue, fx)
	end

	local entries: { any } = {
		cue:entry(),
		{ Hurting, Hurt },
		{ Stacking, Stack },
		{ Sounding, Sound },
		{ Occupying, Occupy },
		{ Taking, Take },
		{ Spending, Spend },
		{ Charging, Charge },
		{ Launching, Launch },
	}
	for _, entry in extra do
		table.insert(entries, entry)
	end
	-- the Phase takes its cursors where the buffers stand now, so it is built before a spec pushes
	local phase = Phase.new("cue", entries)

	function fx.phase(): any
		return phase
	end

	-- one frame: the Phase passes until nothing moved, so a chain started here finishes here
	function fx.frame(dt: number?)
		phase.dt = dt or FRAME
		phase.run()
	end

	-- a run of frames, for anything that waits on the clock
	function fx.seconds(total: number, dt: number?)
		local step = dt or FRAME
		local left = total
		while left > 1e-9 do
			local slice = math.min(step, left)
			fx.frame(slice)
			left -= slice
		end
	end

	function fx.sounds(id: string): number
		local n = 0
		for _, name in world.sounds do
			if name == id then
				n += 1
			end
		end
		return n
	end

	return fx
end

return Fixture
