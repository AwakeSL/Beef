--!strict
-- Stock Sound headless: the engine is a speaker that plays nothing and writes down everything, so what a
-- push turned into is read off the record. A case pushes the game's own Events, runs the phase, and asks
-- the speaker what it was told to play, where, how loud, and what it stopped to make room.

return function(T)
	local function near(got: number, want: number, what: string?)
		if math.abs(got - want) > 1e-4 then
			error(("%s: got %s, want %s"):format(what or "near", tostring(got), tostring(want)), 2)
		end
	end

	local function vec(v: any, x: number, y: number, z: number, what: string?)
		local who = what or "at"
		T.ok(v ~= nil, who .. " is somewhere")
		near(v.X, x, who .. ".X")
		near(v.Y, y, who .. ".Y")
		near(v.Z, z, who .. ".Z")
	end

	local SHOT = "rbxassetid://1"
	local CLICK = "rbxassetid://2"

	-- a Beef, a speaker in place of the engine, and a phase with nothing in it but Sound. `make` is handed
	-- the fresh Beef and hands back the map, so each case declares the Events it needs.
	local function rig(make: (any) -> any, dt: number?): (any, any, any, any)
		local Beef = T.load()
		local speaker = Beef.Stock.speaker()
		local map = make(Beef)
		local phase = Beef.Phase.new("Sound", { { Beef.Stock.Sound, map, speaker } })
		phase.dt = dt or 1 / 60
		return Beef, speaker, phase, map
	end

	-- the commonest rig of all: one Event with no position, one entry, no options but the asset
	local function plain(): (any, any, any, any)
		local event: any = nil
		local Beef, speaker, phase = rig(function(beef)
			event = beef.Events.new("shot", "who:u32")
			return { { event, asset = SHOT } }
		end)
		return Beef, speaker, phase, event
	end

	-- ------------------------------------------------------------------ the surface

	T.case("Stock exports Sound, Duck and a speaker", function()
		local Beef = T.load()
		for _, name in { "Sound", "Duck", "speaker" } do
			T.ok(Beef.Stock[name] ~= nil, "Beef.Stock." .. name)
		end
		T.eq(type(Beef.Stock.Sound), "function", "Sound is a factory a phase can call")
		T.eq(type(Beef.Stock.speaker), "function", "and the speaker is made per test")
	end)

	T.case("Duck is one Event with two columns and nothing else", function()
		local Beef = T.load()
		local duck = Beef.Stock.Duck
		T.eq(duck.name, "duck")
		T.eq(table.concat(duck.columns, " "), "amount lasts")
		T.eq(duck.wire.amount, "f32")
		T.eq(duck.wire.lasts, "f32")
	end)

	T.case("Sound is a controller a phase runs, and the driver is started at boot", function()
		local _, speaker, phase = plain()
		T.eq(speaker.booted(), false, "nothing before the first frame")
		phase.run()
		T.eq(speaker.booted(), true, "the phase's boot took the engine")
		T.ok(phase.describe():find("Sound"), "the controller is named")
	end)

	-- ------------------------------------------------------------------ a push becomes a sound

	T.case("a push plays the sound its entry names", function()
		local _, speaker, phase, event = plain()
		phase.run()
		T.eq(#speaker.played(), 0, "a quiet frame plays nothing")

		event.push(1)
		phase.run()
		local one = speaker.last()
		T.eq(#speaker.played(), 1)
		T.eq(one.asset, SHOT)
		near(one.volume, 1, "volume")
		near(one.pitch, 1, "pitch")
		T.eq(one.at, nil, "an Event with no position is heard everywhere")
	end)

	T.case("two pushes in one frame are two sounds", function()
		local _, speaker, phase, event = plain()
		event.push(1)
		event.push(2)
		phase.run()
		T.eq(#speaker.played(), 2)
		T.eq(#speaker.playing(), 2, "and both are running")
	end)

	T.case("a push is played once, not again on the next frame", function()
		local _, speaker, phase, event = plain()
		event.push(1)
		phase.run()
		phase.run()
		phase.run()
		T.eq(#speaker.played(), 1)
	end)

	T.case("an entry's own volume and pitch reach the engine", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("shot", "who:u32")
			return { { event, asset = SHOT, volume = 0.4, pitch = 1.5 } }
		end)
		event.push(1)
		phase.run()
		near(speaker.last().volume, 0.4, "volume")
		near(speaker.last().pitch, 1.5, "pitch")
	end)

	T.case("two Events make two different sounds", function()
		local shot: any, click: any = nil, nil
		local _, speaker, phase = rig(function(beef)
			shot = beef.Events.new("shot", "who:u32")
			click = beef.Events.new("click", "what:u32")
			return { { shot, asset = SHOT }, { click, asset = CLICK } }
		end)
		click.push(1)
		phase.run()
		T.eq(speaker.last().asset, CLICK)
		shot.push(1)
		phase.run()
		T.eq(speaker.last().asset, SHOT)
	end)

	-- ------------------------------------------------------------------ where the sound is

	T.case("an Event with an at column is placed there", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("boom", "at:vector3")
			return { { event, asset = SHOT } }
		end)
		event.push(Vector3.new(10, 2, -4))
		phase.run()
		vec(speaker.last().at, 10, 2, -4)
	end)

	T.case("a CFrame in the at column is placed at its position", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("boom", "at")
			return { { event, asset = SHOT } }
		end)
		event.push(CFrame.new(1, 2, 3))
		phase.run()
		vec(speaker.last().at, 1, 2, 3)
	end)

	T.case("an Event naming an entity is placed where its Transform is", function()
		local event: any, Rock: any = nil, nil
		local _, speaker, phase = rig(function(beef)
			local Transform = beef.Components.new("transform", { wire = "vector3" })
			Rock = beef.Kinds.new("rock", Transform)
			event = beef.Events.new("broke", "kind:kind", "handle:u32")
			return { { event, asset = SHOT }, transform = Transform }
		end)
		local handle = Rock.spawn(Vector3.new(0, 5, 0))
		event.push(Rock, handle)
		phase.run()
		vec(speaker.last().at, 0, 5, 0)
	end)

	T.case("an entity that is already gone is not heard", function()
		local event: any, Rock: any = nil, nil
		local _, speaker, phase = rig(function(beef)
			local Transform = beef.Components.new("transform", { wire = "vector3" })
			Rock = beef.Kinds.new("rock", Transform)
			event = beef.Events.new("broke", "kind:kind", "handle:u32")
			return { { event, asset = SHOT }, transform = Transform }
		end)
		event.push(Rock, 99)
		phase.run()
		T.eq(#speaker.played(), 0, "no position, no sound")
	end)

	T.case("an entity that died this frame is still where it was", function()
		local event: any, Rock: any = nil, nil
		local _, speaker, phase = rig(function(beef)
			local Transform = beef.Components.new("transform", { wire = "vector3" })
			Rock = beef.Kinds.new("rock", Transform)
			event = beef.Events.new("broke", "kind:kind", "handle:u32")
			return { { event, asset = SHOT }, transform = Transform }
		end)
		local handle = Rock.spawn(Vector3.new(3, 0, 0))
		Rock.despawn(handle)
		event.push(Rock, handle)
		phase.run()
		vec(speaker.last().at, 3, 0, 0, "the last sound of a thing belongs where the thing was")
	end)

	-- ------------------------------------------------------------------ how far it carries

	T.case("a sound past what it carries is not heard", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("boom", "at:vector3")
			return { { event, asset = SHOT, carries = 50 } }
		end)
		event.push(Vector3.new(0, 0, 80))
		phase.run()
		T.eq(#speaker.played(), 0, "too far")

		event.push(Vector3.new(0, 0, 20))
		phase.run()
		T.eq(#speaker.played(), 1, "and near enough")
		near(speaker.last().carries, 50, "how far it carries goes to the engine too")
	end)

	T.case("the listener is where the driver says it is", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("boom", "at:vector3")
			return { { event, asset = SHOT, carries = 50 } }
		end)
		speaker.listen(Vector3.new(0, 0, 100))
		event.push(Vector3.new(0, 0, 80))
		phase.run()
		T.eq(#speaker.played(), 1, "the listener walked over to it")
	end)

	T.case("a sound with no carry distance is heard from anywhere", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("boom", "at:vector3")
			return { { event, asset = SHOT } }
		end)
		event.push(Vector3.new(0, 0, 9000))
		phase.run()
		T.eq(#speaker.played(), 1)
		T.eq(speaker.last().carries, nil, "and the engine is told nothing about distance")
	end)

	-- ------------------------------------------------------------------ what is in the way

	T.case("something in the way makes it quieter", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("boom", "at:vector3")
			return { { event, asset = SHOT } }
		end)
		speaker.blocks(true)
		event.push(Vector3.new(0, 0, 10))
		phase.run()
		near(speaker.last().volume, 0.35, "muffled")
		T.eq(speaker.rays(), 1, "one ray, listener to sound")
	end)

	T.case("a sound heard everywhere is never occluded", function()
		local _, speaker, phase, event = plain()
		speaker.blocks(true)
		event.push(1)
		phase.run()
		near(speaker.last().volume, 1, "nothing can be between the ears and nowhere")
		T.eq(speaker.rays(), 0, "so nothing is asked")
	end)

	T.case("a wall that goes up while it plays reaches the voice on the timer", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("boom", "at:vector3")
			return { { event, asset = SHOT } }
		end, 0.1)
		event.push(Vector3.new(0, 0, 10))
		phase.run()
		near(speaker.volumeOf(1), 1, "clear to begin with")

		speaker.blocks(true)
		phase.run()
		near(speaker.volumeOf(1), 1, "and not asked again every frame")
		phase.run()
		near(speaker.volumeOf(1), 0.35, "a quarter of a second later it is asked, and it is muffled")

		speaker.blocks(false)
		phase.run()
		phase.run()
		phase.run()
		near(speaker.volumeOf(1), 1, "and the wall coming down is heard the same way")
	end)

	-- ------------------------------------------------------------------ mixing

	T.case("a group's volume multiplies the sound's own", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("shot", "who:u32")
			return { { event, asset = SHOT, group = "effects", volume = 0.5 }, groups = { effects = 0.5 } }
		end)
		event.push(1)
		phase.run()
		near(speaker.last().volume, 0.25, "half of a half")
	end)

	T.case("turning a group down reaches a voice already playing", function()
		local event: any = nil
		local _, speaker, phase, map = rig(function(beef)
			event = beef.Events.new("shot", "who:u32")
			return { { event, asset = SHOT, group = "effects" }, groups = { effects = 1 } }
		end)
		event.push(1)
		phase.run()
		near(speaker.volumeOf(1), 1)

		map.groups.effects = 0.25
		phase.run()
		near(speaker.volumeOf(1), 0.25, "the table the game handed in is the mixer")

		event.push(2)
		phase.run()
		near(speaker.last().volume, 0.25, "and a sound starting now is quiet too")
	end)

	T.case("an entry in no group is at its own volume", function()
		local event: any = nil
		local _, speaker, phase = rig(function(beef)
			event = beef.Events.new("shot", "who:u32")
			return { { event, asset = SHOT, volume = 0.8 }, groups = { effects = 0 } }
		end)
		event.push(1)
		phase.run()
		near(speaker.last().volume, 0.8)
	end)

	-- ------------------------------------------------------------------ the voice budget

	local function budget(): (any, any, any, any)
		local event: any = nil
		local Beef, speaker, phase = rig(function(beef)
			event = beef.Events.new("boom", "at:vector3")
			return { { event, asset = SHOT, carries = 100 }, voices = 2 }
		end)
		return Beef, speaker, phase, event
	end

	T.case("the budget caps how many run at once", function()
		local _, speaker, phase, event = budget()
		event.push(Vector3.new(0, 0, 1))
		event.push(Vector3.new(0, 0, 2))
		phase.run()
		T.eq(#speaker.playing(), 2, "both, and the budget is full")
	end)

	T.case("the quietest voice loses its place to a louder one", function()
		local _, speaker, phase, event = budget()
		event.push(Vector3.new(0, 0, 90))
		event.push(Vector3.new(0, 0, 10))
		phase.run()
		T.eq(#speaker.stopped(), 0)

		event.push(Vector3.new(0, 0, 1))
		phase.run()
		T.eq(#speaker.stopped(), 1, "one was stopped to make room")
		T.eq(speaker.stopped()[1], 1, "the far one, which nobody could hear anyway")
		T.eq(#speaker.played(), 3)
		T.eq(#speaker.playing(), 2, "and the budget is still two")
	end)

	T.case("a sound quieter than everything running never starts", function()
		local _, speaker, phase, event = budget()
		event.push(Vector3.new(0, 0, 1))
		event.push(Vector3.new(0, 0, 2))
		phase.run()

		event.push(Vector3.new(0, 0, 99))
		phase.run()
		T.eq(#speaker.played(), 2, "the far one was not worth a voice")
		T.eq(#speaker.stopped(), 0, "and nothing was taken from anything")
	end)

	T.case("a voice that ended gives its place back", function()
		local _, speaker, phase, event = budget()
		event.push(Vector3.new(0, 0, 1))
		event.push(Vector3.new(0, 0, 2))
		phase.run()
		T.eq(#speaker.playing(), 2)

		speaker.finish(1)
		event.push(Vector3.new(0, 0, 90))
		phase.run()
		T.eq(#speaker.played(), 3, "the far one fits now")
		T.eq(#speaker.stopped(), 0)
	end)

	-- ------------------------------------------------------------------ the duck seam

	T.case("an entry that ducks asks the music to drop when it plays", function()
		local event: any = nil
		local Beef, _, phase = rig(function(beef)
			event = beef.Events.new("sting", "who:u32")
			return { { event, asset = SHOT, duck = { amount = 0.6, lasts = 1.5 } } }
		end)
		local duck = Beef.Stock.Duck
		phase.run()
		T.eq(duck.count, 0, "nothing said on a quiet frame")

		event.push(1)
		phase.run()
		T.eq(duck.count, 1)
		near(duck.amount[1], 0.6, "amount")
		near(duck.lasts[1], 1.5, "lasts")
	end)

	T.case("a sound nobody can hear does not duck", function()
		local event: any = nil
		local Beef, _, phase = rig(function(beef)
			event = beef.Events.new("sting", "at:vector3")
			return { { event, asset = SHOT, carries = 10, duck = { amount = 0.6, lasts = 1 } } }
		end)
		event.push(Vector3.new(0, 0, 500))
		phase.run()
		T.eq(Beef.Stock.Duck.count, 0, "it never played, so it never asked")
	end)

	T.case("Sound says it writes the duck ask, and only when something ducks", function()
		local quiet: any = nil
		local Beef, speaker = rig(function(beef)
			quiet = beef.Events.new("shot", "who:u32")
			return { { quiet, asset = SHOT } }
		end)
		local made = Beef.Stock.Sound({ { quiet, asset = SHOT } }, speaker)
		T.eq(made.writes, nil, "a map with no duck writes nothing at all")

		local loud = Beef.Events.new("sting", "who:u32")
		local other = Beef.Stock.Sound({ { loud, asset = SHOT, duck = { amount = 0.5, lasts = 1 } } }, speaker)
		T.eq((other.writes :: any)[1], Beef.Stock.Duck, "and one with a duck says so")
	end)

	-- ------------------------------------------------------------------ what it reads

	T.case("Sound reads every Event in the map", function()
		local shot: any, click: any = nil, nil
		local Beef, speaker = rig(function(beef)
			shot = beef.Events.new("shot", "who:u32")
			click = beef.Events.new("click", "what:u32")
			return { { shot, asset = SHOT }, { click, asset = CLICK } }
		end)
		local made = Beef.Stock.Sound({ { shot, asset = SHOT }, { click, asset = CLICK } }, speaker)
		T.eq(#made.reads, 2)
		T.eq(made.reads[1], shot)
		T.eq(made.reads[2], click)
	end)

	T.case("a push made by another controller in the same frame is heard", function()
		local Beef = T.load()
		local speaker = Beef.Stock.speaker()
		local Fired = Beef.Events.new("fired", "who:u32")
		local Shot = Beef.Events.new("shot", "who:u32")

		local function Gun(fired: any, shot: any): any
			return {
				name = "Gun",
				reads = { fired },
				writes = { shot },
				loop = function()
					for i = fired.from, fired.last do
						shot.push(fired.who[i])
					end
				end,
			}
		end

		local phase = Beef.Phase.new("Sound", {
			{ Gun, Fired, Shot },
			{ Beef.Stock.Sound, { { Shot, asset = SHOT } }, speaker },
		})
		phase.dt = 1 / 60

		Fired.push(7)
		phase.run()
		T.eq(#speaker.played(), 1, "the post window holds the whole frame's pushes")
	end)

	-- ------------------------------------------------------------------ what it refuses

	local function build(Beef: any, map: any, speaker: any): () -> ()
		return function()
			Beef.Stock.Sound(map, speaker)
		end
	end

	T.case("the map takes entries and three keys, and nothing else", function()
		local Beef = T.load()
		local speaker = Beef.Stock.speaker()
		local event = Beef.Events.new("shot", "who:u32")
		T.throws(build(Beef, "loud", speaker), "the map is the Events", "not a table at all")
		T.throws(build(Beef, { { event, asset = SHOT }, reverb = 1 }, speaker), "is not a key of the map", "an invented key")
		T.throws(build(Beef, { { event, asset = SHOT }, voices = 0 }, speaker), "a number above zero", "no voices")
		T.throws(build(Beef, { { event, asset = SHOT }, groups = 1 }, speaker), "groups is a table", "groups that is not a table")
		T.throws(build(Beef, { { event, asset = SHOT }, groups = { effects = "loud" } }, speaker), "a group's volume is a number", "a volume in words")
		T.throws(build(Beef, { { event, asset = SHOT }, transform = {} }, speaker), "transform is the Component", "a transform that is not a Component")
	end)

	T.case("an entry names one event type and the asset it plays", function()
		local Beef = T.load()
		local speaker = Beef.Stock.speaker()
		local event = Beef.Events.new("shot", "who:u32")
		local other = Beef.Events.new("click", "who:u32")
		T.throws(build(Beef, { { event } }, speaker), "asset is the sound it plays", "no asset")
		T.throws(build(Beef, { event }, speaker), "asset is the sound it plays", "a bare Event has none either")
		T.throws(build(Beef, { { event, asset = 7 } }, speaker), "asset is the sound it plays", "an asset that is a number")
		T.throws(build(Beef, { { event, other, asset = SHOT } }, speaker), "names one event type", "two Events in one entry")
		T.throws(build(Beef, { { "shot", asset = SHOT } }, speaker), "is not an event type", "a name rather than the Event")
		T.throws(build(Beef, { { event, asset = SHOT }, { event, asset = CLICK } }, speaker), "two entries both name it", "one Event, one sound")
	end)

	T.case("an option has to be one of the entry's", function()
		local Beef = T.load()
		local speaker = Beef.Stock.speaker()
		local event = Beef.Events.new("shot", "who:u32")
		T.throws(build(Beef, { { event, asset = SHOT, echo = 2 } }, speaker), "is not an option here", "an invented option")
		T.throws(build(Beef, { { event, asset = SHOT, pitch = 0 } }, speaker), "a number above zero", "no pitch at all")
		T.throws(build(Beef, { { event, asset = SHOT, carries = -1 } }, speaker), "a number above zero", "a distance below nothing")
		T.throws(build(Beef, { { event, asset = SHOT, volume = -1 } }, speaker), "volume is a number", "a volume below nothing")
	end)

	T.case("a group has to be one the map declared", function()
		local Beef = T.load()
		local speaker = Beef.Stock.speaker()
		local event = Beef.Events.new("shot", "who:u32")
		T.throws(build(Beef, { { event, asset = SHOT, group = "effects" } }, speaker), "is not a group here", "a group nobody declared")
		T.throws(
			build(Beef, { { event, asset = SHOT, group = 1 }, groups = { effects = 1 } }, speaker),
			"group names one of the map's groups",
			"a group that is not a name"
		)
	end)

	T.case("a duck says how far and how long, and nothing else", function()
		local Beef = T.load()
		local speaker = Beef.Stock.speaker()
		local event = Beef.Events.new("shot", "who:u32")
		T.throws(build(Beef, { { event, asset = SHOT, duck = 0.5 } }, speaker), "duck says how far", "a bare number")
		T.throws(build(Beef, { { event, asset = SHOT, duck = { lasts = 1 } } }, speaker), "a number above zero", "no amount")
		T.throws(build(Beef, { { event, asset = SHOT, duck = { amount = 0.5 } } }, speaker), "a number above zero", "no length")
		T.throws(build(Beef, { { event, asset = SHOT, duck = { amount = 2, lasts = 1 } } }, speaker), "at most one", "louder than silence")
		T.throws(build(Beef, { { event, asset = SHOT, duck = { amount = 0.5, lasts = 1, fade = 1 } } }, speaker), "duck takes", "an invented duck option")
	end)

	T.case("an Event naming an entity needs the Component its position is in", function()
		local Beef = T.load()
		local speaker = Beef.Stock.speaker()
		local event = Beef.Events.new("broke", "kind:kind", "handle:u32")
		T.throws(build(Beef, { { event, asset = SHOT } }, speaker), "the map needs transform", "no transform")
	end)
end
