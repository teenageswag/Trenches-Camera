#include <metal_stdlib>
using namespace metal;

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler glyphSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
constexpr sampler atlasSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

uint blockHash(uint2 block, uint tick, uint seed) {
    uint h = block.x * 374761393u + block.y * 668265263u + tick * 2246822519u + seed * 3266489917u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

float blockRandom(uint hash) { return float(hash & 0x00ffffffu) / 16777216.0; }

kernel void brightPass(texture2d<float, access::sample> source [[texture(0)]],
                       texture2d<float, access::write> target [[texture(1)]],
                       constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(target.get_width(), target.get_height());
    float3 c = source.sample(linearSampler, uv).rgb;
    float l = luminance(c);
    float weight = smoothstep(p[0].x - 0.08, p[0].x + 0.08, l);
    target.write(float4(c * weight * max(l - p[0].x, 0.0) / max(l, 0.001), 1), gid);
}

float3 ghostSample(texture2d<float, access::sample> bright, float2 uv) {
    float inside = all(uv >= 0.0) && all(uv <= 1.0) ? 1.0 : 0.0;
    float2 chroma = (uv - 0.5) * 0.008;
    return float3(bright.sample(linearSampler, uv + chroma).r, bright.sample(linearSampler, uv).g,
                  bright.sample(linearSampler, uv - chroma).b) * inside;
}

kernel void lensComposite(texture2d<float, access::sample> source [[texture(0)]],
                          texture2d<float, access::sample> bright [[texture(1)]],
                          texture2d<float, access::sample> glow [[texture(2)]],
                          texture2d<float, access::sample> dirt [[texture(3)]],
                          texture2d<float, access::write> target [[texture(4)]],
                          constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(target.get_width(), target.get_height());
    float3 c = source.sample(linearSampler, uv).rgb;
    float3 bloom = glow.sample(linearSampler, uv).rgb;
    c += bloom * p[0].y;
    if (p[0].z > 0 || p[0].w > 0) {
        float3 ghosts = float3(0);
        for (int i = 0; i < 5; ++i) {
            float scale = 0.45 + float(i) * 0.4;
            float2 reflected = 0.5 - (uv - 0.5) * scale;
            float fade = 1.0 - smoothstep(0.2, 0.75, length(reflected - 0.5));
            ghosts += ghostSample(bright, reflected) * fade / (1.0 + float(i) * 0.4);
        }
        float3 illumination = bloom + glow.sample(linearSampler, 1.0 - uv).rgb * 0.5 + ghosts * 0.35;
        c += ghosts * p[0].z;
        c += dirt.sample(linearSampler, uv).rgb * illumination * p[0].w * 16.0;
    }
    target.write(float4(c, 1), gid);
}

float2 corruptedBlockOffset(uint hash, float amount, float block) {
    float2 random = float2(blockRandom(hash * 1664525u + 1013904223u), blockRandom(hash * 22695477u + 1u));
    return round((random * 2.0 - 1.0) * amount / block) * block;
}

kernel void macroblockCorrupt(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::write> target [[texture(1)]],
                             constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    float2 size = float2(target.get_width(), target.get_height());
    float block = p[16].x;
    uint hash = blockHash(uint2(float2(gid) / block), uint(p[17].x), uint(p[16].w));
    float2 offset = blockRandom(hash) < p[16].z ? corruptedBlockOffset(hash, p[16].y, block) : float2(0);
    target.write(source.sample(glyphSampler, (float2(gid) + 0.5 + offset) / size), gid);
}

float2 datamoshBlock(float2 uv, float2 grid) {
    return (floor(uv * grid) + 0.5) / grid;
}

float motionCost(texture2d<float, access::sample> current, texture2d<float, access::sample> previous,
                 float2 origin, float2 offset, float2 block) {
    float2 pixel = 1.0 / float2(current.get_width(), current.get_height());
    float cost = 0;
    for (int y = 0; y < 3; ++y) for (int x = 0; x < 3; ++x) {
        float2 uv = origin + (float2(x, y) + 0.5) * block / 3.0;
        cost += abs(luminance(current.sample(linearSampler, uv).rgb) -
                    luminance(previous.sample(linearSampler, uv + offset * pixel).rgb));
    }
    return cost / 9.0;
}

// Store one backward prediction vector per block in normalized image coordinates.
kernel void estimateMotion(texture2d<float, access::sample> current [[texture(0)]],
                           texture2d<float, access::sample> previous [[texture(1)]],
                           texture2d<float, access::write> field [[texture(2)]],
                           constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float2 grid = float2(field.get_width(), field.get_height());
    float2 block = 1.0 / grid;
    float2 origin = float2(gid) * block;
    float stationary = motionCost(current, previous, origin, float2(0), block);
    float best = stationary;
    float2 vector = float2(0);
    if (stationary > 0.006) {
        for (int stepSize = int(p[0].x); stepSize >= 1; stepSize /= 2) {
            float2 center = vector;
            for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
                if (x == 0 && y == 0) continue;
                float2 candidate = center + float2(x, y) * stepSize;
                float cost = motionCost(current, previous, origin, candidate, block) + length(candidate) * 0.00035;
                if (cost < best) { best = cost; vector = candidate; }
            }
        }
    }
    if (stationary - best < 0.004) vector = float2(0);
    field.write(float4(vector / float2(current.get_width(), current.get_height()), stationary, 0), gid);
}

