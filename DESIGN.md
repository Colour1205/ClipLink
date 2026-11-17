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

## Glass

`.glass`: `--glass` tint, `blur(26px) saturate(170%)`, a lit top edge (`inset 0 1px 0 --glass-rim`), a soft shadow, and the grain inside the pane. Phones use an 18px blur. With reduced transparency or more contrast, glass becomes `--surface`.

## Type

System fonts only (no web fonts). Headings use Segoe UI Variable Display where present, weight 700 and tight tracking (none on Chinese). h1 `clamp(2.5rem, 5vw, 3.9rem)`, h2 `clamp(1.65rem, 3.2vw, 2.25rem)`, body 17px (16px on phones).

## Shape and spacing

Radii are 12, 20 and 28px. Buttons and the header are pills. Sections are 72px apart (56px on phones), and content is at most 1120px wide. The device frames on screenshots are near-black bezels with a proportional radius.

## Components

- **Platform tags:** small glass pills under the headline, each a link to its download row; a platform that is not out yet says so in muted text ("iOS soon").
- **Buttons:** primary is a solid accent fill with no glow. Secondary is glass. Neither lifts on hover.
- **Download list:** one panel with a row per platform. Your own platform's row is tinted and gets a "This device" badge.
- **FAQ:** one panel, questions split by hairlines, with a chevron that turns.
- **Links:** links to other sites open in a new tab (`target="_blank" rel="noopener"`). Download buttons stay in the page, since they fetch a file.
