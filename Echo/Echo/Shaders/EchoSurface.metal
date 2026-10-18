//
//  EchoSurface.metal
//  Echo
//
//  Surface shader for the LiDAR mesh. Each surface is a faint fill with a fine
//  world-space grid that shows its shape, faded by horizontal distance from the user so
//  only the nearby room is drawn. Walls and floor are neutral and faint; obstacles
//  (furniture) carry the one accent colour at full strength.
//
//  Everything is computed from RealityKit's own uniforms (view transform, time), so
//  nothing on the CPU has to update as the user walks.
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

constant float kGridSpacing  = 0.25;   // metres between grid lines
constant float kGridWidth    = 1.2;    // line width in pixels
constant float kFullAlphaAt  = 2.2;    // metres: fully visible inside this
constant float kFadedOutAt   = 4.0;    // metres: invisible beyond this

[[visible]]
void echoSurface(realitykit::surface_parameters params)
{
    float3 p    = params.geometry().world_position();
    float3 tint = params.material_constants().base_color_tint();

    // Camera position in world space, from the rigid world->view transform [R t]:
    // the camera is where R c + t = 0, i.e. c = -R^T t.
    float4x4 wv = params.uniforms().world_to_view();
    float3 t = wv[3].xyz;
    float3 camera = -float3(dot(wv[0].xyz, t), dot(wv[1].xyz, t), dot(wv[2].xyz, t));

    float d = distance(p.xz, camera.xz);
    float fade = 1.0 - smoothstep(kFullAlphaAt, kFadedOutAt, d);

    // Grid: distance in pixels to the nearest grid line on each world axis. An axis the
    // surface does not vary along (fwidth ~ 0) is ignored.
    float3 q  = p / kGridSpacing;
    float3 fw = fwidth(q);
    float3 g  = abs(fract(q + 0.5) - 0.5) / max(fw, float3(1e-5));
    g = select(float3(1e9), g, fw > 1e-5);
    float line = 1.0 - smoothstep(0.0, kGridWidth, min(min(g.x, g.y), g.z));

    // Light overlay: the fill is faint so the camera stays bright underneath; the grid
    // carries the shape. Everything fades out with distance.
    // Per-material strength (custom parameter x): walls and floor are faint, obstacles
    // strong, so colour is spent where it matters.
    float strength = params.uniforms().custom_parameter().x;
    if (strength <= 0.0) { strength = 0.5; }
    float alpha = fade * strength * (0.55 + 0.45 * line);

    params.surface().set_base_color(half3(tint));
    params.surface().set_emissive_color(half3(tint) * half(0.15 + 0.5 * line));
    params.surface().set_opacity(half(saturate(alpha)));
}
