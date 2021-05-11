// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

// TODO
// Implement new line                       [done]
// Implement tab                            [done]
// Render line numbers                      [done]
//      Multi-digit lines                   [done]
//      FIX: fix text widget alignment      [done]
// Fix double quotes rendering              [done]
// Fix number margin alignment              [done]
// --help message                           [done]
// Disable shortcut commands when typing    [done]
// Update cursor only
// Add font path as cli option
// Audit function names
// Audit memory allocations
// Audit error code names
// Separate glfw + vulkan definitions
// Save file                                [done]
// Load file                                [done]
// Dynamic viewport                         [done]
// Partial update
// Independent cursor movement              [done]
// Wrap lines
// Auto expand memory buffers
// Modes, Commands E.g (":w <file-name>")   [done]
// Add cursor                               [done]
//      FIX: Cursor not resetting x         [done]
//      FIX: Cursor drifting on y           [done]
// Setup benchmark
// Syntax colouring

const std = @import("std");
const c = std.c;
const os = std.os;
const fs = std.fs;
const fmt = std.fmt;
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ft = text.ft;
const vk = @import("vulkan");
const glfw = vk.glfw;

const text = @import("text.zig");
const gui = @import("gui");
const zvk = @import("vulkan_wrapper.zig");
const TexturePipeline = @import("pipelines/texture.zig").TexturePipeline;
const geometry = @import("geometry");
const graphics = @import("graphics.zig");
const Mesh = graphics.Mesh;
const TextureVertex = text.TextureVertex;
const TextCursor = @import("text_cursor.zig").TextCursor;
const QuadFace = graphics.QuadFace;

const utility = @import("utility.zig");
const digitCount = utility.digitCount;
const lineRange = utility.lineRange;
const reverseLength = utility.reverseLength;
const strlen = utility.strlen;
const sliceShiftLeft = utility.sliceShiftLeft;
const sliceShiftRight = utility.sliceShiftRight;

var is_render_requested: bool = false;

// Build User Configuration
const BuildConfig = struct {
    // zig fmt: off
    comptime app_name: [:0]const u8 = "zedikor",
    comptime font_size: u16 = 16,
    comptime font_path: [:0]const u8 = "/usr/share/fonts/TTF/Hack-Regular.ttf",
    comptime window_dimensions: geometry.Dimensions2D(.pixel) = .{
        .width = 800,
        .height = 600,
    }
    // zig fmt: on
};

const config: BuildConfig = .{};

// Types
const GraphicsContext = struct {
    window: *vk.GLFWwindow,
    vk_instance: vk.Instance,
    surface: vk.SurfaceKHR,
    surface_format: vk.SurfaceFormatKHR,
    physical_device: vk.PhysicalDevice,
    logical_device: vk.Device,
    graphics_present_queue: vk.Queue, // Same queue used for graphics + presenting
    graphics_present_queue_index: u32,
    swapchain: vk.SwapchainKHR,
    swapchain_extent: vk.Extent2D,
    swapchain_image_format: vk.Format,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,
    command_pool: vk.CommandPool,
    command_buffers: []vk.CommandBuffer,
    images_available: []vk.Semaphore,
    renders_finished: []vk.Semaphore,
    inflight_fences: []vk.Fence,
};

const ViewExtent = packed struct {
    line_top_index: u32,
    line_count: u32,
};

const EditorContext = struct {
    source_path: ?[]const u8,
    is_write_file_requested: bool,
    is_text_buffer_modified: bool,
    is_synced_with_source: bool,
    is_command_ongoing: bool,
    cursor_position: geometry.Coordinates2D(.carthesian),
    cursor_buffer_index: u32,
    view_extent: ViewExtent,
};

var editor_context: EditorContext = .{
    .source_path = null,
    .is_write_file_requested = false,
    .is_text_buffer_modified = false,
    .is_synced_with_source = false,
    .is_command_ongoing = false,
    .cursor_position = .{ .x = 0, .y = 0 },
    .cursor_buffer_index = 0,
    .view_extent = .{ .line_top_index = 0, .line_count = 1 },
};

const editor_commands = struct {
    pub fn write(file_name: []const u8) !void {
        log.info("writing to '{s}'", .{file_name});

        editor_context.source_path = file_name;

        const current_directory = fs.cwd();
        var file = try current_directory.createFile(file_name, .{ .read = true });
        _ = try file.writeAll(text_buffer[0..text_buffer_length]);
        file.close();

        editor_context.is_write_file_requested = false;
        editor_context.is_synced_with_source = true;
    }

    pub fn quit() noreturn {
        os.exit(0);
    }

    pub fn cursorVerticallyCenter() void {
        if (text_cursor.coordinates.y > (lines_per_view / 2)) {
            editor_context.view_extent.line_top_index = text_cursor.coordinates.y - (lines_per_view / 2);
            text_buffer_dirty = true;
        }
    }

    pub fn open(file_path: []const u8) !void {
        editor_context.source_path = file_path;

        // TODO: Lock
        const file = try fs.openFileAbsolute(file_path, .{ .read = true });
        const file_stat = try file.stat();

        if (file_stat.kind != .File) {
            log.warn("Cannot open '{s}'. Not a valid file", .{file_path});
            return;
        }

        const bytes_read = try file.read(text_buffer[0..text_buffer_capacity]);
        if (bytes_read == text_buffer_capacity) {
            log.warn("File too large for buffer", .{});
        }

        text_buffer_length = @intCast(u32, bytes_read);
        text_buffer_dirty = true;

        text_buffer_line_count = blk: {
            var line_count: u16 = 1;
            for (text_buffer[0..text_buffer_length]) |char| {
                if (char == '\n') line_count += 1;
            }
            break :blk line_count;
        };
    }
};

var text_cursor: TextCursor = .{
    .coordinates = .{
        .x = 0,
        .y = 0,
    },
    .text_buffer_index = 0,
};

// Globals

var screen_dimensions_previous = geometry.Dimensions2D(.pixel){
    .width = 0,
    .height = 0,
};

var screen_dimensions = geometry.Dimensions2D(.pixel){
    .width = 0,
    .height = 0,
};

// TODO:
const lines_per_view: u16 = 56;

var current_frame: u32 = 0;
var framebuffer_resized: bool = true;

var text_buffer_dirty: bool = true;
const text_buffer_capacity: u32 = 1024 * 1024;
var text_buffer_length: u32 = 0;
var text_buffer: [text_buffer_capacity]u8 = undefined;
var text_buffer_line_count: u16 = 1;

var is_cursor_updated: bool = false;

var mapped_device_memory: [*]u8 = undefined;

const max_texture_quads_per_render: u32 = 1024 * 2;

