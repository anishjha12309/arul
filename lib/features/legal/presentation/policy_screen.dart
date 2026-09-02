import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/state_views.dart';
import '../../../core/config/app_config.dart';
import '../../../theme/arul_tokens.dart';

/// The three legal documents the app links to, and where each one lives.
///
/// The URLs stay in [AppConfig] — the Play listing names the same pages, and a second copy goes stale.
enum PolicyDoc {
  privacy,
  terms,
  refund;

  /// Route slug → doc; anything unrecognised resolves to [privacy] -> a bad link never crashes.
  static PolicyDoc fromSlug(String? slug) => switch (slug) {
    'terms' => PolicyDoc.terms,
    'refund' => PolicyDoc.refund,
    _ => PolicyDoc.privacy,
  };

  String get url => switch (this) {
    PolicyDoc.privacy => AppConfig.privacyUrl,
    PolicyDoc.terms => AppConfig.termsUrl,
    PolicyDoc.refund => AppConfig.refundUrl,
  };

  /// The push target. Call sites use this instead of spelling paths.
  String get route => switch (this) {
    PolicyDoc.privacy => '/policy/privacy',
    PolicyDoc.terms => '/policy/terms',
    PolicyDoc.refund => '/policy/refund',
  };

  /// Reuses the Settings row labels — translated in all 6 locales, and the same word the user tapped.
  String title(AppLocalizations l10n) => switch (this) {
    PolicyDoc.privacy => l10n.settingsPrivacy,
    PolicyDoc.terms => l10n.settingsTerms,
    PolicyDoc.refund => l10n.settingsRefund,
  };
}

/// Privacy Policy / Terms & Conditions / Refund Policy, read INSIDE the app.
///
/// The reviewer requires a policy to open WITHIN the app, with a back button that returns to it.
/// So this is an app screen with the standard sub-screen header, and the web page is only the body.
/// A bundled copy would freeze at whatever the last release shipped -> the document stays REMOTE.
/// The cost is that this screen needs the network -> it has a real offline state.
/// These are Arul's OWN pages and link only to each other -> a link cannot land on Pakiza's.
///
/// What keeps it from reading as "a website in a box":
///  * the site's navbar, mobile menu and footer are suppressed — no second chrome, no way out;
///  * the page is held back until that is applied, so the nav never flashes in and out;
///  * the site's theme is pinned to the app's, so a dark-mode app does not open a white page.
class PolicyScreen extends StatefulWidget {
  const PolicyScreen({super.key, required this.doc});

  final PolicyDoc doc;

  @override
  State<PolicyScreen> createState() => _PolicyScreenState();
}

class _PolicyScreenState extends State<PolicyScreen> {
  late final WebViewController _controller;

  /// True until the document has loaded AND been styled — the web view is invisible throughout.
  bool _loading = true;

  /// A main-frame load failure. Almost always no connection.
  bool _failed = false;

  /// Whether the reader has followed a link deeper into the policy pages.
  ///
  /// Drives BOTH back affordances -> the arrow and the system gesture cannot disagree.
  /// False is the normal case -> the route pops the ordinary way and keeps predictive back.
  bool _canGoBack = false;

  Brightness _brightness = Brightness.light;

  /// Hosts the reader navigates itself — DERIVED from the configured URLs, never written out.
  /// So a dart-define override cannot bounce our own pages out to the browser.
  static final Set<String> _ownHosts = {
    Uri.parse(AppConfig.privacyUrl).host,
    Uri.parse(AppConfig.termsUrl).host,
    Uri.parse(AppConfig.refundUrl).host,
  }..removeWhere((h) => h.isEmpty);

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // The page is first-party and script-driven, and [_applyAppChrome] is script -> unrestricted.
      // Navigation is fenced to [_ownHosts] below -> no third-party page ever runs in here.
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
          // Astro swaps pages client-side -> an in-page link never fires onPageFinished again.
          // Without this the site's own navbar reappears on the second page.
          onUrlChange: (_) => unawaited(_onUrlChange()),
          onWebResourceError: (error) {
            // A sub-resource failure must never blank a page that rendered perfectly well.
            if (error.isForMainFrame == false) return;
            _fail();
          },
          onHttpError: (error) {
            // Only the document itself — a 404 on an asset is nothing the reader can act on.
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
    // Matches the page's ground to the app's before first paint, and re-themes on a live flip.
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
  /// Selectors are the site's stable hooks: `[data-nav]` header, `#mobile-menu` sheet, `footer.foot`.
  /// CSS, not DOM surgery -> a moved hook degrades to the page with its own nav, never to a blank.
  /// `.doc`'s top padding exists to clear the fixed navbar, so it comes down with it.
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
      // A page that will not take the injection is still a readable policy -> show it, never spin.
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
  /// On Android this also fires part-way through the FIRST load -> revealing there flashes the navbar.
  /// So it deliberately does NOT touch [_loading].
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
  /// The text links to `mailto:` support, PhonePe's and Google's policies, and the Play listing.
  /// A policy reader should swallow none of those — `mailto:` a web view cannot render at all.
  FutureOr<NavigationDecision> _decideNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    final isOurs =
        uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        _ownHosts.contains(uri.host);
    if (isOurs) return NavigationDecision.navigate;

    if (uri != null) {
      // Fire-and-forget -> a device with no handler for the scheme must not throw into the reader.
      unawaited(
        launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        ).catchError((_) => false),
      );
    }
    return NavigationDecision.prevent;
  }

  /// One back for the arrow and the gesture — unwind the pages first, then leave the screen.
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
    // Back to the document root, not reload() — the asked-for policy is where to land.
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
      // Intercepted only when there is in-page history -> an ordinary read keeps predictive back.
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: bg,
        body: SafeArea(
          child: Column(
            children: [
              // The pushed sub-screen header, as on Upload and Reminders — this is an app screen.
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
                          // An Offstage web view never lays out -> keep it in the tree, or
                          // rendering starts only at the moment of reveal.
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
