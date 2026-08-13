import { randomBytes } from 'node:crypto';
import { createWriteStream, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const RESTART_DELAY_MS = 5000;
const ADAPTIVE_TIMESTAMP_FILTER = "setts=ts='if(eq(N,0),0,PREV_OUTDTS+DURATION+0.02*(TS-STARTDTS-PREV_OUTDTS))':duration=DURATION";

function describeFailure(error) {
  if (error instanceof Error) {
    const upstreamStatus = error.details?.upstreamStatus ? ` (upstream HTTP ${error.details.upstreamStatus})` : '';
    return `${error.name}: ${error.message}${upstreamStatus}`;
  }
  if (typeof error === 'string') return error;
  if (error === undefined) return 'undefined rejection';
  if (error === null) return 'null rejection';
  return `non-Error rejection (${typeof error})`;
}

function cameraFailure(error) {
  if (error?.details?.upstreamStatus === 403 && error.details?.upstreamCode === 8) {
    return {
      message: 'Bambu Cloud denied remote camera access for this session.',
      retry: false,
    };
  }
  if (error?.details?.upstreamStatus === 401) {
    return { message: 'The Bambu Cloud session has expired.', retry: false };
  }
  return { message: 'Unable to connect to the printer camera.', retry: true };
}

function stopProcess(childProcess) {
  if (!childProcess || childProcess.exitCode !== null) return;
  if (process.platform === 'win32') {
    spawn('taskkill.exe', ['/PID', String(childProcess.pid), '/T', '/F'], { windowsHide: true });
  } else {
    childProcess.kill('SIGTERM');
  }
}

export class StreamManager {
  constructor({ cameraToolsPath, runtimeDirectory, rtspPublishBase = 'rtsp://127.0.0.1:8554' }) {
    this.cameraToolsPath = cameraToolsPath;
    this.runtimeDirectory = join(runtimeDirectory, 'streams');
    this.rtspPublishBase = rtspPublishBase.replace(/\/$/, '');
    this.streams = new Map();
    mkdirSync(this.runtimeDirectory, { recursive: true });
  }

  publicStream(stream) {
    return {
      id: stream.id,
      printerId: stream.printer.id,
      printerName: stream.printer.name,
      status: stream.status,
      error: stream.error,
      whepUrl: `/webrtc/${stream.path}/whep`,
    };
  }

  list(ownerId) {
    return [...this.streams.values()]
      .filter((stream) => stream.ownerId === ownerId)
      .map((stream) => this.publicStream(stream));
  }

  start(ownerId, printer, descriptorProvider) {
    const existing = [...this.streams.values()].find(
      (stream) => stream.ownerId === ownerId && stream.printer.id === printer.id,
    );
    if (existing) return this.publicStream(existing);

    const id = randomBytes(18).toString('base64url');
    const stream = {
      id,
      path: `account-${id}`,
      ownerId,
      printer,
      descriptorProvider,
      status: 'starting',
      error: null,
      stopped: false,
      source: null,
      ffmpeg: null,
      restartTimer: null,
    };
    this.streams.set(id, stream);
    this.launch(stream);
    return this.publicStream(stream);
  }

  get(ownerId, id) {
    const stream = this.streams.get(id);
    return stream?.ownerId === ownerId ? this.publicStream(stream) : null;
  }

  async launch(stream) {
    if (stream.stopped) return;
    stream.status = 'starting';
    stream.error = null;
    const streamDirectory = join(this.runtimeDirectory, stream.id);
    const descriptorPath = join(streamDirectory, 'camera.txt');
    mkdirSync(streamDirectory, { recursive: true });

    try {
      const descriptor = await stream.descriptorProvider();
      if (stream.stopped) return;
      writeFileSync(descriptorPath, descriptor, { encoding: 'ascii', mode: 0o600 });
      const cameraPath = descriptorPath.replaceAll('\\', '/');
      const source = spawn(join(this.cameraToolsPath, 'bambu_source.exe'), [`bambu:///camera/${cameraPath}`], {
        cwd: this.cameraToolsPath,
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      const ffmpeg = spawn(join(this.cameraToolsPath, 'ffmpeg.exe'), [
        '-hide_banner', '-loglevel', 'warning',
        '-fflags', 'nobuffer', '-flags', 'low_delay',
        '-use_wallclock_as_timestamps', '1', '-analyzeduration', '100000', '-probesize', '32768',
        '-f', 'h264', '-i', 'pipe:0', '-map', '0:v:0', '-an', '-c:v', 'copy',
        '-bsf:v', ADAPTIVE_TIMESTAMP_FILTER,
        '-f', 'rtsp', '-rtsp_transport', 'tcp',
        `${this.rtspPublishBase}/${stream.path}`,
      ], {
        cwd: this.cameraToolsPath,
        windowsHide: true,
        stdio: ['pipe', 'ignore', 'pipe'],
      });
      stream.source = source;
      stream.ffmpeg = ffmpeg;
      source.stdout.pipe(ffmpeg.stdin);
      source.stderr.pipe(createWriteStream(join(streamDirectory, 'camera-source.log'), { flags: 'a' }));
      ffmpeg.stderr.pipe(createWriteStream(join(streamDirectory, 'ffmpeg.log'), { flags: 'a' }));
      stream.status = 'live';

      let handled = false;
      const exited = () => {
        if (handled || stream.stopped) return;
        handled = true;
        stopProcess(source);
        stopProcess(ffmpeg);
        stream.status = 'reconnecting';
        stream.restartTimer = setTimeout(() => this.launch(stream), RESTART_DELAY_MS);
      };
      source.once('exit', exited);
      ffmpeg.once('exit', exited);
      source.once('error', exited);
      ffmpeg.once('error', exited);
    } catch (error) {
      const failure = cameraFailure(error);
      stream.status = 'error';
      stream.error = failure.message;
      console.error(`${new Date().toISOString()} Stream ${stream.id} failed: ${describeFailure(error)}`);
      if (failure.retry) stream.restartTimer = setTimeout(() => this.launch(stream), RESTART_DELAY_MS);
    }
  }

  stop(ownerId, id) {
    const stream = this.streams.get(id);
    if (!stream || stream.ownerId !== ownerId) return false;
    stream.stopped = true;
    clearTimeout(stream.restartTimer);
    stopProcess(stream.source);
    stopProcess(stream.ffmpeg);
    const streamDirectory = join(this.runtimeDirectory, stream.id);
    try {
      rmSync(streamDirectory, { recursive: true, force: true });
    } catch {
      const cleanupTimer = setTimeout(() => {
        try {
          rmSync(streamDirectory, { recursive: true, force: true });
        } catch {
          console.error(`${new Date().toISOString()} Unable to remove stream runtime directory ${stream.id}.`);
        }
      }, 1500);
      cleanupTimer.unref();
    }
    this.streams.delete(id);
    return true;
  }

  stopOwner(ownerId) {
    for (const stream of [...this.streams.values()]) this.stop(ownerId, stream.id);
  }

  stopAll() {
    for (const stream of [...this.streams.values()]) this.stop(stream.ownerId, stream.id);
  }
}