// Beginning index for indices / vertices in mapped device memory
const indices_range_index_begin = 0;
const indices_range_size = max_texture_quads_per_render * @sizeOf(u16) * 6; // 12 kb
const indices_range_count = indices_range_size / @sizeOf(u16);

const vertices_range_index_begin = indices_range_size;
const vertices_range_size = max_texture_quads_per_render * @sizeOf(TextureVertex) * 4; // 80 kb
const vertices_range_count = vertices_range_size / @sizeOf(TextureVertex);

const memory_size = indices_range_size + vertices_range_size;

var glyph_set: text.GlyphSet = undefined;

var vertex_buffer: []QuadFace(TextureVertex) = undefined;
var vertex_buffer_count: u32 = 0;

const EditorMode = enum(u8) {
    input,
    command,
};

var editor_mode: EditorMode = .input;
var command_text_buffer: [64]u8 = undefined;
var command_text_buffer_len: u16 = 0;

const enable_validation_layers = if (builtin.mode == .Debug) true else false;
const validation_layers = if (enable_validation_layers) [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"} else [*:0]const u8{};
const device_extensions = [_][*:0]const u8{vk.KHR_SWAPCHAIN_EXTENSION_NAME};

const max_frames_in_flight: u32 = 2;
var texture_pipeline: TexturePipeline = undefined;

var texture_image_view: vk.ImageView = undefined;
var texture_vertices_buffer: vk.Buffer = undefined;
var texture_indices_buffer: vk.Buffer = undefined;

const help_message =
    \\zedikor [<options>] [<filename>]
    \\options:
    \\    --help: display this help message
    \\
;

pub fn main() !void {
    if (os.argv.len > 2) {
        std.debug.print("Invalid usage:\n", .{});
        std.debug.print(help_message, .{});
        return;
    }

    if (os.argv.len > 1) {
        if (std.cstr.cmp(os.argv[1], "--help") == 0) {
            std.debug.print(help_message, .{});
            return;
        }

        log.info("opening '{s}'", .{os.argv[1]});
        editor_context.source_path = os.argv[1][0..strlen(os.argv[1])];

        assert(editor_context.source_path != null);

        if (editor_context.source_path) |path| {
            try editor_commands.open(path);
        }
    }

    var allocator: *Allocator = std.heap.c_allocator;

    var graphics_context: GraphicsContext = undefined;
    graphics_context.window = try initWindow(config.window_dimensions, config.app_name);

    const instance_extension = try zvk.glfwGetRequiredInstanceExtensions();

    for (instance_extension) |extension| {
        log.info("Extension: {s}", .{extension});
    }

    graphics_context.vk_instance = try zvk.createInstance(vk.InstanceCreateInfo{
        .sType = vk.StructureType.INSTANCE_CREATE_INFO,
        .pApplicationInfo = &vk.ApplicationInfo{
            .sType = vk.StructureType.APPLICATION_INFO,
            .pApplicationName = config.app_name,
            .applicationVersion = vk.MAKE_VERSION(0, 0, 1),
            .pEngineName = config.app_name,
            .engineVersion = vk.MAKE_VERSION(0, 0, 1),
            .apiVersion = vk.MAKE_VERSION(1, 2, 0),
            .pNext = null,
        },
        .enabledExtensionCount = @intCast(u32, instance_extension.len),
        .ppEnabledExtensionNames = instance_extension.ptr,
        .enabledLayerCount = if (enable_validation_layers) validation_layers.len else 0,
        .ppEnabledLayerNames = if (enable_validation_layers) &validation_layers else undefined,
        .pNext = null,
        .flags = .{},
    });

    graphics_context.surface = try zvk.createSurfaceGlfw(graphics_context.vk_instance, graphics_context.window);

    var present_mode: vk.PresentModeKHR = .FIFO;

    // Find a suitable physical device to use
    const best_physical_device = outer: {
        const physical_devices = try zvk.enumeratePhysicalDevices(allocator, graphics_context.vk_instance);
        defer allocator.free(physical_devices);

        for (physical_devices) |physical_device| {
            if ((try zvk.deviceSupportsExtensions(allocator, physical_device, device_extensions[0..])) and
                (try zvk.getPhysicalDeviceSurfaceFormatsKHRCount(physical_device, graphics_context.surface)) != 0 and
                (try zvk.getPhysicalDeviceSurfacePresentModesKHRCount(physical_device, graphics_context.surface)) != 0)
            {
                var supported_present_modes = try zvk.getPhysicalDeviceSurfacePresentModesKHR(allocator, physical_device, graphics_context.surface);
                defer allocator.free(supported_present_modes);

                // FIFO should be guaranteed by vulkan spec but validation layers are triggered
                // when vkGetPhysicalDeviceSurfacePresentModesKHR isn't used to get supported PresentModes
                for (supported_present_modes) |supported_present_mode| {
                    if (supported_present_mode == .FIFO) present_mode = .FIFO else continue;
                }

                const best_family_queue_index = inner: {
                    var queue_family_count: u32 = 0;
                    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

                    if (queue_family_count == 0) {
                        break :inner null;
                    }

                    comptime const max_family_queues: u32 = 16;
                    if (queue_family_count > max_family_queues) {
                        log.warn("Some family queues for selected device ignored", .{});
                    }

                    var queue_families: [max_family_queues]vk.QueueFamilyProperties = undefined;
                    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, &queue_families);

                    var i: u32 = 0;
                    while (i < queue_family_count) : (i += 1) {
                        if (queue_families[i].queueCount <= 0) {
                            continue;
                        }

                        if (queue_families[i].queueFlags.graphics) {
                            var present_support: vk.Bool32 = 0;
                            if (vk.vkGetPhysicalDeviceSurfaceSupportKHR(physical_device, i, graphics_context.surface, &present_support) != .SUCCESS) {
                                return error.FailedToGetPhysicalDeviceSupport;
                            }

                            if (present_support != vk.FALSE) {
                                break :inner i;
                            }
                        }
                    }

                    break :inner null;
                };

                if (best_family_queue_index) |queue_index| {
                    graphics_context.graphics_present_queue_index = queue_index;
                    break :outer physical_device;
                }
            }
        }

        break :outer null;
    };

    if (best_physical_device) |physical_device| {
        graphics_context.physical_device = physical_device;
    } else return error.NoSuitablePhysicalDevice;

    graphics_context.logical_device = try zvk.createDevice(graphics_context.physical_device, vk.DeviceCreateInfo{
        .sType = vk.StructureType.DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = @ptrCast([*]vk.DeviceQueueCreateInfo, &vk.DeviceQueueCreateInfo{
            .sType = vk.StructureType.DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = graphics_context.graphics_present_queue_index,
            .queueCount = 1,
            .pQueuePriorities = &[1]f32{1.0},
            .flags = .{},
            .pNext = null,
        }),
        .pEnabledFeatures = &vk.PhysicalDeviceFeatures{
            .robustBufferAccess = vk.FALSE,
            .fullDrawIndexUint32 = vk.FALSE,
            .imageCubeArray = vk.FALSE,
            .independentBlend = vk.FALSE,
            .geometryShader = vk.FALSE,
            .tessellationShader = vk.FALSE,
            .sampleRateShading = vk.FALSE,
            .dualSrcBlend = vk.FALSE,
            .logicOp = vk.FALSE,
            .multiDrawIndirect = vk.FALSE,
            .drawIndirectFirstInstance = vk.FALSE,
            .depthClamp = vk.FALSE,
            .depthBiasClamp = vk.FALSE,
            .fillModeNonSolid = vk.FALSE,
            .depthBounds = vk.FALSE,
            .wideLines = vk.FALSE,
            .largePoints = vk.FALSE,
            .alphaToOne = vk.FALSE,
            .multiViewport = vk.FALSE,
            .samplerAnisotropy = vk.TRUE,
            .textureCompressionETC2 = vk.FALSE,
            .textureCompressionASTC_LDR = vk.FALSE,
            .textureCompressionBC = vk.FALSE,
            .occlusionQueryPrecise = vk.FALSE,
            .pipelineStatisticsQuery = vk.FALSE,
            .vertexPipelineStoresAndAtomics = vk.FALSE,
            .fragmentStoresAndAtomics = vk.FALSE,
            .shaderTessellationAndGeometryPointSize = vk.FALSE,
            .shaderImageGatherExtended = vk.FALSE,
            .shaderStorageImageExtendedFormats = vk.FALSE,
            .shaderStorageImageMultisample = vk.FALSE,
            .shaderStorageImageReadWithoutFormat = vk.FALSE,
            .shaderStorageImageWriteWithoutFormat = vk.FALSE,
            .shaderUniformBufferArrayDynamicIndexing = vk.FALSE,
            .shaderSampledImageArrayDynamicIndexing = vk.FALSE,
            .shaderStorageBufferArrayDynamicIndexing = vk.FALSE,
            .shaderStorageImageArrayDynamicIndexing = vk.FALSE,
            .shaderClipDistance = vk.FALSE,
            .shaderCullDistance = vk.FALSE,
            .shaderFloat64 = vk.FALSE,
            .shaderInt64 = vk.FALSE,
            .shaderInt16 = vk.FALSE,
            .shaderResourceResidency = vk.FALSE,
            .shaderResourceMinLod = vk.FALSE,
            .sparseBinding = vk.FALSE,
            .sparseResidencyBuffer = vk.FALSE,
            .sparseResidencyImage2D = vk.FALSE,
            .sparseResidencyImage3D = vk.FALSE,
            .sparseResidency2Samples = vk.FALSE,
            .sparseResidency4Samples = vk.FALSE,
            .sparseResidency8Samples = vk.FALSE,
            .sparseResidency16Samples = vk.FALSE,
            .sparseResidencyAliased = vk.FALSE,
            .variableMultisampleRate = vk.FALSE,
            .inheritedQueries = vk.FALSE,
        },
        .enabledExtensionCount = device_extensions.len,
        .ppEnabledExtensionNames = &device_extensions,
        .enabledLayerCount = if (enable_validation_layers) validation_layers.len else 0,
        .ppEnabledLayerNames = if (enable_validation_layers) &validation_layers else undefined,
        .flags = .{},
        .pNext = null,
    });

    vk.vkGetDeviceQueue(graphics_context.logical_device, graphics_context.graphics_present_queue_index, 0, &graphics_context.graphics_present_queue);

    var available_formats: []vk.SurfaceFormatKHR = try zvk.getPhysicalDeviceSurfaceFormatsKHR(allocator, graphics_context.physical_device, graphics_context.surface);
    graphics_context.surface_format = zvk.chooseSwapSurfaceFormat(available_formats);
    graphics_context.swapchain_image_format = graphics_context.surface_format.format;

    try setupApplication(allocator, &graphics_context);

    try appLoop(allocator, &graphics_context);
    cleanupSwapchain(allocator, &graphics_context);
}

