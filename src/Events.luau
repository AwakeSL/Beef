--!strict
--!optimize 2

export type Buffer = {
	name: string,
	columns: { string },
	wire: { [string]: string },
	count: number,
	base: number,
	lapStart: number,
	from: number,
	last: number,
	walked: number,
	lost: number,
	unread: number,
	keep: number,
	entity: string?,
	push: (...any) -> (),
	freeze: (number) -> number,
	lap: (time: number?) -> (),
	since: (time: number) -> (number, boolean),
	laps: () -> number,
	lapWindow: (k: number) -> (number, number, number),
}

export type Options = {
	keep: number?,
	entity: string?,
}

local Wire = require(script.Parent.Wire)

local all: { Buffer } = {}

local function bookkeeping(name: string, names: { string }, wire: { [string]: string }, columns: { { any } }, keep: number): any
	-- the last `keep` closed laps stay readable below this lap's window; 1 is the plain two-lap lifetime
	local starts: { number } = table.create(keep, 0)
	local times: { number } = table.create(keep, -math.huge)
	local head = 0
	local closed = 0

	local buffer = {
		name = name,
		columns = names,
		wire = wire,
		keep = keep,
		count = 0,
		base = 0,
		lapStart = 1,
		from = 1,
		last = 0,
		walked = 1,
		lost = 0,
		unread = 0,
	} :: any

	buffer.freeze = function(cursor: number): number
		local base = buffer.base
		local from = cursor - base
		if from < 1 then
			buffer.lost += 1 - from
			from = 1
		end
		buffer.from = from
		buffer.last = buffer.count
		local next = base + buffer.count + 1
		if next > buffer.walked then
			buffer.walked = next
		end
		return next
	end

	buffer.lap = function(time: number?)
		head = head % keep + 1
		starts[head] = buffer.base + buffer.lapStart
		times[head] = time or -math.huge
		if closed < keep then
			closed += 1
		end
		local oldest = (head - closed) % keep + 1
		local dropped = starts[oldest] - buffer.base - 1
		if dropped > 0 then
			local count = buffer.count
			local unread = math.min(dropped, buffer.base + dropped + 1 - buffer.walked)
			if unread > 0 then
				buffer.unread += unread
			end
			for _, values in columns do
				table.move(values, dropped + 1, count, 1)
				for i = count - dropped + 1, count do
					values[i] = nil
				end
			end
			buffer.base += dropped
			buffer.count = count - dropped
		end
		buffer.lapStart = buffer.count + 1
	end

	-- retained closed laps, oldest first: how many, and the k-th one's window (rows from, last) and stamp
	buffer.laps = function(): number
		return closed
	end
	buffer.lapWindow = function(k: number): (number, number, number)
		local i = (head - closed + k - 1) % keep + 1
		local from = starts[i] - buffer.base
		local last
		if k < closed then
			last = starts[i % keep + 1] - buffer.base - 1
		else
			last = buffer.lapStart - 1
		end
		return from, last, times[i]
	end

	-- first row of the oldest retained lap stamped at or after time, and whether every lap since then is still held
	buffer.since = function(time: number): (number, boolean)
		for k = closed, 1, -1 do
			local i = (head - k) % keep + 1
			if times[i] >= time then
				return starts[i] - buffer.base, k < closed or times[i] == time
			end
		end
		return buffer.count + 1, true
	end

	return buffer
end

local makers = {
	function(buffer, a)
		buffer.push = function(x)
			local n = buffer.count + 1
			a[n] = x
			buffer.count = n
		end
	end,
	function(buffer, a, b)
		buffer.push = function(x, y)
			local n = buffer.count + 1
			a[n] = x
			b[n] = y
			buffer.count = n
		end
	end,
	function(buffer, a, b, c)
		buffer.push = function(x, y, z)
			local n = buffer.count + 1
			a[n] = x
			b[n] = y
			c[n] = z
			buffer.count = n
		end
	end,
	function(buffer, a, b, c, d)
		buffer.push = function(x, y, z, w)
			local n = buffer.count + 1
			a[n] = x
			b[n] = y
			c[n] = z
			d[n] = w
			buffer.count = n
		end
	end,
}

local Events = {}

function Events.new(name: string, ...: any): Buffer
	local width = select("#", ...)
	local options: Options? = nil
	if width > 0 and type(select(width, ...)) == "table" then
		options = select(width, ...)
		width -= 1
	end
	local keep = options and options.keep or 1
	local entity = options and options.entity or nil
	local maker = makers[width]
	assert(maker, ("%s: Events.new supports 1 to %d columns, got %d"):format(name, #makers, width))
	local columns = {}
	local names = {}
	local wire = {}
	for i = 1, width do
		columns[i] = {}
		local column, kind = Wire.split((select(i, ...)))
		names[i] = column
		if kind then
			wire[column] = kind
		end
	end
	local buffer = bookkeeping(name, names, wire, columns, keep)
	for i = 1, width do
		buffer[names[i]] = columns[i]
	end
	if entity then
		assert(table.find(names, entity), ("%s: entity column %s is not one of its columns"):format(name, entity))
		buffer.entity = entity
	end
	maker(buffer, table.unpack(columns))
	table.insert(all, buffer)
	return buffer
end

local laps = 0

function Events.lap(time: number?)
	laps += 1
	local stamp = time or laps
	for _, buffer in all do
		buffer.lap(stamp)
	end
end

return Events
