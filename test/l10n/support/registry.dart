/// The screen registry — ONE list, pumped identically by Layer 1
/// (`test/l10n/l10n_matrix_test.dart`) and Layer 2
/// (`integration_test/l10n_matrix_test.dart`).
///
/// It is shared rather than duplicated because the agreement rule only means
/// something if both layers cover the same surfaces: two registries that drift
/// would let a Layer 2 pass "confirm" a Layer 1 result about a different screen.
///
/// Deliberately NOT here:
///
///   * the premium paywall tree (`ArulPaywallView`, `PriceLockup`, `_Footer`,
///     the UPI picker) — English-by-decision, CLAUDE.md §5 and the design
///     handoff. Its bundled Cinzel/Lora/Gelasio cuts are Latin-only subsets, so
///     there is no Indic text to overflow. Ledgered, not measured;
///   * `PolicyScreen` — a WebView with no Flutter-rendered localized chrome
///     beyond a back affordance;
///   * `SplashScreen` — no localized text (wordmark + a Latin-only eyebrow).
///
/// Nothing here touches the network: `AppConfig.hasBackend` is false under
/// `flutter test` and under the Layer 2 build (no dart-defines), which is what
/// keeps sign-in from auto-launching `authenticate()` (CLAUDE.md §8.3) and the
/// entitlement provider from reaching Neon.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is only exported from the misc entry point in Riverpod 3.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart' show TestDefaultBinaryMessenger;
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/shell/app_shell.dart';
import 'package:arul/app/theme/theme.dart';
import 'package:arul/app/widgets/arul_line_icons.dart';
import 'package:arul/core/connectivity/connectivity_provider.dart';
import 'package:arul/data/models/ringtone.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/auth/presentation/sign_in_screen.dart';
import 'package:arul/features/notifications/presentation/notification_settings_screen.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/referral/presentation/refer_screen.dart';
import 'package:arul/features/referral/presentation/share_moment_sheet.dart';
import 'package:arul/features/ringtones/presentation/ringtone_states.dart';
import 'package:arul/features/ringtones/presentation/ringtones_screen.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';
import 'package:arul/features/ringtones/providers/ringtone_preview_provider.dart';
import 'package:arul/features/settings/presentation/confirm_dialog.dart';
import 'package:arul/features/settings/presentation/edit_name_sheet.dart';
import 'package:arul/features/settings/presentation/language_sheet.dart';
import 'package:arul/features/settings/presentation/settings_screen.dart';
import 'package:arul/features/settings/presentation/theme_sheet.dart';
import 'package:arul/features/upload/presentation/upload_screen.dart';
import 'package:arul/features/wallpapers/presentation/apply_sheet.dart';
import 'package:arul/features/wallpapers/presentation/feed_states.dart';
import 'package:arul/features/wallpapers/providers/catalog_providers.dart';

import 'envelope.dart';
import 'real_font_theme.dart';

/// One measurable surface.
class ScreenEntry {
  const ScreenEntry({
    required this.id,
    required this.build,
    this.overrides = const [],
    this.textField = false,
    this.textFree = false,
    this.unlocalizedEnglish = false,
  });

  /// Stable identifier — appears in findings, the audit JSON and the ledger.
  final String id;

  /// The widget handed to `MaterialApp.home`. A sheet or dialog entry returns a
  /// [SheetHost], which opens it on the first frame.
  final Widget Function() build;

  final List<Override> overrides;

  /// Text-field surfaces owe an extra pass with the IME up.
  final bool textField;

  /// A surface that deliberately carries no words — the skeletons. The matrix
  /// otherwise treats "rendered nothing" as a failure, because that is how a
  /// screen that silently failed to build would slip through as a pass.
  final bool textFree;

  /// A surface that is HARDCODED ENGLISH: it renders string literals instead of
  /// reading `AppLocalizations`, so a Tamil user sees English on it.
  ///
  /// This is a defect, not a configuration, and the flag does not excuse it —
  /// it pins it. The matrix asserts that such a screen attributes keys in `en`
  /// and NONE in the other five, which is the exact signature of hardcoded
  /// text. Localize the screen and this assertion fails, which is the point:
  /// the flag has to be deleted in the same change.
  ///
  /// Found by this audit's coverage check, all three with translations already
  /// sitting unused in the ARBs — see OVERNIGHT-L10N-REPORT.md and
  /// docs/known-issues.md.
  final bool unlocalizedEnglish;
}

