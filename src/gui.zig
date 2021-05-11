// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const geometry = @import("geometry.zig");
const ScaleFactor2D = geometry.ScaleFactor2D;
const graphics = @import("graphics.zig");
const QuadFace = graphics.QuadFace;
const text = @import("text.zig");
const util = @import("utility.zig");

pub fn generateLineMargin(comptime VertexType: type, allocator: *Allocator, glyph_set: text.GlyphSet, coordinates: geometry.Coordinates2D(.ndc_right), scale_factor: ScaleFactor2D, line_start: u16, line_count: u16, line_height: f32) ![]QuadFace(VertexType) {

    // Loop through lines to calculate how many vertices will be required
    var quads_required_count = blk: {
        var count: u32 = 0;
        var i: u32 = 1;
        while (i <= line_count) : (i += 1) {
            count += util.digitCount(line_start + i);
        }
        break :blk count;
    };

    assert(line_count > 0);
    const chars_wide_count: u32 = util.digitCount(line_start + line_count);

    var vertex_faces = try allocator.alloc(QuadFace(VertexType), quads_required_count);

    var i: u32 = 1;
    var faces_written_count: u32 = 0;
    while (i <= line_count) : (i += 1) {
        const line_number = line_start + i;
        const digit_count = util.digitCount(line_number);

        assert(digit_count < 6);

        var digit_index: u16 = 0;
        // Traverse digits from least to most significant
        while (digit_index < digit_count) : (digit_index += 1) {
            const digit_char: u8 = blk: {
                const divisors = [5]u16{ 1, 10, 100, 1000, 10000 };
                break :blk '0' + @intCast(u8, (line_number / divisors[digit_index]) % 10);
            };

            const glyph_index = blk: {
                for (glyph_set.character_list) |c, x| {
                    if (c == digit_char) {
                        break :blk @intCast(u8, x);
                    }
                }
                return error.CharacterNotInSet;
            };

            const texture_extent = try glyph_set.imageRegionForGlyph(glyph_index);

            const glyph_dimensions = glyph_set.glyph_information[glyph_index].dimensions;
            const base_x_increment = (@intToFloat(f32, glyph_set.glyph_information[glyph_index].advance) / 64.0) * scale_factor.horizontal;

            const x_increment = (base_x_increment * @intToFloat(f32, chars_wide_count - 1 - digit_index));

            const origin: geometry.Coordinates2D(.ndc_right) = .{
                .x = coordinates.x + x_increment,
                .y = coordinates.y + (line_height * @intToFloat(f32, i - 1)),
            };

            const char_extent = geometry.Dimensions2D(.ndc_right){
                .width = @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal,
                .height = @intToFloat(f32, glyph_dimensions.height) * scale_factor.vertical,
            };

            vertex_faces[faces_written_count] = graphics.generateTexturedQuad(VertexType, origin, char_extent, texture_extent);
            for (vertex_faces[faces_written_count]) |*vertex| {
                vertex.color_index = 3;
            }
            faces_written_count += 1;
        }
    }

    return vertex_faces;
}
