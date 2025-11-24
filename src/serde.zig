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
                    @compileError("custom `serialize` method for type `" ++ @typeName(T) ++ "` does not have correct signature");
                }
                if (!@hasDecl(T, "deserialize")) {
                    @compileError(@typeName(T) ++ " has custom `serialize` method with no corresponding `deserialize` method");
                }

                try value.serialize(writer);
                return;
            }
        },

        else => {},
    }

    switch (@typeInfo(T)) {
        .void => {},

        .int => {
            try writer.writeInt(
                byteAlignedInt(fixedSizeInt(T)),
                @intCast(value.*),
                ENDIAN,
            );
        },

        .bool => {
            const int = @intFromBool(value.*);
            try serialize(@TypeOf(int), &int, writer);
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
                    @compileError("custom `deserialize` method for type `" ++ @typeName(T) ++ "` does not have correct signature");
                }
                if (!@hasDecl(T, "serialize")) {
                    @compileError(@typeName(T) ++ " has custom `deserialize` method with no corresponding `serialize` method");
                }

                return try T.deserialize(reader);
            }
        },

        else => {},
    }

    switch (@typeInfo(T)) {
        .void => return,

        .int => {
            const padded: fixedSizeInt(T) = @intCast(try reader.takeInt(
                byteAlignedInt(fixedSizeInt(T)),
                ENDIAN,
            ));
            return math.cast(T, padded) orelse {
                return error.Malformed;
            };
        },

        .bool => {
            // Invalid `u1` handled when casting from byte
            const int = try deserialize(@TypeOf(@intFromBool(true)), reader);
            return switch (int) {
                0 => false,
                1 => true,
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
                @compileError("deserialization is not supported for untagged unions");
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

fn fixedSizeInt(comptime T: type) type {
    return switch (T) {
        usize => u64,
        isize => i64,
        else => T,
    };
}

fn byteAlignedInt(comptime T: type) type {
    const int = @typeInfo(T).int;
    const bits = 8 * (math.divCeil(u16, int.bits, 8) catch unreachable);
    return @Type(builtin.Type{ .int = .{
        .bits = bits,
        .signedness = int.signedness,
    } });
}

fn intOfSize(comptime T: type) type {
    return @Type(builtin.Type{ .int = .{
        .bits = @bitSizeOf(T),
        .signedness = .unsigned,
    } });
}
