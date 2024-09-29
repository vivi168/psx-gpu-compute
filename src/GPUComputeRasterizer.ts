import {GP0Command} from './GPUCommands';
import computeShaderWGSL from '../shaders/rasterizer.wgsl?raw';
import rendererShaderWGSL from '../shaders/renderer.wgsl?raw';

const VRAM_WIDTH = 1024;
const VRAM_HEIGHT = 512;
const VRAM_SIZE = VRAM_WIDTH * VRAM_HEIGHT;

class GPUComputeRasterizer {
  constructor() {
    this.canvas = new OffscreenCanvas(VRAM_WIDTH, VRAM_HEIGHT);
    this.ctx = this.canvas.getContext('webgpu')!;
  }

  async Init(gpustat: number, gp0Commands: GP0Command[], vramBuf: ArrayBuffer) {
    const adapter = await navigator.gpu?.requestAdapter();
    const device = await adapter?.requestDevice();

    if (!device) {
      throw Error('need a browser that supports WebGPU');
    }

    this.device = device;

    this.InitBuffers(gpustat, gp0Commands, vramBuf);
    this.InitComputeResources();
    this.InitRenderResources();
  }

  Render(canvasRef: React.RefObject<HTMLCanvasElement>) {
    const encoder = this.device!.createCommandEncoder({
      label: 'encoder',
    });

    // TODO: only do once
    const initVramPass = encoder.beginComputePass({
      label: 'init vram pass',
    });

    initVramPass.setPipeline(this.initVramPipeline!);
    initVramPass.setBindGroup(0, this.rasterizerBindGroup!);
    initVramPass.dispatchWorkgroups(VRAM_SIZE / 256);
    initVramPass.end();

    // ====

    const fillRectPass = encoder.beginComputePass({
      label: 'fill rect pass',
    });

    fillRectPass.setPipeline(this.fillRectPipeline!);
    fillRectPass.setBindGroup(0, this.rasterizerBindGroup!);
    fillRectPass.dispatchWorkgroups(1);
    fillRectPass.end();

    // ====

    const renderPolyPass = encoder.beginComputePass({
      label: 'render polygon pass',
    });

    renderPolyPass.setPipeline(this.renderPolyPipeline!);
    renderPolyPass.setBindGroup(0, this.rasterizerBindGroup!);
    renderPolyPass.dispatchWorkgroups(1); // TODO: commands.length / sizeof(command) / 256
    // todo: one pass for fill rect, one pass for poly, one pass for line, one pass for rect
    // todo: one pass to clear zbuffer

    renderPolyPass.end();

    // ====

    const renderPassDescriptor: GPURenderPassDescriptor = {
      colorAttachments: [
        {
          view: this.ctx.getCurrentTexture().createView(),
          clearValue: {r: 1.0, g: 1.0, b: 1.0, a: 1.0},
          loadOp: 'clear',
          storeOp: 'store',
        },
      ],
    };
    const drawPass = encoder.beginRenderPass(renderPassDescriptor);
    drawPass.setPipeline(this.rendererPipeline!);
    drawPass.setBindGroup(0, this.rendererBindGroup!);
    drawPass.draw(6, 1, 0, 0);
    drawPass.end();

    // ====

    const commandBuffer = encoder.finish();
    this.device!.queue.submit([commandBuffer]);

    // ====

    // TODO: from gputstat info, only draw dispenv portion
    const onscreenCanvas = canvasRef.current!;
    const onscreenCtx = onscreenCanvas.getContext('2d')!;

    onscreenCtx.drawImage(this.canvas, 0, 0);
  }

