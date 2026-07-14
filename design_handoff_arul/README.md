# Handoff: Arul — South Indian Devotional Wallpaper App (UI/UX revamp)

## Overview
Complete hi-fi redesign of Arul, an Android-only Flutter app for South Indian devotional wallpapers (428 static + live/video wallpapers, 6 categories, premium-gated at ₹199/mo UPI Autopay with 7-day free trial). Covers: Splash, Sign-in, Reel feed (+ loading/empty/error), Apply sheet, Premium gate nudge + Premium sheet/screen, Settings (+ theme/language sheets, logout/delete dialogs, edit-name sheet), Refer & Earn, Upload — in BOTH light and dark themes.

## About the Design Files
**Open `Arul-design-reference.html` in any browser — it is fully self-contained and works offline.** It renders all screens in Android device frames; the mock chrome (device bezel, status bar, canvas captions, section badges like "1a") is presentation only — do not implement it. These are **design references**, not production code: recreate them **pixel-perfectly in the existing Flutter codebase** using its established patterns (Flutter widgets, existing video pipeline, existing navigation).

## Fidelity
**High-fidelity.** Recreate colors, spacing, typography, radii and copy exactly as specified below.

## Hard constraints (from product — do not violate)
- Splash video and logo are FIXED; only placement is designed here.
- Feed is a vertical full-bleed pager (one wallpaper per page); browse by category chips only — never expose static-vs-live filters.
- Browsing/preview free; Apply + Share trigger premium flow.
- Sign-in auto-launches Google one-tap on first frame; screen is just the video + a slim sheet.
- NO blur/glassmorphism — legibility via gradient scrims only. NO masked shimmer — skeletons use a sliding gradient fill.
- System font stack for all UI text (must render Tamil/Telugu/Kannada/Malayalam/Hindi). Display serif ONLY for the Latin "Arul" wordmark and select display numerals/headings (see Typography).
- Material icons only. Never dynamic/device color. 6 languages exactly: English, Tamil, Telugu, Kannada, Malayalam, Hindi.

## Design Tokens

### Colors
- maroon (primary) `#7A1E33` — active states, light-theme icons, muted destructive buttons, confirm CTA
- maroon hover `#8D2740`
- gold (accent) `#D4A017` — highlights, selection borders, premium badging, icons on dark
- ivory `#FAF5EC` — light bg + dark-theme primary text
- darkSurface `#14090C` — dark bg, splash bg
- dark sheet surface `#1A0B0F`; dark sheet gradient top `#241014`
- ctaGreen `#1FA75A` (hover `#1C9450`) — ALL primary CTAs
- Dark theme: text `#FAF5EC`; secondary `#B9A58F`; body-warm `#C8AC8D`; muted `#8F7C68`; faint `#6E5C4C`; card bg `rgba(250,245,236,.04–.05)`; card border `rgba(250,245,236,.09–.14)`; row divider `rgba(250,245,236,.08)`; gold-tint fill `rgba(212,160,23,.10–.14)`; gold border `rgba(212,160,23,.35–.5)`
- Light theme: text `#2B1116`; secondary `#8A6F5C`; body `#6B5240`; faint `#B09A86`; card bg `#FFFFFF`; card border `rgba(122,30,51,.12)`; divider `rgba(122,30,51,.10)`; maroon-tint fill `rgba(122,30,51,.07–.08)`
- Scrims (rgba(20,9,12,x)): feed top h130 .62→0; feed bottom h190 .72→0; splash bottom .82; sign-in 3-stop .28 → 0 (38–62%) → .72; sheet overlay .55–.62; dialog overlay .6

### Typography
- UI: system font stack (`system-ui`)
- Display serif: **Marcellus** (Google Fonts) — "Arul" wordmark, screen titles (22px), premium price/reward numerals, hero headings
- Scale: wordmark splash 44px (ls .04em); tagline 11px caps ls .42em gold; screen title 22px Marcellus; sheet/section title 17px/600; row title 15px/500; row sub 12.5px; body 13.5px lh 1.5; caption 12px; chip 13.5px (500; active 600); button 15–16px/600; LIVE badge 10.5px/700 ls .14em

