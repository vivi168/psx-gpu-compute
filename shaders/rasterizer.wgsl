struct RenderingAttributes {
    tpage: u32,
    texwin: u32,
    draw_area_x1xy1: u32,
    draw_area_x2xy2: u32,
    drawing_offset: u32,
    mask: u32,
}

struct CommandListsInfo {
    fillRectCount: u32,
    renderPolyCount: u32,
    renderLineCount: u32,
    renderRectCount: u32,
}

struct FillRectCommand {
    z_index: u32,
    rdr_attrs_idx: u32,
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
    rdr_attrs_idx: u32,
    color: u32,
    tex_info: u32,
    vertices: array<Vertex, 3>,
}

struct TexPageAttributes {
    position: vec2u,
    transparency_mode: u32,
    color_mode: u32,
    // texture_disable: bool, // TODO
}

struct TexWindow {
    mask: vec2u,
    offset: vec2u,
}

@group(0) @binding(0) var<storage, read> renderingAttributes: array<RenderingAttributes>;
@group(0) @binding(1) var<storage, read> vramBuffer16: array<u32>;
@group(0) @binding(2) var<storage, read_write> vramBuffer32: array<atomic<u32>>;
@group(0) @binding(3) var<uniform> commandListsInfo: CommandListsInfo;
@group(0) @binding(4) var<storage, read> fillRectCommands: array<FillRectCommand>;
@group(0) @binding(5) var<storage, read> renderPolyCommands: array<RenderPolyCommand>;

const VRAM_WIDTH: u32 = 1024;
const VRAM_HEIGHT: u32 = 512;

fn FinalPixel(color: vec4f, zIndex: u32) -> u32 {
    // TODO: alpha channel (mask bit)
    let c = vec4u(round(color * 31.0));
    let rgb555 = c.x | ((c.y) << 5) | ((c.z) << 10);

    return rgb555 | (zIndex << 16);
}

fn GetCommandColor(word: u32) -> vec4f {
    let r = word & 0xff;
    let g = (word >> 8) & 0xff;
    let b = (word >> 16) & 0xff;

    return vec4f(f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, 0.0);
}

fn GetPixelColor(word: u32) -> vec4f {
    let r5 = word & 31;
    let g5 = (word >> 5) & 31;
    let b5 = (word >> 10) & 31;
    let a1 = (word >> 15) & 1;

    return vec4f(f32(r5) / 31.0, f32(g5) / 31.0, f32(b5) / 31.0, f32(a1));
}

fn GetTexWindow(word: u32) -> TexWindow {
    let mx = word & 0x1f;
    let my = (word >> 5) & 0x1f;
    let ox = (word >> 10) & 0x1f;
    let oy = (word >> 15) & 0x1f;

    let mask = vec2u(mx, my);
    let offset = vec2u(ox, oy);

    return TexWindow(mask, offset);
}

fn GetDrawingArea(x1y1: u32, x2y2: u32) -> vec4u {
    let x1 = x1y1 & 0x3ff;
    let y1 = (x1y1 >> 10) & 0x1ff; // note: on gpu gen2 0x3ff

    let x2 = x2y2 & 0x3ff;
    let y2 = (x2y2 >> 10) & 0x1ff; // note: on gpu gen2 0x3ff

    return vec4u(x1, y1, x2 + 1, y2 + 1);
}

fn SignExtend(bits: u32, value: i32) -> i32 {
    let m = 32 - bits;

    return (value << m) >> m;
}

fn GetDrawingOffset(word: u32) -> vec2f {
    let x = i32(word & 0x7ff);
    let y = i32((word >> 11) & 0x7ff);

    return vec2f(f32(SignExtend(11, x)), f32(SignExtend(11, y)));
}

fn GetCommandUV(word: u32) -> vec2f {
    let u:u32 = word & 0xff;
    let v:u32 = (word >> 8) & 0xff;

    let uv = vec2u(u, v);
    return vec2f(uv);
}

