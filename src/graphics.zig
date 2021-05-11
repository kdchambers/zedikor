// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const geometry = @import("geometry.zig");
const ScaleFactor2D = geometry.ScaleFactor2D;

// TODO: Should not be FaceQuad? To namespace sub types under 'Face'
pub fn TriFace(comptime VertexType: type) type {
    return [3]VertexType;
}
pub fn QuadFace(comptime VertexType: type) type {
    return [4]VertexType;
}

pub fn RGBA(comptime BaseType: type) type {
    return packed struct {
        r: BaseType,
        g: BaseType,
        b: BaseType,
        a: BaseType,
    };
}

pub inline fn generateTexturedQuad(comptime VertexType: type, placement: geometry.Coordinates2D(.ndc_right), dimensions: geometry.Dimensions2D(.ndc_right), texture_extent: geometry.Extent2D(.normalized)) QuadFace(VertexType) {
    return [_]VertexType{
        .{
            // Top Left
            .x = placement.x,
            .y = placement.y - dimensions.height,
            .tx = texture_extent.x,
            .ty = texture_extent.y,
        },
        .{
            // Top Right
            .x = placement.x + dimensions.width,
            .y = placement.y - dimensions.height,
            .tx = texture_extent.x + texture_extent.width,
            .ty = texture_extent.y,
        },
        .{
            // Bottom Right
            .x = placement.x + dimensions.width,
            .y = placement.y,
            .tx = texture_extent.x + texture_extent.width,
            .ty = texture_extent.y + texture_extent.height,
        },
        .{
            // Bottom Left
            .x = placement.x,
            .y = placement.y,
            .tx = texture_extent.x,
            .ty = texture_extent.y + texture_extent.height,
        },
    };
}
