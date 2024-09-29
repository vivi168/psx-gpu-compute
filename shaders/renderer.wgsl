struct VertexOutput {
    @builtin(position) position : vec4f,
}

@group(0) @binding(0) var<storage, read> vramBuffer: array<u32>;

const vertexPositions = array<vec2f, 6>(
    // first triangle
    vec2f( 1.0,  1.0),
    vec2f( 1.0, -1.0),
    vec2f(-1.0, -1.0),
    // second triangle
    vec2f( 1.0,  1.0),
    vec2f(-1.0, -1.0),
    vec2f(-1.0,  1.0),
);
const VRAM_WIDTH:u32 = 1024;

@vertex
fn VSMain(@builtin(vertex_index) vi: u32) -> VertexOutput {
    var output: VertexOutput;
    output.position = vec4f(vertexPositions[vi], 0.0, 1.0);

    return output;
}

@fragment
fn PSMain(@builtin(position) position: vec4f) -> @location(0) vec4f {
    let gx = u32(position.x);
    let gy = u32(position.y);

    let i  = gy * VRAM_WIDTH + gx;

    let word = vramBuffer[i];

    let r5 = word & 31;
    let g5 = (word >> 5) & 31;
    let b5 = (word >> 10) & 31;
    let a1 = (word >> 15) & 1;

    return vec4f(f32(r5) / 31.0, f32(g5) / 31.0, f32(b5) / 31.0, f32(a1));
}
