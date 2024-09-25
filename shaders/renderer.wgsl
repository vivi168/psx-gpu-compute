struct VertexOutput {
    @builtin(position) position : vec4f,
}

@group(0) @binding(0) var<storage, read> vramBuffer: array<u32>;

const vertexPositions = array<vec2f, 6>(
    // first triangle
    vec2<f32>( 1.0,  1.0),
    vec2<f32>( 1.0, -1.0),
    vec2<f32>(-1.0, -1.0),
    // second triangle
    vec2<f32>( 1.0,  1.0),
    vec2<f32>(-1.0, -1.0),
    vec2<f32>(-1.0,  1.0),
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

    // if (gx / 8 + gy / 8) % 2 == 0 {
    //     return vec4f(0, 0, 0, 1);
    // }

    if vramBuffer[i] == 0xff00ffff {
        return vec4f(1, 0, 1, 1);
    }

    return vec4f(1, 1, 1, 1);
}
