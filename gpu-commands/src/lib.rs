use js_sys;
use std::collections::VecDeque;
use wasm_bindgen::prelude::*;

#[repr(u8)]
enum GP0CommandType {
    Transfer = 0,
    RenderPoly = 1,
    RenderLine = 2,
    RenderRect = 3,
    CopyVramToVram = 4,
    CopyCpuToVram = 5,
    CopyVramToCpu = 6,
    RenderingAttribute = 7,
}

impl From<u32> for GP0CommandType {
    fn from(v: u32) -> GP0CommandType {
        match v {
            0 => GP0CommandType::Transfer,
            1 => GP0CommandType::RenderPoly,
            2 => GP0CommandType::RenderLine,
            3 => GP0CommandType::RenderRect,
            4 => GP0CommandType::CopyVramToVram,
            5 => GP0CommandType::CopyCpuToVram,
            6 => GP0CommandType::CopyVramToCpu,
            7 => GP0CommandType::RenderingAttribute,
            _ => panic!("oops"),
        }
    }
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace=console)]
    pub fn log(s: &str);
}

#[repr(C)]
#[derive(Copy, Clone, Default)]
struct Color {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
}

#[repr(C)]
#[derive(Copy, Clone, Default)]
struct Point {
    x: u32,
    y: u32,
}

#[repr(C)]
#[derive(Copy, Clone, Default)]
struct Vec2f {
    x: f32,
    y: f32,
}

#[repr(C)]
#[derive(Copy, Clone, Default)]
struct Vertex {
    position: Vec2f,
    uv: Point,
    color: Color,
}

#[repr(C, align(16))]
struct GP0Command {
    code: u32,
    z_index: u32,
    params: u32,
}

#[repr(C, align(16))]
struct FillRectCommand {
    z_index: u32,
    command: u32,
    position: u32,
    size: u32,
}

#[repr(C, align(16))]
struct RenderPolyCommand {
    command: GP0Command,
    color: Color,
    vertices: [Vertex; 3],
}

#[wasm_bindgen]
pub struct GP0CommandLists {
    fill_rect_cmds: Vec<u8>,
    render_poly_cmds: Vec<u8>,
}

#[wasm_bindgen]
impl GP0CommandLists {
    // === fill rect

    #[wasm_bindgen(getter, js_name=FillRectCommandCount)]
    pub fn fill_rect_cmd_count(&self) -> usize {
        self.fill_rect_cmds.len()
    }

    #[wasm_bindgen(getter, js_name=FillRectCommandSize)]
    pub fn fill_rect_cmd_size(&self) -> usize {
        std::mem::size_of::<FillRectCommand>()
    }

    #[wasm_bindgen(getter, js_name=FillRectCommands)]
    pub fn fill_rect_cmds(&self) -> js_sys::Uint8Array {
        js_sys::Uint8Array::from(self.fill_rect_cmds.as_slice())
    }

    // === render poly

    #[wasm_bindgen(getter, js_name=RenderPolyCommandCount)]
    pub fn render_poly_cmd_count(&self) -> usize {
        self.render_poly_cmds.len()
    }

    #[wasm_bindgen(getter, js_name=RenderPolyCommandSize)]
    pub fn render_poly_cmd_size(&self) -> usize {
        std::mem::size_of::<RenderPolyCommand>()
    }

    #[wasm_bindgen(getter, js_name=RenderPolyCommands)]
    pub fn render_poly_cmds(&self) -> js_sys::Uint8Array {
        js_sys::Uint8Array::from(self.render_poly_cmds.as_slice())
    }
}

#[wasm_bindgen(js_name=BuildGP0CommandLists)]
pub fn build_gp0_command_lists(commands: &[u32]) -> GP0CommandLists {
    let mut fill_rect_cmd_list: Vec<FillRectCommand> = Vec::new();
    let mut render_poly_cmd_list: Vec<RenderPolyCommand> = Vec::new();
    let mut cmd_fifo = VecDeque::from(commands.to_vec());
    let mut z_index = 1u32;

    while let Some(word) = cmd_fifo.pop_front() {
        let cmd_type = get_cmd_type(word);
        let cmd_params = get_cmd_params(word);

        match cmd_type {
            GP0CommandType::Transfer => match cmd_params {
                0x01 => {
                    log("TODO: clear cache command");
                }
                0x02 => {
                    fill_rect_cmd_list.push(build_fill_rect_command(&mut cmd_fifo, word, z_index));
                    z_index += 1;
                }
                _ => {}
            },
            GP0CommandType::RenderPoly => {
                let commands = build_render_poly_command(&mut cmd_fifo, word, z_index);
                render_poly_cmd_list.extend(commands);
                z_index += 1;
            }
            _ => {}
        }
    }

    GP0CommandLists {
        fill_rect_cmds: u8_vec(&fill_rect_cmd_list),
        render_poly_cmds: u8_vec(&render_poly_cmd_list),
    }
}

