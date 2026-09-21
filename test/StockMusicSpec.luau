--!strict
-- Stock Music headless: the engine is a tape that plays nothing and writes down every call, so a fade is a
-- list of numbers a case walks and a crossfade is two of those lists side by side. State changes go in as
-- pushes, the way a game makes them, and what comes out is what the two streams were told to do.

return function(T)
	local function near(got: number, want: number, what: string?)
		if math.abs(got - want) > 1e-4 then
			error(("%s: got %s, want %s"):format(what or "near", tostring(got), tostring(want)), 2)
		end
	end

	-- half way through a fade at equal power, which is where a straight line would have dipped
	local HALF = math.sin(math.pi * 0.25)

	-- a Beef, a state event, a duck event, a tape in place of the engine, and a phase with nothing in it
	-- but Music
	local function rig(tracks: any, dt: number?): (any, any, any, any, any)
		local Beef = T.load()
		local State = Beef.Events.new("music", "state:string")
		local Duck = Beef.Events.new("duck", "amount:f32", "lasts:f32")
		local tape = Beef.Stock.tape()
		local phase = Beef.Phase.new("Music", { { Beef.Stock.Music, State, tracks, Duck, tape } })
		phase.dt = dt or 1 / 60
		return Beef, State, Duck, tape, phase
	end

	-- every call since the tape was cleared, as "vol1:0.000 play1:one stop2", which is what a case about
	-- the shape of a frame actually wants to assert
	local function trace(tape: any): string
		local parts = {}
		for _, call in tape.log() do
			if call.what == "play" then
				table.insert(parts, "play" .. call.slot .. ":" .. call.asset)
			elseif call.what == "stop" then
				table.insert(parts, "stop" .. call.slot)
			else
				table.insert(parts, ("vol%d:%.3f"):format(call.slot, call.level))
			end
		end
		return table.concat(parts, " ")
	end

	local ONE = { calm = { asset = "one", crossfade = 1 } }
	local TWO = {
		calm = { asset = "one", crossfade = 1 },
		chase = { asset = "two", crossfade = 1 },
	}

	-- ------------------------------------------------------------------ the surface

	T.case("Stock exports Music and a tape to drive it with", function()
		local Beef = T.load()
		T.ok(Beef.Stock.Music ~= nil, "Beef.Stock.Music")
		T.eq(type(Beef.Stock.Music), "function", "Music is a factory a phase can call")
		T.eq(type(Beef.Stock.tape), "function", "and tape is the driver a spec hands it")
	end)

	T.case("Music is a controller a phase runs, and describe reads", function()
		local _, State, _, tape, phase = rig(ONE)
		local said = phase.describe()
		T.ok(said:find("Music"), "the controller is named")
		T.ok(said:find("music"), "and the event type it reads")
		T.ok(said:find("reads"), "as something it reads")
		T.eq(tape.bound(), false, "the streams are not built before the phase boots")
		phase.run()
		T.eq(tape.bound(), true, "and they are built once it has")
		T.eq(State.count, 0, "it pushes nothing of its own")
	end)

	T.case("it writes nothing back", function()
		local _, State, Duck, _, phase = rig(TWO, 0.5)
		State.push("calm")
		Duck.push(0.5, 0.2)
		phase.run()
		phase.run()
		T.eq(State.count, 1, "the state event holds what the game pushed and nothing else")
		T.eq(Duck.count, 1)
	end)

	-- ------------------------------------------------------------------ one track

	T.case("a state starts its track silent and fades it up", function()
		local _, State, _, tape, phase = rig(ONE, 0.5)
		State.push("calm")
		phase.run()
		T.eq(trace(tape), ("vol1:0.000 play1:one vol1:%.3f"):format(HALF), "silent, playing, then half way up")
		T.eq(tape.playing(1), "one")

		tape.clear()
		phase.run()
		T.eq(trace(tape), "vol1:1.000", "at the top after its second")

		tape.clear()
		phase.run()
		T.eq(trace(tape), "", "and a steady track is not written again")
	end)

	T.case("a track loops unless it says not to", function()
		local _, State, _, tape, phase = rig({ sting = { asset = "one", loop = false, crossfade = 0 } })
		State.push("sting")
		phase.run()
		T.eq(tape.log()[2].looped, false)

		local _, State2, _, tape2, phase2 = rig(ONE)
		State2.push("calm")
		phase2.run()
		T.eq(tape2.log()[2].looped, true, "music loops when nothing says otherwise")
	end)

	T.case("the volume a track declares is the level it climbs to", function()
		local _, State, _, tape, phase = rig({ calm = { asset = "one", volume = 0.4, crossfade = 0 } })
		State.push("calm")
		phase.run()
		near(tape.level(1), 0.4)
	end)

	T.case("a crossfade of nothing is a cut", function()
		local _, State, _, tape, phase = rig({ calm = { asset = "one", crossfade = 0 } })
		State.push("calm")
		phase.run()
		T.eq(trace(tape), "vol1:0.000 play1:one vol1:1.000", "up in the frame it was asked for")
	end)

	T.case("the fade is equal power, so the middle of one does not sag", function()
		local _, State, _, tape, phase = rig(ONE, 0.25)
		State.push("calm")
		phase.run()
		phase.run()
		phase.run()
		phase.run()
		local levels = tape.levels(1)
		T.eq(#levels, 5, "the silent one it started at, and one a frame after")
		near(levels[2], math.sin(math.pi * 0.125), "a quarter of the way")
		near(levels[3], HALF, "half way, which a straight line would have put at 0.5")
		near(levels[4], math.sin(math.pi * 0.375))
		near(levels[5], 1)
	end)

	T.case("the state it is already in does nothing", function()
		local _, State, _, tape, phase = rig(ONE, 0.5)
		State.push("calm")
		phase.run()
		phase.run()
		tape.clear()
		State.push("calm")
		State.push("calm")
		phase.run()
		T.eq(trace(tape), "", "a game may push the state it is in every frame")
	end)

	T.case("the last state pushed in a frame is the state", function()
		local _, State, _, tape, phase = rig(TWO, 0.5)
		State.push("calm")
		State.push("chase")
		phase.run()
		T.eq(trace(tape), ("vol1:0.000 play1:two vol1:%.3f"):format(HALF), "one stream, so one track starts")
	end)

	-- ------------------------------------------------------------------ crossfading

	T.case("a change runs both streams at once and stops the one leaving", function()
		local _, State, _, tape, phase = rig(TWO, 0.5)
		State.push("calm")
		phase.run()
		phase.run()
		tape.clear()

		State.push("chase")
		phase.run()
		T.eq(tape.streams(), "1:one 2:two", "both are running")
		near(tape.level(1), HALF, "the one leaving")
		near(tape.level(2), HALF, "and the one arriving")
		near(tape.level(1) ^ 2 + tape.level(2) ^ 2, 1, "which together are as loud as either alone")

		tape.clear()
		phase.run()
		T.eq(tape.streams(), "2:two", "the one leaving is stopped once it is silent")
		T.eq(tape.playing(1), nil)
		near(tape.level(2), 1)
	end)

	T.case("the arriving track's time is the time the fade takes", function()
		local _, State, _, tape, phase = rig({
			calm = { asset = "one", crossfade = 4 },
			chase = { asset = "two", crossfade = 0 },
		}, 0.5)
		State.push("calm")
		phase.run()
		near(tape.level(1), math.sin(math.pi * 0.0625), "an eighth of the way into a four second fade")

		tape.clear()
		State.push("chase")
		phase.run()
		T.eq(tape.streams(), "2:two", "and getting into a fight is a cut, whatever the fade out of calm was")
		near(tape.level(2), 1)
	end)

	T.case("a third state takes the slot of the one already leaving", function()
		local _, State, _, tape, phase = rig({
			calm = { asset = "one", crossfade = 1 },
			chase = { asset = "two", crossfade = 1 },
			boss = { asset = "three", crossfade = 1 },
		}, 0.5)
		State.push("calm")
		phase.run()
		phase.run()
		State.push("chase")
		phase.run()
		tape.clear()

		State.push("boss")
		phase.run()
		T.eq(tape.streams(), "1:three", "the one nobody was still listening to made way")
		T.ok(trace(tape):find("stop1"), "it was stopped before the new one took it")
		near(tape.level(1), HALF, "and the new one is half way in")
	end)

	T.case("a state come back to mid fade turns its track around rather than starting it over", function()
		local _, State, _, tape, phase = rig(TWO, 0.25)
		State.push("calm")
		for _ = 1, 4 do
			phase.run()
		end
		State.push("chase")
		phase.run()
		tape.clear()

		State.push("calm")
		phase.run()
		T.eq(trace(tape):find("play") == nil, true, "nothing started")
		T.eq(tape.playing(1), "one", "it was still there")
		near(tape.level(1), 1, "and it went back up from where it had got to")
		phase.run()
		T.eq(tape.streams(), "1:one", "while the one it had begun on is gone")
	end)

	T.case("two states that play the same thing do not crossfade it with itself", function()
		local _, State, _, tape, phase = rig({
			day = { asset = "one", crossfade = 1 },
			dusk = { asset = "one", volume = 0.5, crossfade = 1 },
		}, 0.5)
		State.push("day")
		phase.run()
		phase.run()
		tape.clear()

		State.push("dusk")
		phase.run()
		T.eq(trace(tape), "vol1:0.500", "the track keeps going and only the level it wants changed")
		T.eq(tape.streams(), "1:one")
	end)

	-- ------------------------------------------------------------------ quiet

	T.case("a state that plays nothing fades the stream out", function()
		local _, State, _, tape, phase = rig({
			calm = { asset = "one", crossfade = 1 },
			cutscene = { asset = false, crossfade = 1 },
		}, 0.5)
		State.push("calm")
		phase.run()
		phase.run()
		tape.clear()

		State.push("cutscene")
		phase.run()
		near(tape.level(1), HALF, "on its way out")
		T.eq(trace(tape):find("play") == nil, true, "with nothing taking its place")
		phase.run()
		T.eq(tape.streams(), "", "and then there is no music")
	end)

	T.case("a state the table never heard of is quiet too", function()
		local _, State, _, tape, phase = rig(ONE, 0.5)
		State.push("calm")
		phase.run()
		phase.run()

		State.push("bosss")
		for _ = 1, 4 do
			phase.run()
		end
		T.eq(tape.streams(), "", "a name with nothing declared for it leaves the stream empty")
	end)

	T.case("music can come back after quiet", function()
		local _, State, _, tape, phase = rig({
			calm = { asset = "one", crossfade = 1 },
			gone = { asset = false, crossfade = 1 },
		}, 0.5)
		State.push("calm")
		phase.run()
		phase.run()
		State.push("gone")
		phase.run()
		phase.run()
		tape.clear()

		State.push("calm")
		phase.run()
		T.eq(tape.streams(), "2:one", "on the other stream, since the first one is where it just was")
		near(tape.level(2), HALF)
	end)

	-- ------------------------------------------------------------------ ducking

	T.case("a duck drops the stream at once and eases it back up", function()
		local _, State, Duck, tape, phase = rig({ calm = { asset = "one", crossfade = 0 } }, 0.1)
		State.push("calm")
		phase.run()
		near(tape.level(1), 1)

		Duck.push(0.5, 0.3)
		phase.run()
		near(tape.level(1), 0.5, "half way down in the frame it was asked for")
		phase.run()
		near(tape.level(1), 0.5)
		phase.run()
		near(tape.level(1), 0.5, "for the three tenths it said")
		phase.run()
		near(tape.level(1), 1 - (0.5 - 0.1 / 0.3), "then it climbs")
		phase.run()
		near(tape.level(1), 1, "and it is back")
	end)

	T.case("the largest duck still running is the one that counts", function()
		local _, State, Duck, tape, phase = rig({ calm = { asset = "one", crossfade = 0 } }, 0.1)
		State.push("calm")
		phase.run()

		-- a length that does not land on a frame edge, so counting it down never leaves dust behind
		Duck.push(0.3, 0.45)
		Duck.push(0.7, 0.2)
		phase.run()
		near(tape.level(1), 0.3, "the deeper one wins while it lasts")
		phase.run()
		near(tape.level(1), 0.3)
		phase.run()
		near(tape.level(1), 1 - (0.7 - 0.1 / 0.3), "and when it runs out the stream climbs toward the other")
		phase.run()
		near(tape.level(1), 0.7, "which is as far up as it goes while that one is still running")
		phase.run()
		near(tape.level(1), 0.7)
		phase.run()
		near(tape.level(1), 1, "then all the way")
	end)

	T.case("a duck of nothing, or for no time, is nothing", function()
		local _, State, Duck, tape, phase = rig({ calm = { asset = "one", crossfade = 0 } }, 0.1)
		State.push("calm")
		phase.run()
		tape.clear()

		Duck.push(0, 1)
		Duck.push(0.6, 0)
		phase.run()
		T.eq(trace(tape), "", "the music was not touched")
	end)

	T.case("a duck past the whole of it takes the stream to nothing", function()
		local _, State, Duck, tape, phase = rig({ calm = { asset = "one", crossfade = 0 } }, 0.1)
		State.push("calm")
		phase.run()

		Duck.push(4, 0.1)
		phase.run()
		near(tape.level(1), 0, "a duck deeper than the music is still only the whole of it")
		T.eq(tape.playing(1), "one", "and the track is still running under it")
	end)

	T.case("a duck dents both streams of a crossfade", function()
		local _, State, Duck, tape, phase = rig(TWO, 0.5)
		State.push("calm")
		phase.run()
		phase.run()

		State.push("chase")
		Duck.push(0.5, 1)
		phase.run()
		near(tape.level(1), HALF * 0.5, "the one leaving")
		near(tape.level(2), HALF * 0.5, "and the one arriving")
		near(tape.level(1) ^ 2 + tape.level(2) ^ 2, 0.25, "equal power under the duck as above it")
	end)

	T.case("Music runs with no duck event at all", function()
		local Beef = T.load()
		local State = Beef.Events.new("music", "state:string")
		local tape = Beef.Stock.tape()
		local phase = Beef.Phase.new("Music", { { Beef.Stock.Music, State, ONE, nil, tape } })
		phase.dt = 0.5
		State.push("calm")
		phase.run()
		T.eq(tape.bound(), true, "the tape was still the driver")
		near(tape.level(1), HALF, "and a game with no Sound in it has music")
	end)

	-- ------------------------------------------------------------------ what it refuses

	T.case("a track is named by a string and says what it plays", function()
		local Beef = T.load()
		local State = Beef.Events.new("music", "state:string")
		local function build(tracks: any)
			return function()
				Beef.Stock.Music(State, tracks, nil, Beef.Stock.tape())
			end
		end
		T.throws(build("one"), "tracks is a table", "not a table at all")
		T.throws(build({}), "names at least one state", "no states")
		T.throws(build({ [1] = { asset = "one" } }), "named by a string", "a number for a name")
		T.throws(build({ calm = "one" }), "a track is a table", "the asset on its own")
		T.throws(build({ calm = {} }), "asset names the sound", "a state that says nothing")
		T.throws(build({ calm = { asset = true } }), "asset names the sound", "true for an asset")
	end)

	T.case("an option has to belong where it is put", function()
		local Beef = T.load()
		local State = Beef.Events.new("music", "state:string")
		local function build(tracks: any)
			return function()
				Beef.Stock.Music(State, tracks, nil, Beef.Stock.tape())
			end
		end
		T.throws(build({ calm = { asset = "one", sticky = 1 } }), "is not an option here", "an invented option")
		T.throws(build({ quiet = { asset = false, volume = 0.5 } }), "is an option on a state that plays", "a level on silence")
		T.throws(build({ quiet = { asset = false, loop = true } }), "is an option on a state that plays", "a loop on silence")
	end)

	T.case("the numbers on a track are the numbers they say they are", function()
		local Beef = T.load()
		local State = Beef.Events.new("music", "state:string")
		local function build(tracks: any)
			return function()
				Beef.Stock.Music(State, tracks, nil, Beef.Stock.tape())
			end
		end
		T.throws(build({ calm = { asset = "one", volume = 2 } }), "from zero to one", "louder than the stream has room for")
		T.throws(build({ calm = { asset = "one", volume = "loud" } }), "from zero to one", "a level in words")
		T.throws(build({ calm = { asset = "one", crossfade = -1 } }), "at or above zero", "a fade backwards")
		T.throws(build({ calm = { asset = "one", loop = 1 } }), "loop is true or false", "a number for a loop")
	end)

	T.case("the things handed to the factory are the state event and, if there is one, the duck event", function()
		local Beef = T.load()
		local State = Beef.Events.new("music", "state:string")
		T.throws(function()
			Beef.Stock.Music({}, ONE)
		end, "the first thing handed to it", "not an event at all")
		T.throws(function()
			Beef.Stock.Music(Beef.Events.new("mood", "mood:string"), ONE)
		end, "a column named state", "an event with no state in it")
		T.throws(function()
			Beef.Stock.Music(State, ONE, Beef.Events.new("duck", "amount:f32"))
		end, "amount and lasts", "a duck event missing half of itself")
	end)
end
