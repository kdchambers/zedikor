// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");

const warn = std.debug.warn;
const info = std.debug.warn;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const zvk = @import("vulkan_wrapper.zig");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");

const Mesh = graphics.Mesh;
const RGBA = graphics.RGBA;
const ScaleFactor2D = geometry.ScaleFactor2D;
const QuadFace = graphics.QuadFace;

const utility = @import("utility.zig");
const digitCount = utility.digitCount;

pub const ft = @cImport({
    @cInclude("freetype2/ft2build.h");
    @cDefine("FT_FREETYPE_H", {});
    @cInclude("freetype2/freetype/freetype.h");
});

pub const TextureVertex = packed struct {
    x: f32,
    y: f32,
    tx: f32,
    ty: f32,
    color_index: u32 = 0,
};

pub const GlyphMeta = packed struct {
    advance: u16,
    vertical_offset: i16,
    dimensions: geometry.Dimensions2D(.pixel16),
};

// TODO: Sort characters and use binary search
pub const GlyphSet = struct {
    // TODO:
    // Once the image is created and sent to the GPU, it's no longer needed
    // Therefore, create a generateBitmapImage function instead of storing it here
    image: []u8,
    character_list: []u8,
    glyph_information: []GlyphMeta,
    cells_per_row: u8,
    cell_width: u16,
    cell_height: u16,

    // TODO: Rename
    pub fn cellRowCount(self: GlyphSet) u32 {
        return self.cells_per_row;
    }

    pub fn cellColumnsCount(self: GlyphSet) u32 {
        return blk: {
            if (@mod(self.character_list.len, self.cells_per_row) == 0) {
                break :blk self.cells_per_row * @intCast(u32, (self.character_list.len / self.cells_per_row));
            } else {
                break :blk self.cells_per_row * @intCast(u32, ((self.character_list.len / self.cells_per_row) + 1));
            }
        };
    }

    pub fn width(self: GlyphSet) u32 {
        return self.cells_per_row * self.cell_width;
    }

    pub fn height(self: GlyphSet) u32 {
        return blk: {
            if (@mod(self.character_list.len, self.cells_per_row) == 0) {
                break :blk @intCast(u32, ((self.character_list.len / (self.cells_per_row + 1)) + 1)) * @intCast(u32, self.cell_height);
            } else {
                break :blk @intCast(u32, ((self.character_list.len / (self.cells_per_row)) + 1)) * @intCast(u32, self.cell_height);
            }
        };
    }

    pub fn imageRegionForGlyph(self: GlyphSet, char_index: usize) !geometry.Extent2D(.normalized) {
        if (char_index >= self.character_list.len) return error.InvalidIndex;
        return geometry.Extent2D(.normalized){
            .width = @intToFloat(f32, self.glyph_information[char_index].dimensions.width) / @intToFloat(f32, self.width()),
            .height = @intToFloat(f32, self.glyph_information[char_index].dimensions.height) / @intToFloat(f32, self.height()),
            .x = @intToFloat(f32, (char_index % self.cells_per_row) * self.cell_width) / @intToFloat(f32, self.width()),
            .y = @intToFloat(f32, (char_index / self.cells_per_row) * self.cell_height) / @intToFloat(f32, self.height()),
        };
    }
};