/// Overrides every entry needs, whatever it is.
///
/// `sharedPreferencesProvider` throws by design when it has not been overridden
/// in `main()`, and the theme-mode, locale and notification notifiers all read
/// it during their first build — so without this every stateful screen throws
/// before painting a single word.
late SharedPreferences _prefs;
List<Override> get kBaseOverrides => [
  sharedPreferencesProvider.overrideWithValue(_prefs),
];

/// Call once, before the first pump.
Future<void> initRegistry() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  _prefs = await SharedPreferences.getInstance();
}

/// Opens a modal on the first frame, so a sheet or dialog can be a registry
/// entry without the matrix having to drive taps.
class SheetHost extends StatefulWidget {
  const SheetHost({super.key, required this.open});

  final Future<void> Function(BuildContext context) open;

  @override
  State<SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<SheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.open(context);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}

// ─── Fake data ───────────────────────────────────────────────────────────────

/// Realistic-length titles, on purpose. A fake catalog of "a", "b", "c" gives
/// every row acres of free space and would hide the very overflows this matrix
/// exists to find — the row's fixed furniture (medallion, transport control,
/// Set pill) has to be competing for width the way it does in the shipped app.
final List<Ringtone> kFakeRingtones = <Ringtone>[
  Ringtone(
    id: 'r1',
    title: 'Sri Venkateswara Suprabhatam',
    category: 'perumal',
    audioKey: 'r1.mp3',
  ),
  Ringtone(
    id: 'r2',
    title: 'Kanda Sasti Kavasam',
    category: 'murugan',
    audioKey: 'r2.mp3',
  ),
  Ringtone(
    id: 'r3',
    title: 'Jaya Jaya Chamundeshwari',
    category: 'amman',
    audioKey: 'r3.mp3',
  ),
  Ringtone(
    id: 'r4',
    title: 'Saranam Ayyappa Swamiye',
    category: 'ayyappan',
    audioKey: 'r4.mp3',
  ),
  Ringtone(
    id: 'r5',
    title: 'Dharmasthala Manjunatha',
    category: 'sivan',
    audioKey: 'r5.mp3',
  ),
  Ringtone(
    id: 'r6',
    title: 'Hanuman Chalisa',
    category: 'others',
    audioKey: 'r6.mp3',
  ),
];

Wallpaper _wallpaper(String id, String category) => Wallpaper.fromJson({
  'id': id,
  'title': 'Meenakshi Amman at dusk',
  'type': 'static',
  'category': category,
  'full_key': 'wallpapers/$category/$id.jpg',
  'width': 1080,
  'height': 1920,
});

/// One per category, so every chip in the browse rail is rendered — the chips
/// are the widest row of localized text in the app.
final List<Wallpaper> kFakeWallpapers = <Wallpaper>[
  for (final c in const [
    'amman',
    'ayyappan',
    'murugan',
    'perumal',
    'sivan',
    'temples',
  ])
    _wallpaper('w-$c', c),
];

class _FakeRingtoneCatalog extends RingtoneCatalogNotifier {
  @override
  Future<List<Ringtone>> build() async => kFakeRingtones;
}

class _FakeCatalog extends CatalogNotifier {
  _FakeCatalog(this._items);
  final List<Wallpaper> _items;
  @override
  Future<List<Wallpaper>> build() async => _items;
}

/// The real notifier owns a `just_audio` player, which needs a platform. This
/// keeps the one-row-at-a-time contract and opens with a row PLAYING, so the
/// now-playing row's taller layout is what gets measured.
class _StubPreview extends RingtonePreviewNotifier {
  @override
  RingtonePreviewState build() =>
      const RingtonePreviewState(currentId: 'r1', isPlaying: true);

  @override
  Future<void> toggle(Ringtone ringtone) async {}

  @override
  Future<void> stop() async {}
}

List<Override> _online({bool premium = true}) => [
  isOnlineProvider.overrideWith((ref) => Stream.value(true)),
  entitlementProvider.overrideWith((ref) async => premium),
];

// ─── The registry ────────────────────────────────────────────────────────────

