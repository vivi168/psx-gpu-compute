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
struct FillRectCommand {
    z_index: u32,
    color: u32,
    position: u32,
    size: u32,
}

#[repr(C)]
#[derive(Copy, Clone, Default)]
struct Vec2f {
    x: u32,
    y: u32,
}

#[repr(C)]
#[derive(Copy, Clone, Default)]
struct Vertex {
    position: u32,
    uv: u32,
    color: u32,
}

#[repr(C)]
struct RenderPolyCommand {
    z_index: u32,
    color: u32,
    tex_info: u32,
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
                    z_index += 2;
                }
                _ => {}
            },
            GP0CommandType::RenderPoly => {
                let commands = build_render_poly_command(&mut cmd_fifo, word, z_index);
                render_poly_cmd_list.extend(commands);
                z_index += 2;
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

fn build_fill_rect_command(fifo: &mut VecDeque<u32>, word: u32, z_index: u32) -> FillRectCommand {
    log("build fill rect command");

    let position = fifo.pop_front().unwrap();
    let size = fifo.pop_front().unwrap();

    FillRectCommand {
        z_index,
        color: word,
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

    let num_vertices = num_vertices(word);
    let gouraud = is_gouraud_shaded(word);
    let textured = is_textured(word);

    let mut vertices: [Vertex; 4] = [Vertex::default(); 4];

    for i in 0..num_vertices {
        let mut vertex: Vertex = Vertex::default();

        if i == 0 {
            vertex.color = word;
        }

        if gouraud && i > 0 {
            vertex.color = fifo.pop_front().unwrap();
        }

        vertex.position = fifo.pop_front().unwrap();

        if textured {
            vertex.uv = fifo.pop_front().unwrap();
        }

        vertices[i as usize] = vertex;
    }

    let clut = (vertices[0].uv >> 16) & 0xffff;
    let tpage = (vertices[1].uv >> 16) & 0xffff;
    let tex_info = clut | (tpage << 16);

    commands.push(RenderPolyCommand {
        z_index,
        color: word,
        tex_info,
        vertices: [vertices[0], vertices[1], vertices[2]],
    });

    if num_vertices == 4 {
        commands.push(RenderPolyCommand {
            z_index: z_index + 1,
            color: word,
            tex_info,
            vertices: [vertices[1], vertices[2], vertices[3]],
        });
    }

    commands
}

pub fn u8_vec<T>(v: &Vec<T>) -> Vec<u8> {
    unsafe {
        std::slice::from_raw_parts(v.as_ptr() as *const u8, v.len() * std::mem::size_of::<T>())
            .to_vec()
    }
}