fn cleanupSwapchain(allocator: *Allocator, app: *GraphicsContext) void {
    vk.vkFreeCommandBuffers(app.logical_device, app.command_pool, @intCast(u32, app.command_buffers.len), app.command_buffers.ptr);

    for (app.swapchain_image_views) |image_view| {
        vk.vkDestroyImageView(app.logical_device, image_view, null);
    }

    vk.vkDestroySwapchainKHR(app.logical_device, app.swapchain, null);
}

fn recreateSwapchain(allocator: *Allocator, app: *GraphicsContext) !void {
    _ = vk.vkDeviceWaitIdle(app.logical_device);
    cleanupSwapchain(allocator, app);

    const available_formats: []vk.SurfaceFormatKHR = try zvk.getPhysicalDeviceSurfaceFormatsKHR(allocator, app.physical_device, app.surface);
    const surface_format = zvk.chooseSwapSurfaceFormat(available_formats);
    allocator.free(available_formats);

    var surface_capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(app.physical_device, app.surface, &surface_capabilities) != .SUCCESS) {
        return error.FailedToGetSurfaceCapabilities;
    }

    if (surface_capabilities.currentExtent.width == 0xFFFFFFFF or surface_capabilities.currentExtent.height == 0xFFFFFFFF) {
        var screen_width: i32 = undefined;
        var screen_height: i32 = undefined;
        vk.glfwGetFramebufferSize(app.window, &screen_width, &screen_height);

        if (screen_width <= 0 or screen_height <= 0) {
            return error.InvalidScreenDimensions;
        }

        app.swapchain_extent.width = @intCast(u32, screen_width);
        app.swapchain_extent.height = @intCast(u32, screen_height);

        screen_dimensions.width = app.swapchain_extent.width;
        screen_dimensions.height = app.swapchain_extent.height;
    }

    app.swapchain = try zvk.createSwapchain(app.logical_device, vk.SwapchainCreateInfoKHR{
        .sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
        .surface = app.surface,
        .minImageCount = surface_capabilities.minImageCount + 1,
        .imageFormat = app.swapchain_image_format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = app.swapchain_extent,
        .imageArrayLayers = 1,
        .imageUsage = .{ .colorAttachment = true },
        .imageSharingMode = .EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = undefined,
        .preTransform = surface_capabilities.currentTransform,
        .compositeAlpha = .{ .opaqueFlag = true },
        .presentMode = .FIFO,
        .clipped = vk.TRUE,
        .flags = .{},
        .oldSwapchain = null,
        .pNext = null,
    });

    app.swapchain_images = try zvk.getSwapchainImagesKHR(allocator, app.logical_device, app.swapchain);

    app.swapchain_image_views = try allocator.alloc(vk.ImageView, app.swapchain_images.len);
    for (app.swapchain_image_views) |*image_view, i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
            .image = app.swapchain_images[i],
            .viewType = .T_2D,
            .format = app.swapchain_image_format,
            .components = vk.ComponentMapping{
                .r = .IDENTITY,
                .g = .IDENTITY,
                .b = .IDENTITY,
                .a = .IDENTITY,
            },
            .subresourceRange = vk.ImageSubresourceRange{
                .aspectMask = .{ .color = true },
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .pNext = null,
            .flags = .{},
        };

        image_view.* = try zvk.createImageView(app.logical_device, image_view_create_info);
    }

    try texture_pipeline.create(allocator, app.logical_device, app.surface_format.format, app.swapchain_extent, app.swapchain_image_views, texture_image_view);

    // TODO: Audit
    allocator.free(app.command_buffers);
    app.command_buffers = try zvk.allocateCommandBuffers(allocator, app.logical_device, vk.CommandBufferAllocateInfo{
        .sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = app.command_pool,
        .level = .PRIMARY,
        .commandBufferCount = @intCast(u32, app.swapchain_images.len),
        .pNext = null,
    });

    try updateCommandBuffers(app);
}

