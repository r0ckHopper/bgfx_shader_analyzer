#!/usr/bin/env python3
"""Generate bgfx_spec.json by merging the GLSL spec with bgfx shader builtins."""

import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SPEC_JSON = os.path.join(SCRIPT_DIR, "spec.json")
BGFX_SPEC_JSON = os.path.join(SCRIPT_DIR, "bgfx_spec.json")

BGFX_KEYWORDS = [
    {"name": "$input", "kind": "bgfx"},
    {"name": "$output", "kind": "bgfx"},
    {"name": "$raw", "kind": "bgfx"},
]

BGFX_TYPES = [
    {"name": "Sampler2D", "description": "bgfx 2D texture sampler handle"},
    {"name": "Sampler2DMS", "description": "bgfx multisampled 2D texture sampler handle"},
    {"name": "Sampler2DArray", "description": "bgfx 2D array texture sampler handle"},
    {"name": "Sampler2DShadow", "description": "bgfx 2D shadow sampler handle"},
    {"name": "Sampler2DArrayShadow", "description": "bgfx 2D array shadow sampler handle"},
    {"name": "Sampler3D", "description": "bgfx 3D texture sampler handle"},
    {"name": "SamplerCube", "description": "bgfx cubemap sampler handle"},
    {"name": "SamplerCubeShadow", "description": "bgfx cubemap shadow sampler handle"},
    {"name": "ISampler2D", "description": "bgfx integer 2D sampler handle"},
    {"name": "USampler2D", "description": "bgfx unsigned integer 2D sampler handle"},
    {"name": "ISampler3D", "description": "bgfx integer 3D sampler handle"},
    {"name": "USampler3D", "description": "bgfx unsigned integer 3D sampler handle"},
]

BGFX_BUILTINS = {
    "uniforms": [
        {"name": "u_viewRect", "type": "vec4", "description": "View rectangle: xy = origin, zw = size"},
        {"name": "u_viewTexel", "type": "vec4", "description": "View texel size: xy = 1/width, 1/height"},
        {"name": "u_view", "type": "mat4", "description": "View matrix"},
        {"name": "u_invView", "type": "mat4", "description": "Inverse view matrix"},
        {"name": "u_proj", "type": "mat4", "description": "Projection matrix"},
        {"name": "u_invProj", "type": "mat4", "description": "Inverse projection matrix"},
        {"name": "u_viewProj", "type": "mat4", "description": "View-projection matrix"},
        {"name": "u_invViewProj", "type": "mat4", "description": "Inverse view-projection matrix"},
        {"name": "u_modelView", "type": "mat4", "description": "Model-view matrix"},
        {"name": "u_invModelView", "type": "mat4", "description": "Inverse model-view matrix"},
        {"name": "u_modelViewProj", "type": "mat4", "description": "Model-view-projection matrix"},
        {"name": "u_alphaRef4", "type": "vec4", "description": "Alpha reference value"},
        {"name": "u_model", "type": "mat4[]", "description": "Model matrices array (up to BGFX_CONFIG_MAX_BONES)"},
    ],
    "attributes": [
        {"name": "a_position", "type": "vec4", "semantic": "POSITION"},
        {"name": "a_normal", "type": "vec4", "semantic": "NORMAL"},
        {"name": "a_tangent", "type": "vec4", "semantic": "TANGENT"},
        {"name": "a_bitangent", "type": "vec4", "semantic": "BITANGENT"},
        {"name": "a_color0", "type": "vec4", "semantic": "COLOR0"},
        {"name": "a_color1", "type": "vec4", "semantic": "COLOR1"},
        {"name": "a_color2", "type": "vec4", "semantic": "COLOR2"},
        {"name": "a_color3", "type": "vec4", "semantic": "COLOR3"},
        {"name": "a_indices", "type": "vec4", "semantic": "INDICES"},
        {"name": "a_weight", "type": "vec4", "semantic": "WEIGHT"},
        {"name": "a_texcoord0", "type": "vec4", "semantic": "TEXCOORD0"},
        {"name": "a_texcoord1", "type": "vec4", "semantic": "TEXCOORD1"},
        {"name": "a_texcoord2", "type": "vec4", "semantic": "TEXCOORD2"},
        {"name": "a_texcoord3", "type": "vec4", "semantic": "TEXCOORD3"},
        {"name": "a_texcoord4", "type": "vec4", "semantic": "TEXCOORD4"},
        {"name": "a_texcoord5", "type": "vec4", "semantic": "TEXCOORD5"},
        {"name": "a_texcoord6", "type": "vec4", "semantic": "TEXCOORD6"},
        {"name": "a_texcoord7", "type": "vec4", "semantic": "TEXCOORD7"},
        {"name": "i_data0", "type": "vec4", "semantic": "TEXCOORD4"},
        {"name": "i_data1", "type": "vec4", "semantic": "TEXCOORD5"},
        {"name": "i_data2", "type": "vec4", "semantic": "TEXCOORD6"},
        {"name": "i_data3", "type": "vec4", "semantic": "TEXCOORD7"},
        {"name": "i_data4", "type": "vec4", "semantic": "TEXCOORD8"},
    ],
    "varying_semantics": [
        "POSITION", "NORMAL", "TANGENT", "BITANGENT",
        "COLOR0", "COLOR1", "COLOR2", "COLOR3",
        "TEXCOORD0", "TEXCOORD1", "TEXCOORD2", "TEXCOORD3",
        "TEXCOORD4", "TEXCOORD5", "TEXCOORD6", "TEXCOORD7",
        "INDICES", "WEIGHT",
        "SV_POSITION", "SV_DEPTH",
        "SV_TARGET0", "SV_TARGET1", "SV_TARGET2", "SV_TARGET3",
        "SV_TARGET4", "SV_TARGET5", "SV_TARGET6", "SV_TARGET7",
    ],
}

