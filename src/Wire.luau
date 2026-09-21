--!strict
--!optimize 2

export type Writer = (b: buffer, at: number, value: any) -> number
export type Reader = (b: buffer, at: number) -> (any, number)

local Wire = {}

local size: { [string]: number } = {
	u8 = 1,
	u16 = 2,
	u32 = 4,
	u64 = 8,
	i32 = 4,
	f32 = 4,
	f64 = 8,
	bool = 1,
	color3 = 3,
	vector3 = 12,
	kind = 1,
}

local write: { [string]: Writer } = {}
local read: { [string]: Reader } = {}

write.u8 = function(b, at, v)
	buffer.writeu8(b, at, v)
	return at + 1
end
read.u8 = function(b, at)
	return buffer.readu8(b, at), at + 1
end
write.u16 = function(b, at, v)
	buffer.writeu16(b, at, v)
	return at + 2
end
read.u16 = function(b, at)
	return buffer.readu16(b, at), at + 2
end
write.u32 = function(b, at, v)
	buffer.writeu32(b, at, v)
	return at + 4
end
read.u32 = function(b, at)
	return buffer.readu32(b, at), at + 4
end
-- a user id is past what u32 holds, and Luau's buffer has no 64-bit integer; a double is exact to
-- 2^53, which is far above anything Roblox hands out
write.u64 = function(b, at, v)
	buffer.writef64(b, at, v)
	return at + 8
end
read.u64 = function(b, at)
	return buffer.readf64(b, at), at + 8
end
write.i32 = function(b, at, v)
	buffer.writei32(b, at, v)
	return at + 4
end
read.i32 = function(b, at)
	return buffer.readi32(b, at), at + 4
end
write.f32 = function(b, at, v)
	buffer.writef32(b, at, v)
	return at + 4
end
read.f32 = function(b, at)
	return buffer.readf32(b, at), at + 4
end
write.f64 = function(b, at, v)
	buffer.writef64(b, at, v)
	return at + 8
end
read.f64 = function(b, at)
	return buffer.readf64(b, at), at + 8
end
write.bool = function(b, at, v)
	buffer.writeu8(b, at, if v then 1 else 0)
	return at + 1
end
read.bool = function(b, at)
	return buffer.readu8(b, at) == 1, at + 1
end
write.color3 = function(b, at, v: Color3)
	buffer.writeu8(b, at, math.floor(v.R * 255 + 0.5))
	buffer.writeu8(b, at + 1, math.floor(v.G * 255 + 0.5))
	buffer.writeu8(b, at + 2, math.floor(v.B * 255 + 0.5))
	return at + 3
end
read.color3 = function(b, at)
	return Color3.fromRGB(buffer.readu8(b, at), buffer.readu8(b, at + 1), buffer.readu8(b, at + 2)), at + 3
end
write.vector3 = function(b, at, v: Vector3)
	buffer.writef32(b, at, v.X)
	buffer.writef32(b, at + 4, v.Y)
	buffer.writef32(b, at + 8, v.Z)
	return at + 12
end
read.vector3 = function(b, at)
	return Vector3.new(buffer.readf32(b, at), buffer.readf32(b, at + 4), buffer.readf32(b, at + 8)), at + 12
end
write.string = function(b, at, v: string)
	local n = #v
	buffer.writeu16(b, at, n)
	buffer.writestring(b, at + 2, v)
	return at + 2 + n
end
read.string = function(b, at)
	local n = buffer.readu16(b, at)
	return buffer.readstring(b, at + 2, n), at + 2 + n
end

function Wire.split(column: string): (string, string?)
	local name, kind = column:match("^([%w_]+):([%w_]+)$")
	if name then
		return name, kind
	end
	return column, nil
end

function Wire.sizeOf(kind: string, value: any): number
	if kind == "string" then
		return 2 + #(value :: string)
	end
	return size[kind]
end

function Wire.known(kind: string): boolean
	return write[kind] ~= nil or kind == "kind"
end

Wire.write = write
Wire.read = read

return Wire
