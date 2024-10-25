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

    #[wasm_bindgen(js_namespace=console)]
    pub fn warn(s: &str);

    #[wasm_bindgen(js_namespace=console)]
    pub fn error(s: &str);
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
struct Vertex {
    position: u32,
    uv: u32,
    color: u32,
}

#[repr(C)]
struct RenderPolyCommand {
    z_index: u32,
    rdr_attrs_idx: u32,
    color: u32,
    tex_info: u32,
    vertices: [Vertex; 3],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RenderingAttributes {
    // TODO: also need gpustat
    tpage: u32,
    texwin: u32,
    draw_area_x1xy1: u32,
    draw_area_x2xy2: u32,
    drawing_offset: u32,
    mask: u32,
}

#[wasm_bindgen]
pub struct GP0CommandLists {
    fill_rect_cmds: Vec<u8>,
    render_poly_cmds: Vec<u8>,
    render_transparent_poly_cmds: Vec<u8>,
    rendering_attributes: Vec<u8>,
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

    // TODO: combine all Vec<u8> into one big Uint8Array
    #[wasm_bindgen(getter, js_name=FillRectCommands)]
    pub fn fill_rect_cmds(&self) -> js_sys::Uint8Array {
        self.fill_rect_cmds.as_slice().into()
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
        self.render_poly_cmds.as_slice().into()
    }

    // === render poly

    #[wasm_bindgen(getter, js_name=RenderTransparentPolyCommandCount)]
    pub fn render_transparent_poly_cmd_count(&self) -> usize {
        self.render_transparent_poly_cmds.len()
    }

    #[wasm_bindgen(getter, js_name=RenderTransparentPolyCommandSize)]
    pub fn render_transparent_poly_cmd_size(&self) -> usize {
        std::mem::size_of::<RenderPolyCommand>()
    }

    #[wasm_bindgen(getter, js_name=RenderTransparentPolyCommands)]
    pub fn render_transparent_poly_cmds(&self) -> js_sys::Uint8Array {
        self.render_transparent_poly_cmds.as_slice().into()
    }

    // === rendering attributes

    #[wasm_bindgen(getter, js_name=RenderingAttributesCount)]
    pub fn rendering_attributes_count(&self) -> usize {
        self.rendering_attributes.len()
    }

    #[wasm_bindgen(getter, js_name=RenderingAttributesSize)]
    pub fn rendering_attributes_size(&self) -> usize {
        std::mem::size_of::<RenderingAttributes>()
    }

