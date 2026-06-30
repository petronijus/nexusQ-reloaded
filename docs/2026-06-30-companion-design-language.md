# Nexus Q companion — original design language (visual spec for the reload)

**Date:** 2026-06-30
**Goal:** capture the **original "Nexus Q" app look** so the new cross-platform (Flutter)
companion can faithfully reproduce it. Requirement from the maintainer: *keep the original
interface look.*
**Source:** extracted from the decompiled app resources
(`private/nexusq-original/companion/apktool/res/`). Design **tokens, type scale, spacing, and
motifs are facts** and are reproduced here in the public repo; the **raw Google image assets**
(icons, the spinning-Q frames, the outro video, the "Droplet" mascot) are kept under
`private/nexusq-original/companion/design-assets/` (gitignored, Google-copyrighted — reference
only, not redistributed).

> ## The look in one line
> **Black canvas + a glowing Holo-Blue (`#33B5E5`) sphere outline with a bright equatorial LED
> ring** — Roboto-Light type, minimal Holo-dark chrome, the Nexus Q sphere as the hero element.
> The on-screen ring *is* the device's real LED ring; reuse it as the volume arc and now-playing
> halo, exactly as the 2012 app did.

---

## 1. Color palette (`res/values/colors.xml`)

| Token | Hex | Role |
|---|---|---|
| **Holo Blue (accent)** | `#33B5E5` | `title_color` / `holo_blue_light` — primary accent, the ring glow, titles, active states |
| Off-black (surface) | `#252525` | `off_black` — cards/surfaces above the true-black canvas |
| Canvas | `#000000` | true black background (the sphere renders on pure black) |
| White | `#FFFFFF` | primary text / button labels |
| Divider | `#5F5F60` / `#33FFFFFF` | list & button dividers |
| Dim / disable overlay | `#99000000` / `#66000000` | modal scrims, disabled state |
| Actionbar title | `#224894` | deep-blue action-bar title variant |

**LED / setup accent palette** (doubles as the LED-ring theme colors — see the RE doc §3.2):
white `#FFFFFF` · orange `#FF8800` · blue `#0099CC` · green `#669900` · purple `#AA66CC` ·
yellow `#FFBB33` · red `#CC0000`. (These are the exact swatches the ring + theme presets use,
so the app's color chips and the device's ring stay in lockstep.)

## 2. Typography

- **Roboto** — the Holo-era system face; the on-device welcome used **Roboto-Light**. Use
  Roboto (Light for hero/welcome, Regular for body) in the Flutter app.
- Scale (`dimens.xml`): title **22sp** (`title_size`), splash title 18sp, splash step 14sp,
  next-button label 20dp. Titles are Holo Blue `#33B5E5`.

## 3. Spacing & layout (`dimens.xml`)

- Standard margin **15dp**, grouped margin 6dp, content padding 8dp, vertical spacing 12dp.
- Setup padding 16dp; two-column setup layout (left column 246dp) on tablets.
- Action bar (Holo "ActionBarCompat") height **48dp**; buttons 48dp tall, min-width 128dp.
- Volume panel docks **80dp** from the top; audio-endpoint rows 64dp, volume-detail 84dp.

## 4. Iconography & motifs (`design-assets/`)

- **The sphere / "Q" (hero)** — `q000.png … q035.png`: a 36-frame spin of the Nexus Q as a
  **glowing Holo-Blue circle outline on black, with a bright cyan equatorial LED-ring arc**. This
  is *the* signature visual. The new app's home/now-playing should center this ring; the volume
  control should be the ring arc lighting up (mirrors the device hardware).
- **`ic_q_welcome.png`** — the cyan/white Q logo mark (welcome/branding).
- **`drop.png` ("Droplet")** — Google's cartoon water-drop setup mascot. Setup-era only; **omit**
  from the reload (Google character, and we're not redoing the cloud setup flow).
- **Room icons** (`ic_menu_location_*`: bedroom, kitchen, living room, office, …) — line icons in
  the Holo style; reusable concept if device naming/rooms return.
- **Volume icons** (`ic_audio_vol_multi_*_holo_dark`, mute variants) — 5-step speaker glyphs.
- **Holo-dark chrome** — 9-patch buttons (`btn_default_*_holo_dark`), `btn_dir_next` (the
  forward-chevron "Next" button), dialogs (`dialog_*_holo_dark`), Holo scrubber/seekbar
  (`scrubber_*_holo`), indeterminate spinner (8-frame `progressbar_indeterminate_holo`). Recreate
  these as native Flutter widgets themed to the palette rather than shipping the PNGs.
- **Media**: `res/raw/q_outro.mp4` (setup outro clip), `polaris.ogg` (chime). Reference only.

## 5. How the look maps onto the Flutter v1 (minimal remote)

- **Home / now-playing** — black canvas, the glowing **sphere + LED ring** as the hero. Album
  art (from librespot) sits inside/behind the ring; track/artist in white Roboto; the ring glows
  Holo Blue or the current LED theme color.
- **Volume** — the **ring arc** fills with volume level (cyan glow), reproducing the device's own
  volume-ring overlay (RE doc §3.2: `VOLUME_ACTIVE` lights the ring). Mute dims the ring.
- **LED theme picker** — color chips using the exact §1 LED palette; selecting a theme tints the
  on-screen ring to match what the device shows.
- **Chrome** — Holo-dark: 48dp top bar, Holo-Blue titles, 15dp margins, Roboto, forward-chevron
  for primary actions. Minimal, dark, glowing — not Material 3 pastel.

## 6. Notes for implementation

- Reproduce the **ring/glow procedurally** (Flutter `CustomPainter` / shaders) rather than
  shipping the copyrighted q-spin PNGs — it scales crisply and lets the ring react live to volume
  / theme / now-playing, like the device. The `design-assets/` frames are the visual target.
- Keep a single theme file (palette + type + spacing tokens from §1–3) as the app's design system.
- Light theme existed (`Theme.RemoteControl.Light`) but the device identity is the **dark** look;
  default to dark.