kernel void copyFrame(texture2d<float, access::sample> source [[texture(0)]],
                      texture2d<float, access::write> target [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    float2 uv = (float2(gid) + 0.5) / float2(target.get_width(), target.get_height());
    target.write(source.sample(glyphSampler, uv), gid);
}

// Coarse-to-fine iterative Lucas-Kanade on the canonical analysis image.
kernel void opticalFlow(texture2d<float, access::sample> current [[texture(0)]],
                        texture2d<float, access::sample> previous [[texture(1)]],
                        texture2d<float, access::sample> coarse [[texture(2)]],
                        texture2d<float, access::write> target [[texture(3)]],
                        constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float2 size = float2(target.get_width(), target.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float2 vector = p[0].x > 0.5 ? coarse.sample(linearSampler, uv).xy * size / float2(coarse.get_width(), coarse.get_height()) : float2(0);
    float xx = 0.001, yy = 0.001, xy = 0, xt = 0, yt = 0;
    for (int y = -2; y <= 2; ++y) for (int x = -2; x <= 2; ++x) {
        float2 point = uv + float2(x, y) / size;
        float2 warped = point + vector / size;
        float dx = (luminance(previous.sample(linearSampler, warped + float2(1.0 / size.x, 0)).rgb) -
                    luminance(previous.sample(linearSampler, warped - float2(1.0 / size.x, 0)).rgb)) * 0.5;
        float dy = (luminance(previous.sample(linearSampler, warped + float2(0, 1.0 / size.y)).rgb) -
                    luminance(previous.sample(linearSampler, warped - float2(0, 1.0 / size.y)).rgb)) * 0.5;
        float dt = luminance(previous.sample(linearSampler, warped).rgb) - luminance(current.sample(linearSampler, point).rgb);
        xx += dx * dx; yy += dy * dy; xy += dx * dy; xt += dx * dt; yt += dy * dt;
    }
    float2 update = float2(xy * yt - yy * xt, xy * xt - xx * yt) / max(xx * yy - xy * xy, 0.000001);
    target.write(float4(clamp(vector + clamp(update, -3.0, 3.0), -64.0, 64.0), 0, 0), gid);
}

kernel void flowToBlocks(texture2d<float, access::sample> current [[texture(0)]],
                         texture2d<float, access::sample> previous [[texture(1)]],
                         texture2d<float, access::sample> flow [[texture(2)]],
                         texture2d<float, access::write> target [[texture(3)]], uint2 gid [[thread_position_in_grid]]) {
    float2 block = 1.0 / float2(target.get_width(), target.get_height());
    float2 origin = float2(gid) * block;
    float2 uv = origin + block * 0.5;
    float difference = motionCost(current, previous, origin, float2(0), block);
    float2 vector = round(flow.sample(linearSampler, uv).xy) / float2(flow.get_width(), flow.get_height());
    target.write(float4(difference > 0.008 ? vector : float2(0), difference, 0), gid);
}

kernel void motionActivity(texture2d<float, access::read> field [[texture(0)]],
                           device atomic_uint *activity [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (field.read(gid).z > 0.017) atomic_fetch_add_explicit(activity, 1u, memory_order_relaxed);
}

// Prediction instructions are made against the CLEAN reference. Using the damaged
// reference here would immediately compensate for the glitch on the next frame.
kernel void datamoshResidual(texture2d<float, access::sample> current [[texture(0)]],
                             texture2d<float, access::sample> previous [[texture(1)]],
                             texture2d<float, access::sample> field [[texture(2)]],
                             texture2d<float, access::write> target [[texture(3)]],
                             constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float2 uv = (float2(gid) + 0.5) / float2(target.get_width(), target.get_height());
    float2 grid = float2(field.get_width(), field.get_height());
    float3 delta = current.sample(glyphSampler, uv).rgb -
                   previous.sample(glyphSampler, uv + field.sample(glyphSampler, datamoshBlock(uv, grid)).xy).rgb;
    float y = luminance(delta);
    float3 residual = float3(y, delta.b - y, delta.r - y);
    float3 quantum = mix(0.024, 0.13, p[0].x) * float3(1.0, 1.8, 1.8);
    residual = clamp(round(residual / quantum) * quantum, -0.34, 0.34);
    target.write(float4(residual, 0), gid);
}

kernel void datamoshDecode(texture2d<float, access::sample> current [[texture(0)]],
                           texture2d<float, access::sample> history [[texture(1)]],
                           texture2d<float, access::sample> anchor [[texture(2)]],
                           texture2d<float, access::sample> field [[texture(3)]],
                           texture2d<float, access::sample> residual [[texture(4)]],
                           texture2d<float, access::write> target [[texture(5)]],
                           constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float2 uv = (float2(gid) + 0.5) / float2(target.get_width(), target.get_height());
    float2 grid = float2(field.get_width(), field.get_height());
    uint2 block = uint2(uv * grid);
    int mode = int(p[0].x);
    float strength = p[0].y;
    uint age = uint(p[0].z);
    uint seed = uint(p[0].w);
    float4 motion = field.sample(glyphSampler, datamoshBlock(uv, grid));
    float2 vector = motion.xy;
    uint hash = blockHash(block, 0, seed);
    float random = blockRandom(hash);
    bool repair = random < p[3].x;
    float3 output;
    if (mode == 2) {
        bool update = random > strength || motion.z >= p[1].z;
        output = repair || update ? current.sample(glyphSampler, uv).rgb : anchor.sample(glyphSampler, uv).rgb;
    } else if (mode == 4) {
        uint packet = blockHash(block, age / 8, seed);
        bool damaged = random < p[1].w * strength;
        float2 offset = corruptedBlockOffset(packet, 3.0, 1.0) / grid;
        if (repair || !damaged) output = current.sample(glyphSampler, uv).rgb;
        else if (blockRandom(packet * 1664525u) < 0.65) output = history.sample(glyphSampler, uv).rgb;
        else output = history.sample(glyphSampler, uv + offset).rgb;
    } else if (mode == 6) {
        uint period = max(2u, uint(p[2].z));
        uint hold = uint(round(float(period) * p[1].y * strength));
        bool update = (age + hash % period) % period >= hold;
        output = repair || update ? current.sample(glyphSampler, uv).rgb : history.sample(glyphSampler, uv).rgb;
    } else {
        if (mode == 1) vector *= 1.0 + p[1].x * p[3].y * pow(p[1].y, p[3].y);
        if (mode == 5) {
            int kind = int(p[2].x);
            float amount = p[2].y;
            if (kind == 0) vector *= -amount;
            else if (kind == 1) vector *= 1.0 + amount * 3.0;
            else if (kind == 2) {
                float angle = amount * M_PI_F * 0.5;
                vector = float2(vector.x * cos(angle) - vector.y * sin(angle), vector.x * sin(angle) + vector.y * cos(angle));
            } else {
                uint packet = blockHash(block, age / 4, seed);
                vector += corruptedBlockOffset(packet, amount * 2.0, 1.0) / grid;
            }
        }
        // Hard intra refresh, inter prediction, or retain the wrong reference.
        bool intra = random > 0.32 + 0.68 * strength;
        if (repair || intra) output = current.sample(glyphSampler, uv).rgb;
        else if (motion.z < 0.007 && mode != 5) output = history.sample(glyphSampler, uv).rgb;
        else {
            float3 coded = residual.sample(glyphSampler, uv).rgb;
            float3 delta = float3(coded.x + coded.z, coded.x - (0.0722 * coded.y + 0.2126 * coded.z) / 0.7152, coded.x + coded.y);
            output = history.sample(glyphSampler, uv + vector).rgb + delta * (1.0 - 0.76 * strength);
        }
    }
    target.write(float4(clamp(output, 0.0, 1.0), 1.0), gid);
}

kernel void grade(texture2d<float, access::sample> source [[texture(0)]],
                  texture2d<float, access::sample> blurred [[texture(1)]],
                  texture2d<float, access::sample> depth [[texture(2)]],
                  texture2d<float, access::write> target [[texture(3)]],
                  constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    float2 size = float2(target.get_width(), target.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float3 c = source.sample(linearSampler, uv).rgb;
    if (p[0].x > 0.5) {
        float coc = 0;
        if (p[0].y > 0.5 && p[0].z > 0.5) {
            float2 depthUV = (uv - 0.5) * p[2].zw + 0.5;
            float d = depth.sample(linearSampler, depthUV).r;
            if (isfinite(d) && d > 0) coc = smoothstep(p[1].y * 0.5, p[1].y * 1.5, abs(d - p[1].x));
        } else if (p[0].y < 0.5) {
            float2 delta = (uv - p[2].xy) * float2(size.x / size.y, 1);
            coc = smoothstep(p[1].z, p[1].z + 0.2, length(delta));
        }
        c = mix(c, blurred.sample(linearSampler, uv).rgb, coc);
    }
    if (p[3].x > 0.5) {
        c *= exp2(p[3].y);
        float l = max(luminance(c), 0.0);
        c += p[4].x * pow(1.0 - clamp(l, 0.0, 1.0), 2.0) * 0.25;
        c *= 1.0 + p[3].w * smoothstep(0.4, 1.5, l) * 0.6;
        c = max(c, 0.0);
        if (p[3].z > 1.5) c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
        else if (p[3].z > 0.5) c = c / (1.0 + c);
    }
    if (p[5].x > 0.5) {
        c *= float3(1.0 + p[5].y * 0.2, 1.0 + p[5].z * 0.12, 1.0 - p[5].y * 0.2);
        c = mix(float3(luminance(c)), c, p[5].w);
        c = (c - 0.5) * p[6].x + 0.5;
        c = pow(max(c, 0.0), float3(1.0 / p[6].y));
    }
    target.write(float4(clamp(c, 0.0, 1.0), 1), gid);
}

float3 imageSample(texture2d<float, access::sample> source,
                   texture2d<float, access::sample> compressed, float2 uv, constant float4 *p) {
    float3 c = source.sample(linearSampler, uv).rgb;
    if (p[11].x > 0.5) {
        float3 degraded = p[12].x > 0.5 ? compressed.sample(linearSampler, uv).rgb : compressed.sample(glyphSampler, uv).rgb;
        c = mix(c, degraded, p[12].y);
    }
    return c;
}

float3 postSample(texture2d<float, access::sample> source,
                  texture2d<float, access::sample> compressed, float2 uv, constant float4 *p, float2 size) {
    float2 sampleUV = uv;
    if (p[7].x > 0.5 && p[8].w > 1.01) {
        float cell = p[8].w * size.x / 1080.0;
        sampleUV = (floor(uv * size / cell) + 0.5) * cell / size;
    }
    float3 c = imageSample(source, compressed, sampleUV, p);
    if (p[7].x > 0.5) {
        if (p[7].w > 0.001) {
            float2 shift = float2(p[7].w / 1080.0, 0);
            c.r = imageSample(source, compressed, sampleUV + shift, p).r;
            c.b = imageSample(source, compressed, sampleUV - shift, p).b;
        }
        c *= 1.0 - p[7].z * smoothstep(0.2, 0.75, length((uv - 0.5) * float2(0.8, 1)));
    }
    return c;
}

kernel void asciiPrepare(texture2d<float, access::sample> source [[texture(0)]],
                         texture2d<float, access::sample> compressed [[texture(1)]],
                         texture2d<float, access::write> cells [[texture(2)]],
                         constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= cells.get_width() || gid.y >= cells.get_height()) return;
    float2 size = p[12].zw;
    float2 cell = float2(p[9].y, p[9].y * 1.5) * size.x / 1080.0;
    float2 center = (float2(gid) + 0.5) * cell / size;
    float3 original = postSample(source, compressed, center, p, size);
    float signal = clamp(luminance(original), 0.0, 1.0);
    if (p[10].x > 0.5) signal = 1.0 - signal;
    float l = clamp((signal - 0.5) * p[9].z + 0.5, 0.0, 1.0);
    float count = p[10].w;
    float glyph = min(floor(l * count), count - 1.0);
    // Keep a few sparse glyphs in the toe where high contrast would turn every shadow into a space.
    float toe = clamp((signal - 3.0 / 255.0) / (0.40 - 3.0 / 255.0), 0.0, 1.0);
    float shadowGlyph = ceil(sqrt(toe) * clamp(floor(count / 3.0), 1.0, 3.0));
    glyph = max(glyph, shadowGlyph);
    cells.write(float4(original, glyph / 255.0), gid);
}

kernel void finish(texture2d<float, access::sample> source [[texture(0)]],
                   texture2d<float, access::sample> atlas [[texture(1)]],
                   texture2d<float, access::sample> compressed [[texture(2)]],
                   texture2d<float, access::sample> cells [[texture(3)]],
                   texture2d<float, access::write> target [[texture(4)]],
                   constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    float2 size = float2(target.get_width(), target.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    bool fullASCII = p[9].x > 0.5 && p[10].y >= 0.999;
    float3 c = float3(0);
    if (!fullASCII) c = postSample(source, compressed, uv, p, size);
    if (!fullASCII && p[7].x > 0.5) {
        float n = fract(sin(dot(float2(gid), float2(12.9898, 78.233)) + p[8].z * 57.0) * 43758.5453) - 0.5;
        c += n * p[7].y * 0.23;
        float scanBand = step(0.5, fract((float(gid.y) + 0.5) * 1080.0 / size.x / 3.0));
        c *= 1.0 - p[8].x * scanBand * 0.45;
        if (p[8].y > 0.001) {
            float cell = 7.0 * size.x / 1080.0;
            float2 cellUV = (floor(float2(gid) / cell) + 0.5) * cell / size;
            float l = clamp(luminance(postSample(source, compressed, cellUV, p, size)), 0.0, 1.0);
            float radius = sqrt(l) * 0.7;
            float d = length(fract(float2(gid) / cell) - 0.5);
            float ink = 1.0 - smoothstep(radius - 0.06, radius + 0.06, d);
            c = mix(c, float3(ink), p[8].y);
        }
    }
    if (p[9].x > 0.5) {
        float2 cell = float2(p[9].y, p[9].y * 1.5) * size.x / 1080.0;
        float2 position = (float2(gid) + 0.5) / cell;
        float2 cellUV = (floor(position) + 0.5) / float2(cells.get_width(), cells.get_height());
        float4 cellValue = cells.sample(glyphSampler, cellUV);
        float3 original = cellValue.rgb;
        float glyph = round(cellValue.a * 255.0);
        float2 local = fract(position);
        const float2 glyphSize = float2(32, 48);
        // At 6 px one texel read can miss a thin stroke. Up to level 4 the atlas tiles are mip-aligned.
        float lod = clamp(log2(glyphSize.x / cell.x), 0.0, 4.0);
        float2 inset = 0.5 * exp2(ceil(lod)) / glyphSize;
        float2 atlasPixel = (float2(glyph, p[10].z) + clamp(local, inset, 1.0 - inset)) * glyphSize;
        float2 atlasUV = atlasPixel / float2(atlas.get_width(), atlas.get_height());
        float mask = atlas.sample(atlasSampler, atlasUV, level(lod)).r;
        float3 ink = float3(0.91, 0.90, 0.84);
        if (p[9].w > 4.5) ink = mix(p[13].rgb, p[14].rgb, glyph / max(1.0, p[10].w - 1.0));
        else if (p[9].w > 3.5) ink = p[13].rgb;
        else if (p[9].w > 2.5) ink = original;
        else if (p[9].w > 1.5) ink = float3(1.0, 0.62, 0.19);
        else if (p[9].w > 0.5) ink = float3(0.53, 1.0, 0.43);
        float3 ascii = mix(p[15].rgb, ink, mask);
        c = fullASCII ? ascii : mix(c, ascii, p[10].y);
    }
    target.write(float4(clamp(c, 0.0, 1.0), 1), gid);
}

constant float dctBasis[64] = {0.353553391f, 0.353553391f, 0.353553391f, 0.353553391f, 0.353553391f, 0.353553391f, 0.353553391f, 0.353553391f, 0.490392640f, 0.415734806f, 0.277785117f, 0.097545161f, -0.097545161f, -0.277785117f, -0.415734806f, -0.490392640f, 0.461939766f, 0.191341716f, -0.191341716f, -0.461939766f, -0.461939766f, -0.191341716f, 0.191341716f, 0.461939766f, 0.415734806f, -0.097545161f, -0.490392640f, -0.277785117f, 0.277785117f, 0.490392640f, 0.097545161f, -0.415734806f, 0.353553391f, -0.353553391f, -0.353553391f, 0.353553391f, 0.353553391f, -0.353553391f, -0.353553391f, 0.353553391f, 0.277785117f, -0.490392640f, 0.097545161f, 0.415734806f, -0.415734806f, -0.097545161f, 0.490392640f, -0.277785117f, 0.191341716f, -0.461939766f, 0.461939766f, -0.191341716f, -0.191341716f, 0.461939766f, -0.461939766f, 0.191341716f, 0.097545161f, -0.277785117f, 0.415734806f, -0.490392640f, 0.490392640f, -0.415734806f, 0.277785117f, -0.097545161f};
constant float jpegLuma[64] = {
    16,11,10,16,24,40,51,61, 12,12,14,19,26,58,60,55,
    14,13,16,24,40,57,69,56, 14,17,22,29,51,87,80,62,
    18,22,37,56,68,109,103,77, 24,35,55,64,81,104,113,92,
    49,64,78,87,103,121,120,101, 72,92,95,98,112,100,103,99
};
constant float jpegChroma[64] = {
    17,18,24,47,99,99,99,99, 18,21,26,66,99,99,99,99,
    24,26,56,99,99,99,99,99, 47,66,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99, 99,99,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99, 99,99,99,99,99,99,99,99
};

float3 toYCbCr(float3 rgb) {
    return float3(dot(rgb, float3(0.299, 0.587, 0.114)),
                  dot(rgb, float3(-0.168736, -0.331264, 0.5)),
                  dot(rgb, float3(0.5, -0.418688, -0.081312)));
}

// Each 8x8 group performs a separable DCT, JPEG quantization and inverse DCT.
kernel void jpegDegrade(texture2d<float, access::sample> source [[texture(0)]],
                        texture2d<float, access::write> target [[texture(1)]],
                        constant float4 *p [[buffer(0)]],
                        uint2 tid [[thread_position_in_threadgroup]],
                        uint2 group [[threadgroup_position_in_grid]]) {
    threadgroup float3 spatial[64];
    threadgroup float3 stage[64];
    threadgroup float3 frequency[64];
    uint2 pixel = group * 8 + tid;
    uint index = tid.y * 8 + tid.x;
    float2 size = float2(target.get_width(), target.get_height());
    float2 uv = (float2(pixel) + 0.5) / size;
    float3 ycc = toYCbCr(source.sample(linearSampler, uv).rgb);
    float chromaCell = 1.0 + floor(p[11].w * 7.0);
    float2 chromaUV = (floor(float2(pixel) / chromaCell) + 0.5) * chromaCell / size;
    float3 lowColor = toYCbCr(source.sample(linearSampler, chromaUV).rgb);
    ycc.yz = mix(ycc.yz, lowColor.yz, p[11].w);
    spatial[index] = (ycc - float3(0.5, 0, 0)) * 255.0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float3 value = float3(0);
    for (uint k = 0; k < 8; ++k) value += spatial[tid.y * 8 + k] * dctBasis[tid.x * 8 + k];
    stage[index] = value;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    value = float3(0);
    for (uint k = 0; k < 8; ++k) value += stage[k * 8 + tid.x] * dctBasis[tid.y * 8 + k];
    float quality = clamp(p[11].y, 1.0, 100.0);
    float scale = quality < 50 ? 5000.0 / quality : 200.0 - 2.0 * quality;
    float3 quant = clamp(floor((float3(jpegLuma[index], jpegChroma[index], jpegChroma[index]) * scale + 50.0) / 100.0), 1.0, 255.0);
    frequency[index] = round(value / quant) * quant;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    value = float3(0);
    for (uint k = 0; k < 8; ++k) value += frequency[k * 8 + tid.x] * dctBasis[k * 8 + tid.y];
    stage[index] = value;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    value = float3(0);
    for (uint k = 0; k < 8; ++k) value += stage[tid.y * 8 + k] * dctBasis[k * 8 + tid.x];
    ycc = value / 255.0 + float3(0.5, 0, 0);
    float3 rgb = float3(ycc.x + 1.402 * ycc.z,
                        ycc.x - 0.344136 * ycc.y - 0.714136 * ycc.z,
                        ycc.x + 1.772 * ycc.y);
    target.write(float4(clamp(rgb, 0.0, 1.0), 1), pixel);
}
