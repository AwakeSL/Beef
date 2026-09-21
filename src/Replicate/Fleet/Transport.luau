--!strict
--!optimize 2
-- the one conversation with the relay. Everything a frame decides -- a push offered, a place, a want, an adopt,
-- a claim -- lands in state here, and on its own schedule this posts the lot as one batch and reads the answer
-- back. A frame never waits on a round trip and never knows one happened.
--
-- The relay answers on the same request, so this is a poll with a payload rather than a socket: the schedule is
-- what keeps it cheap, and the arrival-lead servo below is what keeps the schedule aligned with the relay's own
-- tick without either machine knowing the other's clock.
--
-- Nothing in here understands an Event. It moves message ids, subjects, and bytes.

local Buffer = require(script.Parent.Buffer)
local Codec = require(script.Parent.Codec)
local Framing = require(script.Parent.Framing)
local Mint = require(script.Parent.Mint)

local Transport = {}
Transport.__index = Transport

Transport.LEAD_TARGET_MS = 20
Transport.LEAD_SPREAD_P99_MS = 15
Transport.LEAD_BAND_MAX_MS = Transport.LEAD_TARGET_MS + Transport.LEAD_SPREAD_P99_MS + 7
Transport.SERVO_GAIN = 0.25
Transport.SERVO_CLAMP_MS = Transport.LEAD_SPREAD_P99_MS
Transport.LEAD_AIM_MAX_MS = 55
local LEAD_HISTORY = 64
local AIM_MIN_SAMPLES = 16

-- the ids above every message id a boot table can hand out. These are the relay's own vocabulary, and a Beef
-- message is numbered from 1 up, so the two never collide.
local ID_TABLE = 240
local ID_PLACE = 241
local ID_RELEASE = 242
local ID_WANT = 243
local ID_BLOCK_REQUEST = 244
local ID_BLOCK_GRANT = 245
local ID_CLAIM = 246
local ID_CLAIM_RESULT = 247
local ID_ADOPT = 248
local ID_DISOWN = 249
local ID_TICK = 250

Transport.MAX_MESSAGE_ID = 239

local PROTOCOL_STRIDE: { [number]: number } = {
	[ID_TABLE] = 0,
	[ID_PLACE] = 0,
	[ID_RELEASE] = 5,
	[ID_WANT] = 0,
	[ID_BLOCK_REQUEST] = 5,
	[ID_BLOCK_GRANT] = 10,
	[ID_CLAIM] = 9,
	[ID_CLAIM_RESULT] = 10,
	[ID_ADOPT] = 0,
	[ID_DISOWN] = 5,
	[ID_TICK] = 13,
}

export type Options = {
	url: string,
	identity: string,
	messages: { byId: { [number]: any }, byName: { [string]: any } },
	named: { [string]: any },
	http: (url: string, headers: { [string]: string }, body: string) -> (boolean, number, string),
	spawn: ((() -> ()) -> ())?,
	intervalMs: number?,
	maxBackoffMs: number?,
	callsPerMinute: number?,
	cap: number?,
}

export type Inbound = {
	what: string,
	message: any?,
	subject: number,
	ageMs: number,
	values: { any }?,
	key: string?,
	body: string?,
	granted: boolean?,
}

function Transport.new(opts: Options)
	return setmetatable({
		url = opts.url,
		identity = opts.identity,
		messages = opts.messages,
		named = opts.named,
		http = opts.http,
		spawn = opts.spawn or function(fn: () -> ())
			fn()
		end,
		intervalMs = opts.intervalMs or 125,
		maxBackoffMs = opts.maxBackoffMs or 5000,
		callsPerMinute = opts.callsPerMinute or 480,
		callTimes = {} :: { number },

		buffer = Buffer.new(opts.cap),
		pool = Mint.new(),
		tableDirty = true,
		places = {} :: { [number]: string },
		placeDirty = {} :: { [number]: boolean },
		releaseDirty = {} :: { [number]: boolean },
		want = {} :: { string },
		wantDirty = false,
		adopts = {} :: { [number]: { key: string, body: string } },
		adoptDirty = {} :: { [number]: boolean },
		disownDirty = {} :: { [number]: boolean },
		claims = {} :: { [number]: number },

		inflight = 0,
		deadlineMs = nil :: number?,
		sendSeq = 0,
		servoSeq = 0,
		steered = false,
		snapped = false,
		leads = {} :: { number },
		nextAttemptMs = 0,
		failures = 0,
		inbox = {} :: { Inbound },
		stats = {
			sent = 0,
			okCount = 0,
			failed = 0,
			received = 0,
			refusedResponses = 0,
			refusedEntries = 0,
			paused = 0,
			quotaHeld = 0,
			ticks = 0,
			missed = 0,
			nudges = 0,
			servoStaleDrops = 0,
			periodMismatch = 0,
			leadMs = 0,
			sendLateMs = 0,
			snaps = 0,
			aimMs = Transport.LEAD_TARGET_MS,
		},
	}, Transport)
