struct Gpustat {
    gpustat: u32,
}

struct CommandListsInfo {
    fillRectCount: u32,
    renderPolyCount: u32,
    renderLineCount: u32,
    renderRectCount: u32,
}

struct FillRectCommand {
    z_index: u32,
    color: u32,
    position: u32,
    size: u32,
}

struct Vertex {
    position: u32,
    uv: u32,
    color: u32,
}

struct RenderPolyCommand {
    z_index: u32,
    color: u32,
    vertices: array<Vertex, 3>,
}

@group(0) @binding(0) var<uniform> gpustat: Gpustat;
@group(0) @binding(1) var<storage, read> vramBuffer16: array<u32>;
@group(0) @binding(2) var<storage, read_write> vramBuffer32: array<atomic<u32>>;
@group(0) @binding(3) var<uniform> commandListsInfo: CommandListsInfo;
@group(0) @binding(4) var<storage, read> fillRectCommands: array<FillRectCommand>;
@group(0) @binding(5) var<storage, read> renderPolyCommands: array<RenderPolyCommand>;

const VRAM_WIDTH: u32 = 1024;
const VRAM_HEIGHT: u32 = 512;

fn FinalPixel(color: vec4f, zIndex: u32) -> u32 {
    // TODO: alpha channel (mask bit)
    let rgb555 = u32(color.x * 31.0) | (u32(color.y * 31.0) << 5) | (u32(color.z * 31.0) << 10);

    return rgb555 | (zIndex << 16);
}

fn GetCommandColor(word: u32) -> vec4f {
    let r = word & 0xff;
    let g = (word >> 8) & 0xff;
    let b = (word >> 16) & 0xff;

    return vec4f(f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, 0.0);
}

fn GetVertexPosition(word: u32) -> vec2f {
    let xi = i32(word & 0xffff);
    let yi = i32((word >> 16) & 0xffff);

    let xf = f32((xi << 16) >> 16);
    let yf = f32((yi << 16) >> 16);

    return vec2f(xf, yf);
}

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

fn PlotPixel(x: u32, y: u32, c: u32) {
    let i = (y * VRAM_WIDTH + x);

    atomicMax(&vramBuffer32[i], c);
}

fn RenderFlatTriangle(v1: vec2f, v2: vec2f, v3: vec2f, c: u32) {
    // TODO: clip to current drawing area instead of full vram
    let minX = max(0u, u32(min(min(v1.x, v2.x), v3.x)));
    let minY = max(0u, u32(min(min(v1.y, v2.y), v3.y)));
    let maxX = min(VRAM_WIDTH, u32(max(max(v1.x, v2.x), v3.x)));
    let maxY = min(VRAM_HEIGHT, u32(max(max(v1.y, v2.y), v3.y)));

    for (var y: u32 = minY; y < maxY; y = y + 1) {
        for (var x: u32 = minX; x < maxX; x = x + 1) {
            let bc = BarycentricCoords(v1, v2, v3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            PlotPixel(x, y, c);
        }
    }
}

@compute @workgroup_size(256)
fn RenderPoly(@builtin(global_invocation_id) gid: vec3u) {
    let idx = gid.x;

    if idx >= commandListsInfo.renderPolyCount {
        return;
    }

    let poly = renderPolyCommands[idx];
    let p1 = GetVertexPosition(poly.vertices[0].position);
    let p2 = GetVertexPosition(poly.vertices[1].position);
    let p3 = GetVertexPosition(poly.vertices[2].position);

    // TODO: different RenderTriangle function given command params
    let pixel = FinalPixel(GetCommandColor(poly.color), poly.z_index);

    RenderFlatTriangle(p1, p2, p3, pixel);
}

@compute @workgroup_size(256)
fn FillRect(
    @builtin(global_invocation_id) gid : vec3<u32>,
    @builtin(local_invocation_id) lid : vec3u,
) {
    let idx = gid.x;

    if idx >= commandListsInfo.fillRectCount {
        return;
    }

    let rect = fillRectCommands[idx];
    let start_x = (rect.position & 0x3f) * 16;
    let start_y = (rect.position >> 16) & 0x1ff;
    let width = ((rect.size & 0x3ff) + 0xf) & 0xfffffff0;
    let height = (rect.size >> 16) & 0x1ff;

    let end_x = start_x + width;
    let end_y = start_y + height;

    for (var j = start_y; j < end_y; j = j + 1) {
        for (var i = start_x; i < end_x; i = i + 1) {

            let pixel = FinalPixel(GetCommandColor(rect.color), rect.z_index);
            PlotPixel(i % 1024, j % 512, pixel);
        }
    }
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

    // TODO: 2 atomic store per thread
    // dispatch half workgroups ?
    atomicStore(&vramBuffer32[idx], byte);
}
