// The in-app policy reader (docs/edge-cases.md): offline shows the app's own error + Retry, a failed
// load stays failed through Android's error page, the fence keeps only our hosts, and the back arrow
// answers on press-DOWN and pops without a web-view round trip. A fake WebViewPlatform stands in for
// the plugin, which has no implementation under `flutter test`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/l10n/app_localizations_en.dart';
import 'package:arul/app/widgets/arul_spinner.dart';
import 'package:arul/core/config/app_config.dart';
import 'package:arul/features/legal/presentation/policy_screen.dart';

void main() {
  late _FakeWebViewPlatform platform;
  late List<String> haptics;
  final l10n = AppLocalizationsEn();

  setUp(() {
    platform = _FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    haptics = [];
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add('buzz');
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpReader(WidgetTester tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('settings')),
        GoRoute(
          path: '/policy/:doc',
          builder: (_, state) => PolicyScreen(
            doc: PolicyDoc.fromSlug(state.pathParameters['doc']),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    unawaited(router.push(PolicyDoc.privacy.route));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  _FakeController controller() => platform.controllers.single;

  testWidgets('loads the asked-for policy under a spinner', (tester) async {
    await pumpReader(tester);

    expect(controller().loads, [Uri.parse(AppConfig.privacyUrl)]);
    expect(find.byType(ArulSpinner), findsOneWidget);

    controller().delegate!.onPageFinished!(AppConfig.privacyUrl);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ArulSpinner), findsNothing);
    expect(controller().scripts, isNotEmpty, reason: 'site chrome stripped');
  });

  testWidgets(
    'offline shows the app\'s own error + Retry, and Android\'s error page cannot clear it',
    (tester) async {
      await pumpReader(tester);
      final delegate = controller().delegate!;

      delegate.onWebResourceError!(
        const WebResourceError(
          errorCode: -2,
          description: 'net::ERR_INTERNET_DISCONNECTED',
          isForMainFrame: true,
        ),
      );
      // The robot page is itself a finished load.
      delegate.onPageFinished!(AppConfig.privacyUrl);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(l10n.offlineTitle), findsOneWidget);
      expect(find.text(l10n.offlineBody), findsOneWidget);
      expect(find.text(l10n.retry), findsOneWidget);
      expect(find.byType(ArulSpinner), findsNothing);
    },
  );

  testWidgets('a sub-resource failure never blanks the page', (tester) async {
    await pumpReader(tester);

    controller().delegate!.onWebResourceError!(
      const WebResourceError(
        errorCode: -2,
        description: 'font',
        isForMainFrame: false,
      ),
    );
    await tester.pump();

    expect(find.text(l10n.offlineTitle), findsNothing);
  });

  testWidgets('Retry reloads the document root under a spinner', (
    tester,
  ) async {
    await pumpReader(tester);
    controller().delegate!.onWebResourceError!(
      const WebResourceError(
        errorCode: -2,
        description: 'offline',
        isForMainFrame: true,
      ),
    );
    await tester.pump();

    await tester.tap(find.text(l10n.retry));
    await tester.pump();

    expect(controller().loads, [
      Uri.parse(AppConfig.privacyUrl),
      Uri.parse(AppConfig.privacyUrl),
    ]);
    expect(find.text(l10n.offlineTitle), findsNothing);
    expect(find.byType(ArulSpinner), findsOneWidget);

    controller().delegate!.onPageFinished!(AppConfig.privacyUrl);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ArulSpinner), findsNothing);
  });

  testWidgets(
    'the back arrow buzzes on press-DOWN and pops without asking the web view',
    (tester) async {
      await pumpReader(tester);
      controller().delegate!.onPageFinished!(AppConfig.privacyUrl);
      await tester.pump(const Duration(milliseconds: 100));
      final asked = controller().canGoBackCalls;

      final back = find.bySemanticsIdentifier('arul_policy_back');
      final gesture = await tester.startGesture(tester.getCenter(back));
      await tester.pump();
      expect(haptics, ['buzz'], reason: 'answered as the finger lands');

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(PolicyScreen), findsNothing);
      expect(find.text('settings'), findsOneWidget);
      expect(haptics, hasLength(1), reason: 'one beat per press');
      expect(controller().canGoBackCalls, asked);
    },
  );

  testWidgets('with in-page history the arrow steps back inside the reader', (
    tester,
  ) async {
    await pumpReader(tester);
    controller().history = true;
    controller().delegate!.onPageFinished!(AppConfig.privacyUrl);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.bySemanticsIdentifier('arul_policy_back'));
    await tester.pump();

    expect(controller().goBacks, 1);
    expect(find.byType(PolicyScreen), findsOneWidget);
  });

  test('navigation is fenced to our own policy hosts', () {
    final host = Uri.parse(AppConfig.privacyUrl);
    expect(PolicyScreen.keepsInReader(AppConfig.privacyUrl), isTrue);
    expect(PolicyScreen.keepsInReader(AppConfig.termsUrl), isTrue);
    expect(PolicyScreen.keepsInReader(AppConfig.refundUrl), isTrue);
    expect(
      PolicyScreen.keepsInReader(host.replace(path: '/other').toString()),
      isTrue,
    );
    expect(
      PolicyScreen.keepsInReader('https://www.phonepe.com/privacy'),
      isFalse,
    );
    expect(PolicyScreen.keepsInReader('https://policies.google.com/'), isFalse);
    expect(PolicyScreen.keepsInReader('mailto:support@example.com'), isFalse);
    expect(
      PolicyScreen.keepsInReader(host.replace(scheme: 'intent').toString()),
      isFalse,
    );
    expect(PolicyScreen.keepsInReader('::not a url'), isFalse);
  });
}

class _FakeWebViewPlatform extends WebViewPlatform {
  final List<_FakeController> controllers = [];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _FakeController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWidget(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params) : super.implementation();

  final List<Uri> loads = [];
  final List<String> scripts = [];
  _FakeDelegate? delegate;
  bool history = false;
  int canGoBackCalls = 0;
  int goBacks = 0;

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loads.add(params.uri);

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => delegate = handler as _FakeDelegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> runJavaScript(String javaScript) async =>
      scripts.add(javaScript);

  @override
  Future<bool> canGoBack() async {
    canGoBackCalls++;
    return history;
  }

  @override
  Future<void> goBack() async => goBacks++;
}

class _FakeDelegate extends PlatformNavigationDelegate {
  _FakeDelegate(super.params) : super.implementation();

  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async =>
      this.onPageStarted = onPageStarted;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async =>
      this.onPageFinished = onPageFinished;

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async => this.onWebResourceError = onWebResourceError;

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
