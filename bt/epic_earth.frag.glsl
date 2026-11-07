#version 300 es

// Copyright 2025 Blueturn - Michael Boccara. 
// Licensed under CC BY-NC-SA 4.0.
// See https://creativecommons.org/licenses/by-nc-sa/4.0/

precision highp float;

uniform vec3 iResolution;
uniform sampler2D texEarthGround;
uniform sampler2D texEarthLights;

in vec2 vertUV;
out vec4 fragColor;

#define Pi 3.14159265359
#define d2r(a) ((a)*180.0/Pi)
#define RGB(r,g,b) pow(vec3(float(r), float(g), float(b))/255.0, vec3(2.22))

#define R0 1.0000	// Nomralized Earth radius (6360 km)
#define R1 1.0094	// Atmosphere radius (6420 km) 

uniform vec2 pivotScreenCoord;
uniform bool showZoomCircle;
uniform float zoomCircleRadius;
uniform vec2 pivotLatLonDeg;
uniform float devicePixelRatio;

struct EPICImageInfo
{
    sampler2D texture;
    bool hasData; 
    bool hasTexture; 
    mat3 centroid_matrix;
    float earth_radius;
    float time_sec;
    float mix01;
};
uniform EPICImageInfo epicImage[2];
uniform EPICImageInfo curr_epicImage;
uniform float mixBmEpic;
uniform bool zoomActive;
uniform float zoomFactor;
uniform float mapFactor;
uniform float earthClipMargin;
uniform EPICImageInfo pivot_epicImage;

// Free / GEO camera (view_matrix replaces curr centroid for globe projection).
uniform mat3 view_matrix;
uniform float cam_distance;   // Earth radii; large ≈ orthographic
uniform float eye_offset;     // stereo: eye x in view space (Earth radii); 0 = single view
uniform vec3 sun_dir;         // unit sun direction in ground space
uniform float camera_blend;   // 0 = DSCVR lock, 1 = free GEO
// Half-width of the day/night soft edge in cos(sun) space (~radians near the terminator).
uniform float terminator_width;
uniform float city_lights_gain;
// Live cloud map (equirect RGBA, same coords as Blue Marble); 0 = off.
uniform sampler2D texEarthClouds;
// Two cloud maps blended by clouds_swap (weight of texEarthClouds): time
// interpolation between archive frames, or live old → new crossfade.
uniform sampler2D texEarthCloudsPrev;
uniform float clouds_swap;
uniform float clouds_mix;
// Water mask of each cloud map (matteason specular.jpg, white = sea, clouds
// excluded), blended by clouds_swap like the clouds. Black when a cloud map
// has none (archive frames).
uniform sampler2D texEarthSpecular;
uniform sampler2D texEarthSpecularPrev;
// Sun glint on Blue Marble water; 0 = off.
uniform float glint_gain;
// 0..1: grade Blue Marble + live clouds toward the EPIC camera look
// (paler, less saturated, limb darkening + haze).
uniform float epic_look;
// Night-side EPIC: free-camera dim factor (default 0.11); DSCOVR lift when > 0.
uniform float night_epic_dim;
uniform float night_epic_lift;
/** 1 = fast (playback), 2 = 2×2 supersample (paused / still). */
uniform int earth_aa;

// Fully-zoomed map scale (true ground km at the pivot latitude per physical inch).
const float MAP_ZOOM_KM_PER_INCH = 1000.0;
const float MAP_ZOOM_CSS_PX_PER_INCH = 96.0;
const float EARTH_RADIUS_KM = 6371.0;

vec2 fragCoordToUV(vec2 fragCoord)
{
   return (2.0 * fragCoord-iResolution.xy) / min(iResolution.x, iResolution.y)
    // top-down
    * vec2(1., -1.);
}

vec2 CalcBlueMarbleCoordsRound(in vec3 groundNormal)
{
    float lon = atan(- groundNormal.z, groundNormal.x);
    float lat = atan(length(groundNormal.xz), - groundNormal.y);
    return vec2(lon / (2.0 * Pi), lat / Pi);
}

// Equirect content is 2:1. Wider viewports keep equirect (lon repeats);
// taller than 2:1 switches to Mercator filling the full height.
float mapAspect()
{
    return iResolution.x / iResolution.y;
}

bool useMercatorMap()
{
    return mapAspect() < 2.0;
}

// At aspect=2, mercYMax=π/2 so equatorial scale matches equirect.
// Taller screens raise mercYMax (π at square, beyond toward the poles).
float mercatorYMax()
{
    return Pi / mapAspect();
}

// map_uv.y in [-1,0] across full height (north at top → south at bottom).
// Equirect (aspect≥2): y → lat; x may exceed [0,1] when lon repeats.
// Mercator (aspect<2): y → mercator Y over [-mercYMax, mercYMax]; x in [0,1] = 360°.
vec2 ComputeMapUv(in vec2 fragCoord)
{
    vec2 map_uv;
    map_uv.y = fragCoord.y / iResolution.y * -1.0;
    if (useMercatorMap()) {
        map_uv.x = fragCoord.x / iResolution.x;
    } else {
        float worldsAcross = mapAspect() / 2.0;
        map_uv.x = (fragCoord.x / iResolution.x - 0.5) * worldsAcross + 0.5;
    }
    return map_uv;
}

vec2 MapUvToLonLat(in vec2 uv)
{
    float lonRad = uv.x * 2.0 * Pi;
    float latRad;
    if (useMercatorMap()) {
        float mercY = (uv.y + 0.5) * 2.0 * mercatorYMax();
        latRad = atan(sinh(mercY));
    } else {
        latRad = (uv.y + 0.5) * Pi;
    }
    return vec2(lonRad, latRad);
}

