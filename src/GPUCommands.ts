export function BuildGP0CommandList(commandFIFO: number[]) {
  const GetCommandType = (word: number) => (word >>> 29) & 0b111;
  const GetCommandParams = (word: number) => (word >>> 24) & 0x1f;
  const GetCommandCode = (word: number) => (word >>> 24) & 0xff;

  const commandList: GP0Command[] = [];

  const BuildFillRectCommand = (word: number): FillRectCommand => {
    console.log('build fill rect command');

    const command = GetCommandCode(word);
    const color = GetColor(word);

    word = commandFIFO.shift()!;
    const x = word & 0xffff;
    const y = (word >>> 16) & 0xffff;

    word = commandFIFO.shift()!;
    const width = word & 0xffff;
    const height = (word >>> 16) & 0xffff;

    return {
      command,
      color,
      rect: {x, y, width, height},
    };
  };

  const BuildRenderPolyCommand = (word: number): RenderPolyCommand => {
    console.log('build render poly command');

    const IsGouraudShaded = (word: number) => (word & (1 << 28)) !== 0;
    const NumVertices = (word: number) => ((word & (1 << 27)) === 0 ? 3 : 4);
    const IsTextured = (word: number) => (word & (1 << 26)) !== 0;
    const IsOpaque = (word: number) => (word & (1 << 25)) === 0;
    const HasTextureBlending = (word: number) => (word & (1 << 24)) === 0;

    const numVertices = NumVertices(word);
    console.log('num vertices:', numVertices);

    const command = GetCommandCode(word);
    const color = GetColor(word);
    const gouraud = IsGouraudShaded(word);
    const opaque = IsOpaque(word);
    const textured = IsTextured(word);
    const textureBlending = textured && HasTextureBlending(word);

    let vertices: Vertex[] = [];
    let clutPos: Point | undefined = undefined;
    let texpageAttrs: TexPageAttributes | undefined = undefined;

    for (let i = 0; i < numVertices; i++) {
      const vertex: Vertex = {position: {x: 0, y: 0}};

      if (gouraud) {
        if (i === 0) {
          vertex.color = color;
        } else {
          word = commandFIFO.shift()!;
          vertex.color = GetColor(word);
        }
      }

      word = commandFIFO.shift()!;
      const x = word & 0xffff;
      const y = (word >>> 16) & 0xffff;
      vertex.position.x = new Int16Array([x])[0];
      vertex.position.y = new Int16Array([y])[0];

      if (textured) {
        word = commandFIFO.shift()!;
        const uv = word & 0xffff;
        const x = uv & 0xff;
        const y = (uv >>> 8) & 0xff;
        vertex.uv = {x, y};

        if (i === 0) {
          const xy = (word >>> 16) & 0xffff;
          const x = (xy & 0b11111) * 16;
          const y = (xy >>> 6) & 0x1ff; // note: on gpu gen2, y [0..1023]

          clutPos = {x, y};
        } else if (i === 1) {
          const attrs = (word >>> 16) & 0xffff;
          const baseX = (attrs & 0b1111) * 64;
          const baseY = ((attrs >>> 4) & 1) * 256;
          const transparencyMode = (attrs >>> 5) & 0b11;
          const colorMode = (attrs >>> 7) & 0b11;
          const textureDisable = (attrs & (1 << 11)) !== 0;

          texpageAttrs = {
            basePosition: {x: baseX, y: baseY},
            transparencyMode,
            colorMode,
            textureDisable,
          };
        }
      }

      vertices.push(vertex as Vertex);
    }

    return {
      command,
      color,
      vertices,
      gouraud,
      textured,
      opaque,
      textureBlending,
      clutPos,
      texpageAttrs,
    };
  };

  while (commandFIFO.length) {
    const word = commandFIFO.shift()!;

    const type = GetCommandType(word);
    const params = GetCommandParams(word);

    console.log(word.toString(16), type, params);

    switch (type) {
      case GP0CommandType.Transfer:
        switch (params) {
          case 0x01:
            console.warn('TODO: clear cache command');
            break;
          case 0x02:
            commandList.push(BuildFillRectCommand(word));
            break;
          default:
            console.error('unknown command');
            break;
        }
        break;
      case GP0CommandType.RenderPoly:
        commandList.push(BuildRenderPolyCommand(word));
        break;
    }
  }

  return commandList;
}

interface Color {
  r: number;
  g: number;
  b: number;
}

function GetColor(c: number): Color {
  const r = c & 0xff;
  const g = (c >>> 8) & 0xff;
  const b = (c >>> 16) & 0xff;

  return {r, g, b};
}

interface Point {
  x: number;
  y: number;
}

interface Vertex {
  position: Point;
  uv?: Point;
  color?: Color;
}

interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

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

interface GP0Command {
  command: number;
}

interface FillRectCommand extends GP0Command {
  color: Color;
  rect: Rect;
}

interface TexPageAttributes {
  basePosition: Point;
  transparencyMode: number;
  colorMode: number;
  textureDisable: boolean; // note: seems unused, gpu gen2 feature
}

interface RenderPolyCommand extends GP0Command {
  color: Color;
  vertices: Vertex[];
  gouraud: boolean;
  opaque: boolean;
  textured: boolean;
  textureBlending: boolean;
  clutPos?: Point;
  texpageAttrs?: TexPageAttributes;
}
