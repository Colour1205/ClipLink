# ClipLink website design

The website in `site/` follows this. The values live as CSS variables in `site/assets/style.css`; pages use the variable names, never raw colours.

## Direction

Glass panels over a still, warm colour field, with a cool neutral page. The glass stays, but there are only a few panes: the header, the hero window, the Features panel, the privacy pane, and one tile per platform under Download. Items inside the Features panel are plain text in its cells, not cards. Copy is short: a heading and one or two lines, in plain words.

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
| `--accent-soft` | accent at 11% | accent at 13% | your-device tile, hover |
| `--field-a..d` | icon salmon, amber, icon taupe, rose | same, dimmer | the colour field behind the glass |

The accent is a deeper cut of the app icon's salmon (`#e09068`). No purple or blue anywhere.

## Glass and slant

The slant is ClipLink's mark, not its whole layout. Only the shapes the owner sketched lean, at 18deg (like \), with sharp corners: the hero's Download button and platform tags, the Features panel, the privacy diagram's pane, the four download tiles, and the thin dividers between the top bar's links. Each is a skewed `::before` behind upright content. Everything else is straight, sharp-cornered glass: the top bar, the buttons inside the download tiles, the Get app menu, badges, the FAQ (no glass at all) and the policy callout. Never a slanted shape inside another.

Inside a tall slanted shape the content follows the lean: a box inside it is skewed the same way and each block of text is skewed back (`--unskew`), so the words stay upright but each block starts further right the lower it sits, keeping an even distance from the slanted side. The Features cells and the lines in each download tile work this way. Below 820px the Features panel stands straight; below 760px the download tiles stack and stand straight, and the short buttons in them take the lean instead; below 620px the privacy pane stands straight too. Where the window leaves less room beside the content than a leaning panel's lean, the Features panel and the privacy pane move in, so their corners are never cut off. The hero button and tags keep the slant everywhere. (Research: F1, Valorant, Apex and McLaren keep navigation, menus and lists straight and use the angle as a signature.)

The glass: a `--glass` tint, a `--glass-sheen` gradient from the top, a lit top edge (`inset 0 1px 0 --glass-rim`) and a soft shadow. Only the top bar has a real `backdrop-filter` blur, with a deeper `--bar` tint so its text stays readable over the demo; don't add `backdrop-filter` to panels (it cost most of each scrolled frame and looked the same). With reduced transparency or more contrast, glass becomes `--surface`.

The top bar is full width (not floating), straight, 62px high (58px on phones), with a hairline under it. Link hover turns the text accent and draws a straight accent line under it.

## Type

System fonts only (no web fonts). Headings use Segoe UI Variable Display where present, weight 700 and tight tracking (none on Chinese). h1 `clamp(2.5rem, 5vw, 3.9rem)`, h2 `clamp(1.65rem, 3.2vw, 2.25rem)`, body 17px (16px on phones).

## Shape and spacing

Radii are 12, 20 and 28px. Buttons and the header are pills. Sections are 72px apart (56px on phones), and content is at most 1120px wide. The device frames on screenshots are near-black bezels with a proportional radius.

## Components

- **Features:** one leaning panel cut into six cells (three columns, two rows; two columns under 960px, one under 620px). The cell lines run parallel to the panel's sides and across it, so each cell is a piece of the parallelogram, and the second row starts further right along the lean. Each cell's title and text stand upright; with a mouse, the cell under it takes a faint accent fill.
- **Privacy:** two short paragraphs beside the leaning pane with the drawing of four paired devices. The devices are placed along the lean (the lower ones further right), so the drawing sits square in the slanted pane. Straight on phones.
- **Platform tags:** small glass pills under the headline, each a link to its download tile; a platform that is not out yet says so in muted text ("iOS soon").
- **Buttons:** primary is a solid accent fill with no glow. Secondary is glass. Neither lifts on hover.
- **Download:** a staircase of four leaning glass tiles, one per platform, side by side (a 2 x 2 staircase under 1120px, where the lower row starts further right by the slant; stacked and straight under 760px; each switch is where a tile gets too narrow for its button). The row is inset so its outer corners sit on the content edges. In each tile the name, badges, lines and the button step along its lean; the button sits at the bottom so all four line up, and it never reaches past the tile's side (a label that does not fit takes two lines). The visitor's own platform is tinted with an accent top edge and a "This device" badge, and only its button is solid accent; the others turn to glass (with no match, all stay solid). iOS, not out yet, is an outline only. A platform tag (#dl-android) scrolls to its tile, whose glass glows briefly. Everything shows without the script.
- **FAQ:** no glass: questions split by thin lines, with a chevron that turns.
- **Links:** links to other sites open in a new tab (`target="_blank" rel="noopener"`). Download buttons stay in the page, since they fetch a file.
- **Choice button:** when a platform has more than one way to get it (Android: APK or Google Play), the tile has one "Get app" pill with a chevron at its right edge. It is a `<details>`, so it works without script. Opening it turns the pill itself into a solid menu: the same shape grows from its centre, up and down at once, over the rows around it, goes from the accent to `--surface`, and lists the choices under its title, each with an icon for what it does (download, or opens another site). It is quick, since it answers a click: the shape and the choices take about 0.42-0.44 s (spring, with the choices blurring into focus), and closing takes 0.2 s. On phones the closed button leans like the others and stands straight as it opens.
- **Motion:** nothing moves at a constant speed. Movement uses `--spring` (a quick start, about 4% overshoot, then it settles), colour and blur use `--spring-soft` (barely any); durations are long enough (about 0.5 to 0.9 s) to read as one movement, never a stutter (direct answers to a click, like the Get app menu, are quicker: about 0.4 s open, 0.2 s close), exits use `--exit` (a slight pull back before leaving), and the diagram's looping dots use `--wave`. Browsers without `linear()` easing get close cubic curves. When something inside an element changes (a menu opening or closing, an FAQ answer appearing), its contents blur through the change. Reduced motion turns all of it off.
- **Hero:** fills the first screen, with a bouncing chevron at the bottom linking to the next section, so nothing below shows until you scroll. On top, a live demo built from the real screenshots: the ducklings photo lifts out of the Windows window and lands on the iPhone, on a loop, with the spring and blur. Under it, the title, then one line with Download first, the platform tags, and the GitHub link last (on phones: the tags on their own line, then Download and GitHub). On desktop the demo is sized by the window height so all of it fits; on phones it is a compact strip with the phone overlapping the window.
- **Reveal:** with a mouse or pen, the edges of the slanted shapes near the pointer catch a soft light that follows it (like Windows 10 reveal): a border-wide ring on `::after`, masked to the edge, lit by a radial gradient at the pointer (`--rx`/`--ry`/`--ro` set by site.js in the shape's own skewed frame). Never on touch.
- **Header bar:** a deeper tint (`--bar`) than the panels so its text stays readable over the bright demo screenshots.
