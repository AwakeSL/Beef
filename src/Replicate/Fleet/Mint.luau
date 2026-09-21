--!strict
--!optimize 2
-- fleet ids come from the relay in blocks, not one at a time: a server asks for a block, gets a base and a size,
-- and hands out ids from it without another word. The ask goes out while there are still ids left over, so the
-- next block is usually in hand before the last one runs dry and a spawn never waits on a round trip.
--
-- When it does run dry the mint says so by returning nil, and the caller defers: the entity spawns anyway and is
-- given an id on a later frame. Nothing about a spawn is allowed to depend on the relay answering.

local Mint = {}
Mint.__index = Mint

export type Pool = typeof(setmetatable(
	{} :: {
		ranges: { { base: number, size: number, used: number } },
		remaining: number,
		blockSize: number,
		watermark: number,
		requestPending: boolean,
		stats: { minted: number, deferred: number, granted: number },
	},
	Mint
))

function Mint.new(watermark: number?): Pool
	return setmetatable({
		ranges = {},
		remaining = 0,
		blockSize = 0,
		watermark = watermark or 128,
		requestPending = false,
		stats = { minted = 0, deferred = 0, granted = 0 },
	}, Mint)
end

function Mint.grant(self: Pool, base: number, size: number)
	table.insert(self.ranges, { base = base, size = size, used = 0 })
	self.remaining += size
	self.blockSize = size
	self.requestPending = false
	self.stats.granted += 1
end

function Mint.mint(self: Pool): number?
	local range = self.ranges[1]
	if range == nil then
		self.stats.deferred += 1
		return nil
	end
	local id = range.base + range.used
	range.used += 1
	self.remaining -= 1
	if range.used >= range.size then
		table.remove(self.ranges, 1)
	end
	self.stats.minted += 1
	return id
end

-- one ask in flight at a time, and only once the pool is low enough to be worth the bytes
function Mint.wantsBlock(self: Pool): boolean
	if self.requestPending then
		return false
	end
	if self.remaining > self.watermark then
		return false
	end
	self.requestPending = true
	return true
end

return Mint
