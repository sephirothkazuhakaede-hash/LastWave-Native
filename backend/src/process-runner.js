import { spawn } from 'node:child_process';
import { ProcessError } from './errors.js';

const MAX_CAPTURE_BYTES = 12 * 1024 * 1024;

function appendCapped(chunks, chunk, state) {
  if (state.bytes >= MAX_CAPTURE_BYTES) return;
  const remaining = MAX_CAPTURE_BYTES - state.bytes;
  const selected = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
  chunks.push(selected);
  state.bytes += selected.length;
}

export function runProcess(command, args, { timeoutMs = 60_000, cwd, signal } = {}) {
  return new Promise((resolve, reject) => {
    const stdoutChunks = [];
    const stderrChunks = [];
    const stdoutState = { bytes: 0 };
    const stderrState = { bytes: 0 };
    let timedOut = false;
    let settled = false;

    const child = spawn(command, args, {
      cwd,
      windowsHide: true,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const stop = () => {
      if (!child.killed) child.kill();
    };
    const timer = setTimeout(() => {
      timedOut = true;
      stop();
    }, timeoutMs);
    timer.unref?.();

    const abort = () => stop();
    signal?.addEventListener('abort', abort, { once: true });

    child.stdout.on('data', (chunk) => appendCapped(stdoutChunks, chunk, stdoutState));
    child.stderr.on('data', (chunk) => appendCapped(stderrChunks, chunk, stderrState));

    child.once('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      reject(new ProcessError(`Could not start ${command}.`, { cause: error }));
    });

    child.once('close', (exitCode) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      const stdout = Buffer.concat(stdoutChunks).toString('utf8');
      const stderr = Buffer.concat(stderrChunks).toString('utf8').trim();
      if (exitCode === 0 && !timedOut && !signal?.aborted) {
        resolve({ stdout, stderr, exitCode });
        return;
      }
      const reason = timedOut ? 'timed out' : signal?.aborted ? 'was cancelled' : `exited with code ${exitCode}`;
      reject(new ProcessError(`${command} ${reason}.`, { exitCode, stderr, timedOut }));
    });
  });
}