BGFX_VARIABLES = [
    {
        "modifiers": "out",
        "type": "vec4",
        "name": "gl_FragColor",
        "description": [
            "Fragment shader color output. Although deprecated in GLSL 130+, bgfx's `shaderc` cross-compiler expects `gl_FragColor` as the canonical fragment output and translates it to the appropriate target (e.g., `SV_Target` in HLSL, `[[color(0)]]` in Metal).",
            "Use `gl_FragColor` in fragment shaders to write the final color for the default render target."
        ],
    },
    {
        "modifiers": "out",
        "type": "vec4",
        "name": "gl_FragData",
        "description": [
            "Fragment shader multiple render target (MRT) output array. Although deprecated in GLSL 130+, bgfx's `shaderc` cross-compiler translates `gl_FragData[n]` to the appropriate per-target output.",
            "Use `gl_FragData[0]` for the first render target, `gl_FragData[1]` for the second, etc."
        ],
    },
    {
        "modifiers": "out",
        "type": "gl_PerVertex",
        "name": "gl_PerVertex",
        "description": [
            "Output interface block containing per-vertex outputs: `gl_Position` (vec4), `gl_PointSize` (float), `gl_ClipDistance` (float[]), `gl_CullDistance` (float[]).",
            "Used in geometry and tessellation shaders to explicitly redeclare the per-vertex output block.",
            "```glsl\nout gl_PerVertex {\n    vec4 gl_Position;\n    float gl_PointSize;\n    float gl_ClipDistance[];\n};\n```"
        ],
    },
    {
        "modifiers": "in",
        "type": "gl_PerVertex",
        "name": "gl_in",
        "description": [
            "Input array of per-vertex data from the previous shader stage. Each element contains `gl_Position`, `gl_PointSize`, `gl_ClipDistance`, and `gl_CullDistance`.",
            "Available in geometry and tessellation shaders. The array size is determined by the input primitive type.",
            "```glsl\nin gl_PerVertex gl_in[];\n```"
        ],
    },
    {
        "modifiers": "out",
        "type": "gl_PerVertex",
        "name": "gl_out",
        "description": [
            "Output array of per-vertex data to the next shader stage. Each element contains `gl_Position`, `gl_PointSize`, `gl_ClipDistance`, and `gl_CullDistance`.",
            "Available in tessellation control shaders.",
            "```glsl\nout gl_PerVertex gl_out[];\n```"
        ],
    },
]

