

pub fn writeText1(glyph_set: GlyphSet, placement: geometry.Coordinates2D(.ndc_right), screen_dimensions: geometry.Dimensions2D(.pixel), text: []const u8, mesh: *Mesh) !void {

    if(text.len == 0) return;

    if (mesh.remainingSpace() < text.len) {
        return error.InsuffientSpaceInMesh;
    }

    const scale_factor = ScaleFactor2D {
        .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
        .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
    };

    // TODO: Don't hardcode line height to XX pixels
    const line_height = 18.0 * (2.0 / @intToFloat(f32, screen_dimensions.height));

    var fixed_buffer_allocator = FixedBufferAllocator{
        .allocator = .{
            .allocFn = FixedBufferAllocator.alloc,
            .resizeFn = FixedBufferAllocator.resize,
        },
        .buffer = @ptrCast([*]u8, &mesh.vertices[mesh.count * 4]),
        .capacity = @intCast(u32, (mesh.vertices.len - (mesh.count * 4)) * @sizeOf(TextureVertex)),
        .used = 0,
    };

    var mesh_allocator = &fixed_buffer_allocator.allocator;

    // var vertices = mesh.*.vertices;
    var indices = mesh.*.indices;
    const vertices_count = mesh.*.count * 4;
    const indices_count = mesh.*.count * 6;

    var vertices = try mesh_allocator.alloc(TextureVertex, text.len * 4);

    var cursor: geometry.Coordinates2D(.carthesian) = .{
        .x = 0,
        .y = 0,
    };

    var keyword_match_length: u32 = 0;
    var color_index: u32 = 0;
    var skipped_count: u32 = 0;
    var i: u32 = 0;

    for (text) |char, text_i| {
        if (char == ' ') {
            cursor.x += 1;
            skipped_count += 1;
            continue;
        }

        if(char == '\n') {
            cursor.x = 0;
            cursor.y += 1;
            skipped_count += 1;
            continue;
        }

        //
        // Apply syntax highlight on match
        //
        color_index = outer: {
            if (keyword_match_length > 0 or text.len < 6) {
                break :outer color_index;
            }

            for (keyword_list) |keyword, keyword_i| {
                const is_match = blk: {

                    if(keyword.len > (text.len - text_i)) break :blk false;

                    for (keyword) |keyword_char, keyword_char_i| {
                        if(keyword_char != text[text_i + keyword_char_i]) {
                            break :blk false;
                        }
                    }

                    // TODO: Hardcoded
                    keyword_match_length = 6;
                    break :blk true;
                };

                if(is_match) break :outer @enumToInt(keyword_list_colors[keyword_i]);
            }

            break :outer 0;
        };

        const glyph_index = blk: {
            for (glyph_set.character_list) |c, x| {
                if (c == char) {
                    break :blk x;
                }
            }

            return error.CharacterNotInSet;
        };

        const x_increment = (@intToFloat(f32, glyph_set.glyph_information[glyph_index].advance) / 64.0) * scale_factor.horizontal;
        const texture_extent = try glyph_set.imageRegionForGlyph(char);

        // warn("Texture extent: coords ({d},{d}) dimensions ({d}x{d})\n", .{texture_extent.x, texture_extent.y, texture_extent.width, texture_extent.height});

        const glyph_dimensions = glyph_set.glyph_information[glyph_index].dimensions;

        // Positive offset (Glyphs with a descent get shift down)
        const y_offset = (@intToFloat(f32, glyph_set.glyph_information[glyph_index].vertical_offset) / 64) * scale_factor.vertical;

        const height = @intToFloat(f32, glyph_dimensions.height) * scale_factor.vertical;
        const width = @intToFloat(f32, glyph_dimensions.width) * scale_factor.horizontal;
        const text_left_margin = 10 * (2.0 / @intToFloat(f32, screen_dimensions.width));

        vertices[i * 4 + 0] = TextureVertex{
            // Top Left
            .x = placement.x + text_left_margin + (x_increment * @intToFloat(f32, cursor.x)),
            .y = placement.y - height + y_offset + (line_height * @intToFloat(f32, cursor.y)),
            .tx = @floatCast(f32, texture_extent.x),
            .ty = @floatCast(f32, texture_extent.y),
            .color_index = color_index,
        };

        vertices[i * 4 + 1] = TextureVertex{
            // Top Right
            .x = placement.x + text_left_margin + width + (x_increment * @intToFloat(f32, cursor.x)),
            .y = placement.y - height + y_offset + (line_height * @intToFloat(f32, cursor.y)),
            .tx = @floatCast(f32, texture_extent.x) + @floatCast(f32, texture_extent.width),
            .ty = @floatCast(f32, texture_extent.y),
            .color_index = color_index,
        };

        vertices[i * 4 + 2] = TextureVertex{
            // Bottom Right
            .x = placement.x + text_left_margin + width + (x_increment * @intToFloat(f32, cursor.x)),
            .y = placement.y + y_offset + (line_height * @intToFloat(f32, cursor.y)),
            .tx = @floatCast(f32, texture_extent.x) + @floatCast(f32, texture_extent.width),
            .ty = @floatCast(f32, texture_extent.y) + @floatCast(f32, texture_extent.height),
            .color_index = color_index,
        };

        vertices[i * 4 + 3] = TextureVertex{
            // Bottom Left
            .x = placement.x + text_left_margin + (x_increment * @intToFloat(f32, cursor.x)),
            .y = placement.y + y_offset + (line_height * @intToFloat(f32, cursor.y)),
            .tx = @floatCast(f32, texture_extent.x),
            .ty = @floatCast(f32, texture_extent.y) + @floatCast(f32, texture_extent.height),
            .color_index = color_index,
        };

        indices[mesh.count * 6 + 0] = @intCast(u16, mesh.count * 4) + 0; // TL
        indices[mesh.count * 6 + 1] = @intCast(u16, mesh.count * 4) + 1; // TR
        indices[mesh.count * 6 + 2] = @intCast(u16, mesh.count * 4) + 2; // BR

        indices[mesh.count * 6 + 3] = @intCast(u16, mesh.count * 4) + 0; // TL
        indices[mesh.count * 6 + 4] = @intCast(u16, mesh.count * 4) + 2; // BR
        indices[mesh.count * 6 + 5] = @intCast(u16, mesh.count * 4) + 3; // BL

        mesh.count += 1;
        cursor.x += 1;
        i += 1;

        if(keyword_match_length > 0) keyword_match_length -= 1;
    }
    // _ = try mesh_allocator.realloc(vertices, vertices.len - (skipped_count * 4));
}