const freetype = struct {
    pub fn init() !ft.FT_Library {
        var libary: ft.FT_Library = undefined;
        if (ft.FT_Init_FreeType(&libary) != ft.FT_Err_Ok) {
            return error.InitFreeTypeLibraryFailed;
        }
        return libary;
    }

    pub fn newFace(libary: ft.FT_Library, font_path: [:0]const u8, face_index: i64) !ft.FT_Face {
        var face: ft.FT_Face = undefined;
        if (ft.FT_New_Face(libary, font_path, 0, &face) != ft.FT_Err_Ok) {
            return error.CreateNewFaceFailed;
        }
        return face;
    }
};

fn setupApplication(allocator: *Allocator, app: *GraphicsContext) !void {
    var font_library: ft.FT_Library = try freetype.init();
    var font_face: ft.FT_Face = try freetype.newFace(font_library, config.font_path, 0);

    _ = ft.FT_Select_Charmap(font_face, @intToEnum(ft.enum_FT_Encoding_, ft.FT_ENCODING_UNICODE));
    _ = ft.FT_Set_Pixel_Sizes(font_face, 0, config.font_size);

    const font_texture_chars =
        \\abcdefghijklmnopqrstuvwxyz
        \\ABCDEFGHIJKLMNOPQRSTUVWXYZ
        \\0123456789
        \\!\"£$%^&*()-_=+[]{};:'@#~,<.>/?\\|
    ;

    glyph_set = try text.createGlyphSet(allocator, font_face, font_texture_chars[0..]);

    var memory_properties = zvk.getDevicePhysicalMemoryProperties(app.physical_device);

    var texture_width: u32 = glyph_set.width();
    var texture_height: u32 = glyph_set.height();

    const texture_size_bytes = glyph_set.image.len * @sizeOf(u8);

    var staging_buffer: vk.Buffer = try zvk.createBuffer(app.logical_device, .{
        .pNext = null,
        .flags = .{},
        .size = texture_size_bytes,
        .usage = .{ .transferSrc = true },
        .sharingMode = .EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = undefined,
    });

    const staging_memory_alloc = vk.MemoryAllocateInfo{
        .sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = texture_size_bytes,
        .memoryTypeIndex = 0,
    };

    var staging_memory = try zvk.allocateMemory(app.logical_device, staging_memory_alloc);

    try zvk.bindBufferMemory(app.logical_device, staging_buffer, staging_memory, 0);

    var image_memory_map: [*]u8 = undefined;
    if (.SUCCESS != vk.vkMapMemory(app.logical_device, staging_memory, 0, texture_size_bytes, 0, @ptrCast(?**c_void, &image_memory_map))) {
        return error.MapMemoryFailed;
    }

    @memcpy(image_memory_map, @ptrCast([*]u8, glyph_set.image), texture_size_bytes);
    vk.vkUnmapMemory(app.logical_device, staging_memory);

    allocator.free(glyph_set.image);

    var texture_image = try zvk.createImage(app.logical_device, vk.ImageCreateInfo{
        .sType = vk.StructureType.IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = .{},
        .imageType = .T_2D,
        .format = .R8_UNORM,
        .tiling = .OPTIMAL,
        .extent = vk.Extent3D{ .width = texture_width, .height = texture_height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .initialLayout = .UNDEFINED,
        .usage = .{ .transferDst = true, .sampled = true },
        .samples = .{ .t1 = true },
        .sharingMode = .EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = undefined,
    });

    const texture_memory_requirements = zvk.getImageMemoryRequirements(app.logical_device, texture_image);

    const alloc_memory_info = vk.MemoryAllocateInfo{
        .sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = texture_memory_requirements.size,
        .memoryTypeIndex = 0,
    };

    var image_memory = try zvk.allocateMemory(app.logical_device, alloc_memory_info);

    if (.SUCCESS != vk.vkBindImageMemory(app.logical_device, texture_image, image_memory, 0)) {
        return error.BindImageMemoryFailed;
    }

    const command_pool = try zvk.createCommandPool(app.logical_device, vk.CommandPoolCreateInfo{
        .sType = vk.StructureType.COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = .{ .resetCommandBuffer = true },
        .queueFamilyIndex = app.graphics_present_queue_index,
    });

    {
        var command_buffer = try zvk.allocateCommandBuffer(app.logical_device, vk.CommandBufferAllocateInfo{
            .sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .level = .PRIMARY,
            .commandPool = command_pool,
            .commandBufferCount = 1,
        });

        try zvk.beginCommandBuffer(command_buffer, .{
            .sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = .{ .oneTimeSubmit = true },
            .pInheritanceInfo = null,
        });
        {
            const barrier = [_]vk.ImageMemoryBarrier{
                .{
                    .sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = .{},
                    .dstAccessMask = .{ .transferWrite = true },
                    .oldLayout = .UNDEFINED,
                    .newLayout = .TRANSFER_DST_OPTIMAL,
                    .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .image = texture_image,
                    .subresourceRange = .{
                        .aspectMask = .{ .color = true },
                        .baseMipLevel = 0,
                        .levelCount = 1,
                        .baseArrayLayer = 0,
                        .layerCount = 1,
                    },
                },
            };

            const src_stage = @bitCast(u32, vk.PipelineStageFlags{ .topOfPipe = true });
            const dst_stage = @bitCast(u32, vk.PipelineStageFlags{ .transfer = true });
            vk.vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, undefined, 0, undefined, 1, &barrier);
        }

        const region = [_]vk.BufferImageCopy{.{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = .{ .color = true },
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{
                .width = texture_width,
                .height = texture_height,
                .depth = 1,
            },
        }};

        _ = vk.vkCmdCopyBufferToImage(command_buffer, staging_buffer, texture_image, .TRANSFER_DST_OPTIMAL, 1, &region);

        {
            const barrier = [_]vk.ImageMemoryBarrier{
                .{
                    .sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = .{ .transferWrite = true },
                    .dstAccessMask = .{ .shaderRead = true },
                    .oldLayout = .TRANSFER_DST_OPTIMAL,
                    .newLayout = .SHADER_READ_ONLY_OPTIMAL,
                    .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                    .image = texture_image,
                    .subresourceRange = .{
                        .aspectMask = .{ .color = true },
                        .baseMipLevel = 0,
                        .levelCount = 1,
                        .baseArrayLayer = 0,
                        .layerCount = 1,
                    },
                },
            };

            const src_stage = @bitCast(u32, vk.PipelineStageFlags{ .transfer = true });
            const dst_stage = @bitCast(u32, vk.PipelineStageFlags{ .fragmentShader = true });
            vk.vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, undefined, 0, undefined, 1, &barrier);
        }

        try zvk.endCommandBuffer(command_buffer);

        const submit_command_infos = [_]vk.SubmitInfo{.{
            .sType = vk.StructureType.SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = undefined,
            .pWaitDstStageMask = undefined,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast([*]vk.CommandBuffer, &command_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = undefined,
        }};

        if (.SUCCESS != vk.vkQueueSubmit(app.graphics_present_queue, 1, &submit_command_infos, null)) {
            return error.QueueSubmitFailed;
        }
    }

    texture_image_view = try zvk.createImageView(app.logical_device, .{
        .flags = .{},
        .image = texture_image,
        .viewType = .T_2D,
        .format = .R8_UNORM,
        .subresourceRange = .{
            .aspectMask = .{ .color = true },
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .components = .{ .r = .IDENTITY, .g = .IDENTITY, .b = .IDENTITY, .a = .IDENTITY },
    });

    var surface_capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(app.physical_device, app.surface, &surface_capabilities) != .SUCCESS) {
        return error.FailedToGetSurfaceCapabilities;
    }

    if (surface_capabilities.currentExtent.width == 0xFFFFFFFF or surface_capabilities.currentExtent.height == 0xFFFFFFFF) {
        var screen_width: i32 = undefined;
        var screen_height: i32 = undefined;
        vk.glfwGetFramebufferSize(app.window, &screen_width, &screen_height);

        if (screen_width <= 0 or screen_height <= 0) {
            return error.InvalidScreenDimensions;
        }

        app.swapchain_extent.width = @intCast(u32, screen_width);
        app.swapchain_extent.height = @intCast(u32, screen_height);

        screen_dimensions.width = app.swapchain_extent.width;
        screen_dimensions.height = app.swapchain_extent.height;
    }

    app.swapchain = try zvk.createSwapchain(app.logical_device, vk.SwapchainCreateInfoKHR{
        .sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
        .surface = app.surface,
        .minImageCount = surface_capabilities.minImageCount + 1,
        .imageFormat = app.swapchain_image_format,
        .imageColorSpace = app.surface_format.colorSpace,
        .imageExtent = app.swapchain_extent,
        .imageArrayLayers = 1,
        .imageUsage = .{ .colorAttachment = true },
        .imageSharingMode = .EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = undefined,
        .preTransform = surface_capabilities.currentTransform,
        .compositeAlpha = .{ .opaqueFlag = true },
        .presentMode = .FIFO,
        .clipped = vk.TRUE,
        .flags = .{},
        .oldSwapchain = null,
        .pNext = null,
    });

    app.swapchain_images = try zvk.getSwapchainImagesKHR(allocator, app.logical_device, app.swapchain);

    // TODO: Duplicated code
    app.swapchain_image_views = try allocator.alloc(vk.ImageView, app.swapchain_images.len);
    for (app.swapchain_image_views) |image, i| {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
            .image = app.swapchain_images[i],
            .viewType = .T_2D,
            .format = app.swapchain_image_format,
            .components = vk.ComponentMapping{
                .r = .IDENTITY,
                .g = .IDENTITY,
                .b = .IDENTITY,
                .a = .IDENTITY,
            },
            .subresourceRange = vk.ImageSubresourceRange{
                .aspectMask = .{ .color = true },
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .pNext = null,
            .flags = .{},
        };

        app.swapchain_image_views[i] = try zvk.createImageView(app.logical_device, image_view_create_info);
    }

    try texture_pipeline.init(allocator, app.logical_device);
    try texture_pipeline.create(allocator, app.logical_device, app.surface_format.format, app.swapchain_extent, app.swapchain_image_views, texture_image_view);

    assert(vertices_range_index_begin + vertices_range_size <= memory_size);

    var memory: vk.DeviceMemory = try zvk.allocateMemory(app.logical_device, vk.MemoryAllocateInfo{
        .sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
        .allocationSize = memory_size,
        .memoryTypeIndex = 0, // TODO: Audit
        .pNext = null,
    });

    texture_vertices_buffer = try zvk.createBufferOnMemory(app.logical_device, vertices_range_size, vertices_range_index_begin, .{ .transferDst = true, .vertexBuffer = true }, memory);
    texture_indices_buffer = try zvk.createBufferOnMemory(app.logical_device, indices_range_size, indices_range_index_begin, .{ .transferDst = true, .indexBuffer = true }, memory);

    if (vk.vkMapMemory(app.logical_device, memory, 0, memory_size, 0, @ptrCast(**c_void, &mapped_device_memory)) != .SUCCESS) {
        return error.MapMemoryFailed;
    }

    {
        // We won't be reusing vertices except in making quads so we can pre-generate the entire indices buffer
        var indices = @ptrCast([*]u16, @alignCast(16, &mapped_device_memory[indices_range_index_begin]));

        var j: u32 = 0;
        while (j < (indices_range_count / 6)) : (j += 1) {
            indices[j * 6 + 0] = @intCast(u16, j * 4) + 0; // TL
            indices[j * 6 + 1] = @intCast(u16, j * 4) + 1; // TR
            indices[j * 6 + 2] = @intCast(u16, j * 4) + 2; // BR
            indices[j * 6 + 3] = @intCast(u16, j * 4) + 0; // TL
            indices[j * 6 + 4] = @intCast(u16, j * 4) + 2; // BR
            indices[j * 6 + 5] = @intCast(u16, j * 4) + 3; // BL
        }
    }

    var command_pool_create_info = vk.CommandPoolCreateInfo{
        .sType = vk.StructureType.COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = app.graphics_present_queue_index,
        .flags = .{},
        .pNext = null,
    };

    if (vk.vkCreateCommandPool(app.logical_device, &command_pool_create_info, null, &app.command_pool) != .SUCCESS) {
        return error.CreateCommandPoolFailed;
    }

    assert(app.swapchain_images.len > 0);

    app.command_buffers = try zvk.allocateCommandBuffers(allocator, app.logical_device, vk.CommandBufferAllocateInfo{
        .sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = app.command_pool,
        .level = .PRIMARY,
        .commandBufferCount = @intCast(u32, app.swapchain_images.len),
        .pNext = null,
    });

    app.images_available = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    app.renders_finished = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    app.inflight_fences = try allocator.alloc(vk.Fence, max_frames_in_flight);

    var semaphore_create_info = vk.SemaphoreCreateInfo{
        .sType = vk.StructureType.SEMAPHORE_CREATE_INFO,
        .flags = .{},
        .pNext = null,
    };

    var fence_create_info = vk.FenceCreateInfo{
        .sType = vk.StructureType.FENCE_CREATE_INFO,
        .flags = .{ .signaled = true },
        .pNext = null,
    };

    var i: u32 = 0;
    while (i < max_frames_in_flight) {
        if (vk.vkCreateSemaphore(app.logical_device, &semaphore_create_info, null, &app.images_available[i]) != .SUCCESS or
            vk.vkCreateSemaphore(app.logical_device, &semaphore_create_info, null, &app.renders_finished[i]) != .SUCCESS or
            vk.vkCreateFence(app.logical_device, &fence_create_info, null, &app.inflight_fences[i]) != .SUCCESS)
        {
            return error.CreateSemaphoreFailed;
        }

        i += 1;
    }
}

