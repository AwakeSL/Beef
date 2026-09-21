--!strict
--!optimize 2
-- the engine edge of the fleet side, and the only part of it that knows what HttpService is: one POST, a way to
-- run something off the frame, and a clock. Everything above this is buffers and bytes, so a spec stands a
-- table in its place and the whole conversation with the relay runs headless.
--
-- The clock is `os.clock`, not the server clock: every duration the fleet measures is measured inside one
-- machine and crosses as an age, so a shared clock is never wanted and never asked for.

local HttpService = game:GetService("HttpService")

local Live = {}

function Live.http(url: string, headers: { [string]: string }, body: string): (boolean, number, string)
	local ok, response = pcall(HttpService.RequestAsync, HttpService, {
		Url = url,
		Method = "POST",
		Headers = headers,
		Body = body,
		Compress = Enum.HttpCompression.None,
	})
	if not ok then
		return false, 0, ""
	end
	return true, response.StatusCode, response.Body
end

function Live.spawn(fn: () -> ())
	task.spawn(fn)
end

function Live.clock(): number
	return os.clock() * 1000
end

return Live
