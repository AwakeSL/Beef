--!strict
--!optimize 2

-- The controller that runs a cue inside a Phase. It reads every bound anchor and both answers of
-- every primitive that asks on an event, and it is the only thing that pushes an ask. A pass of
-- the loop takes every answer that came back, carries the chains waiting on them one step further,
-- and fires on everything pushed at a bound anchor since the pass before; the Phase keeps passing
-- while something moved, so a whole sequence resolves inside the frame it started in.

local Runner = require(script.Parent.Runner)

local function Control(cue: any): any
	local runner = cue.runner
	Runner.wire(runner)
	local queue = cue.queue
	local pending = false

	local controller
	controller = {
		name = "Cue",
		reads = Runner.reads(runner),
		writes = Runner.writes(runner),
		-- the clock is the phase's, moved once a frame; the queue is stepped against it in the
		-- loop, on the first pass, so an entry that comes due lands in this frame's passes
		pre = function()
			runner.now += controller.phase.dt
			cue:window(runner.now)
			pending = true
		end,
		loop = function()
			Runner.pump(runner)
			if pending then
				pending = false
				queue:step(runner.now)
			end
		end,
	}
	return controller
end

return Control