fn glfwTextCallback(window: *vk.GLFWwindow, codepoint: u32) callconv(.C) void {
    if (editor_mode == .input) {
        if (text_buffer_length < (text_buffer.len - 1)) {
            sliceShiftRight(u8, text_buffer[text_cursor.text_buffer_index .. text_buffer_length + 1]);

            text_buffer[text_cursor.text_buffer_index] = @intCast(u8, codepoint);
            text_cursor.text_buffer_index += 1;
            text_buffer_length += 1;
            text_cursor.coordinates.x += 1;
            text_buffer_dirty = true;
            editor_context.is_synced_with_source = false;
        }
    } else if (editor_mode == .command) {
        if (codepoint == ':') {
            editor_context.is_command_ongoing = true;
        }

        if (editor_context.is_command_ongoing and command_text_buffer_len < 64) {
            command_text_buffer[command_text_buffer_len] = @intCast(u8, codepoint);
            command_text_buffer_len += 1;
            text_buffer_dirty = true;
            return;
        }

        if (codepoint == 'c') {
            editor_commands.cursorVerticallyCenter();
        }

        if (codepoint == 'j') text_buffer_dirty = text_cursor.down(text_buffer[0..text_buffer_length]);
        if (codepoint == 'k') text_buffer_dirty = text_cursor.up(text_buffer[0..text_buffer_length]);
        if (codepoint == 'l') text_buffer_dirty = text_cursor.right(text_buffer[0..text_buffer_length]);
        if (codepoint == 'h') text_buffer_dirty = text_cursor.left(text_buffer[0..text_buffer_length]);

        if (codepoint == 'm' and text_buffer_line_count >= (editor_context.view_extent.line_top_index + lines_per_view)) {
            editor_context.view_extent.line_top_index += 1;
            text_buffer_dirty = true;
            return;
        }

        if (codepoint == 'i' and editor_context.view_extent.line_top_index != 0) {
            editor_context.view_extent.line_top_index -= 1;
            text_buffer_dirty = true;
            return;
        }
    } else {
        unreachable;
    }
}

