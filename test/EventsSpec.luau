--!strict
-- Events.new guards its own bookkeeping fields at declaration, so a column cannot shadow one.

return function(T)
	T.case("a column named after one of the buffer's own fields is refused", function()
		local Beef = T.load()
		T.throws(function()
			Beef.Events.new("landing", "count:u32")
		end, "one of its own fields", "count is a field bookkeeping keeps")
		T.throws(function()
			Beef.Events.new("landing", "push:u32")
		end, "one of its own fields", "push is the field a push calls")
		T.throws(function()
			Beef.Events.new("landing", "handle:u32", "entity")
		end, "one of its own fields", "entity is a field an event can carry")
	end)

	T.case("two columns of the same name are refused", function()
		local Beef = T.load()
		T.throws(function()
			Beef.Events.new("landing", "handle:u32", "handle:u32")
		end, "declared twice", "the second handle column names the same thing as the first")
	end)

	T.case("an ordinary column still declares and pushes", function()
		local Beef = T.load()
		local Landing = Beef.Events.new("landing", "handle:u32", "y:f32")
		Landing.push(7, 1.5)
		T.eq(Landing.count, 1, "the push landed")
		T.eq(Landing.handle[1], 7, "the handle column reads back")
		T.eq(Landing.y[1], 1.5, "the y column reads back")
	end)
end