fn get_cmd_type(word: u32) -> GP0CommandType {
    GP0CommandType::from((word >> 29) & 0b111)
}
fn get_cmd_params(word: u32) -> u32 {
    (word >> 24) & 0x1f
}
fn get_cmd_code(word: u32) -> u32 {
    (word >> 24) & 0xff
}

fn build_fill_rect_command(fifo: &mut VecDeque<u32>, word: u32, z_index: u32) -> FillRectCommand {
    log("build fill rect command");

    let position = fifo.pop_front().unwrap();
    let size = fifo.pop_front().unwrap();

    FillRectCommand {
        z_index,
        command: word,
        position,
        size,
    }
}

fn build_render_poly_command(
    fifo: &mut VecDeque<u32>,
    word: u32,
    z_index: u32,
) -> Vec<RenderPolyCommand> {
    log("build render poly command");
    let mut commands: Vec<RenderPolyCommand> = Vec::new();

    let is_gouraud_shaded = |word: u32| -> bool { (word & (1 << 28)) != 0 };
    let num_vertices = |word: u32| -> u32 {
        if (word & (1 << 27)) == 0 {
            3
        } else {
            4
        }
    };
    let is_textured = |word: u32| -> bool { (word & (1 << 26)) != 0 };
    let is_opaque = |word: u32| -> bool { (word & (1 << 25)) == 0 };
    let has_texture_blending = |word: u32| -> bool { (word & (1 << 24)) == 0 };

    let code = get_cmd_code(word);
    let color = get_cmd_color(word);

    let num_vertices = num_vertices(word);
    let code = get_cmd_code(word);
    let color = get_cmd_color(word);
    let gouraud = is_gouraud_shaded(word);
    let opaque = is_opaque(word);
    let textured = is_textured(word);
    let texture_blending = textured && has_texture_blending(word);

    let mut vertices: [Vertex; 4] = [Vertex::default(); 4];

    let mut clut_pos = Point::default();

    for i in 0..num_vertices {
        let mut vertex: Vertex = Vertex::default();

        if gouraud {
            if i == 0 {
                vertex.color = color;
            } else {
                vertex.color = get_cmd_color(fifo.pop_front().unwrap())
            }
        }

        let pos = fifo.pop_front().unwrap();
        let x = (pos & 0xffff) as i16 as f32;
        let y = ((pos >> 16) & 0xffff) as i16 as f32;
        vertex.position = Vec2f { x, y };

        if textured {
            let tex_info = fifo.pop_front().unwrap();
            let uv = tex_info & 0xffff;
            let x = uv & 0xff;
            let y = (uv >> 8) & 0xff;
            vertex.uv = Point { x, y };

            if i == 0 {
                let xy = (tex_info >> 16) & 0xffff;
                clut_pos.x = (xy & 0b11111) * 16;
                clut_pos.y = (xy >> 6) & 0x1ff; // note: on gpu gen2, y [0..1023]
            } else if i == 1 {
                // TODO: TexPageAttributes struct
                let attrs = (tex_info >> 16) & 0xffff;
                let base_x = (attrs & 0b1111) * 64;
                let base_y = ((attrs >> 4) & 1) * 256;
                let transparency_mode = (attrs >> 5) & 0b11;
                let color_mode = (attrs >> 7) & 0b11;
                let texture_disable = (attrs & (1 << 11)) != 0;
            }
        }

        vertices[i as usize] = vertex;
    }

    commands.push(RenderPolyCommand {
        command: GP0Command {
            code,
            z_index,
            params: 0,
        },
        color,
        vertices: [vertices[0], vertices[1], vertices[2]],
    });

    if num_vertices == 4 {
        commands.push(RenderPolyCommand {
            command: GP0Command {
                code,
                z_index,
                params: 0,
            },
            color,
            vertices: [vertices[1], vertices[2], vertices[3]],
        });
    }

    commands
}

fn get_cmd_color(word: u32) -> Color {
    let r = word & 0xff;
    let g = (word >> 8) & 0xff;
    let b = (word >> 16) & 0xff;

    Color {
        r: r as f32 / 255.0,
        g: g as f32 / 255.0,
        b: b as f32 / 255.0,
        a: 0.0,
    }
}

pub fn u8_vec<T>(v: &Vec<T>) -> Vec<u8> {
    unsafe {
        std::slice::from_raw_parts(v.as_ptr() as *const u8, v.len() * std::mem::size_of::<T>())
            .to_vec()
    }
}
