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
      renderingAttributesCount: 0,
      fillRectCount: 0,
      renderPolyCount: 0,
      renderTransparentPolyCount: 0,
      renderLineCount: 0,
      renderRectCount: 0,
    };
  }

  async Init(gp0CommandLists: GP0CommandLists, vramBuf: ArrayBuffer) {
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
    const renderTransparentPolyCount =
      gp0CommandLists.RenderTransparentPolyCommandCount /
      gp0CommandLists.RenderTransparentPolyCommandSize;
    const renderingAttributesCount =
      gp0CommandLists.RenderingAttributesCount /
      gp0CommandLists.RenderingAttributesSize;

    console.warn('OPAQUE count', renderPolyCount);
    console.warn('TRANSPARENT count', renderTransparentPolyCount);

    this.commandListsInfo = {
      renderingAttributesCount,
      fillRectCount,
      renderPolyCount,
      renderTransparentPolyCount,
      renderLineCount: 0,
      renderRectCount: 0,
    };

    console.log(this.commandListsInfo);

    this.InitBuffers(gp0CommandLists, vramBuf);
    this.InitComputeResources();
    this.InitRenderResources();
  }

  Render(canvasRef: React.RefObject<HTMLCanvasElement>) {
    const encoder = this.device!.createCommandEncoder({
      label: 'encoder',
    });

    // TODO: do this on init, not render
    const initVramPass = encoder.beginComputePass({
      label: 'init vram pass',
    });

    initVramPass.setPipeline(this.initVramPipeline!);
    initVramPass.setBindGroup(0, this.rasterizerBindGroup!);
    initVramPass.dispatchWorkgroups(VRAM_SIZE / 256 / 2);
    initVramPass.end();

    // ====
    // TODO: combine all render compute pass into a single pass

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

    if (this.commandListsInfo.renderTransparentPolyCount > 0) {
      const renderTransparentPolyPass = encoder.beginComputePass({
        label: 'render transparent polygon pass',
      });

      renderTransparentPolyPass.setPipeline(
        this.renderTransparentPolyPipeline!
      );
      renderTransparentPolyPass.setBindGroup(0, this.rasterizerBindGroup!);
      renderTransparentPolyPass.dispatchWorkgroups(16, 8);
      renderTransparentPolyPass.end();
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
    drawPass.draw(3, 1, 0, 0);
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

  private InitBuffers(gp0CommandLists: GP0CommandLists, vramBuf: ArrayBuffer) {
    const vramBuf16Array = new Uint32Array(vramBuf);

    // FIXME: filthy hack
    const renderingAttributesArray =
      this.commandListsInfo.renderingAttributesCount > 0
        ? gp0CommandLists.RenderingAttributess
        : new Uint8Array(gp0CommandLists.RenderingAttributesSize);
    console.log(renderingAttributesArray);

    this.renderingAttributesBuffer = this.device!.createBuffer({
      label: 'rendering attributes storage buffer',
      size: renderingAttributesArray.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(
      this.renderingAttributesBuffer,
      0,
      renderingAttributesArray
    );

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
    console.log(this.commandListsInfo.renderPolyCount);
    console.log(renderPolyCommandsArray);

    this.renderPolyCommandsBuffer = this.device!.createBuffer({
      label: 'gp0 render poly commands storage buffer',
      size: renderPolyCommandsArray.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(
      this.renderPolyCommandsBuffer, // TODO: only one buffer
      0,
      renderPolyCommandsArray
    );

    // ====

    // FIXME: filthy hack
    const renderTransparentPolyCommandsArray =
      this.commandListsInfo.renderTransparentPolyCount > 0
        ? gp0CommandLists.RenderTransparentPolyCommands
        : new Uint8Array(gp0CommandLists.RenderTransparentPolyCommandSize);
    console.log(this.commandListsInfo.renderTransparentPolyCount);
    console.log(renderTransparentPolyCommandsArray);

    this.renderTransparentPolyCommandsBuffer = this.device!.createBuffer({
      label: 'gp0 render transparent poly commands storage buffer',
      size: renderTransparentPolyCommandsArray.byteLength,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.device!.queue.writeBuffer(
      this.renderTransparentPolyCommandsBuffer, // TODO: only one buffer
      0,
      renderTransparentPolyCommandsArray
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
          buffer: {type: 'read-only-storage'}, // rendering attributes storage buffer
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
        {
          binding: 6,
          visibility: GPUShaderStage.COMPUTE,
          buffer: {type: 'read-only-storage'}, // gp0 render transparent poly commands storage buffer
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

    this.renderTransparentPolyPipeline = this.device!.createComputePipeline({
      label: 'render transparent polygon pipeline',
      layout: pipelineLayout,
      compute: {
        module,
        entryPoint: 'RenderTransparentPoly',
      },
    });

    this.rasterizerBindGroup = this.device!.createBindGroup({
      label: 'rasterizer bind group',
      layout: bindGroupLayout,
      entries: [
        {
          binding: 0,
          resource: {buffer: this.renderingAttributesBuffer!},
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
          resource: {buffer: this.fillRectCommandsBuffer!}, // TODO: only one buffer, add offset
        },
        {
          binding: 5,
          resource: {buffer: this.renderPolyCommandsBuffer!}, // TODO: only one buffer, add offset
        },
        {
          binding: 6,
          resource: {buffer: this.renderTransparentPolyCommandsBuffer!}, // TODO: only one buffer, add offset
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
  private renderTransparentPolyPipeline?: GPUComputePipeline;
  private rendererPipeline?: GPURenderPipeline;

  private vramBuffer16?: GPUBuffer;
  private vramBuffer32?: GPUBuffer; // zbuf + color [zzzz|mbgr]
  private commandListsInfoBuffer?: GPUBuffer;

  private renderingAttributesBuffer?: GPUBuffer;
  private fillRectCommandsBuffer?: GPUBuffer;
  private renderPolyCommandsBuffer?: GPUBuffer;
  private renderTransparentPolyCommandsBuffer?: GPUBuffer;

  private rasterizerBindGroup?: GPUBindGroup;
  private rendererBindGroup?: GPUBindGroup;

  private commandListsInfo: CommandListsInfo;
}

interface CommandListsInfo {
  renderingAttributesCount: number;
  fillRectCount: number;
  renderPolyCount: number;
  renderTransparentPolyCount: number;
  renderLineCount: number;
  renderRectCount: number;
}

export default GPUComputeRasterizer;
