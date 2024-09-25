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

fn barycentric_coords(v1: vec2f, v2: vec2f, v3: vec2f, p: vec2f) -> vec3f {
  let u = cross(
    vec3f(v3.x - v1.x, v2.x - v1.x, v1.x - p.x),
    vec3f(v3.y - v1.y, v2.y - v1.y, v1.y - p.y)
  );

  if abs(u.z) < 1.0 {
    return vec3f(-1.0, 1.0, 1.0);
  }

  return vec3f(1.0 - (u.x + u.y) / u.z, u.y / u.z, u.x / u.z);
}

// TODO: function to construct rgb555
fn plot_pixel(x: u32, y: u32, r: u32, g: u32, b: u32) {
    let i = (y * VRAM_WIDTH + x); // / 2u;
    // let bi = i % 2;

    // newPixel = (zIndex << 16) | color
    // TODO atomicMax(&vramBuffer16[i], newPixel);
    atomicStore(&vramBuffer32[i], 0xff00ffff);
}

fn draw_triangle(v1: vec2f, v2: vec2f, v3: vec2f) {
    let minX = u32(min(min(v1.x, v2.x), v3.x));
    let minY = u32(min(min(v1.y, v2.y), v3.y));
    let maxX = u32(max(max(v1.x, v2.x), v3.x));
    let maxY = u32(max(max(v1.y, v2.y), v3.y));


    for (var y: u32 = minY; y < maxY; y = y + 1u) {
        for (var x: u32 = minX; x < maxX; x = x + 1u) {
            let bc = barycentric_coords(v1, v2, v3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            plot_pixel(x, y, 255u, 0u, 255u);
        }
    }
}

@compute @workgroup_size(256)
fn rasterize(@builtin(global_invocation_id) gid: vec3u) {
    let idx = gid.x;

    if idx >= commandsListInfo.renderPolyCount {
        return;
    }

    draw_triangle(
        vec2f(463, 121),
        vec2f(673, 228),
        vec2f(486, 421)
    );
}

@compute @workgroup_size(256)
fn init_vram(@builtin(global_invocation_id) gid: vec3u) {
    let idx = gid.x;
    // TODO init zIndex of each cell to 0
    // copy color from vramBuf16
    // vramBuf16 only needed for init_vram_buf pass

    atomicStore(&vramBuffer32[idx], 0);
}
