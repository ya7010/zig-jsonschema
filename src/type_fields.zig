const std = @import("std");

pub const StructField = struct {
    name: []const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,

    pub fn defaultValue(comptime field: @This()) ?field.type {
        const ptr: *const field.type = @ptrCast(@alignCast(field.default_value_ptr orelse return null));
        return ptr.*;
    }
};

pub const UnionField = struct {
    name: []const u8,
    type: type,
};

pub const EnumField = struct {
    name: []const u8,
    value: comptime_int,
};

pub const StructFieldAttributes = std.builtin.Type.Struct.FieldAttributes;

pub inline fn structFields(comptime T: type) []const StructField {
    comptime {
        const info = @typeInfo(T).@"struct";
        var result: [info.field_names.len]StructField = undefined;
        for (0..result.len) |i| {
            result[i] = .{
                .name = info.field_names[i],
                .type = info.field_types[i],
                .default_value_ptr = info.field_attrs[i].default_value_ptr,
            };
        }
        const final = result;
        return &final;
    }
}

pub inline fn unionFields(comptime T: type) []const UnionField {
    comptime {
        const info = @typeInfo(T).@"union";
        var result: [info.field_names.len]UnionField = undefined;
        for (0..result.len) |i| {
            result[i] = .{ .name = info.field_names[i], .type = info.field_types[i] };
        }
        const final = result;
        return &final;
    }
}

pub inline fn enumFields(comptime T: type) []const EnumField {
    comptime {
        const info = @typeInfo(T).@"enum";
        var result: [info.field_names.len]EnumField = undefined;
        for (0..result.len) |i| {
            result[i] = .{ .name = info.field_names[i], .value = info.field_values[i] };
        }
        const final = result;
        return &final;
    }
}