// Geographic lat/lon (degrees) → ground normal (matches gCalcLatLonNorthRotationMatrix Z axis).
vec3 GeoLatLonDegToGroundNormal(vec2 latLonDeg)
{
    float lat = latLonDeg.x * Pi / 180.0;
    float lon = latLonDeg.y * Pi / 180.0;
    return vec3(
        -cos(lat) * cos(lon),
        -sin(lat),
        cos(lat) * sin(lon));
}

vec2 GeoLatLonDegToMercator(vec2 latLonDeg)
{
    float lat = clamp(latLonDeg.x * Pi / 180.0, -1.48352986, 1.48352986);
    float lon = latLonDeg.y * Pi / 180.0;
    return vec2(lon, atanh(sin(lat)));
}

vec2 MercatorToGeoLatLonDeg(vec2 merc)
{
    return vec2(atan(sinh(merc.y)), merc.x) * (180.0 / Pi);
}

// Mercator zoom around pivot geo pos at MAP_ZOOM_KM_PER_INCH (north-up, east-right).
vec2 MapZoomMercatorGeoLatLonDeg(vec2 fragCoord)
{
    vec2 pressFrag = vec2(pivotScreenCoord.x, iResolution.y - pivotScreenCoord.y);
    vec2 pixelDelta = fragCoord - pressFrag;

    float latRad = clamp(pivotLatLonDeg.x * Pi / 180.0, -1.48352986, 1.48352986);
    float cosLat = max(abs(cos(latRad)), 0.08); // ≥ cos(85°) — avoid huge sec(lat) near poles
    float pixelsPerInch = MAP_ZOOM_CSS_PX_PER_INCH * max(devicePixelRatio, 1e-3);
    float groundKmPerPixel = MAP_ZOOM_KM_PER_INCH / pixelsPerInch;
    float mercRadPerPixel = (groundKmPerPixel / cosLat) / EARTH_RADIUS_KM;

    vec2 mercDelta = vec2(pixelDelta.x, pixelDelta.y) * mercRadPerPixel;
    // Keep mercY in a range where sinh() stays finite in mediump/highp.
    vec2 merc = GeoLatLonDegToMercator(vec2(latRad * (180.0 / Pi), pivotLatLonDeg.y)) + mercDelta;
    merc.y = clamp(merc.y, -8.0, 8.0);
    return MercatorToGeoLatLonDeg(merc);
}

// Blue Marble is equirectangular; fract(x) tiles longitude when the view is wider than 2:1.
vec2 CalcBlueMarbleCoordsMap(in vec2 uv)
{
    // y in [0, 1] (0 = the texture's top row): the textures clamp in y, so a negative
    // y would sample their edge row only (the map was one flat colour without EPIC).
    float lonU = fract(uv.x);
    if (!useMercatorMap())
        return vec2(lonU, uv.y + 1.0);
    vec2 lonLat = MapUvToLonLat(uv);
    return vec2(lonU, lonLat.y / Pi + 0.5);
}

// Per-sample caches: bmCoords is fixed within one Render(), but clouds and the
// water mask are read by several helpers (BM, glint, terminator lights).
bool gCloudsValid;
vec4 gClouds;
bool gWaterValid;
float gWater;

// Cloud map at any coords (uncached): the shadow reads it away from bmCoords.
vec4 SampleCloudsAt(in vec2 coords)
{
    vec4 curr = texture(texEarthClouds, coords);
    return clouds_swap >= 1.0
        ? curr
        : mix(texture(texEarthCloudsPrev, coords), curr, clouds_swap);
}

vec4 SampleClouds(in vec2 bmCoords)
{
    if (gCloudsValid)
        return gClouds;
    gClouds = SampleCloudsAt(bmCoords);
    gCloudsValid = true;
    return gClouds;
}

// Water mask (1 = sea, 0 = land or cloud) matching the cloud maps on screen.
float SampleWater(in vec2 bmCoords)
{
    if (clouds_mix <= 0.0)
        return 0.0;
    if (!gWaterValid) {
        float curr = texture(texEarthSpecular, bmCoords).r;
        gWater = clouds_swap >= 1.0
            ? curr
            : mix(texture(texEarthSpecularPrev, bmCoords).r, curr, clouds_swap);
        gWaterValid = true;
    }
    return gWater;
}

// EPIC look, fitted against a real EPIC frame vs the EUMETSAT composite of
// nearly the same cloud state (2026-10-04 22:36 / 10-05 00:00 UTC).
// EPIC is paler and less saturated: thick cloud 0.91 → 0.79, clear sea
// (0.14,0.19,0.33) → (0.15,0.19,0.27), strong limb darkening + grey-blue haze.
const float EPIC_SAT = 0.95;          // global saturation
const float EPIC_GAIN = 0.92;        // global brightness
const float EPIC_GROUND_SAT = 0.90;   // extra on BM ocean
// BM ocean is a darker, purpler navy than EPIC's teal-ish blue (clear sea, same
// disc area: EPIC ≈ (51,62,77) vs BM ≈ (41,47,69) /255): lift it, red and green most.
const vec3 EPIC_SEA_GAIN = vec3(1.37, 1.37, 1.11);
// BM land vs clear-sky EPIC land (Sahara 10-04 10:00, Amazon 15:24 UTC):
// deserts browner/orange, forests darker olive. Red-biased gain keeps
// chroma (a pure median fit desaturated land to grey). Land via the water mask.
const float EPIC_LAND_SAT = 0.70;
const vec3 EPIC_LAND_GAIN = vec3(0.80, 0.66, 0.53);
const float EPIC_CLOUD_ALPHA_POW = 1.8; // thin EUMETSAT cirrus too opaque
const float EPIC_LIMB_POW = 0.67;     // col *= cos(sun)^k (≈ mu at DSCOVR phase)
const vec3 EPIC_HAZE = vec3(0.28, 0.31, 0.36); // in-scatter at grazing view
const float EPIC_HAZE_POW = 2.35;     // haze *= (1 - mu)^p
// EPIC whites/sea are warmer than EUMETSAT's cool blue-white.
const vec3 EPIC_WARM = vec3(1.03, 1.01, 0.96);