fn glfwKeyCallback(window: *vk.GLFWwindow, key: i32, scancode: i32, action: i32, mods: i32) callconv(.C) void {
    if (@bitCast(glfw.keys.Mods, mods).control and
        action == vk.GLFW_PRESS and
        @intCast(u8, vk.glfwGetKeyScancode(vk.GLFW_KEY_J)) == scancode)
    {
        editor_mode = if (editor_mode == .command) .input else .command;
        text_buffer_dirty = true;
        command_text_buffer_len = 0;
        return;
    }

    switch (action) {
        vk.GLFW_PRESS => {
            switch (key) {
                vk.GLFW_KEY_BACKSPACE => {
                    switch (editor_mode) {
                        .input => {
                            if (text_buffer_length > 0 and text_cursor.text_buffer_index > 0) {
                                if (text_buffer[text_cursor.text_buffer_index - 1] == '\n') {
                                    text_buffer_line_count -= 1;
                                    text_cursor.coordinates.y -= 1;
                                    text_cursor.coordinates.x = reverseLength(text_buffer[0 .. text_cursor.text_buffer_index - 1], '\n');

                                    if (text_buffer_line_count == editor_context.view_extent.line_top_index) {
                                        editor_context.view_extent.line_top_index -= 1;
                                    } else {
                                        editor_context.view_extent.line_count -= 1;
                                    }
                                } else {
                                    text_cursor.coordinates.x -= 1;
                                }

                                // Left shift to make delete
                                var range: u32 = text_buffer_length - text_cursor.text_buffer_index;
                                var i: u32 = 0;
                                while (i < range) : (i += 1) {
                                    text_buffer[text_cursor.text_buffer_index + i - 1] = text_buffer[text_cursor.text_buffer_index + i];
                                }

                                text_cursor.text_buffer_index -= 1;
                                text_buffer_length -= 1;
                                text_buffer_dirty = true;
                                editor_context.is_synced_with_source = false;
                            }
                        },
                        .command => {
                            if (editor_context.is_command_ongoing and command_text_buffer_len > 0) {
                                command_text_buffer_len -= 1;
                                text_buffer_dirty = true;
                                if (command_text_buffer_len == 0) {
                                    editor_context.is_command_ongoing = false;
                                }
                            }
                        },
                    }
                },
                vk.GLFW_KEY_ENTER => {
                    switch (editor_mode) {
                        .input => {
                            if (text_buffer_length < (text_buffer.len - 1)) {
                                sliceShiftRight(u8, text_buffer[text_cursor.text_buffer_index .. text_buffer_length + 1]);

                                text_buffer[text_cursor.text_buffer_index] = '\n';
                                text_buffer_length += 1;
                                text_buffer_line_count += 1;
                                text_cursor.coordinates.y += 1;
                                text_cursor.text_buffer_index += 1;
                                text_cursor.coordinates.x = 0;
                                text_buffer_dirty = true;

                                if (text_buffer_line_count >= lines_per_view) {
                                    editor_context.view_extent.line_top_index += 1;
                                }

                                // TODO:
                                editor_context.view_extent.line_count += 1;

                                editor_context.is_synced_with_source = false;
                            }
                        },
                        .command => {
                            if (editor_context.is_command_ongoing) {
                                if (command_text_buffer_len > 1 and command_text_buffer[1] == 'q') {
                                    editor_commands.quit();
                                }

                                if (command_text_buffer_len > 1 and command_text_buffer[1] == 'w') {
                                    editor_context.is_write_file_requested = true;
                                    editor_context.source_path = command_text_buffer[3..command_text_buffer_len];
                                }
                            }
                        },
                    }
                },
                vk.GLFW_KEY_TAB => {
                    if ((text_buffer_length + 1) < (text_buffer.len - 1)) {
                        text_buffer[text_buffer_length + 0] = ' ';
                        text_buffer[text_buffer_length + 1] = ' ';

                        text_buffer_length += 2;
                        text_cursor.text_buffer_index += 2;
                        text_cursor.coordinates.x += 2;
                        text_buffer_dirty = true;
                        editor_context.is_synced_with_source = false;
                    }
                },
                else => {},
            }
        },
        else => {},
    }

    assert(text_cursor.text_buffer_index <= text_buffer_length);
}

