# site/

The ClipLink website, published to GitHub Pages by `.github/workflows/pages.yml` whenever `site/` changes on `main`. Plain HTML, CSS and one small script: no build step, no frameworks, no web fonts, nothing loaded from other sites.

- `index.html`, `code-signing-policy.html` - English. A small inline script at the top of every page's `<head>` opens it in the browser's language on the first visit (Chinese for `zh*`, otherwise English); the language links add `?lang=` so a visitor's own choice is remembered and not undone.
- `zh/` - the same two pages in Simplified Chinese. Change a page, change its twin.
- `assets/shot-*.webp` - real screenshots (iOS, Android, HarmonyOS, Windows), resized. Replace them when the UI changes; keep the file names so both pages pick them up. The HarmonyOS one is in Chinese.
- `assets/style.css` - the acrylic / glass design (blurred translucent panels over a soft colour field, squircle corners, floating shapes). Light and dark follow the visitor's system.
- `assets/site.js` - points the download buttons at the newest release's files via GitHub's public API (a platform with no file yet stays "Coming soon"), marks the visitor's own platform, and turns "See it in action" into a swipeable stack on small phones. The page works without it.

Links are relative, because the site lives under `/ClipLink/`, not at the domain root. Preview it with `python -m http.server` from this folder.

When an Android APK, an AppGallery listing or a TestFlight link exists, update the matching download card in both languages. The Windows card says the installer is unsigned; take that note out (and update the code signing policy's status box) once releases are signed.
