import {useRef} from 'react';
import {BuildGP0CommandList} from './GPUCommands';
import './App.css';
import GPUComputeRasterizer from './GPUComputeRasterizer';
import InitWasm, {BuildGP0CommandLists} from '../gpu-commands/pkg/gpu_commands';

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
  const {vramViewerRef} = params.canvasRef;

  await InitWasm();
  const commandLists = BuildGP0CommandLists(Uint32Array.from(gpuCommands));

  const commandList = BuildGP0CommandList(gpuCommands);
  console.log(commandList);

  const rasterizer = new GPUComputeRasterizer();
  await rasterizer.Init(gpustat, commandLists, vramBuf);

  rasterizer.Render(vramViewerRef);
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
