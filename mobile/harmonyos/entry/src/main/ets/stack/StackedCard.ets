// The wrapper every card of the Synced tab sits in. For an ordinary card
// (behind is 0) it adds nothing: the card is drawn as it always was. For the
// front card of a stack (the newest item of one history batch) it adds what
// makes it a stack: layers peeking out below the card, a "+N" count, and a
// handle at the bottom that opens the stack when it is swiped down (or tapped).
// The rules and numbers are in SyncedRows.ets; the rows are built in Index.
//
// Everything that moves while a finger is on the handle (the layers, the
// handle and the count fading) is driven by `progress`, a number of this
// component only. A drag therefore redraws this wrapper's few nodes and never
// the page or the card in front, and nothing here is laid out again: the room
// the layers peek into is fixed, and they move with translate and opacity.

import { curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { StackMotion, dragProgress, shouldExpand } from './SyncedRows';
import { resCount } from '../i18n/Strings';

// How far each layer behind the front card peeks out below it.
const PEEK_VP: number = 8;
// How much narrower each layer is, on each side.
const LAYER_INSET_VP: number = 12;
// How much further apart the layers slide, per layer, by the end of the drag.
const SPREAD_VP: number = 22;
// A layer is drawn taller than what shows: only its bottom edge is below the
// card, the rest is clipped away, so it reads as a whole card slid behind.
const LAYER_HEIGHT_VP: number = 70;
const CARD_RADIUS_VP: number = 18;
const HANDLE_WIDTH_VP: number = 96;
const BAR_WIDTH_VP: number = 36;
const BAR_HEIGHT_VP: number = 5;
// The bar sits inside the card's own bottom padding (12 vp on every card).
const BAR_BOTTOM_VP: number = 4;
// How long the layers are left to slide apart before the items show as cards.
const EXPAND_WAIT_MS: number = 260;
const EXPAND_WAIT_REDUCED_MS: number = 120;

@Component
export struct StackedCard {
  // The card in front.
  @BuilderParam front: () => void = this.noFront;
  // Items hidden behind the front card; 0 for an ordinary card.
  @Prop behind: number = 0;
  @Prop groupId: string = '';
  // The cards' fill with the "Card transparency" setting applied, and the
  // accent colour, both as '#AARRGGBB' (see Index.stackLayerFill).
  @Prop layerFill: string = '#FFFFFFFF';
  @Prop badgeFill: string = '#FF5468D4';
  // The system's "reduce animations" setting: short fades, no springs.
  @Prop reduceMotion: boolean = false;
  // The system language, so the accessibility text follows a change of it.
  @StorageProp('language') language: string = '';
  onExpand: (groupId: string) => void = (groupId: string): void => {};
  // 0 (closed) to 1 (open), set by the finger and by the settling animation.
  @State progress: number = 0;
  private opened: boolean = false;

  @Builder
  noFront() {
  }

  private layerDepths(): number[] {
    const layers: number = Math.min(StackMotion.MAX_LAYERS, this.behind);
    return layers >= 2 ? [2, 1] : (layers === 1 ? [1] : []);
  }

  // Opens the stack (a tap, a swipe that went far enough, or an assistive
  // tool pressing the handle): the layers slide apart and the handle fades,
  // then Index shows the items as ordinary cards. Index is told after a fixed
  // wait, not when the animation reports it is over: a drag that already got
  // all the way has nothing left to animate, and that may never report.
  private expand(): void {
    if (this.opened || this.behind < 1) return;
    this.opened = true;
    if (this.reduceMotion) {
      this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.progress = 1; });
    } else {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.85) }, () => { this.progress = 1; });
    }
    setTimeout(() => { this.onExpand(this.groupId); }, this.reduceMotion ? EXPAND_WAIT_REDUCED_MS : EXPAND_WAIT_MS);
  }

  // A drag that let go too early: the layers close again.
  private springBack(): void {
    if (this.opened) return;
    if (this.reduceMotion) {
      this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.progress = 0; });
    } else {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.35, 0.8) }, () => { this.progress = 0; });
    }
  }

  private expandName(): string {
    void this.language;
    return resCount(getContext(this) as common.Context, $r('app.plural.stack_expand_name'), this.behind);
  }

  // The bottom edge of one layer, as it slides: y from the card's bottom.
  private layerShift(depth: number): number {
    return depth * (PEEK_VP + this.progress * SPREAD_VP) - LAYER_HEIGHT_VP;
  }

  @Builder
  layer(depth: number) {
    Column() {
      Row()
        .width('100%')
        .height(LAYER_HEIGHT_VP)
        .borderRadius(CARD_RADIUS_VP)
        .backgroundColor(this.layerFill)
        .border({ width: 1, color: $r('sys.color.comp_divider') })
    }
    .width('100%')
    .padding({ left: depth * LAYER_INSET_VP, right: depth * LAYER_INSET_VP })
    .translate({ y: this.layerShift(depth) })
    // A little dimmer for each step back, and gone by the end of the drag.
    .opacity((1 - 0.22 * (depth - 1)) * (1 - this.progress))
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.behind > 0) {
        // Only what is below the card shows: the clip cuts the rest of each
        // layer off, so a see-through card (see "Card transparency") has
        // nothing showing through it.
        Stack({ alignContent: Alignment.Top }) {
          ForEach(this.layerDepths(), (depth: number) => {
            this.layer(depth)
          }, (depth: number) => `${depth}`)
        }
        .width('100%')
        .height(this.layerDepths().length * (PEEK_VP + SPREAD_VP))
        .clip(true)
        .translate({ y: this.layerDepths().length * (PEEK_VP + SPREAD_VP) - 1 })
        .hitTestBehavior(HitTestMode.None)
      }

      this.front()

      if (this.behind > 0) {
        // The count of what is behind the card, bottom right, clear of the
        // handle and of the card's own text.
        Row() {
          Text($r('app.string.stack_badge', this.behind))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_on_primary'))
            .maxLines(1)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(12)
            .backgroundColor(this.badgeFill)
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ right: 12, bottom: 10 })
        .opacity(1 - this.progress)
        .hitTestBehavior(HitTestMode.None)

        // The handle: a short bar, in a touch target 44 vp tall. A swipe down
        // starting on it opens the stack; one that starts anywhere else is
        // the list's to scroll, and so is a swipe up (the pan only accepts
        // downward moves), so the two never fight.
        Column() {
          Row()
            .width(BAR_WIDTH_VP)
            .height(BAR_HEIGHT_VP)
            .borderRadius(BAR_HEIGHT_VP / 2)
            .backgroundColor($r('sys.color.font_secondary'))
            .opacity(0.5)
        }
        .width(HANDLE_WIDTH_VP)
        .height(StackMotion.HANDLE_HEIGHT_VP)
        .justifyContent(FlexAlign.End)
        .padding({ bottom: BAR_BOTTOM_VP })
        .opacity(1 - this.progress)
        .accessibilityText(this.expandName())
        .accessibilityDescription($r('app.string.stack_expand_hint'))
        .onClick(() => { this.expand(); })
        .gesture(
          PanGesture(new PanGestureOptions({ direction: PanDirection.Down, distance: 4 }))
            .onActionUpdate((event: GestureEvent) => {
              if (this.opened) return;
              this.progress = dragProgress(event.offsetY);
            })
            .onActionEnd((event: GestureEvent) => {
              if (shouldExpand(dragProgress(event.offsetY), event.velocityY)) {
                this.expand();
              } else {
                this.springBack();
              }
            })
            .onActionCancel(() => { this.springBack(); })
        )
      }
    }
    .width('100%')
    // The room the layers peek into: fixed, so a drag never moves the cards below.
    .padding({ bottom: Math.min(StackMotion.MAX_LAYERS, this.behind) * PEEK_VP })
  }
}