### Spacing / radii / misc
- Screen padding 16px; content gap 16px; card padding 16–20px
- Radii: cards 18–22px; sheets 24px top; rows-card 20px; inputs 14px; chips/buttons/pills 999px; LIVE badge 4px; icon chip 12px
- Button heights: primary 50–54px; sign-in pill 56px; hit targets ≥44px
- Sheet grabber: 44×4px r2, `rgba(250,245,236,.25)` dark / `rgba(43,17,22,.2)` light
- Icon chip: 40×40 r12, gold-tint (dark) / maroon-tint (light), 21px icon
- Shadows: none on cards (borders instead). Text over media: `0 1px 8px rgba(0,0,0,.6)`

## Screens (sections 1a, 2a, 3a in the reference file)

### Splash (1a)
Full-bleed fixed video on #14090C. Bottom scrim (180deg, .25 → 0 @35% → 0 @55% → .82). Bottom-centered column (bottom:64px, gap 10): gold gopuram mark 44px wide, "Arul" Marcellus 44px ivory, tagline. Loading indicator = 120×2px gold hairline with sliding gradient (1.6s linear loop) — no spinner.

### Sign-in (1a)
Same video, 3-stop scrim. Top-center (top:96px): gopuram 34px + "Arul" 30px. Bottom (inset 20px, bottom 28px): caption "Sign in to begin your free trial" 13.5px ivory 80%; ONE pill 56px r999 bg `rgba(20,9,12,.55)` border 1px `rgba(212,160,23,.5)` (hover/press: solid gold): 42px white circle with full-color Google G (20px), "Continue as {name}" 15px/600 + email 12px ivory 60% ellipsized, gold arrow_forward 22px right; "Terms · Privacy" 11px below, gold 85% links. One-tap launches on first frame; the pill anchors it.