  private InitBuffers(
    gpustat: number,
    gp0Commands: GP0Command[],
    vramBuf: ArrayBuffer
  ) {
    const gpustatArray = this.BuildGpustatArray(gpustat);
    const gp0CommandsArray = this.BuildGP0CommandsArray(gp0Commands);
    const vramBuf16Array = new Uint32Array(vramBuf);

    // ====

    // TODO struct on wgsl side
    this.gpustatBuffer = this.device!.createBuffer({
      label: 'gpustat uniforms buffer',
      size: gpustatArray.byteLength,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(this.gpustatBuffer, 0, gpustatArray);

    // ====

    // TODO struct on wgsl side
    // contains the size of each commands
    const commandsListInfo = new Uint32Array([1, 1, 1, 1]);

    this.commandsListInfoBuffer = this.device!.createBuffer({
      label: 'commands list info uniforms buffer',
      size: commandsListInfo.byteLength,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(
      this.commandsListInfoBuffer,
      0,
      commandsListInfo
    );

    // ====

    this.gp0CommandsBuffer = this.device!.createBuffer({
      label: 'gp0 commands uniforms buffer',
      size: gp0CommandsArray.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(this.gp0CommandsBuffer, 0, gp0CommandsArray);

    // ====

    this.vramBuffer16 = this.device!.createBuffer({
      label: 'vram 16 buffer',
      size: vramBuf16Array.byteLength,
      usage:
        GPUBufferUsage.STORAGE |
        GPUBufferUsage.COPY_SRC |
        GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(this.vramBuffer16, 0, vramBuf16Array);

    // ====

    this.vramBuffer32 = this.device!.createBuffer({
      label: 'vram 32 buffer',
      size: Uint32Array.BYTES_PER_ELEMENT * VRAM_SIZE,
      usage:
        GPUBufferUsage.STORAGE |
        GPUBufferUsage.COPY_SRC |
        GPUBufferUsage.COPY_DST,
    });
  }

  private BuildGpustatArray(gpustat: number) {
    // TODO: GPUStat class helper + struct of u32 instead of raw bitfield?

    return new Uint32Array([gpustat]);
  }

  private BuildGP0CommandsArray(gp0Commands: GP0Command[]) {
    // TODO: also include the z-index
    for (const command of gp0Commands) {
      console.log(command);
    }

    return new Uint32Array([1, 0, 0xff00ffff]);
  }

  private InitComputeResources() {
    const module = this.device!.createShaderModule({
      label: 'compute module',
      code: computeShaderWGSL,
    });

    const bindGroupLayout = this.device!.createBindGroupLayout({
      label: 'compute bind group layout',
      entries: [
        {
          binding: 0,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {}, // gpustat uniforms buffer
        },
        {
          binding: 1,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {}, // commands list info uniforms buffer
        },
        {
          binding: 2,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {type: 'read-only-storage'}, // gp0 commands storage buffer
        },
        {
          binding: 3,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {type: 'read-only-storage'}, // vram16 buffer storage buffer
        },
        {
          binding: 4,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {type: 'storage'}, // vram32 buffer storage buffer
        },
      ],
    });

    const pipelineLayout = this.device!.createPipelineLayout({
      label: 'compute pipeline layout',
      bindGroupLayouts: [bindGroupLayout],
    });

    this.initVramPipeline = this.device!.createComputePipeline({
      label: 'init vram pipeline',
      layout: pipelineLayout,
      compute: {
        module,
        entryPoint: 'InitVram',
      },
    });

    this.fillRectPipeline = this.device!.createComputePipeline({
      label: 'fill rect pipeline',
      layout: pipelineLayout,
      compute: {
        module,
        entryPoint: 'FillRect',
      },
    });

    this.renderPolyPipeline = this.device!.createComputePipeline({
      label: 'render polygon pipeline',
      layout: pipelineLayout,
      compute: {
        module,
        entryPoint: 'RenderPoly',
      },
    });

    this.rasterizerBindGroup = this.device!.createBindGroup({
      label: 'rasterizer bind group',
      layout: bindGroupLayout,
      entries: [
        {
          binding: 0,
          resource: {buffer: this.gpustatBuffer!},
        },
        {
          binding: 1,
          resource: {buffer: this.commandsListInfoBuffer!},
        },
        {
          binding: 2,
          resource: {buffer: this.gp0CommandsBuffer!},
        },
        {
          binding: 3,
          resource: {buffer: this.vramBuffer16!},
        },
        {
          binding: 4,
          resource: {buffer: this.vramBuffer32!},
        },
      ],
    });
  }

  private InitRenderResources() {
    const module = this.device!.createShaderModule({
      label: 'renderer module',
      code: rendererShaderWGSL,
    });

    const bindGroupLayout = this.device!.createBindGroupLayout({
      label: 'renderer bind group layout',
      entries: [
        {
          binding: 0,
          visibility: GPUShaderStage.FRAGMENT,
          buffer: {type: 'read-only-storage'}, // vram buffer
        },
      ],
    });

    const pipelineLayout = this.device!.createPipelineLayout({
      label: 'renderer pipeline layout',
      bindGroupLayouts: [bindGroupLayout],
    });

    const presentationFormat = navigator.gpu.getPreferredCanvasFormat();
    this.ctx.configure({
      device: this.device!,
      format: presentationFormat,
      alphaMode: 'opaque',
    });

    this.rendererPipeline = this.device!.createRenderPipeline({
      label: 'renderer pipeline',
      layout: pipelineLayout,
      vertex: {
        module,
        entryPoint: 'VSMain',
      },
      fragment: {
        module,
        entryPoint: 'PSMain',
        targets: [
          {
            format: presentationFormat,
          },
        ],
      },
    });

    this.rendererBindGroup = this.device!.createBindGroup({
      label: 'renderer bind group',
      layout: bindGroupLayout,
      entries: [
        {
          binding: 0,
          resource: {buffer: this.vramBuffer32!},
        },
      ],
    });
  }

  private readonly canvas;
  private readonly ctx;

  private device?: GPUDevice;
  private initVramPipeline?: GPUComputePipeline;
  private fillRectPipeline?: GPUComputePipeline;
  private renderPolyPipeline?: GPUComputePipeline;
  private rendererPipeline?: GPURenderPipeline;

  private gpustatBuffer?: GPUBuffer;
  private commandsListInfoBuffer?: GPUBuffer;
  private gp0CommandsBuffer?: GPUBuffer;
  private vramBuffer16?: GPUBuffer;
  private vramBuffer32?: GPUBuffer; // zbuf + color [zzzz|mbgr]

  private rasterizerBindGroup?: GPUBindGroup;
  private rendererBindGroup?: GPUBindGroup;
}

export default GPUComputeRasterizer;
