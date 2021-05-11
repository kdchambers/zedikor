
#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inTexCoord;
layout(location = 2) in uint inColorIndex;

layout(location = 0) out vec2 outFragTexCoord;
layout(location = 1) out uint outColorIndex;

void main() {
    gl_Position = vec4(inPosition.x, inPosition.y, 0.0, 1.0);
    outColorIndex = inColorIndex;
    outFragTexCoord = inTexCoord;
}