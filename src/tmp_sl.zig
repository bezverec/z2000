const std = @import("std");
const codestream = @import("codestream.zig");
const color = @import("color.zig");
test "emit 3-layer sampled" {
    const allocator = std.testing.allocator;
    var planes = try color.SamplePlanes.initWithComponentLayouts(allocator, 32, 32, &.{8,8,8}, &.{32,16,16}, &.{32,16,16});
    defer planes.deinit();
    for (planes.planes[0], 0..) |*s,i| s.* = @intCast((7+i*3)&0xff);
    for (planes.planes[1], 0..) |*s,i| s.* = @intCast((40+i*5)&0xff);
    for (planes.planes[2], 0..) |*s,i| s.* = @intCast((200+i*249)&0xff);
    const sampling = [_]codestream.ComponentSampling{.{.xrsiz=1,.yrsiz=1},.{.xrsiz=2,.yrsiz=2},.{.xrsiz=2,.yrsiz=2}};
    const enc = try codestream.encodeLosslessSampledPlanarWithOptions(allocator, planes, &sampling, .{.levels=2,.mct=.none,.layers=3,.block_width=8,.block_height=8,.tile_part_divisions=null});
    defer allocator.free(enc);
    std.debug.print("HEXSTART\n", .{});
    for (enc) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\nHEXEND\n", .{});
}