vec3 Saturate(vec3 c, float s)
{
    float l = (c.r + c.g + c.b) / 3.0;
    return vec3(l) + (c - vec3(l)) * s;
}

// Blue Marble sample with mip selection that survives the longitude seam. Where
// bmCoords.x wraps it jumps by ~1, so its plain derivatives pick the smallest mip
// and draw a line. The wrap sits at a different place per projection, so take the
// gradients of whichever of three equivalent (REPEAT) longitudes is continuous here:
//   x               globe: atan()/2π ∈ [-0.5, 0.5] jumps at ±0.5 (meridian 0), fine at 0
//   fract(x)        continuous across ±0.5 (globe), jumps at 0
//   fract(x + 0.5)  continuous across 0 / 1 (map mode: fract(uv.x))
vec3 SampleGround(in vec2 bmCoords)
{
    vec2 dx = dFdx(bmCoords);
    vec2 dy = dFdy(bmCoords);
    float best = abs(dx.x) + abs(dy.x);

    vec2 wrapped = vec2(fract(bmCoords.x), bmCoords.y);
    vec2 dxW = dFdx(wrapped);
    vec2 dyW = dFdy(wrapped);
    float w = abs(dxW.x) + abs(dyW.x);
    if (w < best) {
        best = w;
        dx = dxW;
        dy = dyW;
    }

    vec2 shifted = vec2(fract(bmCoords.x + 0.5), bmCoords.y);
    vec2 dxS = dFdx(shifted);
    vec2 dyS = dFdy(shifted);
    if (abs(dxS.x) + abs(dyS.x) < best) {
        dx = dxS;
        dy = dyS;
    }
    return textureGrad(texEarthGround, bmCoords, dx, dy).rgb;
}

// Cloud shadow on the ground. Clouds sit cloud_height_km up (Settings, 0-50 km,
// 0 = off; real clouds are 1-10 km, so the shadow lands only a few cloud-map pixels from
// the cloud, more toward the terminator): the ground point is shadowed when the
// cloud at the sun ray's hit on that shell is opaque.
uniform float cloud_height_km;
const float CLOUD_SHADOW_STRENGTH = 0.45;      // darkening under fully opaque cloud
// Cap near the terminator (no smear), as a multiple of the height (≈ 85° sun zenith).
const float CLOUD_SHADOW_MAX_OFFSET_PER_HEIGHT = 12.0;

// Inverse of CalcBlueMarbleCoordsRound: ground normal of a Blue Marble texel
// (globe, zoom and map all end in these texture coords).
vec3 BmCoordsToNormal(in vec2 bm)
{
    float lon = bm.x * 2.0 * Pi;
    float colat = clamp(bm.y, 0.0, 1.0) * Pi;
    float r = sin(colat);
    return vec3(r * cos(lon), -cos(colat), -r * sin(lon));
}

// Darkening factor 0..CLOUD_SHADOW_STRENGTH of the ground at bmCoords.
float CloudShadow(in vec2 bmCoords)
{
    // Uniform conditions: off skips the whole shadow, extra cloud taps included.
    if (clouds_mix <= 0.0 || cloud_height_km <= 0.0)
        return 0.0;
    vec3 n = BmCoordsToNormal(bmCoords);
    float c = dot(n, sun_dir);
    float sunUp = smoothstep(0.0, 0.15, c);   // none on the night side
    if (sunUp <= 0.0)
        return 0.0;
    // Sun ray n + t*sun_dir meets the shell of radius 1+h: t² + 2ct = 2h + h².
    // Written as (2h + h²) / (c + sqrt(..)): the other form cancels in float32.
    float h = cloud_height_km / EARTH_RADIUS_KM;
    float t = (2.0 * h + h * h) / (c + sqrt(c * c + 2.0 * h + h * h));
    t = min(t, CLOUD_SHADOW_MAX_OFFSET_PER_HEIGHT * h);
    vec2 casterCoords = CalcBlueMarbleCoordsRound(normalize(n + t * sun_dir));
    float a = SampleCloudsAt(casterCoords).a;
    a = mix(a, pow(a, EPIC_CLOUD_ALPHA_POW), epic_look); // same as the visible cloud
    return CLOUD_SHADOW_STRENGTH * a * clouds_mix * sunUp;
}

