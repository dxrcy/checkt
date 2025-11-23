const std = @import("std");
const builtin = std.builtin;
const Io = std.Io;
const math = std.math;

const ENDIAN = builtin.Endian.big;

pub const SerError =
    Io.Writer.Error;
pub const DeError =
    Io.Reader.Error ||
    error{Malformed};

pub fn serialize(comptime T: type, value: *const T, writer: *Io.Writer) SerError!void {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {
            if (@hasDecl(T, "serialize")) {
                const func = switch (@typeInfo(@TypeOf(T.serialize))) {
                    .@"fn" => |func| func,
                    else => @compileError("custom `serialize` declaration for type `" ++ @typeName(T) ++ "` in not a function"),
                };
                if (func.params[0].type != *const T or
                    func.params[1].type != *Io.Writer or
                    func.return_type != SerError!void)
                {
                    @compileError("custom `serialize` function for type `" ++ @typeName(T) ++ "` does not have correct signature");
                }

                try value.serialize(writer);
                return;
            }
        },

        else => {},
    }

    switch (@typeInfo(T)) {
        .int => {
            comptime std.debug.assert(!std.mem.eql(u8, @typeName(T), "usize"));
            try writer.writeInt(resizeIntToBytes(T), value.*, ENDIAN);
        },

        .@"enum" => {
            const int = @intFromEnum(value.*);
            try serialize(@TypeOf(int), &int, writer);
        },

        .optional => |optional| {
            if (value.*) |value_child| {
                try serialize(u8, &1, writer);
                try serialize(optional.child, &value_child, writer);
            } else {
                try serialize(u8, &0, writer);
            }
        },

        .@"struct" => |strct| {
            inline for (strct.fields) |field| {
                const field_value = @field(value, field.name);
                try serialize(@TypeOf(field_value), &field_value, writer);
            }
        },

        .@"union" => |unn| {
            const tag_type = unn.tag_type orelse {
                @compileError("serialization is not supported for type untagged unions");
            };
            const tag = @as(tag_type, value.*);
            try serialize(tag_type, &tag, writer);

            inline for (unn.fields, 0..) |field, i| {
                if (i == @intFromEnum(tag)) {
                    const field_value = @field(value, field.name);
                    try serialize(field.type, &field_value, writer);
                    return;
                }
            }
            unreachable;
        },

        else => @compileError("serialization is not supported for type `" ++ @typeName(T) ++ "`"),
    }
}

pub fn deserialize(comptime T: type, reader: *Io.Reader) DeError!T {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {
            if (@hasDecl(T, "deserialize")) {
                const func = switch (@typeInfo(@TypeOf(T.deserialize))) {
                    .@"fn" => |func| func,
                    else => @compileError("custom `deserialize` declaration for type `" ++ @typeName(T) ++ "` in not a function"),
                };
                if (func.params[0].type != *Io.Reader or
                    func.return_type != DeError!T)
                {
                    @compileError("custom `deserialize` function for type `" ++ @typeName(T) ++ "` does not have correct signature");
                }

                return try T.deserialize(reader);
            }
        },

        else => {},
    }

    switch (@typeInfo(T)) {
        .int => {
            comptime std.debug.assert(!std.mem.eql(u8, @typeName(T), "usize"));
            const padded = try reader.takeInt(resizeIntToBytes(T), ENDIAN);
            return math.cast(T, padded) orelse {
                return error.Malformed;
            };
        },

        .@"enum" => |enm| {
            const int = try deserialize(enm.tag_type, reader);
            return std.meta.intToEnum(T, int) catch {
                return error.Malformed;
            };
        },

        .optional => |optional| {
            const discriminant = try deserialize(u8, reader);
            if (discriminant == 1) {
                const child_value = try deserialize(optional.child, reader);
                return child_value;
            } else if (discriminant == 0) {
                return null;
            } else {
                return error.Malformed;
            }
        },

        .@"struct" => |strct| {
            var value: T = undefined;
            inline for (strct.fields) |field| {
                const field_value = try deserialize(field.type, reader);
                @field(value, field.name) = field_value;
            }
            return value;
        },

        .@"union" => |unn| {
            const tag_type = unn.tag_type orelse {
                @compileError("serialization is not supported for untagged unions");
            };
            const tag = try deserialize(tag_type, reader);

            inline for (unn.fields, 0..) |field, i| {
                if (i == @intFromEnum(tag)) {
                    const field_value = try deserialize(field.type, reader);
                    const value: T = @unionInit(T, field.name, field_value);
                    return value;
                }
            }
            return error.Malformed; // Invalid tag
        },

        else => @compileError("deserialization is not supported for type `" ++ @typeName(T) ++ "`"),
    }
}

fn resizeIntToBytes(comptime T: type) type {
    const int = @typeInfo(T).int;
    const bits = 8 * (math.divCeil(u16, int.bits, 8) catch unreachable);
    return @Type(builtin.Type{ .int = .{
        .bits = bits,
        .signedness = int.signedness,
    } });
}

fn getIntOfSize(comptime T: type) type {
    return @Type(builtin.Type{ .int = .{
        .bits = @bitSizeOf(T),
        .signedness = .unsigned,
    } });
}
