--!strict
-- The one conversation with the relay, with a table standing in for the POST: what state ships, what is cleared
-- only once the relay took it, what comes back into the inbox, and how the schedule steers itself.

return function(T)
	local Transport = T.module("Replicate/Fleet/Transport")
	local Framing = T.module("Replicate/Fleet/Framing")
	local Codec = T.module("Replicate/Fleet/Codec")
	local eq, ok = T.eq, T.ok

	local ID_TABLE, ID_PLACE, ID_RELEASE, ID_WANT = 240, 241, 242, 243
	local ID_BLOCK_REQUEST, ID_CLAIM, ID_ADOPT, ID_DISOWN = 244, 246, 248, 249

	local PROTOCOL: { [number]: number } = {
		[240] = 0,
		[241] = 0,
		[242] = 5,
		[243] = 0,
		[244] = 5,
		[245] = 10,
		[246] = 9,
		[247] = 10,
		[248] = 0,
		[249] = 5,
		[250] = 13,
	}

	local function messages(): any
		local hit = {
			id = 1,
			name = "hit",
			columns = { "amount", "part" },
			wire = { amount = "i32", part = "u8" },
			routing = "owner",
			retention = "none",
			collapsible = false,
			window = 0,
		}
		local motion = {
			id = 2,
			name = "motion",
			columns = { "where" },
			wire = { where = "vector3" },
			routing = "key",
			retention = "replace",
			collapsible = true,
			window = 0.05,
		}
		Codec.prepare(hit, "spec")
		Codec.prepare(motion, "spec")
		return { byId = { [1] = hit, [2] = motion }, byName = { hit = hit, motion = motion } }, hit, motion
	end

	local function fakeNet(): any
		local net: any = { bodies = {}, answers = {} }
		net.http = function(_url, _headers, body: string): (boolean, number, string)
			table.insert(net.bodies, body)
			local answer = table.remove(net.answers, 1) or { true, 200, "\1" }
			return answer[1], answer[2], answer[3]
		end
		return net
	end

	local function make(net: any, declared: any): any
		return Transport.new({
			url = "http://relay",
			identity = "srv",
			messages = declared,
			named = {},
			http = net.http,
		})
	end

	-- a batch this side wrote starts with the message table, whose entries are bare four-byte declarations
	-- rather than framed ones, so it comes off before the rest can be walked
	local function idsIn(body: string, declared: any): { number }
		local strides = table.clone(PROTOCOL)
		for id, message in declared.byId do
			strides[id] = message.stride or 0
		end
		local rest = body
		if #body > 2 and body:byte(2) == ID_TABLE then
			rest = "\1" .. body:sub(4 + body:byte(3) * 4)
		end
		local slices = assert(Framing.walk(buffer.fromstring(rest), strides))
		local out = {}
		for _, slice in slices do
			table.insert(out, slice.id)
		end
		return out
	end

	local function has(list: { number }, id: number): boolean
		return table.find(list, id) ~= nil
	end

	-- ------------------------------------------------------------ what ships

	T.case("the message table goes out once and is not said again", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:step(0)
		eq(net.bodies[1]:byte(2), ID_TABLE, "the first post did not open with the table")
		eq(net.bodies[1]:byte(3), 2, "two messages were declared")
		t:step(130)
		ok(net.bodies[2]:byte(2) ~= ID_TABLE, "the table was restated to a relay that has it")
	end)

	T.case("a lost table is said again", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		net.answers[1] = { false, 0, "" }
		t:step(0)
		t:step(1000)
		eq(net.bodies[2]:byte(2), ID_TABLE, "a relay that never got the table was talked to as if it had")
	end)

	T.case("a place ships, is acked, and is not repeated", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:place(5, "zone:1")
		t:step(0)
		ok(has(idsIn(net.bodies[1], declared), ID_PLACE), "the place never shipped")
		t:step(130)
		ok(not has(idsIn(net.bodies[2], declared), ID_PLACE), "an acked place was said twice")
	end)

	T.case("a place changed while the post was out stays dirty", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		net.answers[1] = { true, 200, "\1" }
		t:place(5, "zone:1")
		-- the http here answers inside the step, so the move has to come after it to be the in-flight case
		t:step(0)
		t:place(5, "zone:2")
		t:step(130)
		ok(has(idsIn(net.bodies[2], declared), ID_PLACE), "the newer place never shipped")
	end)

	T.case("a release ships and takes the place off", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:place(5, "zone:1")
		t:release(5)
		t:step(0)
		local ids = idsIn(net.bodies[1], declared)
		ok(has(ids, ID_RELEASE), "the release never shipped")
		ok(not has(ids, ID_PLACE), "a released subject was placed in the same batch")
	end)

	T.case("a want ships whole and only when it changes", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:setWant({ "zone:1", "zone:2" })
		t:step(0)
		ok(has(idsIn(net.bodies[1], declared), ID_WANT), "the want never shipped")
		t:step(130)
		ok(not has(idsIn(net.bodies[2], declared), ID_WANT), "an unchanged want was restated")
	end)

	T.case("a cold pool asks for a block, and a grant fills it", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		eq(t:mint(), nil, "a cold pool minted an id")
		t:step(0)
		ok(has(idsIn(net.bodies[1], declared), ID_BLOCK_REQUEST), "no block was asked for")

		-- one grant: base 4096, size 512
		local grant = "\1\245\1" .. "\0\0\0" .. "\0\0" .. "\0\16\0" .. "\0\2"
		net.answers[1] = { true, 200, grant }
		t:step(130)
		eq(t:mint(), 4096, "the granted block did not arrive")
		eq(t:mint(), 4097, "the block is not a run")
	end)

	T.case("a claim is one ask, not standing state", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:claim(5, 0)
		t:step(0)
		ok(has(idsIn(net.bodies[1], declared), ID_CLAIM), "the claim never shipped")
		t:step(130)
		ok(not has(idsIn(net.bodies[2], declared), ID_CLAIM), "a claim asked itself twice")
	end)

	T.case("a claim lost to a failed post is asked again", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		net.answers[1] = { false, 0, "" }
		t:claim(5, 0)
		t:step(0)
		t:step(1000)
		ok(has(idsIn(net.bodies[2], declared), ID_CLAIM), "an unanswered claim was dropped")
	end)

	T.case("an adopt ships, is acked, and reships when its body changes", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:adopt(5, "zone:1", "sword")
		t:step(0)
		ok(has(idsIn(net.bodies[1], declared), ID_ADOPT), "the adopt never shipped")
		t:step(130)
		ok(not has(idsIn(net.bodies[2], declared), ID_ADOPT), "an acked adopt was resent")
		t:adopt(5, "zone:1", "broken sword")
		t:step(260)
		ok(has(idsIn(net.bodies[3], declared), ID_ADOPT), "the newer body never shipped")
	end)

	T.case("a disown replaces a pending adopt", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:adopt(5, "zone:1", "sword")
		t:disown(5)
		t:step(0)
		local ids = idsIn(net.bodies[1], declared)
		ok(has(ids, ID_DISOWN), "the disown never shipped")
		ok(not has(ids, ID_ADOPT), "a disowned subject was adopted in the same batch")
	end)

	T.case("a pushed entry ships in a block of its message", function()
		local declared, hit = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:offer(hit, 5, { -12, 3 }, 0)
		t:offer(hit, 6, { 40, 1 }, 0)
		t:step(0)
		local ids = idsIn(net.bodies[1], declared)
		local n = 0
		for _, id in ids do
			if id == 1 then
				n += 1
			end
		end
		eq(n, 2, "two pushes did not make two entries")
	end)

	-- -------------------------------------------------------- what comes back

	T.case("an entry of a declared message reaches the inbox with its age", function()
		local declared, _, motion = messages()
		local net = fakeNet()
		local t = make(net, declared)
		local entry = Codec.encode(motion, 9, 0, { Vector3.new(4, 5, 6) })
		buffer.writeu16(entry, 3, 220)
		local w = Framing.writer()
		Framing.addBlock(w, motion, { entry })
		net.answers[1] = { true, 200, buffer.tostring(Framing.finish(w)) }
		t:step(0)
		local inbox = t:drain()
		eq(#inbox, 1, "nothing arrived")
		eq(inbox[1].what, "motion", "wrong message")
		eq(inbox[1].subject, 9, "wrong subject")
		eq(inbox[1].ageMs, 220, "the age did not survive the trip")
		eq((inbox[1].values :: any)[1], Vector3.new(4, 5, 6), "the column did not survive the trip")
	end)

	T.case("a claim result, an adopt and a release all reach the inbox", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		local adopt = "\5\0\0" .. "\0\0" .. "\6" .. "zone:1" .. "axe"
		net.answers[1] = {
			true,
			200,
			"\1"
				.. "\247\1"
				.. "\5\0\0\0\0\1\0\0\0\0"
				.. "\248\1"
				.. string.char(#adopt, 0)
				.. adopt
				.. "\242\1"
				.. "\7\0\0\30\0",
		}
		t:step(0)
		local inbox = t:drain()
		eq(#inbox, 3, "not everything arrived")
		eq(inbox[1].what, "$claim", "claim")
		eq(inbox[1].granted, true, "a granted claim read as refused")
		eq(inbox[2].what, "$adopt", "adopt")
		eq(inbox[2].key, "zone:1", "the adopt key")
		eq(inbox[2].body, "axe", "the adopt body")
		eq(inbox[3].what, "$release", "release")
		eq(inbox[3].subject, 7, "the released subject")
		eq(inbox[3].ageMs, 30, "the release age")
	end)

	T.case("a response that does not walk is refused whole and counted", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		net.answers[1] = { true, 200, "\1\99\1\0\0\0\0\0" }
		t:step(0)
		eq(#t:drain(), 0, "an unwalkable answer was read anyway")
		eq(t.stats.refusedResponses, 1, "the refusal was not counted")
	end)

	T.case("a failed post puts its entries back", function()
		local declared, hit = messages()
		local net = fakeNet()
		local t = make(net, declared)
		net.answers[1] = { false, 0, "" }
		t:offer(hit, 5, { -12, 3 }, 0)
		t:step(0)
		eq(#t.buffer.pending, 1, "the entry of a lost post was thrown away")
		eq(t.stats.failed, 1, "the failure was not counted")
	end)

	-- ------------------------------------------------------------- the beat

	T.case("a post waits for its deadline and the quota holds it past the budget", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t.callsPerMinute = 2
		eq(t:step(0), "sent", "the first post")
		eq(t:step(10), "waiting", "a post went before its deadline")
		eq(t:step(130), "sent", "the second post")
		eq(t:step(260), "quota", "the budget was spent and the post went anyway")
	end)

	T.case("the first tick snaps the schedule onto the aim and later ones nudge it", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:step(0)
		local deadline = t.deadlineMs
		t:_tick(60, 125, 1, t.sendSeq)
		eq(t.stats.snaps, 1, "the first report did not snap")
		eq(t.deadlineMs, deadline + 60 - Transport.LEAD_TARGET_MS, "the snap did not land on the aim")

		-- a report may steer only if the one before it did not, so the next is skipped and the one after nudges
		t:_tick(60, 125, 2, t.sendSeq)
		eq(t.stats.nudges, 0, "two reports in a row steered")
		local before = t.deadlineMs
		t:_tick(30, 125, 3, t.sendSeq)
		eq(t.stats.nudges, 1, "the nudge never happened")
		eq(t.deadlineMs, before + (30 - Transport.LEAD_TARGET_MS) * Transport.SERVO_GAIN, "the nudge is not a fraction of the error")

		-- one report is worth at most the clamp, however far off it says the post landed
		t:_tick(30, 125, 4, t.sendSeq)
		before = t.deadlineMs
		t:_tick(900, 125, 5, t.sendSeq)
		eq(t.deadlineMs, before + Transport.SERVO_CLAMP_MS * Transport.SERVO_GAIN, "one wild report moved the schedule further than the clamp")
	end)

	T.case("a report from a post older than the last one that steered is dropped", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		t:step(0)
		t:_tick(60, 125, 1, 4)
		t:_tick(60, 125, 1, 2)
		eq(t.stats.servoStaleDrops, 1, "a stale report steered the schedule")
	end)

	T.case("a run of failures backs the schedule off", function()
		local declared = messages()
		local net = fakeNet()
		local t = make(net, declared)
		for i = 1, 3 do
			net.answers[i] = { false, 0, "" }
		end
		t:step(0)
		local first = t.nextAttemptMs
		t:step(first)
		local second = t.nextAttemptMs
		ok(second - first > first, "the backoff did not grow")
		eq(t.stats.paused, 0, "a pause was counted before the third failure")
		t:step(second)
		eq(t.stats.paused, 1, "the third failure did not count as a pause")
	end)
end