fn drawLines() !void {
    // Draw the line numbers
    var i: u32 = 1;
    // TODO: Support multi-digit numbers
    while(i <= line_count) : (i += 1) {

        const line_number = line_start + i;

        const digit_count: u16 = blk: {
            var count: u16 = 1;
            var divisor: u16 = 10;
            while((line_number / divisor) >= 1) : (count += 1) {
                divisor *= 10;
            }
            break :blk count;
        };

        assert(digit_count <= chars_wide_count);
        assert(digit_count < 6);

        var digit_index: u16 = 0;
        // Traverse digits from least to most significant
        while(digit_index < digit_count) : (digit_index += 1) {

            const digit_char: u8 = blk: {
                const divisors = [5]u16 {1, 10, 100, 1000, 10000};
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

            const texture_extent = try glyph_set.imageRegionForGlyph(digit_char);

            const origin: geometry.Coordinates2D(.ndc_right) = .{
                .x = coordinates.x,
                .y = coordinates.y + (line_height * @intToFloat(f32, i - 1)),
            };

            const glyph_dimensions = glyph_set.glyph_information[glyph_index].dimensions;

            const height = @intToFloat(f32, glyph_dimensions.height) * y_scale;
            const width = @intToFloat(f32, glyph_dimensions.width) * x_scale;

            assert(digit_index < chars_wide_count);

            const x_increment = (base_x_increment * @intToFloat(f32, chars_wide_count - 1 - digit_index));

            vertices[mesh.count * 4 + 0] = TextureVertex{
                // Top Left
                .x = origin.x + x_increment,
                .y = origin.y - height,
                .tx = @floatCast(f32, texture_extent.x),
                .ty = @floatCast(f32, texture_extent.y),
                .color_index = 3,
            };

            vertices[mesh.count * 4 + 1] = TextureVertex{
                // Top Right
                .x = origin.x + x_increment + width,
                .y = origin.y - height,
                .tx = @floatCast(f32, texture_extent.x) + @floatCast(f32, texture_extent.width),
                .ty = @floatCast(f32, texture_extent.y),
                .color_index = 3,
            };

            vertices[mesh.count * 4 + 2] = TextureVertex{
                // Bottom Right
                .x = origin.x + x_increment + width,
                .y = origin.y,
                .tx = @floatCast(f32, texture_extent.x) + @floatCast(f32, texture_extent.width),
                .ty = @floatCast(f32, texture_extent.y) + @floatCast(f32, texture_extent.height),
                .color_index = 3,
            };

            vertices[mesh.count * 4 + 3] = TextureVertex{
                // Bottom Left
                .x = origin.x + x_increment,
                .y = origin.y,
                .tx = @floatCast(f32, texture_extent.x),
                .ty = @floatCast(f32, texture_extent.y) + @floatCast(f32, texture_extent.height),
                .color_index = 3,
            };

            mesh.count += 1;
        }
    }
}

fn FixedCircularBuffer(comptime BaseType: type, comptime capacity: u32) type {
    return struct {
        head: u16,
        length: u16,
        buffer: [capacity]BaseType,

        Self = @This();

        pub fn append(self: *Self, value: BaseType) !void {
            if(self.length == capacity) return error.IsFull;

            const tail_index = (self.head + self.length) % capacity;
            self.buffer[tail_index] = value;
            self.length += 1;
        }

        pub fn prepend(self: *Self, value: BaseType) !void {
            if(self.length == capacity) return error.IsFull;

            self.head = if(self.head == 0) capacity - 1 else self.head - 1;
            self.buffer[self.head] == value;
            self.length += 1;
        }

        pub fn popHead(self: *Self) !void {
            if(self.length == 0) return error.IsEmpty;
            self.head = if(self.head == capacity - 1) 0 else self.head + 1;
            length -= 1;
        }

        pub fn popTail(self: *Self) !void {
            if(self.length == 0) return error.IsEmpty;
            length -= 1;
        }
    };
}

pub fn writeTextEditor(
    face_allocator: *Allocator,
    glyph_set: GlyphSet,
    coordinates: geometry.Coordinates2D(.ndc_right),
    scale_factor: ScaleFactor2D,
    line_start: u16,
    line_count: u16,
    cursor_position:
    geometry.Coordinates2D(.carthesian),
    text: []const u8
) ![]QuadFace(TextureVertex) {

    // The number of characters / digits needed for the largest number in the
    // left-hand side margin
    const line_margin_digit_count = digitCount(line_start + line_count);
    assert(line_margin_digit_count > 0);

    // Margin from line count to editor text area
    const left_margin: f32 = 10.0 * scale_factor.horizontal;
    // Generic x increment between characters
    const base_x_increment = 10.0 * scale_factor.horizontal;

    const placement: geometry.Coordinates2D(.ndc_right) = .{
        .x = coordinates.x + left_margin + (@intToFloat(f32, line_margin_digit_count) * base_x_increment),
        .y = coordinates.y
    };

    return try writeText(face_allocator, glyph_set, placement, scale_factor, text);
}