vec3 RenderBlueMarble(in vec2 bmCoords)
{
    vec3 ground = pow(SampleGround(bmCoords), vec3(0.45));
    if (epic_look > 0.0) {
        float land = 1.0 - SampleWater(bmCoords);
        vec3 sea = Saturate(ground, EPIC_GROUND_SAT) * EPIC_SEA_GAIN;
        vec3 soil = Saturate(ground, EPIC_LAND_SAT) * EPIC_LAND_GAIN;
        ground = mix(ground, mix(sea, soil, land), epic_look);
    }
    ground *= 1.0 - CloudShadow(bmCoords);
    vec3 col = ground;
    if (clouds_mix > 0.0) {
        vec4 clouds = SampleClouds(bmCoords);
        float a = mix(clouds.a, pow(clouds.a, EPIC_CLOUD_ALPHA_POW), epic_look);
        col = mix(ground, clouds.rgb, a * clouds_mix);
    }
    return mix(col, Saturate(col, EPIC_SAT) * EPIC_GAIN * EPIC_WARM, epic_look);
}

// Diffuse sun shading of Blue Marble + clouds: ambient + Lambert, one smooth
// curve across the terminator (no day/night seam), same on ground and clouds.
// The terminator gradient spans ±BM_TERMINATOR_DEG of sun elevation (≈ longitude
// at the equator): dark → the Lambert level there, then Lambert takes over.
const float BM_AMBIENT = 0.09;        // night-side floor on ground (sky / moon light)
const float BM_CLOUD_AMBIENT = 0.24;  // same on clouds: brighter, so they stay readable
const float BM_TERMINATOR_HALF = 0.05;
float BlueMarbleShade(float sunDot, float cloud)
{
    float ambient = mix(BM_AMBIENT, BM_CLOUD_AMBIENT, cloud);
    float edge = smoothstep(-BM_TERMINATOR_HALF, BM_TERMINATOR_HALF, sunDot);
    float lambert = edge * max(sunDot, BM_TERMINATOR_HALF);
    return ambient + (1.0 - ambient) * pow(lambert, EPIC_LIMB_POW);
}

// Share of live cloud in the shown Blue Marble pixel (as composed in RenderBlueMarble).
float BlueMarbleCloudAmount(in vec2 bmCoords)
{
    if (clouds_mix <= 0.0)
        return 0.0;
    float a = SampleClouds(bmCoords).a;
    return mix(a, pow(a, EPIC_CLOUD_ALPHA_POW), epic_look) * clouds_mix;
}

// EPIC photos carry no cloud mask: clouds are the bright-ish, near-grey pixels
// (sea, land and vegetation are clearly more saturated). 0..1.
float EpicCloudiness(vec3 rgb)
{
    float mx = max(rgb.r, max(rgb.g, rgb.b));
    float sat = (mx - min(rgb.r, min(rgb.g, rgb.b))) / max(mx, 1e-4);
    float lum = dot(rgb, vec3(0.30, 0.59, 0.11));
    return (1.0 - smoothstep(0.10, 0.24, sat)) * smoothstep(0.07, 0.22, lum);
}
// Night-side EPIC (free-camera remnant, DSCOVR lift): clouds get this much extra.
const float EPIC_NIGHT_CLOUD_BOOST = 2.0;

// Globe-only: diffuse sun shading + Rayleigh-ish haze toward the limb.
// mu = cos(view angle) (1 = disc centre, 0 = limb).
vec3 AddLimbScattering(vec3 col, float mu, float sunDot, float cloud)
{
    if (epic_look <= 0.0)
        return col;
    float shade = BlueMarbleShade(sunDot, cloud);
    float lit = smoothstep(-BM_TERMINATOR_HALF, BM_TERMINATOR_HALF, sunDot);
    vec3 hazed = col * shade + EPIC_HAZE * pow(1.0 - mu, EPIC_HAZE_POW) * lit;
    return mix(col, hazed, epic_look);
}

float CloudCover(in vec2 bmCoords)
{
    return clouds_mix > 0.0 ? SampleClouds(bmCoords).a * clouds_mix : 0.0;
}

// Blinn-Phong sun glint over water, blocked by live clouds. EPIC already has
// the real glint, so this is for Blue Marble only. viewDir: ground space, to camera.
vec3 AddSunGlint(vec3 col, vec3 groundNormal, vec3 viewDir, vec2 bmCoords)
{
    if (glint_gain <= 0.0)
        return col;
    float water = SampleWater(bmCoords);
    if (water <= 0.0)
        return col;
    float nDotL = max(dot(groundNormal, sun_dir), 0.0);
    vec3 h = normalize(sun_dir + viewDir);
    float spec = pow(max(dot(groundNormal, h), 0.0), 120.0) * nDotL;
    return col + vec3(1.0, 0.97, 0.9) * spec * water
        * (1.0 - CloudCover(bmCoords)) * glint_gain;
}

vec2 CalcEpicCoordsRound(vec3 groundNormal, EPICImageInfo epicImage)
{
    // Epic image rotation from ground
    mat3 invCentroidMatrix = transpose(epicImage.centroid_matrix);
    vec3 epicNormal = groundNormal * invCentroidMatrix;
    return (epicNormal.xy * epicImage.earth_radius - 1.0) / 2.0; // override with rotated uv
}

vec3 CalcEpicCoordsMap(in vec2 uv, EPICImageInfo epicImage)
{
    vec2 lonLat = MapUvToLonLat(uv);
    float lonRad = lonLat.x;
    float latRad = lonLat.y;
    vec3 groundNormal;
    groundNormal.y = sin(latRad);
    float cosLat = cos(latRad);
    groundNormal.x = cosLat * cos(lonRad);
    groundNormal.z = - cosLat * sin(lonRad);
    // Epic image rotation from ground
    mat3 invCentroidMatrix = transpose(epicImage.centroid_matrix);
    vec3 epicNormal = groundNormal * invCentroidMatrix;

    // map crop (letterbox / pole margins outside y in [-1, 0])
    float cropFactor = step(-1.0, uv.y) * (1.0 - step(0.0, uv.y));
    epicNormal.z = mix(-1.0, epicNormal.z, cropFactor);
    return (epicNormal * epicImage.earth_radius - vec3(1.0, 1.0, 0.0)) / 2.0;
}