/// Every surface the matrix measures.
final List<ScreenEntry> kScreenRegistry = <ScreenEntry>[
  // ── Wallpapers tab states ──────────────────────────────────────────────
  ScreenEntry(
    id: 'feed.loading',
    textFree: true,
    build: () => const Scaffold(
      body: FeedLoading(margin: EdgeInsets.all(12), radius: 28),
    ),
  ),
  ScreenEntry(
    id: 'feed.empty',
    unlocalizedEnglish: true,
    // The category label is interpolated into the body copy, so it gets the
    // longest of the six ("ayyappan") rather than a short stand-in.
    build: () => Scaffold(
      body: FeedEmpty(categoryLabel: 'Ayyappan', onBrowseAll: () {}),
    ),
  ),
  ScreenEntry(
    id: 'feed.error',
    build: () => Scaffold(body: FeedError(onRetry: () {})),
  ),
  ScreenEntry(
    id: 'feed.offline',
    build: () => Scaffold(body: FeedError(offline: true, onRetry: () {})),
  ),
  ScreenEntry(
    id: 'feed.chips',
    build: () => const Scaffold(
      body: SafeArea(
        child: Align(alignment: Alignment.topCenter, child: FeedChips()),
      ),
    ),
    overrides: [
      catalogProvider.overrideWith(() => _FakeCatalog(kFakeWallpapers)),
    ],
  ),
  ScreenEntry(
    id: 'feed.chips.skeleton',
    textFree: true,
    build: () => const Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: FeedChipsSkeleton(),
        ),
      ),
    ),
  ),

  // ── Ringtones tab ──────────────────────────────────────────────────────
  ScreenEntry(
    id: 'ringtones.loading',
    textFree: true,
    build: () => const Scaffold(body: RingtonesLoading()),
  ),
  ScreenEntry(
    id: 'ringtones.empty',
    build: () => const Scaffold(body: RingtonesEmpty()),
  ),
  ScreenEntry(
    id: 'ringtones.error',
    build: () => Scaffold(body: RingtonesError(onRetry: () {})),
  ),
  ScreenEntry(
    id: 'ringtones.screen',
    build: () => const RingtonesScreen(),
    overrides: [
      ..._online(),
      ringtoneCatalogProvider.overrideWith(_FakeRingtoneCatalog.new),
      ringtonePreviewProvider.overrideWith(_StubPreview.new),
    ],
  ),
  ScreenEntry(
    id: 'ringtones.screen.locked',
    build: () => const RingtonesScreen(),
    overrides: [
      ..._online(premium: false),
      ringtoneCatalogProvider.overrideWith(_FakeRingtoneCatalog.new),
      ringtonePreviewProvider.overrideWith(_StubPreview.new),
    ],
  ),

  // ── Settings ───────────────────────────────────────────────────────────
  ScreenEntry(id: 'settings.screen', build: () => const SettingsScreen()),
  ScreenEntry(
    id: 'settings.language_sheet',
    build: () => SheetHost(
      open: (context) async => showLanguageSheet(context, 'English'),
    ),
  ),
  ScreenEntry(
    id: 'settings.theme_sheet',
    build: () => SheetHost(open: (context) => showThemeSheet(context)),
  ),
  ScreenEntry(
    id: 'settings.edit_name_sheet',
    textField: true,
    build: () =>
        SheetHost(open: (context) async => showEditNameSheet(context, 'Anish')),
  ),
  ScreenEntry(
    id: 'settings.confirm_logout',
    build: () => SheetHost(
      open: (context) async {
        final l10n = AppLocalizations.of(context);
        await showArulConfirmDialog(
          context,
          title: l10n.settingsLogoutConfirmTitle,
          message: l10n.settingsLogoutConfirmBody,
          confirmLabel: l10n.settingsLogout,
        );
      },
    ),
  ),
  ScreenEntry(
    id: 'settings.confirm_delete',
    build: () => SheetHost(
      open: (context) async {
        final l10n = AppLocalizations.of(context);
        await showArulConfirmDialog(
          context,
          title: l10n.settingsDeleteConfirmTitle,
          message: l10n.settingsDeleteConfirmBody,
          confirmLabel: l10n.settingsDeleteAccount,
        );
      },
    ),
  ),
  ScreenEntry(
    // The long-form warning a paying user gets — five sentences about a
    // forfeited subscription, and the single longest string in the ARB.
    id: 'settings.confirm_delete_premium',
    build: () => SheetHost(
      open: (context) async {
        final l10n = AppLocalizations.of(context);
        await showArulConfirmDialog(
          context,
          title: l10n.settingsDeleteConfirmTitle,
          message: l10n.settingsDeleteConfirmBodyPremium,
          confirmLabel: l10n.settingsDeleteAccount,
        );
      },
    ),
  ),

  // ── Reminders ──────────────────────────────────────────────────────────
  ScreenEntry(
    id: 'notifications.screen',
    build: () => const NotificationSettingsScreen(),
  ),

  // ── Refer & Earn ───────────────────────────────────────────────────────
  ScreenEntry(id: 'refer.screen', build: () => const ReferScreen()),
  ScreenEntry(
    id: 'refer.share_moment',
    build: () => SheetHost(
      open: (context) {
        final l10n = AppLocalizations.of(context);
        return ShareMomentSheet.show(
          context,
          title: l10n.uploadShareMomentTitle,
          body: l10n.uploadShareMomentBody,
          source: 'upload',
        );
      },
    ),
  ),

  ScreenEntry(
    id: 'refer.share_moment.ringtone',
    build: () => SheetHost(
      open: (context) {
        final l10n = AppLocalizations.of(context);
        return ShareMomentSheet.show(
          context,
          title: l10n.uploadShareMomentTitle,
          body: l10n.uploadShareMomentBodyRingtone,
          source: 'upload',
        );
      },
    ),
  ),

  // ── Upload ─────────────────────────────────────────────────────────────
  ScreenEntry(
    id: 'upload.screen',
    textField: true,
    build: () => const UploadScreen(),
  ),

  // ── Apply ──────────────────────────────────────────────────────────────
  ScreenEntry(
    id: 'apply.sheet',
    unlocalizedEnglish: true,
    build: () => SheetHost(open: (context) => ApplySheet.show(context)),
  ),

  // ── Auth ───────────────────────────────────────────────────────────────
  ScreenEntry(
    id: 'signin.screen',
    unlocalizedEnglish: true,
    build: () => const SignInScreen(),
  ),

  // ── The dock ───────────────────────────────────────────────────────────
  ScreenEntry(
    id: 'shell.dock',
    build: () => Scaffold(
      extendBody: true,
      body: const SizedBox.expand(),
      bottomNavigationBar: Builder(
        builder: (context) {
          final l10n = AppLocalizations.of(context);
          return ArulNavDock(
            currentIndex: 1,
            onTap: (_) {},
            items: [
              (glyph: ArulLineGlyph.wallpapers, label: l10n.tabWallpapers),
              (glyph: ArulLineGlyph.ringtones, label: l10n.tabRingtones),
              (glyph: ArulLineGlyph.settings, label: l10n.settingsTitle),
            ],
          );
        },
      ),
    ),
  ),
];

