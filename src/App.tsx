import {useRef} from 'react';
import {BuildGP0CommandList} from './GPUCommands';
import './App.css';
import GPUComputeRasterizer from './GPUComputeRasterizer';

function App() {
  const vramViewerRef = useRef<HTMLCanvasElement>(null);
  const framebufferRef = useRef<HTMLCanvasElement>(null);

  const submit = (e: React.SyntheticEvent) => {
    e.preventDefault();
    const target = e.target as typeof e.target & {
      gpustat: {value: string};
      gpuCommands: {value: string};
      vramDump: {files: FileList};
    };

    let gpustat = 0x14802000;
    const newGpustat = parseInt(target.gpustat.value, 16);
    if (!isNaN(newGpustat)) gpustat = newGpustat;
    console.log(gpustat);

    const gpuCommands = target.gpuCommands.value
      .split('\n')
      .map(c => parseInt(c.trim(), 16))
      .filter(c => !isNaN(c));
    console.log(gpuCommands);
    if (gpuCommands.length === 0) {
      return alert('need some commands!');
    }

    const file = target.vramDump.files[0];
    if (!file) {
      return alert('need a VRAM dump!');
    }

    const reader = new FileReader();
    reader.onload = () => {
      const vramBuf = reader.result as ArrayBuffer;

      Render({
        gpustat,
        gpuCommands,
        vramBuf,
        canvasRef: {vramViewerRef, framebufferRef},
      });
    };
    reader.readAsArrayBuffer(file);
  };

  return (
    <>
      <form onSubmit={submit}>
        <fieldset>
          <label htmlFor="gpustat">GPUSTAT</label>
          <input type="text" id="gpustat" placeholder="14802000" />
          <label htmlFor="gpuCommands">GPU GP0 Commands FIFO</label>
          <textarea id="gpuCommands" rows={5} placeholder="1337dead"></textarea>
          <label htmlFor="vramDump">VRAM dump</label>
          <input type="file" id="vramDump" />
        </fieldset>
        <input type="submit" />
      </form>

      <canvas ref={vramViewerRef} width={1024} height={512}></canvas>
      <canvas ref={framebufferRef}></canvas>
    </>
  );
}

async function Render(params: InitParams) {
  const {gpustat, gpuCommands, vramBuf} = params;
  const {vramViewerRef, framebufferRef} = params.canvasRef;

  LoadVramToCanvas(vramBuf, vramViewerRef);

  const commandList = BuildGP0CommandList(gpuCommands);
  console.log(commandList);

  const rasterizer = new GPUComputeRasterizer();
  await rasterizer.Init(gpustat, commandList, vramBuf);

  rasterizer.Render(framebufferRef);
}

function LoadVramToCanvas(
  vramBuf: ArrayBuffer,
  canvasRef: React.RefObject<HTMLCanvasElement>
) {
  const canvas = canvasRef.current!;
  const ctx = canvas.getContext('2d')!;

  const imageData = ctx.createImageData(canvas.width, canvas.height);
  const pixelData = imageData.data;
  const pixelsRGB555 = new Uint16Array(vramBuf);

  const mask = 31;
  for (let i = 0; i < pixelsRGB555.length; i++) {
    const c = pixelsRGB555[i];
    const r5 = c & mask;
    const g5 = (c >> 5) & mask;
    const b5 = (c >> 10) & mask;

    const r8 = (r5 * 527 + 23) >> 6;
    const g8 = (g5 * 527 + 23) >> 6;
    const b8 = (b5 * 527 + 23) >> 6;

    const idx = i * 4;

    pixelData[idx + 0] = r8;
    pixelData[idx + 1] = g8;
    pixelData[idx + 2] = b8;
    pixelData[idx + 3] = 255;
  }
  ctx.putImageData(imageData, 0, 0);
}

interface InitParams {
  gpustat: number;
  gpuCommands: number[];
  vramBuf: ArrayBuffer;
  canvasRef: {
    vramViewerRef: React.RefObject<HTMLCanvasElement>;
    framebufferRef: React.RefObject<HTMLCanvasElement>;
  };
}

export default App;