// Ground normal (the globe's convention, as CalcBlueMarbleCoordsRound reads it) of a map pixel.
vec3 MapGroundNormal(in vec2 uv)
{
    vec2 lonLat = MapUvToLonLat(uv);
    float cosLat = cos(lonLat.y);
    return vec3(cosLat * cos(lonLat.x), sin(lonLat.y), -cosLat * sin(lonLat.x));
}

vec3 RenderEpicImage(vec2 epicCoords, EPICImageInfo epicImage)
{
    if (!epicImage.hasTexture || !epicImage.hasData)
        return vec3(0.0);

    return texture(epicImage.texture, epicCoords).rgb;
}

float signedSqrt(float x) {
    return sign(x) * sqrt(abs(x));
}

// Valid coverage of an EPIC photo: camera-facing AND inside the unit disc.
// Sampling outside this (esp. z<0) yields a badly projected mirror of the disc.
float EpicFrontCoverage(vec3 groundNormal, EPICImageInfo img)
{
    if (!img.hasData)
        return 0.0;
    mat3 invCentroidMatrix = transpose(img.centroid_matrix);
    vec3 epicNormal = groundNormal * invCentroidMatrix;
    // Soften only on the front side — never blend into z<0 (mirror UVs).
    float softZ = mix(0.0, 0.04, camera_blend);
    float facing = smoothstep(0.0, softZ + 0.02, epicNormal.z);
    float r = length(epicNormal.xy);
    float inDisc = smoothstep(1.02, 0.98, r);
    return facing * inDisc;
}

// dayCol = sunlit composite; nightCol = darkened same-EPIC remnant (or black).
// Never re-project EPIC on the night half — nightCol must already be coverage-gated.
vec3 ApplyTerminator(vec3 dayCol, vec3 groundNormal, vec2 bmCoords, vec3 nightCol)
{
    float sunDot = dot(groundNormal, sun_dir);
    // Wide soft twilight band (terminator_width ≈ half-angle in radians near the limb).
    float w = max(terminator_width, 1e-4);
    float day = smoothstep(-w, w, sunDot);

    vec3 base = mix(nightCol, dayCol, day);

    // Dim city lights only on the true night side (not across the twilight band).
    vec3 nightLights = vec3(0.0);
    if (city_lights_gain > 0.0)
        nightLights = texture(texEarthLights, bmCoords).rgb * city_lights_gain
            * (1.0 - 0.7 * CloudCover(bmCoords));
    float lightsMask = smoothstep(0.02, -0.12, sunDot);
    return base + nightLights * lightsMask;
}

// Perspective (or near-ortho) sphere hit in view space. cam at (0,0,cam_distance).
// film = uv / earth_radius (limb near |film|≈1 in the ortho limit).
// Stereo: the eye sits at x = eye_offset (parallel axes, image panned so the Earth
// stays centred), the rays still go through the same film point.
// Closest-approach form: b*b - c cancels catastrophically at L1 (D ≈ 235).
bool IntersectEarth(vec2 film, out vec3 viewNormal, out float hitZ)
{
    float D = max(cam_distance, 1.001);
    vec3 ro = vec3(eye_offset, 0.0, D);
    vec3 d = vec3(film, 0.0) - ro;
    float dl = length(d);
    vec3 rd = d / dl;
    vec3 c = cross(ro, vec3(film, 0.0)) / dl;   // ro x rd
    float h = 1.0 - dot(c, c);
    if (h < 0.0) {
        viewNormal = vec3(0.0);
        hitZ = -1.0;
        return false;
    }
    viewNormal = cross(rd, c) - rd * sqrt(h);   // (ro - rd (rd.ro)) - rd sqrt(h)
    hitZ = viewNormal.z;
    return true;
}

// Classic ortho disk when nearly DSCVR, or when stand-off is so large that
// perspective ≈ ortho but ray hits flicker at the limb (float precision).
// Keep thresholds in sync with bt/utils.js ORTHO_CAMERA_BLEND / ORTHO_CAM_DISTANCE.
bool useOrthoEarthSphere()
{
    // A stereo eye is never ortho: its offset is what makes the two views differ.
    return eye_offset == 0.0 && (camera_blend < 0.05 || cam_distance >= 40.0);
}

// Set by Render(): false when the sample is safely inside/outside the plain
// globe disc, so the paused 2×2 supersample can be skipped for this pixel.
bool gNeedsAA;

