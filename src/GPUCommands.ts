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

    for (let i = 0; i < numVertices; i++) {
      const vertex: Vertex = {position: {x: 0, y: 0}};

      if (gouraud) {
        if (i == 0) {
          vertex.color = color;
        } else {
          word = commandFIFO.shift()!;
          vertex.color = GetColor(word);
        }
      }

      word = commandFIFO.shift()!;
      vertex.position.x = word & 0xffff;
      vertex.position.y = (word >>> 16) & 0xffff;

      if (textured) {
        word = commandFIFO.shift()!;
        const uv = word & 0xffff;
        const x = uv & 0xff;
        const y = (uv >>> 8) & 0xff;
        vertex.uv = {x, y};

        // TODO: i == 0: palette
        // TODO: i == 1: texpage
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

interface RenderPolyCommand extends GP0Command {
  color: Color;
  vertices: Vertex[];
  gouraud: boolean;
  opaque: boolean;
  textured: boolean;
  textureBlending: boolean;
  // TODO: clut
  // TODO: texpage
}
