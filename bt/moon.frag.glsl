#version 300 es

// Copyright 2025 Blueturn - Michael Boccara.
// Licensed under CC BY-NC-SA 4.0.
// See https://creativecommons.org/licenses/by-nc-sa/4.0/

precision highp float;

uniform vec3 iResolution;
uniform mat3 view_matrix;
uniform float cam_distance;
uniform float earth_radius;
uniform vec3 moon_center_view; // Earth radii, view space
uniform float moon_radius;     // Earth radii
uniform vec3 sun_dir;          // unit, ground space
uniform sampler2D texMoonDiffuse;
uniform sampler2D texMoonHeight; // grayscale equirect height / bump (not RGB normals)

in vec2 vertUV;
out vec4 fragColor;

#define Pi 3.14159265359

vec2 fragCoordToUV(vec2 fragCoord)
{
    return (2.0 * fragCoord - iResolution.xy) / min(iResolution.x, iResolution.y)
        * vec2(1.0, -1.0);
}

vec3 viewRay(vec2 film)
{
    float D = max(cam_distance, 1.001);
    vec3 ro = vec3(0.0, 0.0, D);
    return normalize(vec3(film, 0.0) - ro);
}

bool intersectSphere(vec3 ro, vec3 rd, vec3 center, float radius, out float tHit, out vec3 normal)
{
    vec3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float h = b * b - c;
    if (h < 0.0) {
        tHit = -1.0;
        normal = vec3(0.0);
        return false;
    }
    float t = -b - sqrt(h);
    if (t < 1e-4) {
        tHit = -1.0;
        normal = vec3(0.0);
        return false;
    }
    tHit = t;
    normal = normalize(ro + rd * t - center);
    return true;
}

// Body frame: +Z toward Earth (tidal lock), +Y from view up.
mat3 moonBodyFromView(vec3 moonCenter)
{
    vec3 zAxis = normalize(-moonCenter);
    vec3 up = vec3(0.0, 1.0, 0.0);
    vec3 xAxis = cross(up, zAxis);
    if (dot(xAxis, xAxis) < 1e-8)
        xAxis = cross(vec3(1.0, 0.0, 0.0), zAxis);
    xAxis = normalize(xAxis);
    vec3 yAxis = cross(zAxis, xAxis);
    return mat3(xAxis, yAxis, zAxis);
}

vec2 moonEquirectUv(vec3 bodyNormal)
{
    float lon = atan(bodyNormal.x, bodyNormal.z);
    float lat = asin(clamp(bodyNormal.y, -1.0, 1.0));
    return vec2(fract(lon / (2.0 * Pi) + 0.5), 0.5 - lat / Pi);
}

// Tangent frame on the unit sphere for equirect UV (lon along T, lat along B).
mat3 moonTbn(vec3 bodyN)
{
    vec3 t = normalize(vec3(bodyN.z, 0.0, -bodyN.x));
    if (dot(t, t) < 1e-6)
        t = vec3(1.0, 0.0, 0.0);
    vec3 b = normalize(cross(bodyN, t));
    t = normalize(cross(b, bodyN));
    return mat3(t, b, bodyN);
}

// Derive tangent-space normal from grayscale height (finite differences).
vec3 normalFromHeight(vec2 uv)
{
    vec2 texel = 1.0 / vec2(textureSize(texMoonHeight, 0));
    // Scale texel step in lon by latitude so polar stretch doesn't explode slopes.
    float lat = (0.5 - uv.y) * Pi;
    float cosLat = max(cos(lat), 0.15);
    float hC = texture(texMoonHeight, uv).r;
    float hL = texture(texMoonHeight, uv - vec2(texel.x, 0.0)).r;
    float hR = texture(texMoonHeight, uv + vec2(texel.x, 0.0)).r;
    float hD = texture(texMoonHeight, uv + vec2(0.0, texel.y)).r;
    float hU = texture(texMoonHeight, uv - vec2(0.0, texel.y)).r;
    // Strength tuned for lunar height maps (craters readable, not plastic).
    const float bumpStrength = 4.0;
    float dU = (hR - hL) * bumpStrength / cosLat;
    float dV = (hU - hD) * bumpStrength;
    return normalize(vec3(-dU, -dV, 1.0));
}

void main()
{
    vec2 fragCoord = vertUV * iResolution.xy;
    vec2 uv = fragCoordToUV(fragCoord);
    float er = max(earth_radius, 1e-4);
    vec2 film = uv / er;

    float D = max(cam_distance, 1.001);
    vec3 ro = vec3(0.0, 0.0, D);
    vec3 rd = viewRay(film);

    float tMoon;
    vec3 nView;
    if (!intersectSphere(ro, rd, moon_center_view, max(moon_radius, 1e-4), tMoon, nView)) {
        fragColor = vec4(0.0);
        return;
    }

    // Depth: Moon only yields when Earth is closer (DSCVR). In Moon view the
    // Moon is nearer, so it can clip a little of the Earth limb.
    float tEarth;
    vec3 nEarth;
    if (intersectSphere(ro, rd, vec3(0.0), 1.0, tEarth, nEarth) && tEarth < tMoon) {
        fragColor = vec4(0.0);
        return;
    }

    mat3 bodyFromView = moonBodyFromView(moon_center_view);
    vec3 bodyN = normalize(transpose(bodyFromView) * nView);
    vec2 moonUv = moonEquirectUv(bodyN);
    vec3 albedo = texture(texMoonDiffuse, moonUv).rgb;

    mat3 tbn = moonTbn(bodyN);
    vec3 bodyNMap = normalize(tbn * normalFromHeight(moonUv));
    vec3 nShaded = normalize(bodyFromView * bodyNMap);

    // sun_dir is ground-space; view = view_matrix * ground (column).
    vec3 sunView = normalize(view_matrix * sun_dir);
    float ndotl = max(dot(nShaded, sunView), 0.0);
    float lit = mix(0.06, 1.0, ndotl);
    lit = mix(lit, smoothstep(-0.02, 0.4, ndotl), 0.55);

    vec3 col = albedo * lit;
    float rim = pow(1.0 - max(dot(nShaded, -rd), 0.0), 3.0) * ndotl;
    col += vec3(0.12, 0.11, 0.10) * rim;

    fragColor = vec4(col, 1.0);
}
