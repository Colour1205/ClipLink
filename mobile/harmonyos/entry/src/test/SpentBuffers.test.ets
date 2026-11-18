import { describe, it, expect } from '@ohos/hypium';
import { MIN_SPENT_BYTES, SpentBuffers } from '../main/ets/networking/SpentBuffers';

function sizes(batches: ArrayBuffer[][]): string {
  return JSON.stringify(batches.map((batch: ArrayBuffer[]): number[] => batch.map((b: ArrayBuffer): number => b.byteLength)));
}

export default function spentBuffersTest() {
  describe('SpentBuffers', () => {
    it('handsOverABatchOnceEnoughIsWaiting', 0, () => {
      const batches: ArrayBuffer[][] = [];
      const spent = new SpentBuffers((buffers: ArrayBuffer[]): void => { batches.push(buffers); });
      // 466 KB, a file chunk's line: 17 of them pass 8 MB.
      for (let i = 0; i < 17; i++) spent.release(new ArrayBuffer(466 * 1024));
      expect(batches.length).assertEqual(0);
      spent.release(new ArrayBuffer(466 * 1024));
      expect(batches.length).assertEqual(1);
      expect(batches[0].length).assertEqual(18);
      expect(spent.waitingBytes).assertEqual(0);
      spent.flush();
      expect(batches.length).assertEqual(1);
    });

    it('handsOverWhatIsLeftSoonAfter', 0, async () => {
      const batches: ArrayBuffer[][] = [];
      const spent = new SpentBuffers((buffers: ArrayBuffer[]): void => { batches.push(buffers); });
      spent.release(new ArrayBuffer(100 * 1024));
      expect(spent.waitingBytes).assertEqual(100 * 1024);
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 120); });
      expect(sizes(batches)).assertEqual('[[102400]]');
      expect(spent.waitingBytes).assertEqual(0);
    });

    it('leavesSmallAndRepeatedBuffersAlone', 0, () => {
      const batches: ArrayBuffer[][] = [];
      const spent = new SpentBuffers((buffers: ArrayBuffer[]): void => { batches.push(buffers); });
      spent.release(new ArrayBuffer(MIN_SPENT_BYTES - 1));
      spent.release(new ArrayBuffer(0));
      const once: ArrayBuffer = new ArrayBuffer(MIN_SPENT_BYTES);
      spent.release(once);
      // The same buffer twice would make the whole batch fail to transfer.
      spent.release(once);
      spent.flush();
      expect(sizes(batches)).assertEqual(`[[${MIN_SPENT_BYTES}]]`);
    });

    it('survivesAHandThatFails', 0, () => {
      let calls: number = 0;
      const spent = new SpentBuffers((buffers: ArrayBuffer[]): void => {
        calls++;
        throw new Error('no worker');
      });
      spent.release(new ArrayBuffer(MIN_SPENT_BYTES));
      spent.flush();
      spent.release(new ArrayBuffer(MIN_SPENT_BYTES));
      spent.flush();
      expect(calls).assertEqual(2);
      expect(spent.waitingBytes).assertEqual(0);
    });
  });
}
