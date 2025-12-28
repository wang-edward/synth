const std = @import("std");

pub fn Params(comptime T: type) type {
    const fields = std.meta.fields(T);
    var atomic_fields: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |f, i| {
        atomic_fields[i] = .{
            .name = f.name,
            .type = std.atomic.Value(f.type),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(std.atomic.Value(f.type)),
        };
    }
    const AtomicStorage = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &atomic_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
    return struct {
        const Self = @This();

        storage: AtomicStorage,

        fn FieldType(comptime field: std.meta.FieldEnum(T)) type {
            return std.meta.fields(T)[@intFromEnum(field)].type;
        }

        // default values from T
        pub fn init(defaults: T) Self {
            var storage: AtomicStorage = undefined;
            inline for (fields) |f| {
                @field(storage, f.name) = std.atomic.Value(f.type).init(@field(defaults, f.name));
            }
            return .{ .storage = storage };
        }

        pub fn set(self: *Self, comptime field: std.meta.FieldEnum(T), value: FieldType(field)) void {
            @field(self.storage, @tagName(field)).store(value, .release);
        }

        pub fn get(self: *Self, comptime field: std.meta.FieldEnum(T)) FieldType(field) {
            return @field(self.storage, @tagName(field)).load(.acquire);
        }

        pub fn snapshot(self: *Self) T {
            var result: T = undefined;
            inline for (fields) |f| {
                @field(result, f.name) = @field(self.storage, f.name).load(.acquire);
            }
            return result;
        }
    };
}