// TODO: move
// Allocator wrapper around fixed-size array with linear access pattern
const FixedBufferAllocator = struct {
    allocator: Allocator = Allocator{
        .allocFn = alloc,
        .resizeFn = resize,
    },

    buffer: [*]u8,
    capacity: u32,
    used: u32,

    const Self = @This();

    pub fn init(self: *Self, fixed_buffer: [*]u8, length: u32) void {
        self.buffer = fixed_buffer;
        self.capacity = length;
        self.used = 0;
    }

    fn alloc(allocator: *Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) Allocator.Error![]u8 {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        const aligned_size = std.math.max(len, ptr_align);

        if (aligned_size > (self.capacity - self.used)) return error.OutOfMemory;

        defer self.used += @intCast(u32, aligned_size);
        return self.buffer[self.used .. self.used + aligned_size];
    }

    fn resize(
        allocator: *Allocator,
        old_mem: []u8,
        old_align: u29,
        new_size: usize,
        len_align: u29,
        ret_addr: usize,
    ) Allocator.Error!usize {
        const diff: i32 = (@intCast(i32, old_mem.len) - @intCast(i32, new_size));
        if (diff < 0) return error.OutOfMemory;

        const self = @fieldParentPtr(Self, "allocator", allocator);
        self.used -= @intCast(u32, diff);

        return new_size;
    }
};

fn update(allocator: *Allocator, app: *GraphicsContext) !void {
    const vertices = @ptrCast([*]TextureVertex, @alignCast(16, &mapped_device_memory[vertices_range_index_begin]));

    assert(screen_dimensions.width > 0);
    assert(screen_dimensions.height > 0);

    vertex_buffer_count = 0;

    // Wrap our fixed-size buffer in allocator interface to be generic
    var fixed_buffer_allocator = FixedBufferAllocator{
        .allocator = .{
            .allocFn = FixedBufferAllocator.alloc,
            .resizeFn = FixedBufferAllocator.resize,
        },
        .buffer = @ptrCast([*]u8, &vertices[0]),
        .capacity = @intCast(u32, vertices_range_count * @sizeOf(TextureVertex)),
        .used = 0,
    };

    var face_allocator = &fixed_buffer_allocator.allocator;

    const lines_to_render = blk: {
        // Clamp lines_to_render to `lines_per_view`
        const lines_available = text_buffer_line_count - @intCast(u16, editor_context.view_extent.line_top_index);
        break :blk if (lines_available > lines_per_view) lines_per_view else lines_available;
    };

    const line_range = lineRange(text_buffer[0..text_buffer_length], @intCast(u16, editor_context.view_extent.line_top_index), @intCast(u16, lines_to_render));

    assert(lines_to_render <= lines_per_view);
    assert(line_range.len <= lines_per_view * 80);

    const scale_factor = geometry.ScaleFactor2D{
        .horizontal = (2.0 / @intToFloat(f32, screen_dimensions.width)),
        .vertical = (2.0 / @intToFloat(f32, screen_dimensions.height)),
    };

    const is_saved_text = if (editor_context.is_synced_with_source) "saved" else "unsaved";
    const mode_text = if (editor_mode == .input) "input" else "command";
    const save_status_faces = try text.writeText(face_allocator, glyph_set, .{ .x = 0.5, .y = 0.975 }, scale_factor, is_saved_text);
    const current_mode_faces = try text.writeText(face_allocator, glyph_set, .{ .x = 0.8, .y = 0.975 }, scale_factor, mode_text);

    vertex_buffer_count += @intCast(u32, save_status_faces.len + current_mode_faces.len);

    var command_input_face_count: usize = 0;
    if (editor_mode == .command) {
        const command_input_faces = try text.writeText(face_allocator, glyph_set, .{ .x = -0.95, .y = 0.975 }, scale_factor, command_text_buffer[0..command_text_buffer_len]);
        command_input_face_count = command_input_faces.len;
    }

    const placement = geometry.Coordinates2D(.ndc_right){ .x = -0.98, .y = -0.9 };

    const line_margin_digit_count: u32 = digitCount(editor_context.view_extent.line_top_index + lines_to_render);
    assert(line_margin_digit_count > 0);

    // Margin from line count to editor text area
    const left_margin: f32 = 10.0 * scale_factor.horizontal;
    // Generic x increment between characters
    const base_x_increment = 10.0 * scale_factor.horizontal;

    // TODO: Don't hardcode
    const line_height = 18.0 * scale_factor.vertical;

    const line_margin_vertices = try gui.generateLineMargin(TextureVertex, face_allocator, glyph_set, placement, scale_factor, @intCast(u16, editor_context.view_extent.line_top_index), lines_to_render, line_height);
    vertex_buffer_count += @intCast(u16, line_margin_vertices.len);

    // TODO: Don't hardcode
    const cursor_placement: geometry.Coordinates2D(.ndc_right) = .{
        .x = placement.x + (@intToFloat(f32, text_cursor.coordinates.x) * (scale_factor.horizontal * 10.0)) + left_margin + (@intToFloat(f32, line_margin_digit_count) * base_x_increment),
        .y = placement.y + (@intToFloat(f32, text_cursor.coordinates.y - editor_context.view_extent.line_top_index) * (scale_factor.vertical * 18.0)),
    };

    const cursor_face = try text.writeText(face_allocator, glyph_set, cursor_placement, scale_factor, "|");
    vertex_buffer_count += @intCast(u16, cursor_face.len);

    const editor_placement: geometry.Coordinates2D(.ndc_right) = .{
        .x = placement.x + left_margin + (@intToFloat(f32, line_margin_digit_count) * (10.0 * scale_factor.horizontal)),
        .y = placement.y,
    };

    const text_editor_faces = try text.writeText(face_allocator, glyph_set, editor_placement, scale_factor, line_range);

    vertex_buffer_count += @intCast(u16, text_editor_faces.len);

    text_buffer_dirty = false;
    is_render_requested = true;
}

