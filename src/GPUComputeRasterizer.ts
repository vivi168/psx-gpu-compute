import computeShaderWGSL from '../shaders/rasterizer.wgsl?raw';
import rendererShaderWGSL from '../shaders/renderer.wgsl?raw';
import {GP0CommandLists} from '../gpu-commands/pkg/gpu_commands';

const VRAM_WIDTH = 1024;
const VRAM_HEIGHT = 512;
const VRAM_SIZE = VRAM_WIDTH * VRAM_HEIGHT;

class GPUComputeRasterizer {
  constructor() {
    this.canvas = new OffscreenCanvas(VRAM_WIDTH, VRAM_HEIGHT);
    this.ctx = this.canvas.getContext('webgpu')!;

    this.commandListsInfo = {
      fillRectCount: 0,
      renderPolyCount: 0,
      renderLineCount: 0,
      renderRectCount: 0,
    };
  }

  async Init(
    gpustat: number,
    gp0CommandLists: GP0CommandLists,
    vramBuf: ArrayBuffer
  ) {
    const adapter = await navigator.gpu?.requestAdapter();
    const device = await adapter?.requestDevice();

    if (!device) {
      throw Error('need a browser that supports WebGPU');
    }

    this.device = device;

    const fillRectCount =
      gp0CommandLists.FillRectCommandCount /
      gp0CommandLists.FillRectCommandSize;
    const renderPolyCount =
      gp0CommandLists.RenderPolyCommandCount /
      gp0CommandLists.RenderPolyCommandSize;

    this.commandListsInfo = {
      fillRectCount,
      renderPolyCount,
      renderLineCount: 0,
      renderRectCount: 0,
    };

    this.InitBuffers(gpustat, gp0CommandLists, vramBuf);
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
    initVramPass.dispatchWorkgroups(VRAM_SIZE / 256 / 2);
    initVramPass.end();

    // ====

    if (this.commandListsInfo.fillRectCount > 0) {
      const fillRectPass = encoder.beginComputePass({
        label: 'fill rect pass',
      });

      fillRectPass.setPipeline(this.fillRectPipeline!);
      fillRectPass.setBindGroup(0, this.rasterizerBindGroup!);
      fillRectPass.dispatchWorkgroups(
        Math.ceil(this.commandListsInfo.fillRectCount / 256)
      );
      fillRectPass.end();
    }

    // ====

    if (this.commandListsInfo.renderPolyCount > 0) {
      const renderPolyPass = encoder.beginComputePass({
        label: 'render polygon pass',
      });

      renderPolyPass.setPipeline(this.renderPolyPipeline!);
      renderPolyPass.setBindGroup(0, this.rasterizerBindGroup!);
      renderPolyPass.dispatchWorkgroups(
        Math.ceil(this.commandListsInfo.renderPolyCount / 256)
      );
      renderPolyPass.end();
    }

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
    gp0CommandLists: GP0CommandLists,
    vramBuf: ArrayBuffer
  ) {
    const gpustatArray = this.BuildGpustatArray(gpustat);
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

    const commandsListInfo = Uint32Array.from(
      Object.values(this.commandListsInfo)
    );

    this.commandListsInfoBuffer = this.device!.createBuffer({
      label: 'commands list info uniforms buffer',
      size: commandsListInfo.byteLength,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(
      this.commandListsInfoBuffer,
      0,
      commandsListInfo
    );

    // ====

    // FIXME: filthy hack
    const fillRectCommandsArray =
      this.commandListsInfo.fillRectCount > 0
        ? gp0CommandLists.FillRectCommands
        : new Uint8Array(gp0CommandLists.FillRectCommandSize);
    console.log(fillRectCommandsArray);

    this.fillRectCommandsBuffer = this.device!.createBuffer({
      label: 'gp0 fill rect commands storage buffer',
      size: fillRectCommandsArray.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(
      this.fillRectCommandsBuffer,
      0,
      fillRectCommandsArray
    );

    // ====

    // FIXME: filthy hack
    const renderPolyCommandsArray =
      this.commandListsInfo.renderPolyCount > 0
        ? gp0CommandLists.RenderPolyCommands
        : new Uint8Array(gp0CommandLists.RenderPolyCommandSize);
    console.log(renderPolyCommandsArray);

    this.renderPolyCommandsBuffer = this.device!.createBuffer({
      label: 'gp0 render poly commands storage buffer',
      size: renderPolyCommandsArray.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(
      this.renderPolyCommandsBuffer,
      0,
      renderPolyCommandsArray
    );

    // ====

    this.vramBuffer16 = this.device!.createBuffer({
      label: 'vram 16 buffer',
      size: vramBuf16Array.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(this.vramBuffer16, 0, vramBuf16Array);

    // ====

    this.vramBuffer32 = this.device!.createBuffer({
      label: 'vram 32 buffer',
      size: Uint32Array.BYTES_PER_ELEMENT * VRAM_SIZE,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });
  }

  private BuildGpustatArray(gpustat: number) {
    // TODO: GPUStat class helper + struct of u32 instead of raw bitfield?

    return new Uint32Array([gpustat]);
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
          buffer: {type: 'read-only-storage'}, // vram16 buffer storage buffer
        },
        {
          binding: 2,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {type: 'storage'}, // vram32 buffer storage buffer
        },
        {
          binding: 3,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {}, // commands lists info uniforms buffer
        },
        {
          binding: 4,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {type: 'read-only-storage'}, // gp0 fill rect commands storage buffer
        },
        {
          binding: 5,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {type: 'read-only-storage'}, // gp0 render poly commands storage buffer
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
          resource: {buffer: this.vramBuffer16!},
        },
        {
          binding: 2,
          resource: {buffer: this.vramBuffer32!},
        },
        {
          binding: 3,
          resource: {buffer: this.commandListsInfoBuffer!},
        },
        {
          binding: 4,
          resource: {buffer: this.fillRectCommandsBuffer!},
        },
        {
          binding: 5,
          resource: {buffer: this.renderPolyCommandsBuffer!},
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
  private vramBuffer16?: GPUBuffer;
  private vramBuffer32?: GPUBuffer; // zbuf + color [zzzz|mbgr]
  private commandListsInfoBuffer?: GPUBuffer;

  private fillRectCommandsBuffer?: GPUBuffer;
  private renderPolyCommandsBuffer?: GPUBuffer;

  private rasterizerBindGroup?: GPUBindGroup;
  private rendererBindGroup?: GPUBindGroup;

  private commandListsInfo: CommandListsInfo;
}

interface CommandListsInfo {
  fillRectCount: number;
  renderPolyCount: number;
  renderLineCount: number;
  renderRectCount: number;
}

export default GPUComputeRasterizer;
