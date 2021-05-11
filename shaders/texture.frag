#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(binding = 0) uniform sampler2D texSampler;

layout(location = 0) in vec2 inFragTexCoord;
layout(location = 1) flat in uint inColorIndex;

layout(location = 0) out vec4 outColor;

layout(push_constant) uniform constants {
    layout(offset = 0) vec4 textColors[4];
} PushConstants;

void main() {
    vec4 intensity = texture(texSampler, inFragTexCoord);
    outColor = PushConstants.textColors[inColorIndex] * intensity.r;
}