BGFX_MACROS = [
    {"name": "SAMPLER2D", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "sampler2D", "description": "Declare a 2D texture sampler"},
    {"name": "SAMPLER2DMS", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "sampler2DMS", "description": "Declare a multisampled 2D texture sampler"},
    {"name": "SAMPLER2DARRAY", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "sampler2DArray", "description": "Declare a 2D array texture sampler"},
    {"name": "SAMPLER2DSHADOW", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "sampler2DShadow", "description": "Declare a 2D shadow sampler"},
    {"name": "SAMPLER2DARRAYSHADOW", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "sampler2DArrayShadow", "description": "Declare a 2D array shadow sampler"},
    {"name": "SAMPLER3D", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "sampler3D", "description": "Declare a 3D texture sampler"},
    {"name": "SAMPLERCUBE", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "samplerCube", "description": "Declare a cubemap sampler"},
    {"name": "SAMPLERCUBESHADOW", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "samplerCubeShadow", "description": "Declare a cubemap shadow sampler"},
    {"name": "ISAMPLER2D", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "isampler2D", "description": "Declare an integer 2D sampler"},
    {"name": "USAMPLER2D", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "usampler2D", "description": "Declare an unsigned integer 2D sampler"},
    {"name": "ISAMPLER3D", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "isampler3D", "description": "Declare an integer 3D sampler"},
    {"name": "USAMPLER3D", "params": ["_name", "_reg"], "kind": "sampler", "glsl_type": "usampler3D", "description": "Declare an unsigned integer 3D sampler"},

    {"name": "NUM_THREADS", "params": ["_x", "_y", "_z"], "kind": "thread_declaration", "description": "Declare compute shader thread group size"},

    {"name": "IMAGE2D_RO", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "readonly image2D", "description": "Declare read-only 2D image"},
    {"name": "IMAGE2D_WO", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "writeonly image2D", "description": "Declare write-only 2D image"},
    {"name": "IMAGE2D_RW", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "image2D", "description": "Declare read-write 2D image"},
    {"name": "UIMAGE2D_RO", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "readonly uimage2D", "description": "Declare read-only unsigned 2D image"},
    {"name": "UIMAGE2D_WO", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "writeonly uimage2D", "description": "Declare write-only unsigned 2D image"},
    {"name": "UIMAGE2D_RW", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "uimage2D", "description": "Declare read-write unsigned 2D image"},
    {"name": "IMAGE3D_RO", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "readonly image3D", "description": "Declare read-only 3D image"},
    {"name": "IMAGE3D_WO", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "writeonly image3D", "description": "Declare write-only 3D image"},
    {"name": "IMAGE3D_RW", "params": ["_name", "_format", "_reg"], "kind": "compute_image", "glsl_type": "image3D", "description": "Declare read-write 3D image"},

    {"name": "BUFFER_RO", "params": ["_name", "_type", "_reg"], "kind": "compute_buffer", "description": "Declare read-only shader buffer"},
    {"name": "BUFFER_RW", "params": ["_name", "_type", "_reg"], "kind": "compute_buffer", "description": "Declare read-write shader buffer"},
    {"name": "BUFFER_WO", "params": ["_name", "_type", "_reg"], "kind": "compute_buffer", "description": "Declare write-only shader buffer"},

    {"name": "BRANCH", "params": [], "kind": "flow_control", "description": "Branch hint (HLSL only)"},
    {"name": "LOOP", "params": [], "kind": "flow_control", "description": "Loop hint (HLSL only)"},
    {"name": "UNROLL", "params": [], "kind": "flow_control", "description": "Unroll hint (HLSL only)"},
    {"name": "CONST", "params": ["_x"], "kind": "utility", "description": "Declare constant (static const on HLSL, const on GLSL)"},
    {"name": "EARLY_DEPTH_STENCIL", "params": [], "kind": "utility", "description": "Early depth stencil hint (fragment shader only)"},
    {"name": "SHARED", "params": [], "kind": "utility", "description": "Compute shared memory (shared on GLSL, groupshared on HLSL)"},
    {"name": "FORMAT", "params": ["_format"], "kind": "utility", "description": "Image format qualifier"},
    {"name": "WRITEONLY", "params": [], "kind": "utility", "description": "Non-readable image qualifier"},
    {"name": "REGISTER", "params": ["_type", "_reg"], "kind": "utility", "description": "HLSL register binding"},
    {"name": "mul", "params": ["_a", "_b"], "kind": "utility", "description": "Matrix multiplication (platform-aware argument order)"},
]

