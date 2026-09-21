--!strict
-- The rig itself: Beef loads headless, and a kind, a component, an event and a phase do a frame.

return function(T)
	T.case("Beef loads with every core module", function()
		local Beef = T.load()
		for _, name in { "Kinds", "Components", "Events", "Phase", "Drivers", "Wire" } do
			T.ok(Beef[name] ~= nil, "Beef." .. name)
		end
	end)

	T.case("a phase moves an entity and reads an event", function()
		local Beef = T.load()
		local Position = Beef.Components.new("position", { wire = "vector3" })
		local Velocity = Beef.Components.new("velocity", { wire = "vector3" })
		local Drop = Beef.Kinds.new("drop", Position, Velocity)
		local Landing = Beef.Events.new("landing", "handle:u32", "y:f32")

		local function Fall(drop, position, velocity, landing)
			local self
			self = {
				name = "Fall",
				loop = function()
					local p, v = position.of(drop).value, velocity.of(drop).value
					for n = 1, drop.count do
						if v[n].Y ~= 0 then
							p[n] = p[n] + v[n]
							if p[n].Y <= 0 then
								landing.push(drop.handle[n], p[n].Y)
								v[n] = Vector3.zero
							end
						end
					end
				end,
			}
			return self
		end

		local landed = 0
		local function Land(landing, drop)
			return {
				name = "Land",
				reads = { landing },
				loop = function()
					for i = landing.from, landing.last do
						landed += 1
						drop.despawn(landing.handle[i])
					end
				end,
			}
		end

		local phase = Beef.Phase.new("Test", {
			{ Fall, Drop, Position, Velocity, Landing },
			{ Land, Landing, Drop },
		})

		Drop.spawn(Vector3.new(0, 1, 0), Vector3.new(0, -1, 0))
		Drop.spawn(Vector3.new(0, 5, 0), Vector3.new(0, -1, 0))
		Beef.Kinds.lap()
		T.eq(Drop.count, 2, "two drops")

		for _ = 1, 3 do
			Beef.Events.lap()
			Beef.Kinds.lap()
			phase.run()
		end
		T.eq(landed, 1, "the low drop landed")
		Beef.Events.lap()
		Beef.Kinds.lap()
		T.eq(Drop.count, 1, "and was despawned")
	end)

	T.case("Wire packs a vector3 round trip", function()
		local Wire = T.module("Wire")
		local b = buffer.create(12)
		Wire.write.vector3(b, 0, Vector3.new(1, 2, 3))
		local v = Wire.read.vector3(b, 0)
		T.eq(v.X, 1)
		T.eq(v.Z, 3)
	end)
end