// TODO: Separate image generation to own function
pub fn createGlyphSet(allocator: *Allocator, face: ft.FT_Face, character_list: []const u8) !GlyphSet {
    var glyph_set: GlyphSet = undefined;

    glyph_set.character_list = try allocator.alloc(u8, character_list.len);
    for (character_list) |char, i| {
        glyph_set.character_list[i] = char;
    }

    glyph_set.glyph_information = try allocator.alloc(GlyphMeta, character_list.len);
    glyph_set.cells_per_row = @floatToInt(u8, @sqrt(@intToFloat(f64, character_list.len)));

    var max_width: u32 = 0;
    var max_height: u32 = 0;

    // In order to not waste space on our texture, we loop through each glyph and find the largest dimensions required
    // We then use the largest width and height to form the cell size that each glyph will be put into
    for (character_list) |char, i| {
        if (ft.FT_Load_Char(face, char, ft.FT_LOAD_RENDER) != ft.FT_Err_Ok) {
            warn("Failed to load char {}\n", .{char});
            return error.LoadFreeTypeCharFailed;
        }

        const width = face.*.glyph.*.bitmap.width;
        const height = face.*.glyph.*.bitmap.rows;
        if (width > max_width) max_width = width;
        if (height > max_height) max_height = height;

        // Also, we can extract additional glyph information
        glyph_set.glyph_information[i].vertical_offset = @intCast(i16, face.*.glyph.*.metrics.height - face.*.glyph.*.metrics.horiBearingY);
        glyph_set.glyph_information[i].advance = @intCast(u16, face.*.glyph.*.metrics.horiAdvance);

        glyph_set.glyph_information[i].dimensions = .{
            .width = @intCast(u16, @divTrunc(face.*.glyph.*.metrics.width, 64)),
            .height = @intCast(u16, @divTrunc(face.*.glyph.*.metrics.height, 64)),
        };
    }

    // The glyph texture is divided into fixed size cells. However, there may not be enough characters
    // to completely fill the rectangle.
    // Therefore, we need to compute required_cells_count to allocate enough space for the full texture
    const required_cells_count = glyph_set.cellColumnsCount();

    glyph_set.image = try allocator.alloc(u8, required_cells_count * max_height * max_width);
    errdefer allocator.free(glyph_set.image);

    var i: u32 = 0;
    while (i < required_cells_count) : (i += 1) {
        const cell_position = geometry.Coordinates2D(.carthesian){
            .x = @mod(i, glyph_set.cells_per_row),
            .y = (i * max_width) / (max_width * glyph_set.cells_per_row),
        };

        // Trailing cells (Once we've rasterized all our characters) filled in as transparent pixels
        if (i >= character_list.len) {
            var x: u32 = 0;
            var y: u32 = 0;
            while (y < max_height) : (y += 1) {
                while (x < max_width) : (x += 1) {
                    const texture_position = geometry.Coordinates2D(.pixel){
                        .x = cell_position.x * max_width + x,
                        .y = cell_position.y * max_height + y,
                    };

                    const pixel_index: usize = texture_position.y * (max_width * glyph_set.cells_per_row) + texture_position.x;
                    glyph_set.image[pixel_index] = 0;
                }
                x = 0;
            }
            continue;
        }

        if (ft.FT_Load_Char(face, character_list[i], ft.FT_LOAD_RENDER) != ft.FT_Err_Ok) {
            warn("Failed to load char {}\n", .{character_list[i]});
            return error.LoadFreeTypeCharFailed;
        }

        const width = face.*.glyph.*.bitmap.width;
        const height = face.*.glyph.*.bitmap.rows;

        // Buffer is 8-bit pixel greyscale
        // Will need to be converted into RGBA, etc
        const buffer = @ptrCast([*]u8, face.*.glyph.*.bitmap.buffer);

        assert(width <= max_width);
        assert(width > 0);
        assert(height <= max_height);
        assert(height > 0);

        var x: u32 = 0;
        var y: u32 = 0;
        var texture_index: u32 = 0;

        while (y < max_height) : (y += 1) {
            while (x < max_width) : (x += 1) {
                const background_pixel = (y >= height or x >= width);
                const texture_position = geometry.Coordinates2D(.pixel){
                    .x = cell_position.x * max_width + x,
                    .y = cell_position.y * max_height + y,
                };

                const pixel_index: usize = texture_position.y * (max_width * glyph_set.cells_per_row) + texture_position.x;
                if (!background_pixel) {
                    glyph_set.image[pixel_index] = buffer[texture_index];
                    assert(texture_index < (height * width));
                    texture_index += 1;
                } else {
                    glyph_set.image[pixel_index] = 0;
                }
            }
            x = 0;
        }
    }

    glyph_set.cell_height = @intCast(u16, max_height);
    glyph_set.cell_width = @intCast(u16, max_width);

    return glyph_set;
}

pub fn generateText(comptime VertexType: type, face_allocator: *Allocator, text: []const u8, origin: geometry.Coordinates2D(.ndc_right), line_height: f32, scale_factor: ScaleFactor2D, glyph_set: GlyphSet) ![]QuadFace(VertexType) {
    var vertices = try face_allocator.alloc(QuadFace(VertexType), text.len);
    var cursor = geometry.Coordinates2D(.carthesian){ .x = 0, .y = 0 };
    var skipped_count: u32 = 0;

    for (text) |char, i| {
        if (char == '\n') {
            cursor.y += 1;
            cursor.x = 0;
            skipped_count += 1;
            continue;
        }

        if (char != ' ') {
            const glyph_index = blk: {
                for (glyph_set.character_list) |c, x| {
                    if (c == char) {
                        break :blk x;
                    }
                }
                return error.CharacterNotInSet;
            };

            const x_increment = (@intToFloat(f32, glyph_set.glyph_information[glyph_index].advance) / 64.0) * scale_factor.horizontal;
            const texture_extent = try glyph_set.imageRegionForGlyph(glyph_index);
            const glyph_dimensions = glyph_set.glyph_information[glyph_index].dimensions;

            // Positive offset (Glyphs with a descent get shift down)
            const y_offset = (@intToFloat(f32, glyph_set.glyph_information[glyph_index].vertical_offset) / 64) * scale_factor.vertical;

            const placement = geometry.Coordinates2D(.ndc_right){
                .x = origin.x + (x_increment * @intToFloat(f32, cursor.x)),
                .y = origin.y + y_offset + (line_height * @intToFloat(f32, cursor.y)),
            };

            const char_extent = geometry.Dimensions2D(.ndc_right){
                .width = @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal,
                .height = @intToFloat(f32, glyph_dimensions.height) * scale_factor.vertical,
            };

            vertices[i - skipped_count] = graphics.generateTexturedQuad(VertexType, placement, char_extent, texture_extent);
        } else {
            skipped_count += 1;
        }

        cursor.x += 1;
    }

    // Return length not used -- I.e whitespace
    return try face_allocator.realloc(vertices, vertices.len - skipped_count);
}

pub fn writeText(face_allocator: *Allocator, glyph_set: GlyphSet, placement: geometry.Coordinates2D(.ndc_right), scale_factor: ScaleFactor2D, text: []const u8) ![]QuadFace(TextureVertex) {
    // TODO: Don't hardcode line height to XX pixels
    const line_height = 18.0 * scale_factor.vertical;
    return try generateText(TextureVertex, face_allocator, text, placement, line_height, scale_factor, glyph_set);
}
