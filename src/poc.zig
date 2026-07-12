const std = @import("std");
const packet_plan = @import("packet_plan.zig");

pub const PocError = error{
    InvalidSegment,
    InvalidSchedule,
};

pub const Progression = enum(u8) {
    lrcp = 0,
    rlcp = 1,
    rpcl = 2,
    pcrl = 3,
    cprl = 4,
};

pub const Record = struct {
    resolution_start: u8,
    component_start: u16,
    layer_end: u16,
    resolution_end: u8,
    component_end: u16,
    progression: Progression,
};

pub fn appendSegmentPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    records: []const Record,
    component_count: u16,
    resolution_count: u8,
    layer_count: u16,
) !void {
    if (records.len == 0 or component_count == 0 or resolution_count == 0 or layer_count == 0) {
        return PocError.InvalidSegment;
    }
    const component_bytes: usize = if (component_count <= 256) 1 else 2;
    const record_bytes = 5 + 2 * component_bytes;
    const payload_bytes = std.math.mul(usize, records.len, record_bytes) catch
        return PocError.InvalidSegment;
    // Lpoc includes its own two bytes and is itself a 16-bit field.
    if (payload_bytes > std.math.maxInt(u16) - 2) return PocError.InvalidSegment;

    try out.ensureUnusedCapacity(allocator, payload_bytes);
    for (records) |record| {
        try validateRecord(record, component_count, resolution_count, layer_count);
        out.appendAssumeCapacity(record.resolution_start);
        appendComponentAssumeCapacity(out, record.component_start, component_bytes);
        appendU16BeAssumeCapacity(out, record.layer_end);
        out.appendAssumeCapacity(record.resolution_end);
        appendComponentAssumeCapacity(out, record.component_end, component_bytes);
        out.appendAssumeCapacity(@intFromEnum(record.progression));
    }
}

/// Parses one POC marker payload (without Lpoc). Component indices are one
/// byte when Csiz <= 256 and two bytes otherwise, per ISO A.6.6.
pub fn appendSegment(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    payload: []const u8,
    component_count: u16,
    resolution_count: u8,
    layer_count: u16,
) !void {
    if (component_count == 0 or resolution_count == 0 or layer_count == 0) {
        return PocError.InvalidSegment;
    }
    const component_bytes: usize = if (component_count <= 256) 1 else 2;
    const record_bytes = 5 + 2 * component_bytes;
    if (payload.len == 0 or payload.len % record_bytes != 0) return PocError.InvalidSegment;

    var cursor: usize = 0;
    while (cursor < payload.len) : (cursor += record_bytes) {
        const resolution_start = payload[cursor];
        const component_start = readComponent(payload, cursor + 1, component_bytes);
        const layer_offset = cursor + 1 + component_bytes;
        const layer_end = readU16Be(payload, layer_offset);
        const resolution_end = payload[layer_offset + 2];
        const component_end = readComponent(payload, layer_offset + 3, component_bytes);
        const progression_byte = payload[layer_offset + 3 + component_bytes];
        if (progression_byte > @intFromEnum(Progression.cprl)) return PocError.InvalidSegment;
        const record = Record{
            .resolution_start = resolution_start,
            .component_start = component_start,
            .layer_end = layer_end,
            .resolution_end = resolution_end,
            .component_end = component_end,
            .progression = @enumFromInt(progression_byte),
        };
        try validateRecord(record, component_count, resolution_count, layer_count);
        try records.append(allocator, record);
    }
}

