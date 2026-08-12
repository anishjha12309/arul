import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/state_views.dart';
import '../../../core/config/app_config.dart';
import '../../../theme/arul_tokens.dart';

/// The two legal documents the app links to, and where each one lives.
///
/// The URLs stay in [AppConfig] — they are the SAME pages the Play listing
/// names, and a second copy is how one of them goes stale.
enum PolicyDoc {
  privacy,
  terms;

  /// Route slug → doc. Anything unrecognised resolves to [privacy] rather than
  /// throwing: a bad deep link must land on a real policy, not a crash.
  static PolicyDoc fromSlug(String? slug) =>
      slug == 'terms' ? PolicyDoc.terms : PolicyDoc.privacy;

  String get url => switch (this) {
    PolicyDoc.privacy => AppConfig.privacyUrl,
    PolicyDoc.terms => AppConfig.termsUrl,
  };

  /// The push target. Call sites use this instead of spelling paths.
  String get route => switch (this) {
    PolicyDoc.privacy => '/policy/privacy',
    PolicyDoc.terms => '/policy/terms',
  };

  /// Reuses the Settings row labels — already translated in all 6 locales, and
  /// the header should read the same word the user just tapped.
  String title(AppLocalizations l10n) => switch (this) {
    PolicyDoc.privacy => l10n.settingsPrivacy,
    PolicyDoc.terms => l10n.settingsTerms,
  };
}

/// Privacy Policy / Terms & Conditions, read INSIDE the app.
///
/// These used to open with `LaunchMode.externalApplication`, which threw the
/// user out into Chrome with no way back except the system back stack. The
/// reviewer's instruction (2026-08-12) is that a policy must open within the
/// app and carry a back button that returns to it — so this is an app screen
/// with the standard sub-screen header, and the web page is only the body.
///
/// The document stays REMOTE rather than bundled: privacy and terms are shared
/// with Pakiza and served from one company page, and a copy compiled into the
/// app would freeze at whatever the last release shipped. The cost is that this
/// screen needs the network, which is why it has a real offline state.
///
/// What keeps it from reading as "a website in a box":
///  * the site's own navbar, mobile menu and footer are suppressed, so there is
///    no second set of chrome and no route out into the marketing pages;
///  * the page is held back until that has been applied, so the nav never
///    flashes in and out;
///  * the site's theme is pinned to the app's, so a dark-mode app does not open
///    a white page.
class PolicyScreen extends StatefulWidget {
  const PolicyScreen({super.key, required this.doc});

  final PolicyDoc doc;

  @override
  State<PolicyScreen> createState() => _PolicyScreenState();
}

class _PolicyScreenState extends State<PolicyScreen> {
  late final WebViewController _controller;

  /// True until the document has loaded AND been styled. The web view stays
  /// invisible for the whole of it — see [_applyAppChrome].
  bool _loading = true;

  /// A main-frame load failure. Almost always no connection.
  bool _failed = false;

  /// Whether the user has followed a link deeper into the policy pages (the
  /// privacy page links to terms, terms links back). Drives BOTH back affordances
  /// so the arrow and the system gesture cannot disagree.
  ///
  /// While it is false — the normal case, one page opened and read — the route
  /// pops the ordinary way and keeps its predictive-back transition.
  bool _canGoBack = false;

  Brightness _brightness = Brightness.light;

