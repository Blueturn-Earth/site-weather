#version 300 es

// Copyright 2025 Blueturn - Michael Boccara.
// Licensed under CC BY-NC-SA 4.0.
// See https://creativecommons.org/licenses/by-nc-sa/4.0/

precision highp float;

uniform vec3 iResolution;
uniform mat3 view_matrix;
uniform float cam_distance;
uniform float earth_radius;
uniform mat3 sky_matrix;      // ground → J2000 (column-vector multiply)
uniform float sky_ra_offset;  // radians, equirect yaw calibration
uniform float sky_exposure;
uniform vec3 sun_dir;         // unit sun direction in ground space (same as Earth terminator)
uniform sampler2D texSkyEquirect;

in vec2 vertUV;
out vec4 fragColor;

#define Pi 3.14159265359

vec2 fragCoordToUV(vec2 fragCoord)
{
    return (2.0 * fragCoord - iResolution.xy) / min(iResolution.x, iResolution.y)
        * vec2(1.0, -1.0);
}

// Same film / camera convention as epic_earth.frag IntersectEarth.
vec3 viewRay(vec2 film)
{
    float D = max(cam_distance, 1.001);
    vec3 ro = vec3(0.0, 0.0, D);
    return normalize(vec3(film, 0.0) - ro);
}

vec3 sampleEquirect(vec3 j2000Dir)
{
    vec3 d = normalize(j2000Dir);
    // J2000: +X vernal equinox, +Z north celestial pole.
    float ra = atan(d.y, d.x) + sky_ra_offset;
    float dec = asin(clamp(d.z, -1.0, 1.0));
    // Equirect: u = RA/2π (0 at +X), v = 0.5 - Dec/π (north at top).
    vec2 uv = vec2(fract(ra / (2.0 * Pi)), 0.5 - dec / Pi);
    return texture(texSkyEquirect, uv).rgb;
}

// Compact yellow disk — no wide orange corona.
vec3 renderSun(vec3 groundDir, vec3 sunGround)
{
    float sunLen = length(sunGround);
    if (sunLen < 1e-4)
        return vec3(0.0);

    float mu = clamp(dot(normalize(groundDir), sunGround / sunLen), -1.0, 1.0);
    // Stable small-angle distance (avoids acos precision issues near the limb).
    float ang = sqrt(max(0.0, 2.0 - 2.0 * mu));

    float core = smoothstep(0.012, 0.003, ang);
    float glow = exp(-ang * ang * 2200.0);

    vec3 yellow = vec3(1.0, 0.92, 0.55);
    vec3 white = vec3(1.0, 0.98, 0.90);

    return white * core * 5.0 + yellow * glow * 1.4;
}

void main()
{
    vec2 fragCoord = vertUV * iResolution.xy;
    vec2 uv = fragCoordToUV(fragCoord);
    float er = max(earth_radius, 1e-4);
    vec2 film = uv / er;
    vec3 rd = viewRay(film);

    // Row-vector style matching epic_earth: ground = view * view_matrix
    vec3 groundDir = normalize(rd * view_matrix);
    vec3 j2000Dir = sky_matrix * groundDir;

    // Day side toward camera ⇒ dim stars (Hermite smoothstep, flat at ends).
    // view_matrix packing: Earth→camera is (m[0][2], m[1][2], m[2][2]).
    vec3 camFromEarth = normalize(vec3(view_matrix[0][2], view_matrix[1][2], view_matrix[2][2]));
    float day = clamp(dot(normalize(sun_dir), camFromEarth), 0.0, 1.0);
    float dayH = day * day * (3.0 - 2.0 * day);
    float starGain = 1.0 - dayH;

    vec3 col = sampleEquirect(j2000Dir) * sky_exposure * starGain;
    col += renderSun(groundDir, sun_dir);

    fragColor = vec4(col, 1.0);
}
