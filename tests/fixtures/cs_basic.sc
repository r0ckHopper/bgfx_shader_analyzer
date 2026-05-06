NUM_THREADS(8, 8, 1);

#include "bgfx_compute.sh"

BUFFER_RO(data, vec4, 0);
IMAGE2D_WO(output, rgba32f, 1);

void main()
{
    uvec3 dt = gl_GlobalInvocationID.xyz;
    vec4 val = data[dt.x];
    imageStore(output, ivec2(dt.xy), val);
}