  /// Hosts the reader will navigate to itself. Derived from the configured URLs
  /// rather than written out, so a dart-define override cannot leave the reader
  /// bouncing its own pages out to the browser.
  static final Set<String> _ownHosts = {
    Uri.parse(AppConfig.privacyUrl).host,
    Uri.parse(AppConfig.termsUrl).host,
  }..removeWhere((h) => h.isEmpty);

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // Unrestricted because the page is first-party and its theme, motion and
      // in-page anchors are script-driven — and because [_applyAppChrome] is
      // itself script. Navigation is fenced to [_ownHosts] below, so no
      // third-party page ever runs in here.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _decideNavigation,
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _failed = false;
            });
          },
          onPageFinished: (_) => unawaited(_reveal()),
          // Astro swaps these pages client-side, so following the in-page link
          // from privacy to terms never fires onPageFinished again. Without
          // this the site's own navbar would reappear on the second page.
          onUrlChange: (_) => unawaited(_onUrlChange()),
          onWebResourceError: (error) {
            // Sub-resource failures (a font, an image) must never blank a page
            // that rendered perfectly well.
            if (error.isForMainFrame == false) return;
            _fail();
          },
          onHttpError: (error) {
            // Only the document itself — a 404 on some asset is not an error
            // the reader can do anything about.
            final failed = error.response?.uri;
            if (failed == null) return;
            if (failed.path.replaceAll('/', '') !=
                Uri.parse(widget.doc.url).path.replaceAll('/', '')) {
              return;
            }
            _fail();
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.doc.url));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (brightness == _brightness) return;
    _brightness = brightness;
    // Matches the page's ground to the app's before the first paint, and
    // re-themes it if the user flips the theme while reading.
    unawaited(
      _controller.setBackgroundColor(
        _brightness == Brightness.dark
            ? ArulTokens.darkSurface
            : ArulTokens.ivory,
      ),
    );
    if (!_loading) unawaited(_applyAppChrome());
  }

  void _fail() {
    if (!mounted) return;
    setState(() {
      _failed = true;
      _loading = false;
    });
  }

  /// Strips the site's own chrome and pins its theme to the app's.
  ///
  /// Selectors are the site's stable hooks (`c:\Anish\hsrutillity`): `[data-nav]`
  /// is the header, `#mobile-menu` its sheet, `footer.foot` the footer. If any
  /// of them ever moves, this degrades to showing the page with its own nav —
  /// never to a blank or broken screen, which is why it is CSS and not surgery
  /// on the DOM. `.doc`'s top padding exists to clear the fixed navbar, so it
  /// comes down with it.
  Future<void> _applyAppChrome() async {
    final theme = _brightness == Brightness.dark ? 'dark' : 'light';
    try {
      await _controller.runJavaScript('''
(function () {
  var css = '.skip-link,[data-nav],#mobile-menu,footer.foot{display:none!important}'
          + '.doc{padding-block:1.25rem 2.5rem!important}';
  var el = document.getElementById('arul-app-chrome');
  if (!el) {
    el = document.createElement('style');
    el.id = 'arul-app-chrome';
    document.head.appendChild(el);
  }
  if (el.textContent !== css) el.textContent = css;
  document.documentElement.dataset.theme = '$theme';
  document.documentElement.dataset.themePref = '$theme';
})();
''');
    } catch (_) {
      // A page that will not take the injection is still a readable policy.
      // Callers carry on and show it — that beats holding the user on a
      // spinner over a cosmetic step.
    }
  }

  /// The document has finished loading: style it, then show it.
  Future<void> _reveal() async {
    await _applyAppChrome();
    if (!mounted) return;
    final canGoBack = await _controller.canGoBack();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = false;
      _canGoBack = canGoBack;
    });
  }

  /// A client-side page swap inside the reader.
  ///
  /// Deliberately does NOT touch [_loading]. On Android this also fires part-way
  /// through the very first load, and revealing there would put the site's own
  /// navbar on screen for the frame or two before the styling lands — the exact
  /// flash the page is held back to avoid.
  Future<void> _onUrlChange() async {
    if (_loading) return;
    await _applyAppChrome();
    if (!mounted) return;
    final canGoBack = await _controller.canGoBack();
    if (!mounted || canGoBack == _canGoBack) return;
    setState(() => _canGoBack = canGoBack);
  }

  /// In-app for our own pages; out to the OS for everything else.
  ///
  /// The policy text links to `mailto:` support, to PhonePe's and Google's own
  /// policies, and to the Play listing — none of which a policy reader should
  /// swallow. `mailto:` in particular is not something a web view can render.
  FutureOr<NavigationDecision> _decideNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    final isOurs =
        uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        _ownHosts.contains(uri.host);
    if (isOurs) return NavigationDecision.navigate;

    if (uri != null) {
      // Fire-and-forget, as at every other link in the app: a device with no
      // handler for the scheme must not throw into the reader.
      unawaited(
        launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        ).catchError((_) => false),
      );
    }
    return NavigationDecision.prevent;
  }

  /// One back for the arrow and the system gesture: unwind the policy pages
  /// first, leave the screen once there is nothing left to unwind.
  Future<void> _back() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (!mounted) return;
    if (context.canPop()) context.pop();
  }

  void _retry() {
    setState(() {
      _failed = false;
      _loading = true;
    });
    // Back to the document root rather than reload(): whatever failed, the
    // policy the user asked for is the right place to land.
    unawaited(_controller.loadRequest(Uri.parse(widget.doc.url)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final textPrimary = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;

    return PopScope(
      // Only intercepted once there is in-page history to unwind; the ordinary
      // read keeps canPop true and with it the predictive-back transition the
      // theme gives every route.
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: bg,
        body: SafeArea(
          child: Column(
            children: [
              // The pushed sub-screen header, unchanged from Upload and
              // Reminders — this is an app screen and has to look like one.
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 16, 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => unawaited(_back()),
                      icon: Icon(Icons.arrow_back, color: textPrimary),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.doc.title(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ArulTokens.screenTitle.copyWith(
                          color: textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: _failed
                    ? StateView.error(
                        title: l10n.offlineTitle,
                        message: l10n.offlineBody,
                        actionLabel: l10n.retry,
                        onAction: _retry,
                      )
                    : Stack(
                        children: [
                          // Kept in the tree while loading — an Offstage web
                          // view never lays out, so the page would only start
                          // rendering the moment it was revealed.
                          Opacity(
                            opacity: _loading ? 0 : 1,
                            child: WebViewWidget(controller: _controller),
                          ),
                          if (_loading)
                            Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: accent,
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
