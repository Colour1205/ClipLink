import { describe, it, expect } from '@ohos/hypium';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  AmountParts, ProgressThrottle, SpeedMeter, TransferView, amountParts, percentLabel, progressFraction, receivedLabel,
  speedLabel, transferView
} from '../main/ets/networking/TransferProgress';
import { EMPTY_FILE_HASH, hexString } from '../main/ets/storage/FileStore';

const MIB: number = 1024 * 1024;

// A meter fed `bytesPerSecond` from 0, a report every 250 ms, up to `untilMs`.
function steadyMeter(bytesPerSecond: number, untilMs: number): SpeedMeter {
  const meter: SpeedMeter = new SpeedMeter();
  for (let t = 0; t <= untilMs; t += 250) {
    meter.add(Math.round(bytesPerSecond * t / 1000), t);
  }
  return meter;
}

function amount(parts: AmountParts): string {
  return `${parts.done} of ${parts.total} ${parts.unit}`;
}

// The SHA-256 of `bytes` fed in pieces of `piece` bytes with updateSync, as
// SyncManager hashes a file while it writes it; '' if this runtime has no real
// digest (the local unit-test runtime may stub the crypto framework).
function digestInPieces(bytes: Uint8Array, piece: number): string {
  try {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    for (let at = 0; at < bytes.length; at += piece) {
      md.updateSync({ data: bytes.slice(at, Math.min(bytes.length, at + piece)) });
    }
    return hexString(md.digestSync().data);
  } catch (e) {
    return '';
  }
}