// ─── Pumping ─────────────────────────────────────────────────────────────────

/// Wraps [entry] in the app's real theme, real delegates and the configuration
/// under test.
///
/// The theme goes through [applyRealFonts] so every style that descends from it
/// names a real face; the dark theme is used because the type scale is
/// identical in both (`ArulType.scale` differs only in colour) and layout
/// cannot depend on which one is up.
Widget buildHarness({
  required ScreenEntry entry,
  required String locale,
  required L10nConfig config,
}) {
  // MaterialApp.router, not MaterialApp: several screens call `GoRouter.of`
  // during their first build (the Ringtones header's Earn pill, Settings' row
  // taps, sign-in's post-auth `context.go`) and assert without a router
  // ancestor. Giving every entry the same shell keeps one code path.
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => entry.build()),
      for (final path in const [
        '/browse',
        '/ringtones',
        '/settings',
        '/settings/notifications',
        '/refer',
        '/upload',
        '/premium',
        '/sign-in',
        '/legal/privacy',
        '/legal/terms',
        '/legal/refund',
      ])
        GoRoute(path: path, builder: (_, _) => const SizedBox.shrink()),
    ],
  );

  return ProviderScope(
    overrides: [...kBaseOverrides, ...entry.overrides],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: applyRealFonts(ArulTheme.dark()),
      routerConfig: router,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            size: Size(config.width, config.height),
            textScaler: TextScaler.linear(config.textScale),
            padding: const EdgeInsets.only(
              top: L10nConfig.topInset,
              bottom: L10nConfig.bottomInset,
            ),
            viewPadding: const EdgeInsets.only(
              top: L10nConfig.topInset,
              bottom: L10nConfig.bottomInset,
            ),
            viewInsets: config.viewInsets,
          ),
          child: child!,
        );
      },
    ),
  );
}

/// Native channels the registry's screens reach for. Returning null from every
/// one keeps the video pool, the audio preview and the platform info plugins
/// inert without changing a line of app code.
const List<String> kFakeChannels = <String>[
  'arul/feed_video',
  'arul/feed_video_events',
  'com.ryanheise.just_audio.methods',
  'dev.fluttercommunity.plus/package_info',
  'plugins.flutter.io/path_provider',
  'plugins.flutter.io/url_launcher',
  'plugins.flutter.io/shared_preferences',
];

/// Installs the no-op handlers. Layer 1 calls this; Layer 2 does not — on the
/// device the real plugins exist and are harmless (nothing here initiates a
/// network call or a sign-in).
void installFakeChannels(TestDefaultBinaryMessenger messenger) {
  for (final name in kFakeChannels) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }
}
