--!strict
--!optimize 2
-- what is waiting to go out. A frame offers as many payloads as it likes and the transport takes them on its own
-- beat, so this is the only place that decides which offers survive the wait.
--
-- A collapsible message keeps one slot per subject: an offer whose bytes match what is already pending, or what
-- last went out, is dropped as unchanged; an offer that lands inside the entry's window of the one already
-- pending replaces it in place rather than queueing behind it. That is the whole of the `window` option, and it
-- is why a transform that moves every frame costs one entry a flush instead of one an offer.
--
-- The age is written at the flush, not at the offer, because what the far side needs is how long the value sat
-- here, and that is not known until it leaves.

local Buffer = {}
Buffer.__index = Buffer

export type Pending = {
	message: any,
	subject: number,
	payload: buffer,
	anchorMs: number,
	sampledMs: number,
}

export type Buf = typeof(setmetatable(
	{} :: {
		cap: number,
		pending: { Pending },
		bySlot: { [string]: Pending },
		lastSent: { [string]: string },
		dropped: number,
		unchanged: number,
		replaced: number,
		appended: number,
	},
	Buffer
))

function Buffer.new(cap: number?): Buf
	return setmetatable({
		cap = cap or 512,
		pending = {},
		bySlot = {},
		lastSent = {},
		dropped = 0,
		unchanged = 0,
		replaced = 0,
		appended = 0,
	}, Buffer)
end

local function slotOf(message: any, subject: number): string
	return message.id .. ":" .. subject
end

local function payloadKey(payload: buffer): string
	return buffer.tostring(payload)
end

function Buffer.offer(self: Buf, message: any, subject: number, payload: buffer, nowMs: number): string
	local slot = slotOf(message, subject)
	local key = payloadKey(payload)

	if message.collapsible then
		local pending = self.bySlot[slot]
		local known = if pending then payloadKey(pending.payload) else self.lastSent[slot]
		if known == key then
			self.unchanged += 1
			return "unchanged"
		end
		if pending and (nowMs - pending.anchorMs) < message.window * 1000 then
			pending.payload = payload
			pending.sampledMs = nowMs
			self.replaced += 1
			return "replaced"
		end
	end

	-- a full buffer sheds its oldest offer rather than the newest: what is stale is worth less than what is fresh
	if #self.pending >= self.cap then
		local evicted = table.remove(self.pending, 1) :: Pending
		local eslot = slotOf(evicted.message, evicted.subject)
		if self.bySlot[eslot] == evicted then
			self.bySlot[eslot] = nil
		end
		self.lastSent[eslot] = nil
		self.dropped += 1
	end

	local entry: Pending = {
		message = message,
		subject = subject,
		payload = payload,
		anchorMs = nowMs,
		sampledMs = nowMs,
	}
	table.insert(self.pending, entry)
	if message.collapsible then
		self.bySlot[slot] = entry
	end
	self.appended += 1
	return "appended"
end

function Buffer.flush(self: Buf, nowMs: number): { Pending }
	local out = self.pending
	self.pending = {}
	table.clear(self.bySlot)
	for _, entry in out do
		self.lastSent[slotOf(entry.message, entry.subject)] = payloadKey(entry.payload)
		local age = math.clamp(math.round(nowMs - entry.sampledMs), 0, 65535)
		buffer.writeu16(entry.payload, 3, age)
	end
	return out
end

-- a batch that did not land comes back. What is already pending for that slot is newer, so the old entry is
-- thrown away and only the memory of having sent it is cleared, which lets the next offer through.
function Buffer.mergeBack(self: Buf, failed: { Pending })
	for i = #failed, 1, -1 do
		local entry = failed[i]
		local slot = slotOf(entry.message, entry.subject)
		if entry.message.collapsible and self.bySlot[slot] ~= nil then
			self.lastSent[slot] = nil
		else
			self.lastSent[slot] = nil
			table.insert(self.pending, 1, entry)
			if entry.message.collapsible then
				self.bySlot[slot] = entry
			end
		end
	end
end

return Buffer