export default function transferProgressTest() {
  describe('TransferProgress', () => {
    it('reportsAtMostFourTimesASecond', 0, () => {
      const throttle: ProgressThrottle = new ProgressThrottle();
      expect(throttle.due(1000)).assertTrue();
      expect(throttle.due(1100)).assertFalse();
      expect(throttle.due(1249)).assertFalse();
      expect(throttle.due(1250)).assertTrue();
      expect(throttle.due(1400)).assertFalse();
      expect(throttle.due(1600)).assertTrue();
    });

    it('hidesTheSpeedForTheFirstMoments', 0, () => {
      const meter: SpeedMeter = new SpeedMeter();
      meter.add(0, 0);
      meter.add(2 * MIB, 250);
      meter.add(4 * MIB, 500);
      expect(meter.bytesPerSecond(500)).assertEqual(-1);
      meter.add(6 * MIB, 750);
      expect(meter.bytesPerSecond(750)).assertEqual(8 * MIB);
    });

    it('measuresOverAboutTheLastTwoSeconds', 0, () => {
      // 10 MB/s for 3 s, then 2 MB/s: after 2 s at the new pace the old one
      // has left the window.
      const meter: SpeedMeter = new SpeedMeter();
      let bytes = 0;
      for (let t = 0; t <= 5000; t += 250) {
        if (t > 0) bytes += (t <= 3000 ? 10 : 2) * MIB / 4;
        meter.add(bytes, t);
      }
      expect(Math.round(meter.bytesPerSecond(5000) / MIB)).assertEqual(2);
      expect(Math.round(steadyMeter(8.3 * MIB, 4000).bytesPerSecond(4000) / MIB * 10)).assertEqual(83);
    });

    it('saysWaitingAfterThreeSecondsWithNoBytes', 0, () => {
      const meter: SpeedMeter = steadyMeter(MIB, 2000);
      expect(meter.stalled(4999)).assertFalse();
      expect(meter.stalled(5000)).assertTrue();
      expect(meter.bytesPerSecond(5000)).assertEqual(-1);
      // Bytes again: no longer waiting.
      meter.add(3 * MIB, 5100);
      expect(meter.stalled(5100)).assertFalse();
    });

    it('startsAgainWhenTheSenderDoes', 0, () => {
      const meter: SpeedMeter = steadyMeter(10 * MIB, 3000);
      // Chunk 0 again: fewer bytes than before is a new stream, measured from
      // its own start (and hidden at first again).
      meter.add(256 * 1024, 3250);
      expect(meter.bytesPerSecond(3250)).assertEqual(-1);
      expect(meter.stalled(3250)).assertFalse();
    });

    it('measuresFromTheStreamNotFromWhenTheCardWasListed', 0, () => {
      // The card is listed (a report of 0) 4 s before the stream's own 0.
      const meter: SpeedMeter = new SpeedMeter();
      meter.add(0, 0);
      meter.add(0, 4000);
      meter.add(2 * MIB, 4250);
      // Hidden at first, as for any stream, not 2 MB spread over 4.25 s.
      expect(meter.bytesPerSecond(4250)).assertEqual(-1);
      meter.add(4 * MIB, 4500);
      expect(meter.bytesPerSecond(4500)).assertEqual(-1);
      meter.add(6 * MIB, 4750);
      expect(meter.bytesPerSecond(4750)).assertEqual(8 * MIB);
    });

    it('writesTheSpeedAsPeopleReadIt', 0, () => {
      expect(speedLabel(-1)).assertEqual('');
      expect(speedLabel(8.3 * MIB)).assertEqual('8.3 MB/s');
      expect(speedLabel(123.4 * MIB)).assertEqual('123 MB/s');
      expect(speedLabel(512 * 1024)).assertEqual('512 KB/s');
      expect(speedLabel(10)).assertEqual('1 KB/s');
    });

    it('neverSays100PercentBeforeTheLastByte', 0, () => {
      expect(percentLabel(0, 1000)).assertEqual('0%');
      expect(percentLabel(430, 1000)).assertEqual('43%');
      expect(percentLabel(999, 1000)).assertEqual('99%');
      expect(percentLabel(9995, 10000)).assertEqual('99%');
      expect(percentLabel(1000, 1000)).assertEqual('100%');
      expect(percentLabel(1200, 1000)).assertEqual('100%');
      expect(percentLabel(5, 0)).assertEqual('');
      expect(progressFraction(250, 1000)).assertEqual(0.25);
      expect(progressFraction(2000, 1000)).assertEqual(1);
      expect(progressFraction(10, 0)).assertEqual(-1);
    });

    it('writesHowMuchHasArrivedInTheTotalsUnit', 0, () => {
      expect(amount(amountParts(124 * MIB, 290 * MIB))).assertEqual('124 of 290 MB');
      // Rounded down: never the whole before it is.
      expect(amount(amountParts(290 * MIB - 1, 290 * MIB))).assertEqual('289 of 290 MB');
      expect(amount(amountParts(1.45 * MIB, 3.2 * MIB))).assertEqual('1.4 of 3.2 MB');
      expect(amount(amountParts(300 * 1024, 473 * 1024))).assertEqual('300 of 473 KB');
      expect(amount(amountParts(1.2 * 1024 * MIB, 2.5 * 1024 * MIB))).assertEqual('1.2 of 2.5 GB');
      expect(amount(amountParts(100, 500))).assertEqual('100 of 500 B');
      expect(receivedLabel(12.4 * MIB)).assertEqual('12.4 MB');
      expect(receivedLabel(300)).assertEqual('300 B');
    });

    it('showsTheNumbersWhileReceiving', 0, () => {
      const meter: SpeedMeter = steadyMeter(8.3 * MIB, 4000);
      const view: TransferView = transferView('receiving', 124 * MIB, 290 * MIB, meter, 4000);
      expect(view.speed).assertEqual('8.3 MB/s');
      expect(view.cardRight).assertEqual('42%');
      expect(amount(view.amount)).assertEqual('124 of 290 MB');
      expect(view.status).assertEqual('none');
      expect(view.done).assertFalse();
    });

    it('showsWhatArrivedWhenTheSizeIsNotKnown', 0, () => {
      const meter: SpeedMeter = steadyMeter(MIB, 1000);
      const view: TransferView = transferView('receiving', 12.4 * MIB, 0, meter, 1000);
      expect(view.fraction).assertEqual(-1);
      expect(view.cardRight).assertEqual('12.4 MB');
      expect(view.received).assertEqual('12.4 MB');
      expect(view.amount.total).assertEqual('');
    });

    it('putsAPlainWordInPlaceOfTheNumbers', 0, () => {
      const meter: SpeedMeter = steadyMeter(MIB, 1000);
      const stalled: TransferView = transferView('receiving', MIB, 10 * MIB, meter, 5000);
      expect(stalled.status).assertEqual('stalled');
      expect(stalled.speed).assertEqual('');
      expect(stalled.cardRight).assertEqual('10%');
      const retrying: TransferView = transferView('retrying', 0, 10 * MIB, new SpeedMeter(), 5000);
      expect(retrying.status).assertEqual('retrying');
      expect(retrying.cardRight).assertEqual('');
      expect(retrying.fraction).assertEqual(0);
      const waiting: TransferView = transferView('waiting', 0, 10 * MIB, new SpeedMeter(), 5000);
      expect(waiting.status).assertEqual('waiting');
      expect(waiting.speed).assertEqual('');
      const stopped: TransferView = transferView('stopped', 0, 10 * MIB, new SpeedMeter(), 5000);
      expect(stopped.status).assertEqual('stopped');
      expect(stopped.cardRight).assertEqual('');
      expect(stopped.speed).assertEqual('');
    });

    it('fillsTheBarWhenStored', 0, () => {
      const view: TransferView = transferView('done', 290 * MIB, 290 * MIB, steadyMeter(MIB, 1000), 9000);
      expect(view.fraction).assertEqual(1);
      expect(view.cardRight).assertEqual('100%');
      expect(view.speed).assertEqual('');
      expect(view.status).assertEqual('none');
      expect(view.done).assertTrue();
    });

    it('hashesAFileInPiecesTheSameAsWhole', 0, () => {
      expect(hexString(new Uint8Array([0, 1, 15, 16, 255]))).assertEqual('00010f10ff');
      // "abc" over and over, a bit more than two 256 KiB chunks, so the last
      // piece is short as a file's last chunk is.
      const bytes: Uint8Array = new Uint8Array(2 * 262144 + 1000);
      for (let i = 0; i < bytes.length; i++) bytes[i] = 97 + (i % 3);
      const whole: string = digestInPieces(bytes, bytes.length);
      if (whole === '' || whole === EMPTY_FILE_HASH || digestInPieces(new Uint8Array([97, 98, 99]), 3) !==
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') {
        console.info('TransferProgress: no real SHA-256 in this runtime - hashing while writing is checked on a device');
        return;
      }
      expect(digestInPieces(bytes, 262144)).assertEqual(whole);
      expect(digestInPieces(bytes, 4096)).assertEqual(whole);
    });
  });
}