vec4 Render(in vec2 fragCoord)
{
    gCloudsValid = false;
    gWaterValid = false;
    gNeedsAA = true;
    vec2 uv = fragCoordToUV(fragCoord);

    // View orientation (DSCVR lock or free GEO camera).
    mat3 viewMatrix = view_matrix;

    vec4 pivot_circle_color = vec4(0.0, 0.0, 0.0, 0.0);
    float pivot_circle_radius = zoomCircleRadius;
    float pivot_circle_descent = 200.0;
    float zoomBlend = zoomActive ? clamp(zoomFactor - 1.0, 0.0, 1.0) : 0.0;
    vec2 press_fragCoord = vec2(pivotScreenCoord.x, iResolution.y - pivotScreenCoord.y);

    if (zoomActive && mapFactor < 0.999)
    {
        // Globe zoom keeps pivotLatLonDeg under pivotScreenCoord (enables grab-pan).
        // If the pivot crosses the limb, clamp to the silhouette so zoom stays engaged
        // instead of falling back to a full-disk (unzoomed) view.
        vec2 nozoom_uv = uv;
        vec2 press_uv = fragCoordToUV(press_fragCoord);
        vec3 pivot_Ground = GeoLatLonDegToGroundNormal(pivotLatLonDeg);
        vec3 pivot_View = pivot_Ground * transpose(viewMatrix);

        const float horizonZ = 0.001;
        float xyLen = length(pivot_View.xy);
        if (pivot_View.z < horizonZ) {
            if (xyLen < 1e-6)
                pivot_View = vec3(0.0, 0.0, 1.0);
            else
                pivot_View = normalize(vec3(pivot_View.xy, horizonZ));
        } else {
            pivot_View = normalize(pivot_View);
        }

        // Film coords of the pivot: ortho = view.xy; perspective = P.xy * D/(D−P.z)
        // (same as bt/utils.js gCalculateScreenCoordFromLatLon). Mismatch here vs
        // IntersectEarth makes zoomed overlays drift in elevation under GEO tilt.
        vec2 pivot_uv;
        if (useOrthoEarthSphere()) {
            pivot_uv = pivot_View.xy * curr_epicImage.earth_radius;
        } else {
            float D = max(cam_distance, 1.001);
            float denom = D - pivot_View.z;
            vec2 film = abs(denom) > 1e-6
                ? pivot_View.xy * (D / denom)
                : pivot_View.xy;
            pivot_uv = film * curr_epicImage.earth_radius;
        }

        // Inverse of the screen zoom bt/utils.js applies to overlays and hit tests:
        //   D = U + t (zf - 1) (U - E) + t^2 (Q - E)
        // (D: zoomed pixel, U: unzoomed, E: pivot unzoomed, Q: pivot on screen,
        // t = zoomBlend). Equal to (D - Q) / zf + E at full zoom; in between a
        // plain lerp of the two would not match it, and overlays (the ISS orbit)
        // would float off the Earth while the zoom is changing.
        float zoomScale = 1.0 + zoomBlend * (zoomFactor - 1.0);
        uv = (uv
              - zoomBlend * zoomBlend * (press_uv - pivot_uv)
              + zoomBlend * (zoomFactor - 1.0) * pivot_uv) / zoomScale;

        if (showZoomCircle)
        {
            float pixelToUVFactor = 1.0 / min(iResolution.x, iResolution.y);
            float globeCircleRadius = pivot_circle_radius / max(zoomFactor - 1.0, 1e-3);
            float globeCircleDescent = pivot_circle_descent / max(zoomFactor - 1.0, 1e-3);
            pivot_circle_color.a =
                smoothstep(
                    globeCircleRadius * pixelToUVFactor,
                    (globeCircleRadius + globeCircleDescent) * pixelToUVFactor,
                    length(uv - pivot_uv)) * 0.9;
        }
    }

    // round normal from UV:
    float earth_radius = curr_epicImage.earth_radius;
    vec2 pixel_uv = uv / earth_radius;

    // Globe mode: skip expensive texture work outside the clip disk (octagon mesh may overshoot).
    // Use return instead of discard — discard breaks ANGLE/D3D11 pixel shader compilation.
    // Alpha 0 so the sky pass shows through when blending.
    float clipRadiusSq = earthClipMargin * earthClipMargin;
    float clipPad = mix(1.0, 1.15, camera_blend);
    if (!zoomActive && mapFactor < 0.01 && dot(pixel_uv, pixel_uv) > clipRadiusSq * clipPad * clipPad) {
        gNeedsAA = false;
        return vec4(0.0);
    }

    // Plain ortho globe: the only hard edge is the limb (terminator, haze and
    // zoom circle are smooth), so supersample just the pixels near it.
    if (!zoomActive && mapFactor < 0.01 && useOrthoEarthSphere()) {
        float pxUv = 2.0 / (min(iResolution.x, iResolution.y) * earth_radius);
        gNeedsAA = abs(length(pixel_uv) - 1.0) < 2.0 * pxUv;
    }

    // DSCVR / map / zoom / far stand-off: classic orthographic sphere.
    // Close free-camera (GEO): perspective intersection.
    vec3 viewNormal;
    float hitZView;
    bool hitEarth;
    if (useOrthoEarthSphere()) {
        float z2 = 1.0 - dot(pixel_uv, pixel_uv);
        hitEarth = z2 >= 0.0;
        viewNormal = hitEarth ? vec3(pixel_uv, signedSqrt(z2)) : vec3(0.0);
        hitZView = hitEarth ? viewNormal.z : -1.0;
    } else {
        hitEarth = IntersectEarth(pixel_uv, viewNormal, hitZView);
        if (!hitEarth) {
            float z2 = 1.0 - dot(pixel_uv, pixel_uv);
            if (z2 >= 0.0) {
                viewNormal = vec3(pixel_uv, signedSqrt(z2));
                hitZView = viewNormal.z;
                hitEarth = true;
            }
        }
    }
    vec3 groundNormal = hitEarth ? (viewNormal * viewMatrix) : vec3(0.0, 0.0, -1.0);

    vec2 bmCoordsMap = vec2(0.0);
    vec2 epicCoords0Map = vec2(0.0);
    vec2 epicCoords1Map = vec2(0.0);
    vec3 mapHit = vec3(0.0, 0.0, -1.0);

    // Default disk: skip mercator / map-zoom UVs (mapFactor and zoomBlend are uniforms).
    if (mapFactor > 0.01 || zoomBlend > 0.0)
    {
        vec2 map_uv = ComputeMapUv(fragCoord);

        bmCoordsMap = CalcBlueMarbleCoordsMap(map_uv);
        epicCoords0Map = CalcEpicCoordsMap(map_uv, epicImage[0]).xy;
        epicCoords1Map = CalcEpicCoordsMap(map_uv, epicImage[1]).xy;
        mapHit = CalcEpicCoordsMap(map_uv, curr_epicImage);
        // The map shows the whole world: only its own crop (letterbox / pole margins)
        // cuts it, not the hemisphere EPIC sees (the rest is Blue Marble, as in free camera).
        mapHit.z = step(-1.0, map_uv.y) * (1.0 - step(0.0, map_uv.y)) * 2.0 - 1.0;

        if (zoomBlend > 0.0)
        {
            vec2 geoDeg = MapZoomMercatorGeoLatLonDeg(fragCoord);
            vec3 geoNormal = GeoLatLonDegToGroundNormal(geoDeg);
            bmCoordsMap = mix(bmCoordsMap, CalcBlueMarbleCoordsRound(geoNormal), zoomBlend);
            epicCoords0Map = mix(epicCoords0Map, CalcEpicCoordsRound(geoNormal, epicImage[0]), zoomBlend);
            epicCoords1Map = mix(epicCoords1Map, CalcEpicCoordsRound(geoNormal, epicImage[1]), zoomBlend);

            mat3 invView = transpose(viewMatrix);
            vec3 zoomEpicNormal = geoNormal * invView;
            vec3 zoomHit = (zoomEpicNormal * curr_epicImage.earth_radius - vec3(1.0, 1.0, 0.0)) / 2.0;
            zoomHit.z = 1.0;
            mapHit = mix(mapHit, zoomHit, zoomBlend);
            // Only remap groundNormal for map zoom — doing this on the globe path
            // made zoomed-globe jump to a mercator-like view once zoomBlend > 0.5.
            if (zoomBlend > 0.5 && mapFactor > 0.5) {
                groundNormal = geoNormal;
                hitEarth = true;
                hitZView = zoomHit.z;
            }
        }
        // Unzoomed map: the pixel's own ground normal drives the terminator and EPIC coverage.
        if (zoomBlend <= 0.5 && mapFactor > 0.5) {
            groundNormal = MapGroundNormal(map_uv);
            hitEarth = true;
            hitZView = 1.0;
        }
    }

    vec2 bmCoordsRound = CalcBlueMarbleCoordsRound(groundNormal);
    vec2 epicCoords0Round = CalcEpicCoordsRound(groundNormal, epicImage[0]);
    vec2 epicCoords1Round = CalcEpicCoordsRound(groundNormal, epicImage[1]);
    // Prefer a select when fully in map mode so any globe-path NaNs cannot leak
    // through mix(a, b, 1) (NaN * 0 is still NaN in GLSL).
    vec2 bmCoords = bmCoordsRound;
    vec2 epicCoords0 = epicCoords0Round;
    vec2 epicCoords1 = epicCoords1Round;
    if (mapFactor > 0.999) {
        bmCoords = bmCoordsMap;
        epicCoords0 = epicCoords0Map;
        epicCoords1 = epicCoords1Map;
    } else if (mapFactor > 0.01) {
        bmCoords = mix(bmCoordsRound, bmCoordsMap, mapFactor);
        epicCoords0 = mix(epicCoords0Round, epicCoords0Map, mapFactor);
        epicCoords1 = mix(epicCoords1Round, epicCoords1Map, mapFactor);
    }

    vec3 bmImage = vec3(0.0);
    if (mixBmEpic < 0.99) {
        bmImage = RenderBlueMarble(bmCoords);
        // Globe: glint, sun shading and limb haze. Map: sun shading only (day / night, no
        // glint, no limb), so Blue Marble is dark on the night side as on the globe.
        bool flatMap = mapFactor > 0.5;
        if (hitEarth && (flatMap || mapFactor < 0.99)) {
            vec3 viewDirView = useOrthoEarthSphere()
                ? vec3(0.0, 0.0, 1.0)
                : normalize(vec3(eye_offset, 0.0, max(cam_distance, 1.001)) - viewNormal);
            vec3 globeImage = flatMap
                ? bmImage
                : AddSunGlint(bmImage, groundNormal, viewDirView * viewMatrix, bmCoords);
            globeImage = AddLimbScattering(globeImage,
                flatMap ? 1.0 : max(dot(viewNormal, viewDirView), 0.0), dot(groundNormal, sun_dir),
                BlueMarbleCloudAmount(bmCoords));
            bmImage = flatMap ? globeImage : mix(globeImage, bmImage, mapFactor);
        }
    }

    float mix01 = curr_epicImage.mix01;
    bool needEpic0 = mix01 < 0.995
        || !epicImage[1].hasTexture || !epicImage[1].hasData;
    bool needEpic1 = mix01 > 0.005
        || !epicImage[0].hasTexture || !epicImage[0].hasData;
    vec3 epicSample0 = vec3(0.0);
    vec3 epicSample1 = vec3(0.0);
    if (needEpic0)
        epicSample0 = RenderEpicImage(epicCoords0, epicImage[0]);
    if (needEpic1)
        epicSample1 = RenderEpicImage(epicCoords1, epicImage[1]);

    vec3 epicImageMix;
    float epicCov;
    if (camera_blend < 0.05 && mapFactor <= 0.5) {
        // Classic DSCVR compositing — do not use free-camera coverage weights.
        // (The map takes the free-camera path below: EPIC where it sees, Blue Marble and night elsewhere.)
        if (!epicImage[0].hasTexture || !epicImage[0].hasData)
            epicImageMix = epicSample1;
        else if (!epicImage[1].hasTexture || !epicImage[1].hasData)
            epicImageMix = epicSample0;
        else
            epicImageMix = mix(epicSample0, epicSample1, vec3(curr_epicImage.mix01));
        epicCov = 1.0;
    } else {
        // Free-camera: closest west/east EPIC discs, crossfaded by lon mix01.
        // Artificial terminator darkens night — do not suppress EPIC by sun here
        // (that forced a fallback look and fought closest-centroid selection).
        float cov0 = EpicFrontCoverage(groundNormal, epicImage[0]);
        float cov1 = EpicFrontCoverage(groundNormal, epicImage[1]);
        float has0 = (epicImage[0].hasTexture && epicImage[0].hasData) ? 1.0 : 0.0;
        float has1 = (epicImage[1].hasTexture && epicImage[1].hasData) ? 1.0 : 0.0;
        float w0 = (1.0 - curr_epicImage.mix01) * has0 * cov0;
        float w1 = curr_epicImage.mix01 * has1 * cov1;
        float wSum = w0 + w1;
        epicImageMix = (wSum > 1e-4)
            ? (epicSample0 * w0 + epicSample1 * w1) / wSum
            : vec3(0.0);
        epicCov = min(wSum, 1.0);

        float epicMixFree = mixBmEpic * epicCov;
        // Day: BM under EPIC limbs. Night: same coverage-gated EPIC, dimmed for lights
        // (no BM haze, no back-face UV — cov already zero outside the unit disc).
        vec3 dayComposite = mix(bmImage, epicImageMix, epicMixFree);
        vec3 nightComposite = epicImageMix * epicMixFree * night_epic_dim
            * (1.0 + EPIC_NIGHT_CLOUD_BOOST * EpicCloudiness(epicImageMix))
            + bmImage * (1.0 - epicMixFree);
        vec3 col = ApplyTerminator(dayComposite, groundNormal, bmCoords, nightComposite);

        float hitZ = mapFactor > 0.999 ? mapHit.z : mix(hitZView, mapHit.z, mapFactor);
        if (!hitEarth && mapFactor < 0.999)
            hitZ = -1.0;
        float cover = step(0.0, hitZ);
        col *= cover;

        if (showZoomCircle && zoomActive)
        {
            float mapCircleA =
                smoothstep(pivot_circle_radius, pivot_circle_radius + pivot_circle_descent,
                    length(fragCoord - press_fragCoord)) * 0.9;
            pivot_circle_color.a = mix(pivot_circle_color.a, mapCircleA, mapFactor);
            col = mix(col, pivot_circle_color.rgb, pivot_circle_color.a);
        }

        return vec4(col, cover);
    }

    float epicMix = mixBmEpic * epicCov;
    vec3 col = mix(bmImage, epicImageMix, epicMix);

    // Artificial day/night from fixed-time sun (free-camera only).
    // Classic path: black night base (no BM/EPIC haze outside free-cam coverage path).
    // mix(..., 0) still evaluates ApplyTerminator — skip it on the default disk.
    if (camera_blend > 0.0)
        col = mix(col, ApplyTerminator(col, groundNormal, bmCoords, bmImage * (1.0 - epicMix)), camera_blend);

    // DSCOVR: slightly lift natural EPIC on the night hemisphere (live-Earth modes).
    if (night_epic_lift > 0.0 && camera_blend < 0.05) {
        float sunDot = dot(groundNormal, sun_dir);
        float w = max(terminator_width, 1e-4);
        float night = 1.0 - smoothstep(-w, w, sunDot);
        col *= 1.0 + night * night_epic_lift
            * (1.0 + EPIC_NIGHT_CLOUD_BOOST * epicMix * EpicCloudiness(col));
    }

    // Sphere hit / map crop:
    float hitZ = mapFactor > 0.999 ? mapHit.z : mix(hitZView, mapHit.z, mapFactor);
    if (!hitEarth && mapFactor < 0.999)
        hitZ = -1.0;
    float cover = step(0.0, hitZ);
    col *= cover;

    if (showZoomCircle && zoomActive)
    {
        // Map zoom: screen-space circle around the pivot (radius already in canvas pixels).
        float mapCircleA =
            smoothstep(pivot_circle_radius, pivot_circle_radius + pivot_circle_descent,
                length(fragCoord - press_fragCoord)) * 0.9;
        pivot_circle_color.a = mix(pivot_circle_color.a, mapCircleA, mapFactor);
        col = mix(col, pivot_circle_color.rgb, pivot_circle_color.a);
    }

    return vec4(col, cover);
}

void main() 
{
    vec2 fragCoord = vertUV * iResolution.xy;

    vec4 centre = Render(fragCoord);
    if (earth_aa <= 1 || !gNeedsAA) {
        fragColor = centre;
        return;
    }

    vec4 tot = vec4(0.0);
    for (int m = 0; m < earth_aa; m++)
    for (int n = 0; n < earth_aa; n++)
    {
        vec2 o = vec2(float(m), float(n)) / float(earth_aa) - 0.5;
        tot += Render(fragCoord + o);
    }
    fragColor = tot / float(earth_aa * earth_aa);
}
