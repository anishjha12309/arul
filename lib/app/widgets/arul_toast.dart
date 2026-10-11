import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_palette.dart';
import '../../theme/arul_tokens.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import 'arul_surface.dart';

enum ToastKind { info, success, error }

/// Branded toast on the ROOT overlay, so it shows above every route, sheet and dialog and survives
/// navigation; a new one replaces the last. Not a SnackBar: Material's floating snack bar fades in
/// over a fifth of its entrance behind a clipped height wipe, and that cannot be restyled.
/// Every meaningful outcome lands here -> this is the ONE place the outcome haptic fires, keyed off
/// [kind] -> callers must never add their own; `haptic: false` marks a toast that is pure chrome.
void showArulToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  bool haptic = true,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  if (haptic) {
    switch (kind) {
      case ToastKind.success:
        ArulHaptics.success();
      case ToastKind.error:
        ArulHaptics.error();
      case ToastKind.info:
        ArulHaptics.warning();
    }
  }

  // A tab floats it over the dock; a pushed screen has no dock to clear.
  final overDock = AppShell.dockClearance(context) > 0;
  _Toaster.show(overlay, message: message, kind: kind, overDock: overDock);
}

abstract final class _Toaster {
  static _ToastHandle? _current;

  static void show(
    OverlayState overlay, {
    required String message,
    required ToastKind kind,
    required bool overDock,
  }) {
    _current?.dismiss();
    final handle = _ToastHandle();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        handle: handle,
        message: message,
        kind: kind,
        overDock: overDock,
        onGone: () {
          if (entry.mounted) entry.remove();
          if (identical(_current, handle)) _current = null;
        },
      ),
    );
    _current = handle;
    overlay.insert(entry);
  }
}

/// Lets the next toast send this one away, even before its first frame has built it.
class _ToastHandle {
  _ToastViewState? _state;
  bool _dismissed = false;

  void dismiss() {
    _dismissed = true;
    _state?._leave();
  }
}

class _ToastView extends StatefulWidget {
  const _ToastView({
    required this.handle,
    required this.message,
    required this.kind,
    required this.overDock,
    required this.onGone,
  });

  final _ToastHandle handle;
  final String message;
  final ToastKind kind;
  final bool overDock;
  final VoidCallback onGone;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.toastIn,
    reverseDuration: Motion.overlayOut,
  );
  late final CurvedAnimation _t = CurvedAnimation(
    parent: _c,
    curve: Motion.overlayInCurve,
    reverseCurve: Motion.overlayOutCurve,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: Motion.dialogScaleFrom,
    end: 1,
  ).animate(_t);

  Timer? _timer;
  bool _armed = false;
  bool _leaving = false;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    widget.handle._state = this;
  }

  /// Armed here, not in initState: the reduce-motion answer and TalkBack's state are inherited.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_armed) return;
    _armed = true;
    if (widget.handle._dismissed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
      return;
    }
    if (context.reduceMotion) {
      _c.value = 1;
    } else {
      unawaited(_c.forward());
    }
    _timer = Timer(
      _holdFor(widget.message, MediaQuery.accessibleNavigationOf(context)),
      _leave,
    );
  }

  /// Material's 4 s floor, plus reading time for a long line up to the cap; doubled under TalkBack,
  /// which speaks the line before anyone can act on it.
  static Duration _holdFor(String message, bool accessible) {
    final extra = Motion.toastReadPerChar * math.max(0, message.length - 40);
    final hold = Motion.toastHold + extra;
    final capped = hold > Motion.toastHoldMax ? Motion.toastHoldMax : hold;
    return accessible ? capped * 2 : capped;
  }

  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _timer?.cancel();
    if (context.reduceMotion) {
      _finish();
      return;
    }
    _c.reverse().whenCompleteOrCancel(_finish);
  }

  void _finish() {
    if (_gone) return;
    _gone = true;
    widget.onGone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (identical(widget.handle._state, this)) widget.handle._state = null;
    _t.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final dock = widget.overDock && keyboard == 0
        ? ArulTokens.dockHeight + ArulTokens.dockBottomInset
        : 0.0;
    final bottom =
        math.max(keyboard, media.viewPadding.bottom) +
        dock +
        ArulTokens.toastGap;

    final body = AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, (1 - _t.value) * Motion.toastRise),
        child: child,
      ),
      child: ScaleTransition(
        scale: _scale,
        alignment: Alignment.bottomCenter,
        child: _ToastBody(message: widget.message, kind: widget.kind),
      ),
    );

    return Positioned(
      left: ArulSpace.s16,
      right: ArulSpace.s16,
      bottom: bottom,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ArulTokens.toastMaxWidth),
          child: Dismissible(
            key: ObjectKey(widget.handle),
            direction: DismissDirection.down,
            onDismissed: (_) => _finish(),
            child: GestureDetector(
              // A tap sends it away early; it carries no action of its own.
              onTap: _leave,
              child: FadeTransition(opacity: _t, child: body),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({required this.message, required this.kind});

  final String message;
  final ToastKind kind;

  @override
  Widget build(BuildContext context) {
    final (accent, icon) = switch (kind) {
      ToastKind.info => (ArulTokens.gold, Icons.info_outline_rounded),
      ToastKind.success => (ArulTokens.ctaGreen, Icons.check_rounded),
      ToastKind.error => (
        ArulTokens.dangerInkDark,
        Icons.priority_high_rounded,
      ),
    };
    const ink = ArulPalette.dark;
    // An overlay entry sits under no Material: without one, Text falls back to the debug style.
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        container: true,
        liveRegion: true,
        child: ArulSurface(
          // The inverse surface: dark in both themes, so it reads as news over either page.
          palette: ink,
          borderRadius: BorderRadius.circular(ArulTokens.toastRadius),
          rimColor: accent.withValues(alpha: ArulTokens.toastRimAlpha),
          litEdge: kind == ToastKind.info,
          // A dark pill over the light page still needs the light page's lift.
          shadow: ArulPalette.of(context).overlayShadow,
          padding: const EdgeInsets.fromLTRB(
            ArulSpace.s12,
            ArulSpace.s12,
            ArulSpace.s16,
            ArulSpace.s12,
          ),
          child: Row(
            children: [
              Container(
                width: ArulTokens.toastBadgeSize,
                height: ArulTokens.toastBadgeSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: ArulTokens.toastBadgeAlpha),
                ),
                child: Icon(
                  icon,
                  size: ArulTokens.toastIconSize,
                  color: accent,
                ),
              ),
              const SizedBox(width: ArulSpace.s12),
              Expanded(
                child: Text(
                  message,
                  style: ArulTokens.toastText.copyWith(color: ink.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
