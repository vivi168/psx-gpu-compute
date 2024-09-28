struct Gpustat {
    gpustat: u32,
}

struct Command {
    command: u32,
    zIndex: u32,
    color: u32,
}

struct CommandsListInfo {
    fillRectCount: u32,
    renderPolyCount: u32,
    renderLineCount: u32,
    renderRectCount: u32,
}

@group(0) @binding(0) var<uniform> gpustat: Gpustat;
@group(0) @binding(1) var<uniform> commandsListInfo: CommandsListInfo;
@group(0) @binding(2) var<storage> commandsBuffer: array<Command>;
@group(0) @binding(3) var<storage> vramBuffer16: array<u32>;
@group(0) @binding(4) var<storage, read_write> vramBuffer32: array<atomic<u32>>;

const VRAM_WIDTH: u32 = 1024;

fn BarycentricCoords(v1: vec2f, v2: vec2f, v3: vec2f, p: vec2f) -> vec3f {
    let u = cross(
        vec3f(v3.x - v1.x, v2.x - v1.x, v1.x - p.x),
        vec3f(v3.y - v1.y, v2.y - v1.y, v1.y - p.y)
    );

    if abs(u.z) < 1.0 {
        return vec3f(-1.0, 1.0, 1.0);
    }

    return vec3f(1.0 - (u.x + u.y) / u.z, u.y / u.z, u.x / u.z);
}

// TODO: function to construct zindex | rgba5551
fn PlotPixel(x: u32, y: u32) {
    let i = (y * VRAM_WIDTH + x);

    // newPixel = (zIndex << 16) | color
    atomicMax(&vramBuffer32[i], 0x10007c1f);
}

fn RasterTriangle(v1: vec2f, v2: vec2f, v3: vec2f) {
    let minX = u32(min(min(v1.x, v2.x), v3.x));
    let minY = u32(min(min(v1.y, v2.y), v3.y));
    let maxX = u32(max(max(v1.x, v2.x), v3.x));
    let maxY = u32(max(max(v1.y, v2.y), v3.y));


    for (var y: u32 = minY; y < maxY; y = y + 1) {
        for (var x: u32 = minX; x < maxX; x = x + 1) {
            let bc = BarycentricCoords(v1, v2, v3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            PlotPixel(x, y);
        }
    }
}

@compute @workgroup_size(256)
fn Rasterize(@builtin(global_invocation_id) gid: vec3u) {
    let idx = gid.x;

    if idx >= commandsListInfo.renderPolyCount {
        return;
    }

    RasterTriangle(
        vec2f(463, 121),
        vec2f(673, 228),
        vec2f(486, 421)
    );
}

@compute @workgroup_size(256)
fn InitVram(@builtin(global_invocation_id) gid: vec3u) {
    let idx = gid.x;

    let ri = idx / 2;
    let bi = idx % 2;

    let word = vramBuffer16[ri];
    var byte = 0u;

    if bi % 2 == 1 {
        byte = (word >> 16) & 0xffff;
    } else {
        byte = word & 0xffff;
    }

    atomicStore(&vramBuffer32[idx], byte);
}