fn GetCommadClutPos(word: u32) -> vec2u {
    let xy = word & 0xffff;
    let x = (xy & 0x3f) * 16;
    let y = (xy >> 6) & 0x1ff; // note: on gpu gen2, y [0..1023]

    return vec2u(x, y);
}

fn GetCommandTexPageAttributes(word: u32) -> TexPageAttributes {
    let attrs = (word >> 16) & 0xffff;
    let x = (attrs & 15) * 64;
    let y = ((attrs >> 4) & 1) * 256;

    let transparency_mode = (attrs >> 5) & 3;
    let color_mode = (attrs >> 7) & 3;

    return TexPageAttributes(vec2u(x, y), transparency_mode, color_mode);
}

// AKA texture blending
fn GetCommandModulation(word: u32) -> f32 {
    let modulation = (word & (1 << 24)) == 0;
    return 1.0 + f32(modulation) * (255.0/128.0 - 1.0);
}

fn GetVertexPosition(word: u32) -> vec2f {
    let x = i32(word & 0x7ff);
    let y = i32((word >> 16) & 0x7ff);

    return vec2f(f32(SignExtend(11, x)), f32(SignExtend(11, y)));
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

fn SampleTex(uv: vec2u, clut: vec2u, tex_base_page: TexPageAttributes, twin: TexWindow) -> vec4f {
    let bpp = 4u << tex_base_page.color_mode;
    let r = 16u / bpp;

    let uv1 = (uv & (~(twin.mask * 8))) | ((twin.offset & twin.mask) * 8);
    let uv2 = vec2u(uv1.x / r, uv1.y);
    let xy = (tex_base_page.position + uv2) % vec2u(VRAM_WIDTH, VRAM_HEIGHT);
    let ti = xy.y * VRAM_WIDTH + xy.x;

    let texel = atomicLoad(&vramBuffer32[ti]) & 0xffff;

    if tex_base_page.color_mode == 2 {
        return GetPixelColor(texel);
    }

    let mask = (1u << bpp) - 1;
    let index = (texel >> (uv1.x % r * bpp)) & mask;

    let cx = clut.x + index;
    let cy = clut.y;
    let ci = cy * VRAM_WIDTH + cx;

    let c = atomicLoad(&vramBuffer32[ci]);

    return GetPixelColor(c);
}

fn PlotPixel(x: u32, y: u32, c: u32) {
    if (c & 0xffff) == 0 {
        return;
    }

    let i = y * VRAM_WIDTH + x;

    atomicMax(&vramBuffer32[i], c);
}

fn PlotPixel1(x: u32, y: u32, c: u32) {
    let i = y * VRAM_WIDTH + x;

    atomicMax(&vramBuffer32[i], c);
}

fn RenderFlatTriangle(v1: Vertex, v2: Vertex, v3: Vertex, color: u32, z_index: u32, rdr_attrs_idx: u32) {
    let rdr_attrs = renderingAttributes[rdr_attrs_idx];
    let da = GetDrawingArea(rdr_attrs.draw_area_x1xy1, rdr_attrs.draw_area_x2xy2);
    let drawing_offset = GetDrawingOffset(rdr_attrs.drawing_offset);

    let p1 = GetVertexPosition(v1.position) + drawing_offset;
    let p2 = GetVertexPosition(v2.position) + drawing_offset;
    let p3 = GetVertexPosition(v3.position) + drawing_offset;

    // TODO: clip to current drawing area instead of full vram
    let minX = max(da.x, u32(min(min(p1.x, p2.x), p3.x)));
    let minY = max(da.y, u32(min(min(p1.y, p2.y), p3.y)));
    let maxX = min(da.z, u32(max(max(p1.x, p2.x), p3.x)));
    let maxY = min(da.w, u32(max(max(p1.y, p2.y), p3.y)));

    let c = GetCommandColor(color);

    for (var y: u32 = minY; y < maxY; y = y + 1) {
        for (var x: u32 = minX; x < maxX; x = x + 1) {
            let bc = BarycentricCoords(p1, p2, p3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            PlotPixel1(x, y, FinalPixel(c, z_index));
        }
    }
}

fn RenderFlatTexturedTriangle(v1: Vertex, v2: Vertex, v3: Vertex, color: u32, tex_info: u32, z_index: u32, rdr_attrs_idx: u32) {
    // TODO: DRY
    let rdr_attrs = renderingAttributes[rdr_attrs_idx];
    let da = GetDrawingArea(rdr_attrs.draw_area_x1xy1, rdr_attrs.draw_area_x2xy2);
    let twin = GetTexWindow(rdr_attrs.texwin);
    let drawing_offset = GetDrawingOffset(rdr_attrs.drawing_offset);

    let p1 = GetVertexPosition(v1.position) + drawing_offset;
    let p2 = GetVertexPosition(v2.position) + drawing_offset;
    let p3 = GetVertexPosition(v3.position) + drawing_offset;

    // TODO: clip to current drawing area instead of full vram
    let minX = max(da.x, u32(min(min(p1.x, p2.x), p3.x)));
    let minY = max(da.y, u32(min(min(p1.y, p2.y), p3.y)));
    let maxX = min(da.z, u32(max(max(p1.x, p2.x), p3.x)));
    let maxY = min(da.w, u32(max(max(p1.y, p2.y), p3.y)));

    let c = GetCommandColor(color) * GetCommandModulation(color);

    let uv1 = GetCommandUV(v1.uv);
    let uv2 = GetCommandUV(v2.uv);
    let uv3 = GetCommandUV(v3.uv);

    let clut = GetCommadClutPos(tex_info);
    let tex_base_page = GetCommandTexPageAttributes(tex_info);

    for (var y: u32 = minY; y < maxY; y = y + 1) {
        for (var x: u32 = minX; x < maxX; x = x + 1) {
            let bc = BarycentricCoords(p1, p2, p3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            let uv = round(bc.x * uv1 + bc.y * uv2 + bc.z * uv3);
            let p = SampleTex(vec2u(uv), clut, tex_base_page, twin);

            PlotPixel(x, y, FinalPixel(clamp(c * p, vec4f(0), vec4f(1)) , z_index));
        }
    }
}

fn RenderGouraudTriangle(v1: Vertex, v2: Vertex, v3: Vertex, z_index: u32, rdr_attrs_idx: u32) {
    // TODO: DRY
    let rdr_attrs = renderingAttributes[rdr_attrs_idx];
    let da = GetDrawingArea(rdr_attrs.draw_area_x1xy1, rdr_attrs.draw_area_x2xy2);
    let drawing_offset = GetDrawingOffset(rdr_attrs.drawing_offset);

    let p1 = GetVertexPosition(v1.position) + drawing_offset;
    let p2 = GetVertexPosition(v2.position) + drawing_offset;
    let p3 = GetVertexPosition(v3.position) + drawing_offset;

    // TODO: clip to current drawing area instead of full vram
    let minX = max(da.x, u32(min(min(p1.x, p2.x), p3.x)));
    let minY = max(da.y, u32(min(min(p1.y, p2.y), p3.y)));
    let maxX = min(da.z, u32(max(max(p1.x, p2.x), p3.x)));
    let maxY = min(da.w, u32(max(max(p1.y, p2.y), p3.y)));

    let c1 = GetCommandColor(v1.color);
    let c2 = GetCommandColor(v2.color);
    let c3 = GetCommandColor(v3.color);

    for (var y: u32 = minY; y < maxY; y = y + 1) {
        for (var x: u32 = minX; x < maxX; x = x + 1) {
            let bc = BarycentricCoords(p1, p2, p3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            let color = bc.x * c1 + bc.y * c2 + bc.z * c3;

            PlotPixel1(x, y, FinalPixel(color, z_index));
        }
    }
}

fn RenderGouraudTexturedTriangle(v1: Vertex, v2: Vertex, v3: Vertex, color: u32, tex_info: u32, z_index: u32, rdr_attrs_idx: u32) {
    // TODO: DRY
    let rdr_attrs = renderingAttributes[rdr_attrs_idx];
    let da = GetDrawingArea(rdr_attrs.draw_area_x1xy1, rdr_attrs.draw_area_x2xy2);
    let twin = GetTexWindow(rdr_attrs.texwin);
    let drawing_offset = GetDrawingOffset(rdr_attrs.drawing_offset);

    let p1 = GetVertexPosition(v1.position) + drawing_offset;
    let p2 = GetVertexPosition(v2.position) + drawing_offset;
    let p3 = GetVertexPosition(v3.position) + drawing_offset;

    // TODO: clip to current drawing area instead of full vram
    let minX = max(da.x, u32(min(min(p1.x, p2.x), p3.x)));
    let minY = max(da.y, u32(min(min(p1.y, p2.y), p3.y)));
    let maxX = min(da.z, u32(max(max(p1.x, p2.x), p3.x)));
    let maxY = min(da.w, u32(max(max(p1.y, p2.y), p3.y)));

    let c1 = GetCommandColor(v1.color);
    let c2 = GetCommandColor(v2.color);
    let c3 = GetCommandColor(v3.color);

    let uv1 = GetCommandUV(v1.uv);
    let uv2 = GetCommandUV(v2.uv);
    let uv3 = GetCommandUV(v3.uv);

    let m = GetCommandModulation(color);
    let clut = GetCommadClutPos(tex_info);
    let tex_base_page = GetCommandTexPageAttributes(tex_info);

    for (var y: u32 = minY; y < maxY; y = y + 1) {
        for (var x: u32 = minX; x < maxX; x = x + 1) {
            let bc = BarycentricCoords(p1, p2, p3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            let c = bc.x * c1 + bc.y * c2 + bc.z * c3;
            // TODO: DRY
            let uv = round(bc.x * uv1 + bc.y * uv2 + bc.z * uv3);
            let p = SampleTex(vec2u(uv), clut, tex_base_page, twin);

            PlotPixel(x, y, FinalPixel(clamp(c * m * p, vec4f(0), vec4f(1)) , z_index));
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
    let v1 = poly.vertices[0];
    let v2 = poly.vertices[1];
    let v3 = poly.vertices[2];

    let gouraud = (poly.color & (1 << 28)) != 0;
    let textured = (poly.color & (1 << 26)) != 0;

    if gouraud {
        if textured {
            RenderGouraudTexturedTriangle(v1, v2, v3, poly.color, poly.tex_info, poly.z_index, poly.rdr_attrs_idx);
        } else {
            RenderGouraudTriangle(v1, v2, v3, poly.z_index, poly.rdr_attrs_idx);
        }
    } else {
        if textured {
            RenderFlatTexturedTriangle(v1, v2, v3, poly.color, poly.tex_info, poly.z_index, poly.rdr_attrs_idx);
        } else {
            RenderFlatTriangle(v1, v2, v3, poly.color, poly.z_index, poly.rdr_attrs_idx);
        }
    }
}

@compute @workgroup_size(256)
fn FillRect(
    @builtin(global_invocation_id) gid : vec3u,
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
            PlotPixel1(i % 1024, j % 512, pixel);
        }
    }
}

@compute @workgroup_size(256)
fn InitVram(@builtin(global_invocation_id) gid: vec3u) {
    let idx = gid.x;
    let ri = idx * 2;

    let word = vramBuffer16[idx];

    let byte1 = word & 0xffff;
    let byte2 = (word >> 16) & 0xffff;

    atomicStore(&vramBuffer32[ri], byte1);
    atomicStore(&vramBuffer32[ri + 1], byte2);
}