    #[wasm_bindgen(getter, js_name=RenderingAttributess)]
    pub fn rendering_attributes(&self) -> js_sys::Uint8Array {
        self.rendering_attributes.as_slice().into()
    }
}

#[wasm_bindgen(js_name=BuildGP0CommandLists)]
pub fn build_gp0_command_lists(gpustat: u32, commands: &[u32]) -> GP0CommandLists {
    log(&format!("{:08x}", gpustat));
    let mut fill_rect_cmd_list: Vec<FillRectCommand> = Vec::new();
    let mut render_poly_cmd_list: Vec<RenderPolyCommand> = Vec::new();
    let mut render_transparent_poly_cmd_list: Vec<RenderPolyCommand> = Vec::new();
    let mut rendering_attributes: Vec<RenderingAttributes> = Vec::new();
    let mut current_rdr_attr: RenderingAttributes = Default::default(); // TODO: initial value from gpustat?

    let mut cmd_fifo = VecDeque::from(commands.to_vec());
    let mut z_index = 1u32;
    let mut rdr_attrs_idx = 0u32;
    let mut reading_rdr_attrs = true;

    while let Some(word) = cmd_fifo.pop_front() {
        let cmd_type = GP0CommandType::from((word >> 29) & 0b111);
        let cmd_params = (word >> 24) & 0x1f;

        match cmd_type {
            GP0CommandType::Transfer => match cmd_params {
                0x01 => {
                    // Clear Cache
                    warn("TODO: clear cache command");
                }
                0x02 => {
                    // Fill Rectangle in VRAM
                    if reading_rdr_attrs {
                        reading_rdr_attrs = false;
                        rendering_attributes.push(current_rdr_attr);
                        rdr_attrs_idx += 1;
                        warn("reading DONE!");
                    }
                    fill_rect_cmd_list.push(build_fill_rect_command(&mut cmd_fifo, word, z_index));
                    z_index += 1;
                }
                // TODO: GP0(80h) - Copy Rectangle (VRAM to VRAM)
                // TODO: GP0(A0h) - Copy Rectangle (CPU to VRAM)
                // TODO: GP0(C0h) - Copy Rectangle (VRAM to CPU)
                _ => {
                    warn("unknown params");
                }
            },
            GP0CommandType::RenderPoly => {
                if reading_rdr_attrs {
                    reading_rdr_attrs = false;
                    rendering_attributes.push(current_rdr_attr);
                    rdr_attrs_idx += 1;
                    warn("reading DONE!");
                }
                let commands =
                    build_render_poly_command(&mut cmd_fifo, word, z_index, rdr_attrs_idx - 1);

                let opaque = (commands[0].color & (1 << 25)) == 0;
                let len = commands.len() as u32;

                // TODO: also check mask setting
                if opaque {
                    render_poly_cmd_list.extend(commands);
                } else {
                    render_transparent_poly_cmd_list.extend(commands);
                }

                z_index += len;
            }
            GP0CommandType::RenderingAttribute => {
                if !reading_rdr_attrs {
                    reading_rdr_attrs = true;
                    current_rdr_attr = rendering_attributes.last().unwrap().clone();
                    warn("reading START!");
                }
                log("record rendering attribute");
                match cmd_params {
                    0x01 => {
                        // Draw Mode setting (aka "Texpage")
                        current_rdr_attr.tpage = word;
                    }
                    0x02 => {
                        // Texture Window setting
                        current_rdr_attr.texwin = word;
                    }
                    0x03 => {
                        // Set Drawing Area top left (X1,Y1)
                        current_rdr_attr.draw_area_x1xy1 = word;
                    }
                    0x04 => {
                        // Set Drawing Area bottom right (X2,Y2)
                        current_rdr_attr.draw_area_x2xy2 = word;
                    }
                    0x05 => {
                        // Set Drawing Offset (X,Y)
                        current_rdr_attr.drawing_offset = word;
                    }
                    0x06 => {
                        // Mask Bit Setting
                        current_rdr_attr.mask = word;
                    }
                    _ => {
                        warn("unknown params");
                    }
                }
            }
            _ => {
                error(&format!("unknown command {:#08x}", word));
            }
        }
    }

    GP0CommandLists {
        fill_rect_cmds: u8_vec(&fill_rect_cmd_list),
        render_poly_cmds: u8_vec(&render_poly_cmd_list),
        render_transparent_poly_cmds: u8_vec(&render_transparent_poly_cmd_list),
        rendering_attributes: u8_vec(&rendering_attributes),
    }
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
    rdr_attrs_idx: u32,
) -> Vec<RenderPolyCommand> {
    log("build render poly command");
    let mut commands: Vec<RenderPolyCommand> = Vec::new();
    let mut vertices: [Vertex; 4] = [Vertex::default(); 4];

    let gouraud = (word & (1 << 28)) != 0;
    let textured = (word & (1 << 26)) != 0;
    let num_vertices: u32 = {
        if (word & (1 << 27)) == 0 {
            3
        } else {
            4
        }
    };

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
        rdr_attrs_idx,
        color: word,
        tex_info,
        vertices: [vertices[0], vertices[1], vertices[2]],
    });

    if num_vertices == 4 {
        commands.push(RenderPolyCommand {
            z_index: z_index + 1,
            rdr_attrs_idx,
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