### Reel feed (1a)
Full-bleed wallpaper page (live video plays inline). Top scrim 130px; chips row top:14px, pad 0 16px, gap 8, h-scroll: All · Amman · Ayyappan · Murugan · Perumal · Sivan · Temples. Chip 7px 15px r999; inactive bg `rgba(20,9,12,.42)` border `rgba(250,245,236,.22)` text ivory 92%; active solid gold, text #14090C 600.
Right-edge stack (right:10px, bottom:118px, gap 22): Apply (`wallpaper` 30px) + Share (`share` 28px) ONLY — icon + 10.5px label, ivory, text-shadow. No like button.
Bottom-left meta (left:16 right:76 bottom:26): LIVE badge (gold bg, #14090C text, 2px 7px r4) + category 12.5px ivory 75%; title 17px/600 ivory.
Chrome recede: fade chips+stack+meta out 150ms while swiping, back 250ms ease-out on settle. Opacity/transform only.

### Apply sheet (1a)
Bottom sheet: #1A0B0F, gold 35% top border, r24 top, pad 18/20/24. Grabber; "Set wallpaper on" 17px/600; 3 equal cards (r16, icon 26px + label 13px): Home screen / Lock screen / Both (default Both); selected: gold 1.5px border, gold-tint bg, gold icon; unselected: ivory-5% bg, ivory-14% border. Green CTA 50px "Apply wallpaper". Entrance: translateY 24px + fade, .3s ease.

### Premium gate (1a)
First Share tap (free user): floating nudge pill above meta — bg `rgba(20,9,12,.92)`, gold 45% border, r999, 9px 18px: gold `workspace_premium` 17px + "Sharing is a premium treat — **try it free**" (bold gold). Auto-dismiss ~2.6s. Second tap → premium bottom sheet: gradient #241014→#1A0B0F, gold 40% top border; gopuram 30px + "Arul Premium" Marcellus 22px + one-line pitch; plan row (gold 40% border r16): "₹199 / month" 15px/600 + "UPI Autopay · cancel anytime" 12.5px | gold pill "7 DAYS FREE" 12px/700; green 52px "Start free trial"; link "Keep browsing free" 13.5px secondary.

### Premium screen (3a, dark + light)
Close X top-left. Centered: gopuram 40px (gold dark / maroon light), "Arul Premium" Marcellus 30px, subline "The full collection, alive on your screen". Perks card: 4 rows icon 22px + 14.5px text — all 428 wallpapers · live wallpapers on home screen · apply/share without limits · new arrivals weekly. Plan card: silk gradient, **1.5px solid gold border**, price Marcellus 20px, "7 DAYS FREE" gold pill. Green CTA 54px. Footnote 12px: "Free for 7 days, then ₹199/month. Browsing stays free forever."

### Settings (2a, dark + light)
Header: back arrow + "Settings" Marcellus 22px. Profile card: silk gradient (dark `135deg rgba(122,30,51,.35)→rgba(212,160,23,.10)` gold 30% border; light `rgba(122,30,51,.10)→rgba(212,160,23,.10)` maroon 18% border) r20 p16: 52px maroon avatar circle w/ gold Marcellus initial, name 16px/600 + email 13px, edit pencil 20px.
One rows-card (r20): Refer & Earn (`featured_seasonal_and_gifts`, "Earn 30 days free premium") · Language (`translate`, current) · Theme (`dark_mode`, current) · Need help? (`help`, "Support & subscription") · Upload your wallpaper (`upload`, "Share your own image or video"). Row: 14/16 pad, icon chip, chevron_right 20px @40%. NO "Quick Access Bar", no ringtones/status.
Logout: 50px r999 muted — dark bg `rgba(122,30,51,.35)` border `rgba(122,30,51,.6)` text `#F0C9BA`; light bg `rgba(122,30,51,.08)` border 35% text maroon. Delete account: underlined text link 13.5px secondary. Legal line 12px faint.

### Theme sheet (2a)
Bottom sheet "Theme"; 3 rows (r14, 12px pad): System default (`settings_suggest`, "Follow device setting") / Light (`light_mode`, "Ivory & silk") / Dark (`dark_mode`, "Lamp-lit maroon"). Selected: gold-tint bg, gold icon+title, gold check_circle.

### Language sheet (2a)
Bottom sheet "Language"; 2-col grid gap 10, 6 tiles (r16, 16/8 pad, centered): native 17px/600 over English 12px. EXACTLY: English / தமிழ் Tamil / తెలుగు Telugu / ಕನ್ನಡ Kannada / മലയാളം Malayalam / हिन्दी Hindi. Selected: gold 1.5px border + gold-tint bg + gold native text.

### Confirm dialogs (2a)
Centered card (24px side margins, r22, gold 35% border on #1A0B0F): title 18px/600, message 13.5px secondary, two 46px r999 buttons: Cancel (outlined ivory 25%) + confirm (solid #7A1E33, hover #8D2740). Logout: "Logout?" / "You can sign back in anytime with Google." Delete: "Delete account?" / "This removes your account, favourites and rewards for good."

### Edit name sheet (3a)
Bottom sheet over dimmed settings: "Your name" + "Shown on wallpapers you upload"; field 54px r14, 1.5px focus border (gold dark / maroon light), person icon, counter "11 / 40" 11.5px right; green Save 50px. Max 40 chars.

### Refer & Earn (2a dark, 3a light)
Hero card (silk gradient, gold border, r22, centered): 56px gold-tint circle + `featured_seasonal_and_gifts` 28px; "Gift a friend, earn a month" Marcellus 21px; "30 days of free premium for every friend who subscribes with your link"; green 50px "Share via WhatsApp". Rewards card: `emoji_events` 26px + "Rewards earned" 12.5px + "0 days" Marcellus 22px gold/maroon. How-it-works: 3 steps w/ 24px numbered circles (gold-tint/maroon-tint 12.5px/700): share link → friend installs & subscribes → 30 days lands. Empty: group icon 26px @30% + "No referrals yet — your first friend is one share away".

### Upload (2a dark, 3a light)
"Upload wallpaper". Pick zone: 1.5px DASHED border (gold 50% / maroon 45%), r20, 34/20 pad: `add_photo_alternate` 32px + "Choose an image or video" 15px/500 + "Portrait, 1080×2400 or larger" 12.5px. Wallpaper-only, no type tabs. Title field (optional, "e.g. Meenakshi at dusk"); category chips wrap gap 8 (6 categories, no "All"; selected solid gold/maroon); rights checkbox (`check_box` 22px accent) "I own the rights to this content or have permission to share it"; green 52px "Submit for review"; footnote "Approved wallpapers appear in the feed with your name".

### Feed states (1a, 2a)
- Loading: full-bleed sliding gradient `110deg #14090C 30% → #2A1218 50% → #14090C 70%`, bg-size 200%, 1.8s linear loop; chip skeleton pills ivory-8%; centered gopuram 38px + "Bringing your wallpapers…" 13px, opacity pulse .55↔1 2s.
- Empty (category): chips remain; gopuram 40px @55%, "Nothing here yet" Marcellus 20px, sub, outlined gold pill "Browse all".
- Error: `cloud_off` 34px ivory 35%, "Couldn't load wallpapers" Marcellus 20px, "Check your connection and try again.", green pill "Retry" + refresh icon.

## Interactions & Motion (transform/opacity only)
- Feed: vertical PageView snap; live video autoplays on settle, pauses off-screen.
- Chrome recede: out 150ms while swiping, in 250ms ease-out on settle.
- Sheets/dialogs: translateY(24px)+fade, .3s ease (dialogs .25s); scrim fade.
- Nudge: same rise, auto-dismiss 2.6s. Buttons darken on press.
- Splash → sign-in: same video player continues; UI crossfades.

## State Management
- Feed: category, page index, premium status, chromeVisible, sheet none|apply|premium, nudgeShownOnce, applyTarget home|lock|both (default both)
- Settings: theme system|light|dark, language, active sheet/dialog
- Upload: pickedFile, title, category, rightsAccepted (submit disabled until file+category+rights)
- Premium/trial status + referral days from backend

## Logo mark
Mock gopuram SVG (viewBox 0 0 44 40): path `M20 0h4v3h-4z M14 5h16l-2 5H16z M10 12h24l-2.5 6H12.5z M6 20h32l-3 7H9z M2 29h40l-2 8H4z`. Gold #D4A017 on dark, maroon #7A1E33 on light. Replace with the real fixed launcher mark; sizes/placements stay.

## Assets
- `assets/splash_video.mp4` — fixed splash video (also sign-in bg)
- `assets/sample_wallpaper.jpg` — sample feed wallpaper (mock only)
- Marcellus (Google Fonts; bundle in app, Latin only)
- Material Symbols Rounded, weight 300, FILL 0. Icons: wallpaper, share, home, lock, smartphone, workspace_premium, arrow_back, arrow_forward, close, chevron_right, edit, person, check_circle, check_box, translate, dark_mode, light_mode, settings_suggest, help, upload, featured_seasonal_and_gifts, emoji_events, group, add_photo_alternate, movie, ios_share, auto_awesome, refresh, cloud_off, logout

## Files
- `Arul-design-reference.html` — self-contained, opens offline in any browser. Section 3a = premium/edit-name/light variants, 2a = settings/refer/upload/feed states, 1a = splash/sign-in/feed. First settings phone and the feed phone are interactive. Device bezels are mock chrome.
- `assets/` — video + sample wallpaper