end

function Transport.offer(self: any, message: any, subject: number, values: { any }, nowMs: number): string
	return self.buffer:offer(message, subject, Codec.encode(message, subject, 0, values), nowMs)
end

function Transport.place(self: any, subject: number, key: string)
	self.places[subject] = key
	self.placeDirty[subject] = true
	self.releaseDirty[subject] = nil
end

function Transport.release(self: any, subject: number)
	self.places[subject] = nil
	self.placeDirty[subject] = nil
	self.releaseDirty[subject] = true
end

function Transport.adopt(self: any, subject: number, key: string, body: string)
	self.adopts[subject] = { key = key, body = body }
	self.adoptDirty[subject] = true
	self.disownDirty[subject] = nil
end

function Transport.disown(self: any, subject: number)
	self.adopts[subject] = nil
	self.adoptDirty[subject] = nil
	self.disownDirty[subject] = true
end

function Transport.claim(self: any, subject: number, holdMs: number?)
	self.claims[subject] = holdMs or 0
end

function Transport.setWant(self: any, keys: { string })
	self.want = keys
	self.wantDirty = true
end

function Transport.mint(self: any): number?
	return self.pool:mint()
end

function Transport.drain(self: any): { Inbound }
	local out = self.inbox
	self.inbox = {}
	return out
end

