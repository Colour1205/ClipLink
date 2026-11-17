// The bar on the card of a file that is still arriving, and in the opened
// item: one thin line, the speed above its left end, and above its right end
// the percentage (on a card) or "124 of 290 MB" (in the opened item). The
// numbers are worked out in networking/TransferProgress.ets.
//
// One TransferState per file, kept by Index in a plain Map and handed to
// every TransferBar that shows that file (its card, and the opened item). A
// report from SyncManager changes the state's fields, which redraws those
// bars and nothing else: the history list is never assigned again for
// progress, so the page is not laid out again 4 times a second.

import {
  PROGRESS_INTERVAL_MS, SpeedMeter, TransferPhase, TransferStatus, TransferView, transferView
} from '../networking/TransferProgress';

// When the last byte is stored the bar stays full this long, then fades out
// over FADE_MS, and the card becomes the file's normal card (see
// Index.finishArrival).
export const DONE_HOLD_MS: number = 300;
export const FADE_MS: number = 220;
// With reduce motion on: no hold, a short plain fade.
export const REDUCED_FADE_MS: number = 150;

const BAR_HEIGHT_VP: number = 3;

@Observed
export class TransferState {
  // What is drawn. Each is assigned only when it changes, so a report that
  // changes nothing on screen redraws nothing.
  fraction: number = 0;
  // How long the fill takes to reach `fraction`: one report's interval,
  // linearly, so it moves steadily between reports. 0 when it goes back (a
  // stream that started over jumps to the start, never sliding backwards)
  // and with reduce motion on.
  fillMs: number = PROGRESS_INTERVAL_MS;
  speed: string = '';
  cardRight: string = '';
  amountDone: string = '';
  amountTotal: string = '';
  amountUnit: string = '';
  received: string = '';
  status: TransferStatus = 'none';
  // The bar's opacity: 1, and 0 once a stored file's bar has faded out.
  shown: number = 1;

  // Not drawn: what the view is worked out from.
  phase: TransferPhase = 'receiving';
  bytes: number = 0;
  // The entry's FileSize; 0 or less when it is not known.
  total: number = 0;
  meter: SpeedMeter = new SpeedMeter();

  constructor(total: number) {
    this.total = total;
  }

  // A report from SyncManager.
  update(phase: TransferPhase, received: number, now: number, reduceMotion: boolean): void {
    if (phase === 'receiving') {
      this.meter.add(received, now);
    } else if (phase !== 'done') {
      // A failed stream: the next one is measured from its own start.
      this.meter.reset();
    }
    this.phase = phase;
    this.bytes = received;
    this.refresh(now, reduceMotion);
  }

  // The same report seen later: the speed fades into "Waiting" once no bytes
  // have come for a while (see Index's transfer ticker).
  refresh(now: number, reduceMotion: boolean): void {
    const view: TransferView = transferView(this.phase, this.bytes, this.total, this.meter, now);
    const fillMs: number = reduceMotion || view.fraction < this.fraction ? 0 : PROGRESS_INTERVAL_MS;
    if (this.fillMs !== fillMs) this.fillMs = fillMs;
    if (this.fraction !== view.fraction) this.fraction = view.fraction;
    if (this.speed !== view.speed) this.speed = view.speed;
    if (this.cardRight !== view.cardRight) this.cardRight = view.cardRight;
    if (this.amountDone !== view.amount.done) this.amountDone = view.amount.done;
    if (this.amountTotal !== view.amount.total) this.amountTotal = view.amount.total;
    if (this.amountUnit !== view.amount.unit) this.amountUnit = view.amount.unit;
    if (this.received !== view.received) this.received = view.received;
    if (this.status !== view.status) this.status = view.status;
  }
}

@Component
export struct TransferBar {
  @ObjectLink state: TransferState;
  // In the opened item the right end reads "124 of 290 MB"; on a card, "43%".
  @Prop detail: boolean = false;
  // The accent colour for the fill and, much lighter, the track, as
  // '#AARRGGBB' (see Index.colorWithAlpha).
  @Prop fill: string = '#D95468D4';
  @Prop track: string = '#2E5468D4';
  @Prop fontSize: number = 11;
  // The system's "reduce animations" setting.
  @Prop reduceMotion: boolean = false;

  // The left end: the speed, or a word in its place.
  private leftLabel(): ResourceStr {
    if (this.state.status === 'stalled') return $r('app.string.transfer_stalled');
    if (this.state.status === 'retrying') return $r('app.string.transfer_retrying');
    if (this.state.status === 'waiting') return $r('app.string.transfer_waiting');
    if (this.state.status === 'stopped') return $r('app.string.transfer_stopped');
    return this.state.speed;
  }

  // The right end: nothing when a status replaces the numbers.
  private rightLabel(): ResourceStr {
    if (this.state.status === 'retrying' || this.state.status === 'waiting' || this.state.status === 'stopped') return '';
    if (!this.detail) return this.state.cardRight;
    if (this.state.amountTotal === '') return this.state.received;
    return $r('app.string.transfer_amount_of', this.state.amountDone, this.state.amountTotal, this.state.amountUnit);
  }

  build() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(this.leftLabel())
          .fontSize(this.fontSize)
          .fontColor($r('sys.color.font_secondary'))
          .fontFeature('"tnum" 1')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.rightLabel())
          .fontSize(this.fontSize)
          .fontColor($r('sys.color.font_secondary'))
          .fontFeature('"tnum" 1')
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(BAR_HEIGHT_VP)
          .borderRadius(BAR_HEIGHT_VP / 2)
          .backgroundColor(this.track)
        // Linear, never a spring: the fill shows bytes, and a spring would
        // overshoot what has arrived.
        Row()
          .width(`${Math.max(0, this.state.fraction) * 100}%`)
          .height(BAR_HEIGHT_VP)
          .borderRadius(BAR_HEIGHT_VP / 2)
          .backgroundColor(this.fill)
          .animation({ duration: this.state.fillMs, curve: Curve.Linear })
      }
      .width('100%')
      .height(BAR_HEIGHT_VP)
    }
    .width('100%')
    .opacity(this.state.shown)
    .animation({ duration: this.reduceMotion ? REDUCED_FADE_MS : FADE_MS, curve: Curve.EaseOut })
  }
}
