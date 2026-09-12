--!strict
--!optimize 2
type Controller = { name: string, post: () -> (), phase: { describe: () -> string }? }

local EVERY = 10000

return function()
	local runs = 0
	local self: Controller
	self = {
		name = "Report",
		post = function()
			runs += 1
			if runs % EVERY == 0 then
				local phase = self.phase :: { describe: () -> string }
				print(phase.describe())
			end
		end,
	}
	return self
end
