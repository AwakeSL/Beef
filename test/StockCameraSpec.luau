--!strict
-- Stock Camera headless: the engine is a film the controller writes to, so where each mode puts the camera,
-- what a constraint does to it, and what an effect lays on top are all read back off what was written, with
-- no Roblox in the loop.

return function(T)
	local function near(got: number, want: number, what: string?)
		if math.abs(got - want) > 1e-3 then
			error(("%s: got %s, want %s"):format(what or "near", tostring(got), tostring(want)), 2)
		end
	end

	local function vec(v: any, x: number, y: number, z: number, what: string?)
		local who = what or "at"
		near(v.X, x, who .. ".X")
		near(v.Y, y, who .. ".Y")
		near(v.Z, z, who .. ".Z")
	end

	local FOLLOW = { follow = { distance = 12, offset = Vector3.new(0, 2, 0) } }

	-- a Beef, a kind carrying a transform and a view, a film in place of the engine, and a phase with
	-- nothing in it but Camera
	local function rig(modes: any, dt: number?): any
		local Beef = T.load()
		local Transform = Beef.Components.new("transform")
		local View = Beef.Components.new("view")
		local Effect = Beef.Events.new("effect", "effect:string", "amount:f32", "x:f32", "y:f32", "lasts:f32")
		local Eye = Beef.Kinds.new("eye", Transform, View)
		local film = Beef.Stock.film()
		local phase = Beef.Phase.new("Camera", { { Beef.Stock.Camera, Transform, Effect, View, modes, film } })
		phase.dt = dt or 1 / 60
		return {
			Beef = Beef,
			Transform = Transform,
			View = View,
			Effect = Effect,
			Eye = Eye,
			film = film,
			phase = phase,
			-- the view value of the first body, which is where the aim lands
			view = function(): any
				return View.of(Eye).value[1]
			end,
			watch = function(at: any, said: any): number
				return Eye.spawn(at, said)
			end,
		}
	end

	local function push(r: any, what: string, amount: number, x: number, y: number, lasts: number)
		r.Effect.push(what, amount, x, y, lasts)
	end

	-- ------------------------------------------------------------------ the surface

	T.case("Stock exports Camera, a factory a phase can call, and a film to drive it headless", function()
		local Beef = T.load()
		T.ok(Beef.Stock.Camera ~= nil, "Beef.Stock.Camera")
		T.eq(type(Beef.Stock.Camera), "function")
		T.eq(type(Beef.Stock.film), "function", "and the headless driver")
	end)

	T.case("Camera is a controller a phase runs, and describe reads", function()
		local r = rig(FOLLOW)
		local said = r.phase.describe()
		T.ok(said:find("Camera"), "the controller is named")
		T.ok(said:find("effect"), "and the event type it reads")
		T.eq(r.film.frames(), 0, "it writes nothing before a frame runs")
	end)

	T.case("the driver is started once, at the phase's boot", function()
		local r = rig(FOLLOW)
		T.eq(r.film.started(), false, "not before the first frame")
		r.phase.run()
		T.eq(r.film.started(), true, "the default camera scripts are told to let go at boot")
	end)

	T.case("with nothing carrying the view there is no camera to write", function()
		local r = rig(FOLLOW)
		r.phase.run()
		T.eq(r.film.frames(), 0, "a client with no body yet leaves the camera alone")
	end)

	-- ------------------------------------------------------------------ the modes

	T.case("follow sits behind the body at the distance, looking at it", function()
		local r = rig(FOLLOW)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.phase.run()
		vec(r.film.at().Position, 0, 2, 12, "behind a body facing -Z")
		vec(r.film.at().LookVector, 0, 0, -1, "looking back at it")
	end)

	T.case("the offset is where the camera looks, not where the body is", function()
		local r = rig({ follow = { distance = 10, offset = Vector3.new(0, 6, 0) } })
		r.watch(CFrame.new(4, 0, -3), { mode = "follow" })
		r.phase.run()
		vec(r.film.at().Position, 4, 6, 7, "the pivot is the body plus the offset")
	end)

	T.case("follow swings around as the body turns", function()
		local r = rig(FOLLOW)
		r.watch(CFrame.fromEulerAnglesYXZ(0, math.pi / 2, 0), { mode = "follow" })
		r.phase.run()
		vec(r.film.at().Position, 12, 2, 0, "a body looking -X is watched from +X")
		vec(r.film.at().LookVector, -1, 0, 0)
	end)

	T.case("the player's own turn moves a follow camera around the body", function()
		local r = rig(FOLLOW)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow", yaw = math.pi })
		r.phase.run()
		vec(r.film.at().Position, 0, 2, -12, "half a turn puts it in front")
	end)

	T.case("orbit leaves the body's own turn out of it", function()
		local r = rig({ orbit = { distance = 12, offset = Vector3.new(0, 2, 0) } })
		r.watch(CFrame.fromEulerAnglesYXZ(0, math.pi / 2, 0), { mode = "orbit" })
		r.phase.run()
		vec(r.film.at().Position, 0, 2, 12, "the body turns underneath it")
	end)

	T.case("first person sits at the body and looks where the player turned", function()
		local r = rig({ first = { offset = Vector3.new(0, 1.5, 0) } })
		r.watch(CFrame.new(3, 0, -4), { mode = "first", yaw = math.pi / 2 })
		r.phase.run()
		vec(r.film.at().Position, 3, 1.5, -4, "at the body's eyes")
		vec(r.film.at().LookVector, -1, 0, 0, "looking where the turn says")
	end)

	T.case("fixed sits where it was told and looks at the body", function()
		local at = CFrame.new(0, 20, 40)
		local r = rig({ fixed = { at = at } })
		r.watch(CFrame.new(0, 0, 0), { mode = "fixed" })
		r.phase.run()
		vec(r.film.at().Position, 0, 20, 40, "it does not move")
		local want = (Vector3.new(0, 0, 0) - at.Position).Unit
		vec(r.film.at().LookVector, want.X, want.Y, want.Z, "and it watches the body")
	end)

	T.case("fixed with nothing to watch keeps its own CFrame", function()
		local Beef = T.load()
		local Transform = Beef.Components.new("transform")
		local View = Beef.Components.new("view")
		local Effect = Beef.Events.new("effect", "effect:string", "amount:f32", "x:f32", "y:f32", "lasts:f32")
		local Post = Beef.Kinds.new("post", View)
		local film = Beef.Stock.film()
		local at = CFrame.new(5, 9, -2) * CFrame.fromEulerAnglesYXZ(0, math.pi / 2, 0)
		local phase = Beef.Phase.new("Camera", { { Beef.Stock.Camera, Transform, Effect, View, { fixed = { at = at } }, film } })
		phase.dt = 1 / 60

		Post.spawn({ mode = "fixed" })
		phase.run()
		vec(film.at().Position, 5, 9, -2, "a body with no transform is nothing to look at")
		vec(film.at().LookVector, -1, 0, 0, "so the CFrame it was given stands")
	end)

	T.case("the one declared mode is what a view that names none takes", function()
		local r = rig(FOLLOW)
		r.watch(CFrame.new(0, 0, 0), {})
		r.phase.run()
		vec(r.film.at().Position, 0, 2, 12, "there is nothing to pick between")
	end)

	T.case("a kind carrying the view as an option is found too", function()
		local Beef = T.load()
		local Transform = Beef.Components.new("transform")
		local View = Beef.Components.new("view")
		local Effect = Beef.Events.new("effect", "effect:string", "amount:f32", "x:f32", "y:f32", "lasts:f32")
		local Tag = Beef.Components.new("tag")
		local Crowd = Beef.Kinds.new("crowd", Tag)
		local film = Beef.Stock.film()
		local phase = Beef.Phase.new("Camera", { { Beef.Stock.Camera, Transform, Effect, View, FOLLOW, film } })
		phase.dt = 1 / 60

		Crowd.spawn(true)
		Crowd.spawn(true)
		Transform.add(Crowd, 2, CFrame.new(0, 0, 0))
		View.add(Crowd, 2, { mode = "follow" })

		phase.run()
		vec(film.at().Position, 0, 2, 12, "the one carrying the view is the one the camera is on")
	end)

	-- ------------------------------------------------------------------ the constraints

	T.case("the pitch is clamped to the mode's limits and the clamp is written back", function()
		local r = rig({ follow = { distance = 12, offset = Vector3.new(0, 2, 0), pitch = { -20, 45 } } })
		r.watch(CFrame.new(0, 0, 0), { mode = "follow", pitch = math.rad(80) })
		r.phase.run()
		near(r.view().pitch, math.rad(45), "a game that keeps adding does not have to unwind")
		local back = 12 * math.cos(math.rad(45))
		vec(r.film.at().Position, 0, 2 - back, back, "looking up puts the camera below and behind")
	end)

	T.case("the pitch clamps downward as well", function()
		local r = rig({ follow = { distance = 12, offset = Vector3.new(0, 2, 0), pitch = { -20, 45 } } })
		r.watch(CFrame.new(0, 0, 0), { mode = "follow", pitch = -math.pi })
		r.phase.run()
		near(r.view().pitch, math.rad(-20))
	end)

	T.case("a mode that collides pulls the camera in as far as the way is clear", function()
		local r = rig({ follow = { distance = 12, offset = Vector3.new(0, 2, 0), collide = true } })
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.clears(0.5)
		r.phase.run()
		vec(r.film.at().Position, 0, 2, 6, "half the way is all there is")
		T.eq(#r.film.asked(), 1, "and it asked once")
	end)

	T.case("a mode that does not collide never asks", function()
		local r = rig(FOLLOW)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.clears(0.25)
		r.phase.run()
		T.eq(#r.film.asked(), 0, "a camera that may clip is a mode's decision")
		vec(r.film.at().Position, 0, 2, 12)
	end)

	T.case("first person asks nothing of the world, since it is inside the body", function()
		local r = rig({ first = {} })
		r.watch(CFrame.new(0, 0, 0), { mode = "first" })
		r.phase.run()
		T.eq(#r.film.asked(), 0)
	end)

	-- ------------------------------------------------------------------ the field of view

	T.case("the mode says how much is across the screen and the driver is given the angle up it", function()
		local r = rig({ follow = { distance = 12, fov = 90 } })
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.sized(1000, 1000)
		r.phase.run()
		near(r.film.fov(), 90, "on a square window the two are the same")

		r.film.sized(1920, 1080)
		r.phase.run()
		local want = math.deg(2 * math.atan(math.tan(math.rad(45)) / (1920 / 1080)))
		near(r.film.fov(), want, "on a wide one the angle up the screen is smaller")
		T.ok(r.film.fov() < 90, "the window got wider, not taller")
	end)

	T.case("a mode with no field of view of its own takes the usual one", function()
		local r = rig(FOLLOW)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.sized(1000, 1000)
		r.phase.run()
		near(r.film.fov(), 90)
	end)

	-- ------------------------------------------------------------------ the effects

	T.case("a shake moves the camera off the aim and puts it back when it is over", function()
		local r = rig(FOLLOW, 0.25)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		push(r, "shake", 2, 0, 0, 0.5)
		r.phase.run()
		local off = (r.film.at().Position - Vector3.new(0, 2, 12)).Magnitude
		T.ok(off > 0, "the camera is not where the mode put it")
		T.ok(off <= 2 * math.sqrt(2) + 1e-3, "and it is never further off than the shake says")

		r.phase.run()
		r.phase.run()
		vec(r.film.at().Position, 0, 2, 12, "the shake ran its length and stopped")
	end)

	T.case("a shake fades rather than stopping dead", function()
		local r = rig(FOLLOW, 0.1)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		push(r, "shake", 4, 0, 0, 1)
		-- the wobble itself is not going one way, so what is asserted is what holds it in: the amount left
		-- of the shake's length, which shrinks every frame
		for i = 1, 10 do
			r.phase.run()
			local left = (1 - (i - 1) * 0.1) / 1
			local off = (r.film.at().Position - Vector3.new(0, 2, 12)).Magnitude
			T.ok(off <= 4 * left * math.sqrt(2) + 1e-6, ("frame %d is inside what is left of it"):format(i))
		end
		r.phase.run()
		vec(r.film.at().Position, 0, 2, 12, "and there is nothing left of it after")
	end)

	T.case("a punch turns the view and decays back to the aim", function()
		local r = rig(FOLLOW, 0.5)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		push(r, "punch", 10, 1, 0, 1)
		r.phase.run()
		vec(r.film.at().LookVector, math.sin(math.rad(10)), 0, -math.cos(math.rad(10)), "x kicks it right")

		r.phase.run()
		vec(r.film.at().LookVector, math.sin(math.rad(5)), 0, -math.cos(math.rad(5)), "and half of it is left half way through")

		r.phase.run()
		vec(r.film.at().LookVector, 0, 0, -1, "then it is back where the mode put it")
	end)

	T.case("a punch upward is the y of the push", function()
		local r = rig(FOLLOW, 0.5)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		push(r, "punch", 10, 0, 1, 1)
		r.phase.run()
		near(r.film.at().LookVector.Y, math.sin(math.rad(10)), "y kicks it up")
	end)

	T.case("a zoom moves the field of view and leaves the camera where it was", function()
		local r = rig({ follow = { distance = 12, offset = Vector3.new(0, 2, 0), fov = 90 } }, 0.5)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.sized(1000, 1000)
		push(r, "zoom", 20, 0, 0, 1)
		r.phase.run()
		near(r.film.fov(), 110, "degrees on top of the mode's")
		vec(r.film.at().Position, 0, 2, 12, "and nothing else moved")

		r.phase.run()
		near(r.film.fov(), 100, "half way through, half of it is left")

		r.phase.run()
		near(r.film.fov(), 90, "then the mode's own again")
	end)

	T.case("a zoom in is a push with less than nothing in it", function()
		local r = rig({ follow = { distance = 12, fov = 90 } }, 0.5)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.sized(1000, 1000)
		push(r, "zoom", -40, 0, 0, 1)
		r.phase.run()
		near(r.film.fov(), 50)
	end)

	T.case("a second push of the same effect replaces the one running", function()
		local r = rig({ follow = { distance = 12, fov = 90 } }, 0.5)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.sized(1000, 1000)
		push(r, "zoom", 20, 0, 0, 1)
		r.phase.run()
		near(r.film.fov(), 110)

		r.phase.run()
		near(r.film.fov(), 100, "it is half gone")

		push(r, "zoom", 20, 0, 0, 1)
		r.phase.run()
		near(r.film.fov(), 110, "the new one is the whole of it, not both of them")
	end)

	T.case("two pushes in one frame leave the last one running", function()
		local r = rig({ follow = { distance = 12, fov = 90 } }, 0.5)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.sized(1000, 1000)
		push(r, "zoom", 20, 0, 0, 1)
		push(r, "zoom", 6, 0, 0, 1)
		r.phase.run()
		near(r.film.fov(), 96)
	end)

	T.case("an effect with no length in it does nothing", function()
		local r = rig({ follow = { distance = 12, fov = 90 } })
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.film.sized(1000, 1000)
		push(r, "zoom", 20, 0, 0, 0)
		r.phase.run()
		near(r.film.fov(), 90, "there is no moment for it to happen in")
	end)

	T.case("an effect it has never heard of goes past it", function()
		local r = rig(FOLLOW)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		push(r, "wobble", 9, 0, 0, 1)
		r.phase.run()
		vec(r.film.at().Position, 0, 2, 12, "the way an action Movement does not read goes past that one")
	end)

	T.case("an effect runs down even on a frame with no camera to put it on", function()
		local r = rig({ follow = { distance = 12, fov = 90 } }, 0.5)
		r.film.sized(1000, 1000)
		push(r, "zoom", 20, 0, 0, 1)
		r.phase.run()
		T.eq(r.film.frames(), 0, "nothing carried the view yet")

		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.phase.run()
		near(r.film.fov(), 100, "the frame it missed still cost it half")
	end)

	-- ------------------------------------------------------------------ the aim underneath

	T.case("the aim is written on the body with none of the effects in it", function()
		local r = rig(FOLLOW, 0.5)
		r.watch(CFrame.new(0, 0, 0), { mode = "follow" })
		r.phase.run()
		vec(r.view().at.Position, 0, 2, 12, "where the mode put it")

		push(r, "shake", 3, 0, 0, 1)
		push(r, "punch", 20, 1, 0, 1)
		r.phase.run()
		vec(r.view().at.Position, 0, 2, 12, "and the effects are not in it")
		vec(r.view().at.LookVector, 0, 0, -1)
		T.ok((r.film.at().Position - r.view().at.Position).Magnitude > 0, "while the camera itself has them")
	end)

	T.case("the aim follows the body, so a game reads where the player is looking off it", function()
		local r = rig({ first = { offset = Vector3.new(0, 1.5, 0) } })
		local handle = r.watch(CFrame.new(0, 0, 0), { mode = "first", yaw = math.pi / 2 })
		r.phase.run()
		vec(r.view().at.LookVector, -1, 0, 0, "which is what a body's facing is written from")
		T.ok(handle > 0)
	end)

	-- ------------------------------------------------------------------ what it refuses

	local function build(Beef: any, modes: any, effect: any?): () -> ()
		local Transform = Beef.Components.new("transform")
		local View = Beef.Components.new("view")
		local Effect = effect or Beef.Events.new("effect", "effect:string", "amount:f32", "x:f32", "y:f32", "lasts:f32")
		return function()
			Beef.Stock.Camera(Transform, Effect, View, modes)
		end
	end

	T.case("a mode is one of the four, named by a string, and a table", function()
		local Beef = T.load()
		T.throws(build(Beef, { chase = { distance = 4 } }), "is not a mode here", "a mode it has never heard of")
		T.throws(build(Beef, { [1] = { distance = 4 } }), "named by a string", "a number for a name")
		T.throws(build(Beef, { follow = "close" }), "a mode is a table", "not a table")
		T.throws(build(Beef, {}), "names at least one mode", "no modes at all")
		T.throws(build(Beef, "follow"), "modes is a table", "not a table at all")
	end)

	T.case("an option has to belong where it is put", function()
		local Beef = T.load()
		T.throws(build(Beef, { follow = { distance = 12, sticky = 1 } }), "is not an option here", "an invented option")
		T.throws(build(Beef, { first = { distance = 12 } }), "is an option on", "a distance on a first person camera")
		T.throws(build(Beef, { fixed = { at = CFrame.new(), collide = true } }), "is an option on", "collision on a fixed camera")
		T.throws(build(Beef, { follow = { distance = 12, at = CFrame.new() } }), "is an option on", "a place for a camera that follows")
	end)

	T.case("a mode needs the numbers that make it", function()
		local Beef = T.load()
		T.throws(build(Beef, { follow = {} }), "a follow needs distance", "a follow with no distance")
		T.throws(build(Beef, { orbit = {} }), "an orbit needs distance", "an orbit with no distance")
		T.throws(build(Beef, { fixed = {} }), "a fixed needs at", "a fixed camera with nowhere to be")
		T.throws(build(Beef, { follow = { distance = 0 } }), "a number above zero", "no distance at all")
		T.throws(build(Beef, { follow = { distance = "far" } }), "a number above zero", "a distance in words")
	end)

	T.case("the constraints are checked where they are written", function()
		local Beef = T.load()
		T.throws(build(Beef, { follow = { distance = 12, pitch = 40 } }), "pitch is how far down", "one number for two limits")
		T.throws(build(Beef, { follow = { distance = 12, pitch = { 40, -40 } } }), "looks down first", "the limits the wrong way round")
		T.throws(build(Beef, { follow = { distance = 12, pitch = { -95, 40 } } }), "degrees of level", "past straight down")
		T.throws(build(Beef, { follow = { distance = 12, fov = 0 } }), "across the screen", "a window with nothing in it")
		T.throws(build(Beef, { follow = { distance = 12, fov = 200 } }), "across the screen", "more of the world than there is")
		T.throws(build(Beef, { follow = { distance = 12, offset = 4 } }), "offset is a Vector3", "a number for an offset")
		T.throws(build(Beef, { follow = { distance = 12, collide = "yes" } }), "collide is true or false", "a word for a switch")
		T.throws(build(Beef, { fixed = { at = Vector3.zero } }), "at is the CFrame", "a position with no facing in it")
	end)

	T.case("the things handed to the factory are two Components and an Effect event that carries the columns", function()
		local Beef = T.load()
		local Transform = Beef.Components.new("transform")
		local View = Beef.Components.new("view")
		local Effect = Beef.Events.new("effect", "effect:string", "amount:f32", "x:f32", "y:f32", "lasts:f32")
		T.throws(function()
			Beef.Stock.Camera({}, Effect, View, FOLLOW)
		end, "the first thing handed to it")
		T.throws(function()
			Beef.Stock.Camera(Transform, {}, View, FOLLOW)
		end, "the second thing handed to it is the Effect event type")
		T.throws(function()
			Beef.Stock.Camera(Transform, Effect, Effect, FOLLOW)
		end, "the third thing handed to it")

		local thin = Beef.Events.new("thin", "effect:string", "amount:f32")
		T.throws(build(Beef, FOLLOW, thin), "needs a x column", "an event with no direction in it")
	end)
end
