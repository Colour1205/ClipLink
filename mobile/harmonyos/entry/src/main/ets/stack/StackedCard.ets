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
//
// The pull has two parts. Up to the commit point the stack stretches against a
// rubber band's resistance, following the finger. At the commit point (with a
// tack of haptic feedback, see Index.expandStack) the items become real cards
// that start where the layers were and slide out to their places by
// themselves - the finger still down - and stay tied to the finger: bring it
// back above the release point and they slide back into the stack, as far
// down as it goes and they pop out again.

import { curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { StackMotion, dragProgress, reachedCommit, shouldCollapse, shouldExpand } from './SyncedRows';
import { resCount } from '../i18n/Strings';

// How far each layer behind the front card peeks out below it.
const PEEK_VP: number = StackMotion.PEEK_VP;
// How much narrower each layer is, on each side.
const LAYER_INSET_VP: number = StackMotion.LAYER_INSET_VP;
// How much further apart the layers slide, per layer, by the end of the drag.
const SPREAD_VP: number = StackMotion.SPREAD_VP;
// A layer is drawn taller than what shows: only its bottom edge is below the
// card, the rest is clipped away, so it reads as a whole card slid behind.
const LAYER_HEIGHT_VP: number = 70;
const CARD_RADIUS_VP: number = 18;
const HANDLE_WIDTH_VP: number = 240;
const BAR_WIDTH_VP: number = 36;
const BAR_HEIGHT_VP: number = 5;
// The bar's distance from the card's bottom edge: inside the card's own bottom
// padding (12 vp), clear of the edge and of the layers below.
const BAR_BOTTOM_VP: number = 8;
// The layers hand over to the real cards, which start exactly where the layers
// are and slide out to their places (see Index.expandStack): the layers fade
// out over this long, under the cards that replace them.
const LAYER_FADE_MS: number = 120;
// After a finger lets go with the cards popped out, the handle stays this much
// longer (ms) so the layers can finish fading.
const HOLD_AFTER_RELEASE_MS: number = 320;

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
  // Shows the items as ordinary cards sliding out of the stack from where the
  // layers are, `stretch` (0 to 1) being how far they had been pulled apart.
  onExpand: (groupId: string, stretch: number) => void = (groupId: string, stretch: number): void => {};
  // Puts the items back into their stack (a finger that popped them out came
  // back up before it was lifted).
  onCollapse: (groupId: string) => void = (groupId: string): void => {};
  // 0 (closed) to 1 (open). While the finger is down it is the rubber-band
  // stretch of the drag (it never gets past RUBBER_REACH); once the pull gets
  // to the commit point it springs to 1 by itself.
  @State progress: number = 0;
  // 0 to 1: how much the layers have faded out, after the pop.
  @State fade: number = 0;
  // A finger is on the handle, or just left it: the handle (and what is drawn
  // for the stack) stays even when the stack has been opened, because the
  // stack's items, and so `behind`, change under the finger when it pops.
  @State holding: boolean = false;
  // What `behind` was when the finger came down.
  @State heldBehind: number = 0;
  // The cards are out (popped by a pull or opened by a tap).
  private opened: boolean = false;
  // They were popped by a pull whose finger is still down, so they can still
  // go back; a tap or a lifted finger makes them final.
  private revertible: boolean = false;
  private openedGroup: string = '';
  private holdTimer: number = -1;

  @Builder
  noFront() {
  }

  // Items behind the card as far as this component draws them.
  private shownBehind(): number {
    return this.holding ? Math.max(this.behind, this.heldBehind) : this.behind;
  }

  private layerDepths(): number[] {
    const layers: number = Math.min(StackMotion.MAX_LAYERS, this.shownBehind());
    return layers >= 2 ? [2, 1] : (layers === 1 ? [1] : []);
  }

  // Opens the stack (the pull got to the commit point, a fast swipe, a tap, or
  // an assistive tool pressing the handle): Index shows the items as ordinary
  // cards that start where the layers are, wherever the finger had stretched
  // them to, and slide out to their places; the layers fade out under them.
  private expand(revertible: boolean): void {
    if (this.opened || this.shownBehind() < 1) return;
    this.opened = true;
    this.revertible = revertible;
    // `groupId` is empty once the stack has been opened, so keep it.
    this.openedGroup = this.groupId;
    this.getUIContext().animateTo({ duration: this.reduceMotion ? 100 : LAYER_FADE_MS, curve: Curve.EaseIn }, () => { this.fade = 1; });
    this.onExpand(this.openedGroup, this.progress);
  }

  // The finger that popped the cards out came back up before it was lifted:
  // they go back into the stack, which follows the finger again.
  private collapse(translationVp: number): void {
    if (!this.opened || !this.revertible) return;
    this.opened = false;
    this.revertible = false;
    this.onCollapse(this.openedGroup);
    if (this.reduceMotion) {
      this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.progress = dragProgress(translationVp); this.fade = 0; });
    } else {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.35, 0.8) }, () => { this.progress = dragProgress(translationVp); this.fade = 0; });
    }
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

  // The finger let go (or the system took the gesture): where the cards are
  // now is final.
  private release(translationVp: number, velocityVp: number, cancelled: boolean): void {
    if (this.opened) {
      this.revertible = false;
    } else if (!cancelled && shouldExpand(translationVp, velocityVp)) {
      this.expand(false);
    } else {
      this.springBack();
    }
    if (this.holdTimer !== -1) clearTimeout(this.holdTimer);
    this.holdTimer = setTimeout(() => {
      this.holdTimer = -1;
      // The room the layers took goes: in an animateTo, so the cards below
      // slide up into it instead of jumping.
      this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.85) }, () => { this.holding = false; });
    }, this.opened ? HOLD_AFTER_RELEASE_MS : 0);
  }

  // The count and the handle fade as the stack stretches, and are gone once it
  // has popped open.
  private chromeOpacity(): number {
    return (1 - Math.min(1, this.progress * 1.5)) * (1 - this.fade);
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
    // A little dimmer for each step back, and faded out after the pop.
    .opacity((1 - 0.22 * (depth - 1)) * (1 - this.fade))
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.shownBehind() > 0) {
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

      if (this.shownBehind() > 0) {
        // The count of what is behind the card, bottom right, clear of the
        // handle and of the card's own text.
        Row() {
          Text($r('app.string.stack_badge', this.shownBehind()))
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
        .padding({ right: 12, bottom: 6 })
        .opacity(this.chromeOpacity())
        .hitTestBehavior(HitTestMode.None)

        // The handle: a short bar, low in a touch target 56 vp tall and 240 wide. A swipe down starting on it opens the stack; one that
        // starts anywhere else is the list's to scroll, and so is a swipe up
        // (the pan only accepts downward moves), so the two never fight.
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
        // The bar sits low in the touch target, near the card's bottom edge.
        .justifyContent(FlexAlign.End)
        .padding({ bottom: BAR_BOTTOM_VP })
        .opacity(this.chromeOpacity())
        .accessibilityText(this.expandName())
        .accessibilityDescription($r('app.string.stack_expand_hint'))
        .onClick(() => { this.expand(false); })
        .gesture(
          PanGesture(new PanGestureOptions({ direction: PanDirection.Down, distance: 4 }))
            .onActionStart(() => {
              if (this.holdTimer !== -1) {
                clearTimeout(this.holdTimer);
                this.holdTimer = -1;
              }
              this.heldBehind = this.behind;
              this.holding = true;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.opened) {
                // Popped out, finger still down: back above the release point
                // and the cards go back into the stack.
                if (this.revertible && shouldCollapse(event.offsetY)) this.collapse(event.offsetY);
                return;
              }
              // Past the commit point the cards pop out by themselves, finger
              // still down; before it the stack follows the finger with a
              // rubber band's resistance.
              if (reachedCommit(event.offsetY)) {
                this.expand(true);
              } else {
                this.progress = dragProgress(event.offsetY);
              }
            })
            .onActionEnd((event: GestureEvent) => { this.release(event.offsetY, event.velocityY, false); })
            .onActionCancel(() => { this.release(0, 0, true); })
        )
      }
    }
    .width('100%')
    // The room the layers peek into: fixed, so a drag never moves the cards below.
    .padding({ bottom: Math.min(StackMotion.MAX_LAYERS, this.shownBehind()) * PEEK_VP })
  }
}