/// Composes the final stream order. Records may overlap; packets sequenced by
/// an earlier record are skipped by later records, exactly as POC requires.
/// Every packet must be covered once by the completed schedule.
pub fn buildSequence(
    allocator: std.mem.Allocator,
    plan: packet_plan.Plan,
    component_count: u16,
    layer_count: u16,
    records: []const Record,
) ![]packet_plan.Packet {
    if (records.len == 0) return PocError.InvalidSchedule;
    const total = std.math.cast(usize, plan.packets) orelse return PocError.InvalidSchedule;
    const output = try allocator.alloc(packet_plan.Packet, total);
    errdefer allocator.free(output);
    const seen = try allocator.alloc(bool, total);
    defer allocator.free(seen);
    @memset(seen, false);

    var output_count: usize = 0;
    for (records) |record| {
        const ordered = try buildProgressionSequence(
            allocator,
            plan,
            component_count,
            layer_count,
            record.progression,
        );
        defer allocator.free(ordered);
        for (ordered) |candidate| {
            if (candidate.resolution < record.resolution_start or candidate.resolution >= record.resolution_end or
                candidate.component < record.component_start or candidate.component >= record.component_end or
                candidate.layer >= record.layer_end)
            {
                continue;
            }
            const identity_u64 = packet_plan.rpclSequenceForPacket(
                plan,
                component_count,
                layer_count,
                candidate,
            ) catch return PocError.InvalidSchedule;
            const identity = std.math.cast(usize, identity_u64) orelse return PocError.InvalidSchedule;
            if (identity >= seen.len or seen[identity]) continue;
            if (output_count >= output.len) return PocError.InvalidSchedule;
            var packet = candidate;
            packet.sequence = output_count;
            output[output_count] = packet;
            output_count += 1;
            seen[identity] = true;
        }
    }
    if (output_count != output.len) return PocError.InvalidSchedule;
    return output;
}

fn buildProgressionSequence(
    allocator: std.mem.Allocator,
    plan: packet_plan.Plan,
    component_count: u16,
    layer_count: u16,
    progression: Progression,
) ![]packet_plan.Packet {
    switch (progression) {
        .pcrl, .cprl => return packet_plan.positionOrderedPackets(
            allocator,
            plan,
            component_count,
            layer_count,
            if (progression == .pcrl) .pcrl else .cprl,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => PocError.InvalidSchedule,
        },
        .rpcl, .lrcp, .rlcp => {},
    }

    const total = std.math.cast(usize, plan.packets) orelse return PocError.InvalidSchedule;
    const packets = try allocator.alloc(packet_plan.Packet, total);
    errdefer allocator.free(packets);
    var count: usize = 0;
    switch (progression) {
        .rpcl => {
            var iterator = packet_plan.RpclIterator.init(plan, component_count, layer_count) catch
                return PocError.InvalidSchedule;
            while (iterator.next()) |packet| : (count += 1) packets[count] = packet;
        },
        .lrcp => {
            var iterator = packet_plan.LrcpIterator.init(plan, component_count, layer_count) catch
                return PocError.InvalidSchedule;
            while (iterator.next()) |packet| : (count += 1) packets[count] = packet;
        },
        .rlcp => {
            var iterator = packet_plan.RlcpIterator.init(plan, component_count, layer_count) catch
                return PocError.InvalidSchedule;
            while (iterator.next()) |packet| : (count += 1) packets[count] = packet;
        },
        else => unreachable,
    }
    if (count != packets.len) return PocError.InvalidSchedule;
    return packets;
}

fn readComponent(bytes: []const u8, offset: usize, count: usize) u16 {
    return if (count == 1) bytes[offset] else readU16Be(bytes, offset);
}

fn validateRecord(record: Record, component_count: u16, resolution_count: u8, layer_count: u16) !void {
    if (record.resolution_start >= record.resolution_end or record.resolution_end > resolution_count or
        record.component_start >= record.component_end or record.component_end > component_count or
        record.layer_end == 0 or record.layer_end > layer_count)
    {
        return PocError.InvalidSegment;
    }
}

fn appendComponentAssumeCapacity(out: *std.ArrayList(u8), component: u16, count: usize) void {
    if (count == 1) {
        out.appendAssumeCapacity(@intCast(component));
    } else {
        appendU16BeAssumeCapacity(out, component);
    }
}

fn appendU16BeAssumeCapacity(out: *std.ArrayList(u8), value: u16) void {
    out.appendAssumeCapacity(@intCast(value >> 8));
    out.appendAssumeCapacity(@intCast(value & 0xff));
}

fn readU16Be(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}
