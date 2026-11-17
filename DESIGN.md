# ClipLink website design

The website in `site/` follows this. The values live as CSS variables in `site/assets/style.css`; pages use the variable names, never raw colours.

## Direction

Glass panels over a still, warm colour field, with a cool neutral page. The glass stays, but there are only a few large panes: the header, the hero window, and one panel per section. Items inside a panel are plain text, not cards. Copy is short: a heading and one or two lines, in plain words.

Things that made the old page read as generated and are not used: a pill label above the headline, gradient text, floating shapes, icon tiles on feature cards, glowing number circles, a grey subtitle under every heading, and slogan lines ("Your X, on every Y", "No X. No Y. Just Z.").

## Colour

| Token | Light | Dark | Role |
|---|---|---|---|
| `--bg` | `#f1f2f4` | `#101113` | page |
| `--surface` | `#ffffff` | `#1b1c1f` | solid fallback for glass |
| `--text` | `#16171a` | `#f1f1f3` | text, focus ring |
| `--muted` | `#555961` | `#a9adb5` | secondary text |
| `--line` | text at 10% | white at 9% | dividers inside panels |
| `--accent` | `#b94a24` | `#ec9a74` | primary button, links |
| `--accent-ink` | `#ffffff` | `#1d0f09` | text on the accent |
| `--accent-soft` | accent at 11% | accent at 13% | your-device row, hover |
| `--field-a..d` | icon salmon, amber, icon taupe, rose | same, dimmer | the colour field behind the glass |

The accent is a deeper cut of the app icon's salmon (`#e09068`). No purple or blue anywhere.

## Glass and slant

The slant is ClipLink's mark, not its whole layout. Only the shapes the owner sketched lean, at 18deg (like \), with sharp corners: the hero's Download button and platform tags, the Features panel, the privacy diagram's pane, and the thin dividers between the top bar's links (and between the download tabs). Each is a skewed `::before` behind upright content. Everything else is straight, sharp-cornered glass: the top bar, the download card and its buttons, the Get app menu, badges, the FAQ (no glass at all) and the policy callout. Never a slanted shape inside another. On phones the tall Features and privacy panels stand straight; the short hero button and tags keep the slant. (Research: F1, Valorant, Apex and McLaren keep navigation, menus and lists straight and use the angle as a signature.)

The glass: a `--glass` tint, a `--glass-sheen` gradient from the top, a lit top edge (`inset 0 1px 0 --glass-rim`) and a soft shadow. Only the top bar has a real `backdrop-filter` blur, with a deeper `--bar` tint so its text stays readable over the demo; don't add `backdrop-filter` to panels (it cost most of each scrolled frame and looked the same). With reduced transparency or more contrast, glass becomes `--surface`.

The top bar is full width (not floating), straight, 62px high (58px on phones), with a hairline under it. Link hover turns the text accent and draws a straight accent line under it.

## Type

System fonts only (no web fonts). Headings use Segoe UI Variable Display where present, weight 700 and tight tracking (none on Chinese). h1 `clamp(2.5rem, 5vw, 3.9rem)`, h2 `clamp(1.65rem, 3.2vw, 2.25rem)`, body 17px (16px on phones).

## Shape and spacing

Radii are 12, 20 and 28px. Buttons and the header are pills. Sections are 72px apart (56px on phones), and content is at most 1120px wide. The device frames on screenshots are near-black bezels with a proportional radius.

## Components

- **Platform tags:** small glass pills under the headline, each a link to its download row; a platform that is not out yet says so in muted text ("iOS soon").
- **Buttons:** primary is a solid accent fill with no glow. Secondary is glass. Neither lifts on hover.
- **Download:** one straight glass card: platform tabs across the top (slanted dividers, an accent line under the chosen one), the chosen platform's row below. It opens on the visitor's own platform (with a "This device" badge), or the one a link points at (#dl-android); without the script the first platform shows.
- **FAQ:** no glass: questions split by thin lines, with a chevron that turns.
- **Links:** links to other sites open in a new tab (`target="_blank" rel="noopener"`). Download buttons stay in the page, since they fetch a file.
- **Choice button:** when a platform has more than one way to get it (Android: APK or Google Play), the row has one "Get app" pill with a chevron at its right edge. It is a `<details>`, so it works without script. Opening it turns the pill itself into a solid menu: the same shape grows from its centre, up and down at once, over the rows around it, goes from the accent to `--surface`, and lists the choices under its title, each with an icon for what it does (download, or opens another site).
- **Motion:** nothing moves at a constant speed. Movement uses `--spring` (a quick start, about 12% overshoot and a small dip back before it settles), colour and blur use `--spring-soft` (about 5%), exits use `--exit` (a slight pull back before leaving), and the diagram's looping dots use `--wave`. Browsers without `linear()` easing get close cubic curves. When something inside an element changes (a menu opening or closing, an FAQ answer appearing), its contents blur through the change. Reduced motion turns all of it off.
- **Hero:** fills the first screen, with a bouncing chevron at the bottom linking to the next section, so nothing below shows until you scroll. On top, a live demo built from the real screenshots: the ducklings photo lifts out of the Windows window and lands on the iPhone, on a loop, with the spring and blur. Under it, the title, then one line with Download first, the platform tags, and the GitHub link last (on phones: the tags on their own line, then Download and GitHub). On desktop the demo is sized by the window height so all of it fits; on phones it is a compact strip with the phone overlapping the window.
- **Reveal:** with a mouse or pen, the edges of the slanted shapes near the pointer catch a soft light that follows it (like Windows 10 reveal): a border-wide ring on `::after`, masked to the edge, lit by a radial gradient at the pointer (`--rx`/`--ry`/`--ro` set by site.js in the shape's own skewed frame). Never on touch.
- **Header bar:** a deeper tint (`--bar`) than the panels so its text stays readable over the bright demo screenshots.