BGFX_FUNCTIONS = [
    {"name": "vec2_splat", "return_type": "vec2", "parameters": [{"name": "_x", "type": "float"}], "description": "Create vec2 with all components set to _x"},
    {"name": "vec3_splat", "return_type": "vec3", "parameters": [{"name": "_x", "type": "float"}], "description": "Create vec3 with all components set to _x"},
    {"name": "vec4_splat", "return_type": "vec4", "parameters": [{"name": "_x", "type": "float"}], "description": "Create vec4 with all components set to _x"},
    {"name": "uvec2_splat", "return_type": "uvec2", "parameters": [{"name": "_x", "type": "uint"}], "description": "Create uvec2 with all components set to _x"},
    {"name": "uvec3_splat", "return_type": "uvec3", "parameters": [{"name": "_x", "type": "uint"}], "description": "Create uvec3 with all components set to _x"},
    {"name": "uvec4_splat", "return_type": "uvec4", "parameters": [{"name": "_x", "type": "uint"}], "description": "Create uvec4 with all components set to _x"},

    {"name": "mtxFromRows", "return_type": "mat4", "parameters": [{"name": "_0", "type": "vec4"}, {"name": "_1", "type": "vec4"}, {"name": "_2", "type": "vec4"}, {"name": "_3", "type": "vec4"}], "description": "Construct mat4 from row vectors"},
    {"name": "mtxFromCols", "return_type": "mat4", "parameters": [{"name": "_0", "type": "vec4"}, {"name": "_1", "type": "vec4"}, {"name": "_2", "type": "vec4"}, {"name": "_3", "type": "vec4"}], "description": "Construct mat4 from column vectors"},
    {"name": "mtxFromRows", "return_type": "mat3", "parameters": [{"name": "_0", "type": "vec3"}, {"name": "_1", "type": "vec3"}, {"name": "_2", "type": "vec3"}], "description": "Construct mat3 from row vectors"},
    {"name": "mtxFromCols", "return_type": "mat3", "parameters": [{"name": "_0", "type": "vec3"}, {"name": "_1", "type": "vec3"}, {"name": "_2", "type": "vec3"}], "description": "Construct mat3 from column vectors"},
    {"name": "mtxGetRow", "return_type": "vec4", "parameters": [{"name": "_mtx", "type": "mat4"}, {"name": "_row", "type": "int"}], "description": "Get row of mat4"},
    {"name": "mtxGetColumn", "return_type": "vec4", "parameters": [{"name": "_mtx", "type": "mat4"}, {"name": "_column", "type": "int"}], "description": "Get column of mat4"},
    {"name": "mtxGetRow", "return_type": "vec3", "parameters": [{"name": "_mtx", "type": "mat3"}, {"name": "_row", "type": "int"}], "description": "Get row of mat3"},
    {"name": "mtxGetColumn", "return_type": "vec3", "parameters": [{"name": "_mtx", "type": "mat3"}, {"name": "_column", "type": "int"}], "description": "Get column of mat3"},
    {"name": "mtxGetElement", "return_type": "float", "parameters": [{"name": "_mtx", "type": "mat3"}, {"name": "_column", "type": "int"}, {"name": "_row", "type": "int"}], "description": "Get element of mat3"},
    {"name": "mtxGetElement", "return_type": "float", "parameters": [{"name": "_mtx", "type": "mat4"}, {"name": "_column", "type": "int"}, {"name": "_row", "type": "int"}], "description": "Get element of mat4"},

    {"name": "select", "return_type": "float", "parameters": [{"name": "_cond", "type": "bool"}, {"name": "_true", "type": "float"}, {"name": "_false", "type": "float"}], "description": "Conditional select"},
    {"name": "select", "return_type": "vec2", "parameters": [{"name": "_cond", "type": "bool"}, {"name": "_true", "type": "vec2"}, {"name": "_false", "type": "vec2"}], "description": "Conditional select"},
    {"name": "select", "return_type": "vec3", "parameters": [{"name": "_cond", "type": "bool"}, {"name": "_true", "type": "vec3"}, {"name": "_false", "type": "vec3"}], "description": "Conditional select"},
    {"name": "select", "return_type": "vec4", "parameters": [{"name": "_cond", "type": "bool"}, {"name": "_true", "type": "vec4"}, {"name": "_false", "type": "vec4"}], "description": "Conditional select"},

    {"name": "texture2D", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "vec2"}], "description": "Sample 2D texture"},
    {"name": "texture2DBias", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "vec2"}, {"name": "_bias", "type": "float"}], "description": "Sample 2D texture with bias"},
    {"name": "texture2DLod", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "vec2"}, {"name": "_level", "type": "float"}], "description": "Sample 2D texture at specific LOD"},
    {"name": "texture2DLodOffset", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "vec2"}, {"name": "_level", "type": "float"}, {"name": "_offset", "type": "ivec2"}], "description": "Sample 2D texture at specific LOD with offset"},
    {"name": "texture2DProj", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "vec3"}], "description": "Sample 2D texture with projection"},
    {"name": "texture2DGrad", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "vec2"}, {"name": "_dPdx", "type": "vec2"}, {"name": "_dPdy", "type": "vec2"}], "description": "Sample 2D texture with explicit gradients"},
    {"name": "texture2DArray", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2DArray"}, {"name": "_coord", "type": "vec3"}], "description": "Sample 2D array texture"},
    {"name": "texture2DArrayLod", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2DArray"}, {"name": "_coord", "type": "vec3"}, {"name": "_lod", "type": "float"}], "description": "Sample 2D array texture at specific LOD"},
    {"name": "texture3D", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler3D"}, {"name": "_coord", "type": "vec3"}], "description": "Sample 3D texture"},
    {"name": "texture3DLod", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler3D"}, {"name": "_coord", "type": "vec3"}, {"name": "_level", "type": "float"}], "description": "Sample 3D texture at specific LOD"},
    {"name": "textureCube", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "samplerCube"}, {"name": "_coord", "type": "vec3"}], "description": "Sample cubemap"},
    {"name": "textureCubeBias", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "samplerCube"}, {"name": "_coord", "type": "vec3"}, {"name": "_bias", "type": "float"}], "description": "Sample cubemap with bias"},
    {"name": "textureCubeLod", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "samplerCube"}, {"name": "_coord", "type": "vec3"}, {"name": "_level", "type": "float"}], "description": "Sample cubemap at specific LOD"},
    {"name": "shadow2D", "return_type": "float", "parameters": [{"name": "_sampler", "type": "sampler2DShadow"}, {"name": "_coord", "type": "vec3"}], "description": "Sample shadow map"},
    {"name": "shadow2DProj", "return_type": "float", "parameters": [{"name": "_sampler", "type": "sampler2DShadow"}, {"name": "_coord", "type": "vec4"}], "description": "Sample shadow map with projection"},
    {"name": "shadow2DArray", "return_type": "float", "parameters": [{"name": "_sampler", "type": "sampler2DArrayShadow"}, {"name": "_coord", "type": "vec4"}], "description": "Sample shadow array"},
    {"name": "shadowCube", "return_type": "float", "parameters": [{"name": "_sampler", "type": "samplerCubeShadow"}, {"name": "_coord", "type": "vec4"}], "description": "Sample cube shadow map"},
    {"name": "texelFetch", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "ivec2"}, {"name": "_lod", "type": "int"}], "description": "Fetch texel at integer coordinates"},
    {"name": "texelFetchOffset", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "ivec2"}, {"name": "_lod", "type": "int"}, {"name": "_offset", "type": "ivec2"}], "description": "Fetch texel with offset"},
    {"name": "textureSize", "return_type": "ivec2", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_lod", "type": "int"}], "description": "Get texture dimensions"},
    {"name": "textureGather", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "vec2"}, {"name": "_comp", "type": "int"}], "description": "Gather texture samples"},
    {"name": "textureGatherOffset", "return_type": "vec4", "parameters": [{"name": "_sampler", "type": "sampler2D"}, {"name": "_coord", "type": "vec2"}, {"name": "_offset", "type": "ivec2"}, {"name": "_comp", "type": "int"}], "description": "Gather texture samples with offset"},

    {"name": "rcp", "return_type": "float", "parameters": [{"name": "_a", "type": "float"}], "description": "Reciprocal (1/a)"},
    {"name": "rcp", "return_type": "vec2", "parameters": [{"name": "_a", "type": "vec2"}], "description": "Reciprocal (component-wise)"},
    {"name": "rcp", "return_type": "vec3", "parameters": [{"name": "_a", "type": "vec3"}], "description": "Reciprocal (component-wise)"},
    {"name": "rcp", "return_type": "vec4", "parameters": [{"name": "_a", "type": "vec4"}], "description": "Reciprocal (component-wise)"},
    {"name": "saturate", "return_type": "float", "parameters": [{"name": "_x", "type": "float"}], "description": "Clamp to [0, 1]"},
    {"name": "atan2", "return_type": "float", "parameters": [{"name": "_y", "type": "float"}, {"name": "_x", "type": "float"}], "description": "Arc tangent of y/x"},

    {"name": "encodeRE8", "return_type": "vec4", "parameters": [{"name": "_r", "type": "float"}], "description": "Encode to RE8 format"},
    {"name": "decodeRE8", "return_type": "float", "parameters": [{"name": "_re8", "type": "vec4"}], "description": "Decode from RE8 format"},
    {"name": "encodeRGBE8", "return_type": "vec4", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "Encode to RGBE8 format"},
    {"name": "decodeRGBE8", "return_type": "vec3", "parameters": [{"name": "_rgbe8", "type": "vec4"}], "description": "Decode from RGBE8 format"},
    {"name": "encodeNormalUint", "return_type": "vec3", "parameters": [{"name": "_normal", "type": "vec3"}], "description": "Encode normal to unsigned int format"},
    {"name": "decodeNormalUint", "return_type": "vec3", "parameters": [{"name": "_encoded", "type": "vec3"}], "description": "Decode normal from unsigned int format"},
    {"name": "encodeNormalOctahedron", "return_type": "vec2", "parameters": [{"name": "_normal", "type": "vec3"}], "description": "Encode normal to octahedron format"},
    {"name": "decodeNormalOctahedron", "return_type": "vec3", "parameters": [{"name": "_encoded", "type": "vec2"}], "description": "Decode normal from octahedron format"},
    {"name": "packFloatToRgba", "return_type": "vec4", "parameters": [{"name": "_value", "type": "float"}], "description": "Pack float to RGBA"},
    {"name": "unpackRgbaToFloat", "return_type": "float", "parameters": [{"name": "_rgba", "type": "vec4"}], "description": "Unpack RGBA to float"},
    {"name": "packHalfFloat", "return_type": "vec2", "parameters": [{"name": "_value", "type": "float"}], "description": "Pack float to half"},
    {"name": "unpackHalfFloat", "return_type": "float", "parameters": [{"name": "_rg", "type": "vec2"}], "description": "Unpack half to float"},

    {"name": "toLinear", "return_type": "vec3", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "Convert sRGB to linear (approximate)"},
    {"name": "toLinearAccurate", "return_type": "vec3", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "Convert sRGB to linear (accurate)"},
    {"name": "toGamma", "return_type": "vec3", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "Convert linear to gamma (approximate)"},
    {"name": "toGammaAccurate", "return_type": "vec3", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "Convert linear to gamma (accurate)"},
    {"name": "toReinhard", "return_type": "vec3", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "Reinhard tone mapping"},
    {"name": "toFilmic", "return_type": "vec3", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "Filmic tone mapping"},
    {"name": "toAcesFilmic", "return_type": "vec3", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "ACES filmic tone mapping"},
    {"name": "luma", "return_type": "vec3", "parameters": [{"name": "_rgb", "type": "vec3"}], "description": "Compute luminance"},
    {"name": "random", "return_type": "float", "parameters": [{"name": "_uv", "type": "vec2"}], "description": "Pseudo-random from UV"},
    {"name": "fixCubeLookup", "return_type": "vec3", "parameters": [{"name": "_v", "type": "vec3"}, {"name": "_lod", "type": "float"}, {"name": "_topLevelCubeSize", "type": "float"}], "description": "Fix cubemap seam artifacts"},
    {"name": "cofactor", "return_type": "mat3", "parameters": [{"name": "_m", "type": "mat4"}], "description": "Compute cofactor matrix"},
    {"name": "toClipSpaceDepth", "return_type": "float", "parameters": [{"name": "_depth", "type": "float"}], "description": "Convert depth to clip space"},
    {"name": "clipToWorld", "return_type": "vec3", "parameters": [{"name": "_invViewProj", "type": "mat4"}, {"name": "_clipPos", "type": "vec3"}], "description": "Transform clip space to world space"},

    {"name": "imageLoad", "return_type": "vec4", "parameters": [{"name": "_image", "type": "image2D"}, {"name": "_coord", "type": "ivec2"}], "description": "Load from image"},
    {"name": "imageStore", "return_type": "void", "parameters": [{"name": "_image", "type": "image2D"}, {"name": "_coord", "type": "ivec2"}, {"name": "_value", "type": "vec4"}], "description": "Store to image"},
    {"name": "imageSize", "return_type": "ivec2", "parameters": [{"name": "_image", "type": "image2D"}], "description": "Get image dimensions"},
]


def main():
    with open(SPEC_JSON, "r") as f:
        spec = json.load(f)

    spec["keywords"].extend(BGFX_KEYWORDS)
    spec["types"].extend(BGFX_TYPES)
    spec["variables"].extend(BGFX_VARIABLES)
    spec["builtins"] = BGFX_BUILTINS
    spec["macros"] = BGFX_MACROS
    spec["bgfx_functions"] = BGFX_FUNCTIONS

    with open(BGFX_SPEC_JSON, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")

    size = os.path.getsize(BGFX_SPEC_JSON)
    print(f"Generated {BGFX_SPEC_JSON} ({size:,} bytes)")

    with open(BGFX_SPEC_JSON, "r") as f:
        verify = json.load(f)
    print(f"Verified: {len(verify['keywords'])} keywords, {len(verify['types'])} types, "
          f"{len(verify['variables'])} variables, "
          f"{len(verify['functions'])} GLSL functions, {len(verify['bgfx_functions'])} bgfx functions, "
          f"{len(verify['macros'])} macros, {len(verify['builtins']['uniforms'])} uniforms, "
          f"{len(verify['builtins']['attributes'])} attributes")


if __name__ == "__main__":
    main()
