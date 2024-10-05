struct Gpustat {
    gpustat: u32,
}

struct CommandListsInfo {
    fillRectCount: u32,
    renderPolyCount: u32,
    renderLineCount: u32,
    renderRectCount: u32,
}

struct Vertex {
    position: vec2f,
    uv: vec2u,
    color: vec4f,
}

struct GP0Command {
    code: u32,
    zIndex: u32,
    params: u32,
}

struct FillRectCommand {
    z_index: u32,
    command: u32,
    position: u32,
    size: u32,
}

struct RenderPolyCommand {
    command: GP0Command,
    color: vec4f,
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
    let p1 = poly.vertices[0].position;
    let p2 = poly.vertices[1].position;
    let p3 = poly.vertices[2].position;

    // TODO: different RenderTriangle function given command params
    let pixel = FinalPixel(poly.color, poly.command.zIndex);

    RenderFlatTriangle(
        vec2f(p1.x, p1.y),
        vec2f(p2.x, p2.y),
        vec2f(p3.x, p3.y),
        pixel
    );
}

fn GetCommandColor(word: u32) -> vec4f {
    let r = word & 0xff;
    let g = (word >> 8) & 0xff;
    let b = (word >> 16) & 0xff;

    return vec4f(f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, 0.0);
}

// TODO: don't be clever => don't split into small rectangles?
@compute @workgroup_size(16, 16)
fn FillRect(
    @builtin(workgroup_id) wid : vec3<u32>,
    @builtin(local_invocation_id) lid : vec3u,
) {
    let ri = wid.x;

    let rect = fillRectCommands[ri];
    let x = (rect.position & 0x3f) * 16;
    let y = (rect.position >> 16) & 0x1ff;
    let width = ((rect.size & 0x3ff) + 0xf) & 0xfffffff0;
    let height = (rect.size >> 16) & 0x1ff;

    let numPixelX = (width + 15) / 16;
    let numPixelY = (height + 15) / 16;

    let startX = x + lid.x * numPixelX;
    let startY = y + lid.y * numPixelY;

    let endX = min(startX + numPixelX, startX + width);
    let endY = min(startY + numPixelY, startY + height);

    for (var j = startY; j < endY; j = j + 1) {
        for (var i = startX; i < endX; i = i + 1) {

            let pixel = FinalPixel(GetCommandColor(rect.command), rect.z_index);
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

    atomicStore(&vramBuffer32[idx], byte);
}