fn appLoop(allocator: *Allocator, app: *GraphicsContext) !void {
    const target_fps = 25;
    const target_ms_per_frame: u32 = 1000 / target_fps;

    log.info("Target MS / frame: {d}", .{target_ms_per_frame});

    var actual_fps: u64 = 0;
    var frames_current_second: u64 = 0;

    _ = vk.glfwSetCharCallback(app.window, glfwTextCallback);
    _ = vk.glfwSetKeyCallback(app.window, glfwKeyCallback);

    while (vk.glfwWindowShouldClose(app.window) == 0) {
        vk.glfwPollEvents();

        var screen_width: i32 = undefined;
        var screen_height: i32 = undefined;

        vk.glfwGetFramebufferSize(app.window, &screen_width, &screen_height);

        if (screen_width <= 0 or screen_height <= 0) {
            return error.InvalidScreenDimensions;
        }

        if (screen_dimensions.width != screen_dimensions_previous.width or
            screen_dimensions.height != screen_dimensions_previous.height)
        {
            framebuffer_resized = true;
            screen_dimensions_previous = screen_dimensions;
        }

        screen_dimensions.width = @intCast(u32, screen_width);
        screen_dimensions.height = @intCast(u32, screen_height);

        const frame_start_ms: i64 = std.time.milliTimestamp();

        if (editor_context.is_write_file_requested) {
            assert(editor_context.source_path != null);
            if (editor_context.source_path) |source_path| {
                try editor_commands.write(source_path);
                command_text_buffer_len = 0;
                editor_context.is_command_ongoing = false;
                text_buffer_dirty = true;
            }
        }

        if (text_buffer_dirty or framebuffer_resized) {
            try update(allocator, app);
        }

        // TODO:
        if (is_render_requested) {
            if (vk.vkDeviceWaitIdle(app.logical_device) != .SUCCESS) {
                return error.DeviceWaitIdleFailed;
            }
            if (vk.vkResetCommandPool(app.logical_device, app.command_pool, 0) != .SUCCESS) {
                return error.resetCommandBufferFailed;
            }
            try updateCommandBuffers(app);

            is_render_requested = false;
        }

        try renderFrame(allocator, app);

        const frame_end_ms: i64 = std.time.milliTimestamp();
        const frame_duration_ms = frame_end_ms - frame_start_ms;
        assert(frame_duration_ms >= 0);

        if (frame_duration_ms >= target_ms_per_frame) {
            continue;
        }

        assert(target_ms_per_frame > frame_duration_ms);
        const remaining_ms: u32 = target_ms_per_frame - @intCast(u32, frame_duration_ms);
        std.time.sleep(remaining_ms * 1000 * 1000);
    }

    if (vk.vkDeviceWaitIdle(app.logical_device) != .SUCCESS) {
        return error.DeviceWaitIdleFailed;
    }
}

fn updateCommandBuffers(app: *GraphicsContext) !void {
    try texture_pipeline.recordRenderPass(app.command_buffers, texture_vertices_buffer, texture_indices_buffer, app.swapchain_extent, vertex_buffer_count * 6);
}

fn renderFrame(allocator: *Allocator, app: *GraphicsContext) !void {
    if (vk.vkWaitForFences(app.logical_device, 1, @ptrCast([*]const vk.Fence, &app.inflight_fences[current_frame]), vk.TRUE, std.math.maxInt(u64)) != .SUCCESS) {
        return error.WaitForFencesFailed;
    }

    var swapchain_image_index: u32 = undefined;
    var result = vk.vkAcquireNextImageKHR(app.logical_device, app.swapchain, std.math.maxInt(u64), app.images_available[current_frame], null, &swapchain_image_index);

    if (result == .ERROR_OUT_OF_DATE_KHR) {
        log.info("Swapchain out of date; Recreating..", .{});
        try recreateSwapchain(allocator, app);
        return;
    } else if (result != .SUCCESS and result != .SUBOPTIMAL_KHR) {
        return error.AcquireNextImageFailed;
    }

    const wait_semaphores = [1]vk.Semaphore{app.images_available[current_frame]};
    const wait_stages = [1]vk.PipelineStageFlags{.{ .colorAttachmentOutput = true }};
    const signal_semaphores = [1]vk.Semaphore{app.renders_finished[current_frame]};

    const command_submit_info = vk.SubmitInfo{
        .sType = vk.StructureType.SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait_semaphores,
        .pWaitDstStageMask = @ptrCast([*]align(4) const vk.PipelineStageFlags, &wait_stages),
        .commandBufferCount = 1,
        .pCommandBuffers = @ptrCast([*]vk.CommandBuffer, &app.command_buffers[swapchain_image_index]),
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &signal_semaphores,
        .pNext = null,
    };

    if (vk.vkResetFences(app.logical_device, 1, @ptrCast([*]const vk.Fence, &app.inflight_fences[current_frame])) != .SUCCESS) {
        return error.ResetFencesFailed;
    }

    if (vk.vkQueueSubmit(app.graphics_present_queue, 1, @ptrCast([*]const vk.SubmitInfo, &command_submit_info), app.inflight_fences[current_frame]) != .SUCCESS) {
        return error.QueueSubmitFailed;
    }

    const swapchains = [1]vk.SwapchainKHR{app.swapchain};
    const present_info = vk.PresentInfoKHR{
        .sType = vk.StructureType.PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &signal_semaphores,
        .swapchainCount = 1,
        .pSwapchains = &swapchains,
        .pImageIndices = @ptrCast([*]u32, &swapchain_image_index),
        .pResults = null,
        .pNext = null,
    };

    result = vk.vkQueuePresentKHR(app.graphics_present_queue, &present_info);

    if (result == .ERROR_OUT_OF_DATE_KHR or result == .SUBOPTIMAL_KHR or framebuffer_resized) {
        framebuffer_resized = false;
        try recreateSwapchain(allocator, app);
        return;
    } else if (result != .SUCCESS) {
        return error.QueuePresentFailed;
    }

    current_frame = (current_frame + 1) % max_frames_in_flight;
}

fn initWindow(window_dimensions: geometry.Dimensions2D(.pixel), title: [:0]const u8) !*vk.GLFWwindow {
    if (vk.glfwInit() != 1) {
        return error.GLFWInitFailed;
    }
    vk.glfwWindowHint(vk.GLFW_CLIENT_API, vk.GLFW_NO_API);

    return vk.glfwCreateWindow(@intCast(c_int, window_dimensions.width), @intCast(c_int, window_dimensions.height), title.ptr, null, null) orelse
        return error.GlfwCreateWindowFailed;
}
