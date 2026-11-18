// The app's one SpentBuffers, and the TaskPool worker its buffers go to (see
// SpentBuffers.ets for why).

import { taskpool } from '@kit.ArkTS';
import { SpentBuffers } from './SpentBuffers';

// Runs on the worker. The buffers arrive there by transfer and are simply
// dropped; the worker's collector frees them.
@Concurrent
function dropBuffers(buffers: ArrayBuffer[]): number {
  return buffers.length;
}

function handToWorker(buffers: ArrayBuffer[]): void {
  const task: taskpool.Task = new taskpool.Task(dropBuffers, buffers);
  // Moved, not copied: each buffer is detached here as the task is queued.
  task.setTransferList(buffers);
  taskpool.execute(task).catch(() => { /* nothing to report: they are freed either way */ });
}

const spent: SpentBuffers = new SpentBuffers(handToWorker);

// This buffer will never be read or written again (see SpentBuffers.release).
export function releaseBuffer(buffer: ArrayBuffer): void {
  spent.release(buffer);
}