local function envelope(subject: number, ageMs: number): buffer
	local b = buffer.create(5)
	buffer.writeu16(b, 0, subject % 65536)
	buffer.writeu8(b, 2, subject // 65536)
	buffer.writeu16(b, 3, ageMs)
	return b
end

-- the relay is told what each message id means only so it can walk a batch and know what to keep: how wide an
-- entry is, whether it routes by key or by owner, and how long to hold it. It is never told what a column is.
local function tableEntry(messages: any): buffer
	local sorted = {}
	for _, message in messages.byId do
		table.insert(sorted, message)
	end
	table.sort(sorted, function(a, b)
		return a.id < b.id
	end)
	local b = buffer.create(4 * #sorted)
	local at = 0
	for _, message in sorted do
		local flags = (if message.routing == "owner" then 1 else 0)
			+ (if message.retention == "replace" then 2 elseif message.retention == "append" then 4 else 0)
		buffer.writeu8(b, at, message.id)
		buffer.writeu8(b, at + 1, flags)
		buffer.writeu16(b, at + 2, message.stride or 0)
		at += 4
	end
	return b
end

local function adoptEntry(subject: number, key: string, body: string): buffer
	local b = buffer.create(6 + #key + #body)
	buffer.copy(b, 0, envelope(subject, 0))
	buffer.writeu8(b, 5, #key)
	buffer.writestring(b, 6, key)
	if #body > 0 then
		buffer.writestring(b, 6 + #key, body)
	end
	return b
end

local function claimEntry(subject: number, holdMs: number): buffer
	local b = buffer.create(9)
	buffer.copy(b, 0, envelope(subject, 0))
	buffer.writeu32(b, 5, holdMs)
	return b
end

local function placeEntry(subject: number, key: string): buffer
	local b = buffer.create(6 + #key)
	buffer.copy(b, 0, envelope(subject, 0))
	buffer.writeu8(b, 5, #key)
	buffer.writestring(b, 6, key)
	return b
end

local function wantEntry(keys: { string }): buffer
	local size = 7
	for _, key in keys do
		size += 1 + #key
	end
	local b = buffer.create(size)
	buffer.copy(b, 0, envelope(0, 0))
	buffer.writeu16(b, 5, #keys)
	local at = 7
	for _, key in keys do
		buffer.writeu8(b, at, #key)
		buffer.writestring(b, at + 1, key)
		at += 1 + #key
	end
	return b
end

local function tableBlock(messages: any): buffer
	local entry = tableEntry(messages)
	local n = buffer.len(entry) // 4
	local b = buffer.create(2 + buffer.len(entry))
	buffer.writeu8(b, 0, ID_TABLE)
	buffer.writeu8(b, 1, n)
	buffer.copy(b, 2, entry)
	return b
end

-- one post: every dirty piece of state and everything the buffer has been holding, in one batch. What went into
-- it is remembered in `snapshot` and only cleared once the relay says it took it, so a failed post loses
-- nothing.
function Transport.step(self: any, nowMs: number): string
	if nowMs < self.nextAttemptMs then
		return "waiting"
	end

	local windowStart = nowMs - 60000
	while self.callTimes[1] ~= nil and self.callTimes[1] < windowStart do
		table.remove(self.callTimes, 1)
	end
	if #self.callTimes >= self.callsPerMinute then
		self.stats.quotaHeld += 1
		return "quota"
	end

	local w = Framing.writer()
	local snapshot = { entries = nil, tableIncluded = false, placesIncluded = {}, wantIncluded = false }

	if self.tableDirty then
		table.insert(w.parts, tableBlock(self.messages))
		w.size += buffer.len(w.parts[#w.parts])
		snapshot.tableIncluded = true
	end

	local placeEntries = {}
	for subject in self.placeDirty do
		table.insert(placeEntries, placeEntry(subject, self.places[subject]))
		snapshot.placesIncluded[subject] = self.places[subject]
	end
	if #placeEntries > 0 then
		Framing.addBlock(w, { id = ID_PLACE, stride = nil }, placeEntries)
	end

	local releaseEntries = {}
	snapshot.releasesIncluded = {}
	for subject in self.releaseDirty do
		table.insert(releaseEntries, envelope(subject, 0))
		table.insert(snapshot.releasesIncluded, subject)
	end
	if #releaseEntries > 0 then
		Framing.addBlock(w, { id = ID_RELEASE, stride = 5 }, releaseEntries)
	end

	if self.wantDirty then
		Framing.addBlock(w, { id = ID_WANT, stride = nil }, { wantEntry(self.want) })
		snapshot.wantIncluded = true
	end

	local adoptEntries = {}
	snapshot.adoptsIncluded = {}
	for subject in self.adoptDirty do
		local held = self.adopts[subject]
		table.insert(adoptEntries, adoptEntry(subject, held.key, held.body))
		snapshot.adoptsIncluded[subject] = ("%d|%s|%s"):format(#held.key, held.key, held.body)
	end
	if #adoptEntries > 0 then
		Framing.addBlock(w, { id = ID_ADOPT, stride = nil }, adoptEntries)
	end

	local disownEntries = {}
	snapshot.disownsIncluded = {}
	for subject in self.disownDirty do
		table.insert(disownEntries, envelope(subject, 0))
		table.insert(snapshot.disownsIncluded, subject)
	end
	if #disownEntries > 0 then
		Framing.addBlock(w, { id = ID_DISOWN, stride = 5 }, disownEntries)
	end

	local claimEntries = {}
	for subject, holdMs in self.claims do
		table.insert(claimEntries, claimEntry(subject, holdMs))
	end
	if #claimEntries > 0 then
		Framing.addBlock(w, { id = ID_CLAIM, stride = 9 }, claimEntries)
		snapshot.claimsIncluded = self.claims
		self.claims = {}
	end

	if self.pool:wantsBlock() then
		Framing.addBlock(w, { id = ID_BLOCK_REQUEST, stride = 5 }, { envelope(0, 0) })
		snapshot.blockRequested = true
	end

	-- the buffer hands back its pending entries in offer order, so entries of the same message are already
	-- neighbours and one block covers a run of them
	local flushed = self.buffer:flush(nowMs)
	snapshot.entries = flushed
	local i = 1
	while i <= #flushed do
		local message = flushed[i].message
		local entries = {}
		while i <= #flushed and flushed[i].message == message do
			table.insert(entries, flushed[i].payload)
			i += 1
		end
		Framing.addBlock(w, message, entries)
	end

	local body = buffer.tostring(Framing.finish(w))
	self.inflight += 1
	self.sendSeq += 1
	snapshot.seq = self.sendSeq
	snapshot.postedMs = nowMs
	local deadline = self.deadlineMs or nowMs
	snapshot.lateMs = nowMs - deadline
	self.stats.sendLateMs = snapshot.lateMs
	self.deadlineMs = deadline + self.intervalMs
	self.nextAttemptMs = self.deadlineMs
	table.insert(self.callTimes, nowMs)
	self.stats.sent += 1

	self.spawn(function()
		local ok, status, response = self.http(self.url, { ["x-tether-id"] = self.identity }, body)
		self:_complete(snapshot, ok and status == 200, response, nowMs)
	end)
	return "sent"
end

function Transport._complete(self: any, snapshot: any, ok: boolean, response: string, nowMs: number)
	self.inflight -= 1
	if not ok then
		self.stats.failed += 1
		self.failures += 1
		self.nextAttemptMs = nowMs + math.min(self.intervalMs * 2 ^ self.failures, self.maxBackoffMs)
		self.deadlineMs = nil
		self.snapped = false
		if self.failures > 2 then
			self.stats.paused += 1
		end
		self.buffer:mergeBack(snapshot.entries)
		if snapshot.blockRequested then
			self.pool.requestPending = false
		end
		for subject, holdMs in snapshot.claimsIncluded or {} do
			if self.claims[subject] == nil then
				self.claims[subject] = holdMs
			end
		end
		return
	end

	self.stats.okCount += 1
	self.failures = 0
	if snapshot.tableIncluded then
		self.tableDirty = false
	end
	-- only clear what is still what was sent: a place changed while the post was out stays dirty
	for subject, sentKey in snapshot.placesIncluded do
		if self.places[subject] == sentKey then
			self.placeDirty[subject] = nil
		end
	end
	for _, subject in snapshot.releasesIncluded or {} do
		self.releaseDirty[subject] = nil
	end
	if snapshot.wantIncluded then
		self.wantDirty = false
	end
	for subject, sentState in snapshot.adoptsIncluded or {} do
		local held = self.adopts[subject]
		if held ~= nil and ("%d|%s|%s"):format(#held.key, held.key, held.body) == sentState then
			self.adoptDirty[subject] = nil
		end
	end
	for _, subject in snapshot.disownsIncluded or {} do
		self.disownDirty[subject] = nil
	end

	self:_accept(response, snapshot.seq)
end

--- The arrival-lead servo (the aligned tick). The relay reports how early this post reached the deadline it was
--- released on; the next deadline moves by a clamped fraction of the error, on this clock alone. Feedback,
--- never clock synchronisation. A response may steer only if the previous one did not, so the loop has one real
--- pole at every gain.
--- Every deadline posts, whatever is still out: the schedule says when, the quota bounds how often, and a cap
--- on outstanding posts was a second rule for the same thing that only ever made a slow answer delay the next.
--- The first report snaps the deadline onto the target in one move: a cold start lands at any phase, and
--- walking in at the clamp takes up to 5 s. After that the clamp bounds one report's worth of trust.
function Transport._tick(self: any, leadMs: number, periodMs: number, _tick: number, seq: number?)
	self.stats.ticks += 1
	self.stats.leadMs = leadMs
	table.insert(self.leads, leadMs)
	if #self.leads > LEAD_HISTORY then
		table.remove(self.leads, 1)
	end
	if periodMs ~= self.intervalMs then
		self.stats.periodMismatch += 1
	end
	if leadMs < 0 then
		self.stats.missed += 1
	end
	if seq ~= nil and seq < self.servoSeq then
		self.stats.servoStaleDrops += 1
		return
	end
	self.servoSeq = seq or self.servoSeq
	if self.deadlineMs == nil then
		return
	end
	local aim = self:aimMs()
	self.stats.aimMs = aim
	if not self.snapped then
		self.snapped = true
		self.leads = {}
		self.deadlineMs += leadMs - aim
		self.nextAttemptMs = self.deadlineMs
		self.steered = true
		self.stats.snaps += 1
		return
	end
	if self.steered then
		self.steered = false
		return
	end
	local nudge = math.clamp(leadMs - aim, -Transport.SERVO_CLAMP_MS, Transport.SERVO_CLAMP_MS)
		* Transport.SERVO_GAIN
	self.deadlineMs += nudge
	self.nextAttemptMs = self.deadlineMs
	self.steered = true
	self.stats.nudges += 1
end

--- Where this server aims its posts: the fleet target, raised by however much this route's own late tail
--- exceeds the spread the target was derived on. A jittery route pays the extra lead as hold and stops missing;
--- a clean one aims at 20 exactly as before. The aim ratchets up and decays slowly, so it does not chase the
--- window it is measured over, and its ceiling leaves the route's early tail under the half period, past which
--- an early post reads as a miss.
function Transport.aimMs(self: any): number
	local held = self.stats.aimMs
	local n = #self.leads
	if n < AIM_MIN_SAMPLES then
		return held
	end
	local sorted = table.clone(self.leads)
	table.sort(sorted)
	local p50 = sorted[math.clamp(math.ceil(0.5 * n), 1, n)]
	local low = sorted[math.clamp(math.ceil(0.02 * n), 1, n)]
	local high = sorted[math.clamp(math.ceil(0.98 * n), 1, n)]
	local lateTail = p50 - low
	local earlyTail = high - p50
	local ceiling = math.max(
		Transport.LEAD_TARGET_MS,
		math.min(Transport.LEAD_AIM_MAX_MS, self.intervalMs / 2 - earlyTail - 3)
	)
	local wanted = math.clamp(
		Transport.LEAD_TARGET_MS + math.max(0, lateTail - Transport.LEAD_SPREAD_P99_MS),
		Transport.LEAD_TARGET_MS,
		ceiling
	)
	return math.max(wanted, held - 1 / LEAD_HISTORY)
end

function Transport.leadStats(self: any): { p50: number, p99: number, n: number }
	local n = #self.leads
	if n == 0 then
		return { p50 = 0, p99 = 0, n = 0 }
	end
	local sorted = table.clone(self.leads)
	table.sort(sorted)
	local function at(q: number): number
		return sorted[math.clamp(math.ceil(q * n), 1, n)]
	end
	return { p50 = at(0.5), p99 = at(0.99), n = n }
end

function Transport._accept(self: any, response: string, seq: number?)
	if #response == 0 then
		return
	end
	local b = buffer.fromstring(response)
	local strides: { [number]: number } = table.clone(PROTOCOL_STRIDE)
	for id, message in self.messages.byId do
		strides[id] = message.stride or 0
	end
	local slices = Framing.walk(b, strides)
	if not slices then
		self.stats.refusedResponses += 1
		return
	end
	for _, slice in slices do
		if slice.id == ID_BLOCK_GRANT then
			local base = buffer.readu16(b, slice.at + 5) + buffer.readu8(b, slice.at + 7) * 65536
			local size = buffer.readu16(b, slice.at + 8)
			self.pool:grant(base, size)
			continue
		end
		if slice.id == ID_CLAIM_RESULT then
			table.insert(self.inbox, {
				what = "$claim",
				subject = slice.subject,
				ageMs = buffer.readu16(b, slice.at + 3),
				granted = buffer.readu8(b, slice.at + 5) == 1,
			})
			continue
		end
		if slice.id == ID_ADOPT then
			local klen = buffer.readu8(b, slice.at + 5)
			table.insert(self.inbox, {
				what = "$adopt",
				subject = slice.subject,
				ageMs = buffer.readu16(b, slice.at + 3),
				key = buffer.readstring(b, slice.at + 6, klen),
				body = buffer.readstring(b, slice.at + 6 + klen, slice.len - 6 - klen),
			})
			continue
		end
		if slice.id == ID_RELEASE then
			table.insert(self.inbox, {
				what = "$release",
				subject = slice.subject,
				ageMs = buffer.readu16(b, slice.at + 3),
			})
			continue
		end
		if slice.id == ID_TICK then
			self:_tick(
				buffer.readi16(b, slice.at + 5),
				buffer.readu16(b, slice.at + 7),
				buffer.readu32(b, slice.at + 9),
				seq
			)
			continue
		end
		local message = self.messages.byId[slice.id]
		if message then
			local values = {}
			local subject, ageMs = Codec.decode(message, b, slice.at, slice.len, values, self.named)
			if subject ~= nil then
				table.insert(self.inbox, {
					what = message.name,
					message = message,
					subject = subject,
					ageMs = ageMs :: number,
					values = values,
				})
				self.stats.received += 1
			else
				self.stats.refusedEntries += 1
			end
		end
	end
end

return Transport
