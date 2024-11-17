struct RenderingAttributes {
    tpage: u32,
    texwin: u32,
    draw_area_x1xy1: u32,
    draw_area_x2xy2: u32,
    drawing_offset: u32,
    mask: u32,
}

struct CommandListsInfo {
    renderingAttributesCount: u32,
    fillRectCount: u32,
    renderPolyCount: u32,
    renderTransparentPolyCount: u32,
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

struct Triangle {
    p1: vec2f,
    p2: vec2f,
    p3: vec2f,
    uvs: vec3u,
    colors: vec3u,
    bbox: vec4u,
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
@group(0) @binding(6) var<storage, read> renderTransparentPolyCommands: array<RenderPolyCommand>;

const VRAM_WIDTH: u32 = 1024;
const VRAM_HEIGHT: u32 = 512;

fn FinalPixel(color: vec4f, zIndex: u32) -> u32 {
    let c = vec4u(round(color * 31.0));
    let rgb5551 = c.x | ((c.y) << 5) | ((c.z) << 10) | ((c.w & 1) << 15);

    return rgb5551 | (zIndex << 16);
}

fn GetCommandColor(word: u32) -> vec4f {
    let r = word & 0xff;
    let g = (word >> 8) & 0xff;
    let b = (word >> 16) & 0xff;

    return vec4f(f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, 1.0);
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

fn GetTpageTransparencyMode(word: u32) -> u32 {
    return (word >> 5) & 3;
}

fn GetCommandTexPageAttributes(word: u32) -> TexPageAttributes {
    let attrs = (word >> 16) & 0xffff;
    let x = (attrs & 15) * 64;
    let y = ((attrs >> 4) & 1) * 256;

    let transparency_mode = GetTpageTransparencyMode(attrs);
    let color_mode = (attrs >> 7) & 3;

    return TexPageAttributes(vec2u(x, y), transparency_mode, color_mode);
}

fn GetTransparencyMode(mode: u32) -> vec2f {
    if mode == 0 {
        return vec2f(0.5, 0.5);
    } else if mode == 1 {
        return vec2f(1.0, 1.0);
    } else if mode == 2 {
        return vec2f(1.0, -1.0);
    } else if mode == 3 {
        return vec2f(1.0, 0.25);
    } else {
        // unreachable
        return vec2f(0.0, 0.0);
    }
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

fn PlotTexel(x: u32, y: u32, fg: vec4f, z_index: u32, opaque: bool, tmode: vec2f) {
    let c = FinalPixel(fg, z_index);

    // black texels are ignored
    if (c & 0xffff) == 0 {
        return;
    }

    let i = y * VRAM_WIDTH + x;

    if opaque || (c & 0x8000) == 0 {
        atomicMax(&vramBuffer32[i], c);
        return;
    }

    let b = atomicLoad(&vramBuffer32[i]);

    if c <= b {
        return;
    }

    let bg = GetPixelColor(b);

    let blend = clamp(tmode.x * bg + tmode.y * fg, vec4f(0), vec4f(1));
    let fc = FinalPixel(blend, z_index);

    atomicMax(&vramBuffer32[i], fc);
}

fn PlotPixel(x: u32, y: u32, c: u32) {
    let i = y * VRAM_WIDTH + x;

    atomicMax(&vramBuffer32[i], c);
}

fn PlotPixel2(x: u32, y: u32, fg: vec4f, z_index: u32, opaque: bool, tmode: vec2f) {
    let c = FinalPixel(fg, z_index);
    let i = y * VRAM_WIDTH + x;

    if opaque {
        atomicMax(&vramBuffer32[i], c);
        return;
    }

    let b = atomicLoad(&vramBuffer32[i]);

    if c <= b {
        return;
    }

    let bg = GetPixelColor(b);

    let blend = clamp(tmode.x * bg + tmode.y * fg, vec4f(0), vec4f(1));
    let fc = FinalPixel(blend, z_index);

    atomicMax(&vramBuffer32[i], fc);
}

fn GetTriangle(v1: Vertex, v2: Vertex, v3:Vertex, drawing_area:vec4u, offset:vec2f) -> Triangle {
    let p1 = GetVertexPosition(v1.position) + offset;
    let p2 = GetVertexPosition(v2.position) + offset;
    let p3 = GetVertexPosition(v3.position) + offset;

    let minX = max(drawing_area.x, u32(min(min(p1.x, p2.x), p3.x)));
    let minY = max(drawing_area.y, u32(min(min(p1.y, p2.y), p3.y)));
    let maxX = min(drawing_area.z, u32(max(max(p1.x, p2.x), p3.x)));
    let maxY = min(drawing_area.w, u32(max(max(p1.y, p2.y), p3.y)));

    return Triangle(
        p1,
        p2,
        p3,
        vec3u(v1.uv, v2.uv, v3.uv),
        vec3u(v1.color, v2.color, v3.color),
        vec4u(minX, minY, maxX, maxY)
    );
}

fn RenderFlatTriangle(t: Triangle, color: u32, z_index: u32, opaque: bool, tmode: vec2f) {
    let c = GetCommandColor(color);

    for (var y: u32 = t.bbox.y; y < t.bbox.w; y = y + 1) {
        for (var x: u32 = t.bbox.x; x < t.bbox.z; x = x + 1) {
            let bc = BarycentricCoords(t.p1, t.p2, t.p3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            PlotPixel2(x, y, c, z_index, opaque, tmode);
        }
    }
}

fn RenderFlatTexturedTriangle(t: Triangle, color: u32, tex_info: u32, twin: TexWindow, z_index: u32, opaque: bool) {
    let c = GetCommandColor(color) * GetCommandModulation(color);

    let uv1 = GetCommandUV(t.uvs.x);
    let uv2 = GetCommandUV(t.uvs.y);
    let uv3 = GetCommandUV(t.uvs.z);

    let clut = GetCommadClutPos(tex_info);
    let tex_base_page = GetCommandTexPageAttributes(tex_info);
    let tmode = GetTransparencyMode(tex_base_page.transparency_mode);

    for (var y: u32 = t.bbox.y; y < t.bbox.w; y = y + 1) {
        for (var x: u32 = t.bbox.x; x < t.bbox.z; x = x + 1) {
            let bc = BarycentricCoords(t.p1, t.p2, t.p3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            let uv = round(bc.x * uv1 + bc.y * uv2 + bc.z * uv3);
            let p = SampleTex(vec2u(uv), clut, tex_base_page, twin);
            let fg = clamp(c * p, vec4f(0), vec4f(1));

            PlotTexel(x, y, fg, z_index, opaque, tmode);
        }
    }
}

fn RenderGouraudTriangle(t: Triangle, z_index: u32, opaque: bool, tmode: vec2f) {
    let c1 = GetCommandColor(t.colors.x);
    let c2 = GetCommandColor(t.colors.y);
    let c3 = GetCommandColor(t.colors.z);

    for (var y: u32 = t.bbox.y; y < t.bbox.w; y = y + 1) {
        for (var x: u32 = t.bbox.x; x < t.bbox.z; x = x + 1) {
            let bc = BarycentricCoords(t.p1, t.p2, t.p3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            let color = bc.x * c1 + bc.y * c2 + bc.z * c3;

            PlotPixel2(x, y, color, z_index, opaque, tmode);
        }
    }
}

fn RenderGouraudTexturedTriangle(t: Triangle, color: u32, tex_info: u32, twin: TexWindow, z_index: u32, opaque: bool) {
    let c1 = GetCommandColor(t.colors.x);
    let c2 = GetCommandColor(t.colors.y);
    let c3 = GetCommandColor(t.colors.z);

    let uv1 = GetCommandUV(t.uvs.x);
    let uv2 = GetCommandUV(t.uvs.y);
    let uv3 = GetCommandUV(t.uvs.z);

    let m = GetCommandModulation(color);
    let clut = GetCommadClutPos(tex_info);
    let tex_base_page = GetCommandTexPageAttributes(tex_info);
    let tmode = GetTransparencyMode(tex_base_page.transparency_mode);

    for (var y: u32 = t.bbox.y; y < t.bbox.w; y = y + 1) {
        for (var x: u32 = t.bbox.x; x < t.bbox.z; x = x + 1) {
            let bc = BarycentricCoords(t.p1, t.p2, t.p3, vec2f(f32(x), f32(y)));

            if bc.x < 0.0 || bc.y < 0.0 || bc.z < 0.0 {
                continue;
            }

            let c = bc.x * c1 + bc.y * c2 + bc.z * c3;
            // TODO: DRY
            let uv = round(bc.x * uv1 + bc.y * uv2 + bc.z * uv3);
            let p = SampleTex(vec2u(uv), clut, tex_base_page, twin);
            let fg = clamp(c * m * p, vec4f(0), vec4f(1));

            PlotTexel(x, y, fg, z_index, opaque, tmode);
        }
    }
}

fn RenderTriangle(t: Triangle, poly: RenderPolyCommand, rdr_attrs: RenderingAttributes) {
    let gouraud = (poly.color & (1 << 28)) != 0;
    let textured = (poly.color & (1 << 26)) != 0;
    let opaque = (poly.color & (1 << 25)) == 0;

    if gouraud {
        if textured {
            let twin = GetTexWindow(rdr_attrs.texwin);
            RenderGouraudTexturedTriangle(t, poly.color, poly.tex_info, twin, poly.z_index, opaque);
        } else {
            let tmode = GetTransparencyMode(GetTpageTransparencyMode(rdr_attrs.tpage));
            RenderGouraudTriangle(t, poly.z_index, opaque, tmode);
        }
    } else {
        if textured {
            let twin = GetTexWindow(rdr_attrs.texwin);
            RenderFlatTexturedTriangle(t, poly.color, poly.tex_info, twin, poly.z_index, opaque);
        } else {
            let tmode = GetTransparencyMode(GetTpageTransparencyMode(rdr_attrs.tpage));
            RenderFlatTriangle(t, poly.color, poly.z_index, opaque, tmode);
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

    let rdr_attrs = renderingAttributes[poly.rdr_attrs_idx];
    let da = GetDrawingArea(rdr_attrs.draw_area_x1xy1, rdr_attrs.draw_area_x2xy2);
    let drawing_offset = GetDrawingOffset(rdr_attrs.drawing_offset);

    let v1 = poly.vertices[0];
    let v2 = poly.vertices[1];
    let v3 = poly.vertices[2];

    let t = GetTriangle(v1, v2, v3, da, drawing_offset);

    RenderTriangle(t, poly, rdr_attrs);
}

const CELL_SIZE:u32 = 8;

fn BBoxesOverlap(b1: vec4u, b2: vec4u) -> bool {
    return b1.x < b2.z && b1.z > b2.x && b1.y < b2.w && b1.w > b2.y;
}

fn PointInCell(p: vec2u, cell: vec4u) -> bool {
    return cell.x <= p.x && p.x <= cell.z && cell.y <= p.y && p.y <= cell.w;
}

fn LinesIntersect(l1: vec4u, l2: vec4u) -> bool {
    let det = (l1.x - l1.z) * (l2.y - l2.w) - (l1.y - l1.w) * (l2.x - l2.z);

    if det == 0 {
        return false;
    }

    let inv_det:f32 = 1 / f32(det);

    let t =   f32((l1.x - l2.x) * (l2.y - l2.w) - (l1.y - l2.y) * (l2.x - l2.z)) * inv_det;
    let u = -(f32((l1.x - l1.z) * (l1.y - l2.y) - (l1.y - l1.w) * (l1.x - l2.x)) * inv_det);

    return 0 <= t && t <= 1 && 0 <= u && u <= 1;
}

@compute @workgroup_size(CELL_SIZE, CELL_SIZE)
fn RenderTransparentPoly(
    @builtin(global_invocation_id) gid: vec3u,
    @builtin(workgroup_id) wid: vec3u,
    @builtin(local_invocation_id) lid : vec3u,
    @builtin(num_workgroups) num_workgroups: vec3u
) {
    let wx = wid.x * 64;
    let wy = wid.y * 64;

    let startX = wx + lid.x * CELL_SIZE;
    let startY = wy + lid.y * CELL_SIZE;

    let endX = min(startX + CELL_SIZE, VRAM_WIDTH);
    let endY = min(startY + CELL_SIZE, VRAM_HEIGHT);

    let cell = vec4u(startX, startY, endX, endY);

    for (var i = 0u; i < commandListsInfo.renderTransparentPolyCount; i = i + 1) {
        let poly = renderTransparentPolyCommands[i];

        let rdr_attrs = renderingAttributes[poly.rdr_attrs_idx];
        let da = GetDrawingArea(rdr_attrs.draw_area_x1xy1, rdr_attrs.draw_area_x2xy2);
        let drawing_offset = GetDrawingOffset(rdr_attrs.drawing_offset);

        let v1 = poly.vertices[0];
        let v2 = poly.vertices[1];
        let v3 = poly.vertices[2];

        let t = GetTriangle(v1, v2, v3, cell, drawing_offset);

        if !BBoxesOverlap(cell, da) {
            continue;
        }

        if !BBoxesOverlap(t.bbox, cell) {
            continue;
        }

        // TODO: also check if vertices of triangle/edges of triangle intersect with cell

        RenderTriangle(t, poly, rdr_attrs);
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
            PlotPixel(i % 1024, j % 512, pixel);
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
