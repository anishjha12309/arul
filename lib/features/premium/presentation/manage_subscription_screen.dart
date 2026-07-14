import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../data/models/subscription_model.dart';
import '../../../theme/arul_tokens.dart';
import '../../settings/presentation/confirm_dialog.dart';
import '../domain/entitlement.dart';
import '../providers/entitlement_provider.dart';
import '../providers/premium_purchase_provider.dart';

/// "Arul Premium" (Settings → Arul Premium) — the account's premium home.
///
/// Renders the user's REAL subscription state and the one action that fits it:
///   • trialing / active            → Cancel subscription (access stays until the
///                                    period ends; only auto-renew stops)
///   • cancelled, still paid-through → Resubscribe, plus a plain "won't renew"
///                                    note so the remaining access is not a surprise
///   • expired / paused / none      → Get Premium (routes to the paywall)
///
/// This is also the only screen that can reach `POST /payments/cancel` — the
/// Worker has always exposed it, but nothing on the client called it, so a user
/// literally could not cancel from inside the app.
class ManageSubscriptionScreen extends ConsumerStatefulWidget {
  const ManageSubscriptionScreen({super.key});

  @override
  ConsumerState<ManageSubscriptionScreen> createState() =>
      _ManageSubscriptionScreenState();
}

class _ManageSubscriptionScreenState
    extends ConsumerState<ManageSubscriptionScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Reconcile on open. A user who revokes the mandate from inside their UPI
    // app fires NO merchant webhook, so our row can still read 'active' forever.
    // /payments/status makes the Worker re-check PhonePe and flip the row, so
    // this screen never confidently states a plan that no longer exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(premiumPurchaseProvider.notifier).refreshStatus();
    });
  }

  Future<void> _confirmAndCancel(SubscriptionModel sub) async {
    if (_busy) return;
    final until = _formatDate(sub.currentPeriodEnd);

    final ok = await showArulConfirmDialog(
      context,
      title: 'Cancel subscription?',
      message: until == null
          ? 'Your premium access stays active until the end of the current '
                'billing period. After that you won\'t be charged again.'
          : 'Your premium access stays active until $until. After that you '
                'won\'t be charged again.',
      confirmLabel: 'Cancel it',
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final notifier = ref.read(premiumPurchaseProvider.notifier);

    // cancel() owns the message. refreshStatus() is a best-effort reconcile and
    // must never turn a successful cancel into an error — hence the separate
    // try. _busy is always cleared, so the button can't get stuck spinning.
    String? error;
    try {
      error = await notifier.cancel();
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    try {
      await notifier.refreshStatus();
    } catch (_) {}

    if (!mounted) return;
    setState(() => _busy = false);

    showArulToast(
      context,
      error ??
          (until == null
              ? 'Subscription cancelled. You keep premium until the period ends.'
              : 'Subscription cancelled. You keep premium until $until.'),
      kind: error != null ? ToastKind.error : ToastKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep the (autoDispose) purchase provider alive while this screen is up, so
    // cancel()/refreshStatus() still hold a live Ref across their async gaps.
    ref.watch(premiumPurchaseProvider);

    final entitlementAsync = ref.watch(entitlementDetailProvider);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final headerColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (context.canPop()) context.pop();
                    },
                    child: Icon(Icons.arrow_back, size: 24, color: headerColor),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Arul Premium',
                    style: ArulTokens.screenTitle.copyWith(color: headerColor),
                  ),
                ],
              ),
            ),
            Expanded(
              child: entitlementAsync.when(
                loading: () => const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                // A failed fetch (offline, 401, 500) falls back to the free view
                // rather than a dead-end error card: the upsell is still a useful
                // screen, and the Worker remains the authoritative gate anyway.
                error: (_, _) => _body(const Entitlement.none(), isDark),
                data: (e) => _body(e, isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(Entitlement entitlement, bool isDark) {
    final view = _PlanView.resolve(entitlement);
    final sub = entitlement.subscription;

    final textPrimary = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final textSecondary = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final cardBg = isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight;
    final cardBorder = isDark
        ? ArulTokens.cardBorderDark09
        : ArulTokens.cardBorderLight;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        // Hero — the plan, stated once, in the app's own voice.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
          decoration: BoxDecoration(
            gradient: isDark ? ArulTokens.silkDark : ArulTokens.silkLight,
            border: Border.all(
              color: isDark
                  ? ArulTokens.silkBorderDark
                  : ArulTokens.silkBorderLight,
            ),
            borderRadius: BorderRadius.circular(ArulTokens.cardRadius),
          ),
          child: Column(
            children: [
              GopuramMark(size: 34, color: accent),
              const SizedBox(height: 12),
              Text(
                view.headline,
                textAlign: TextAlign.center,
                style: ArulTokens.sheetTitle.copyWith(color: textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                view.subline,
                textAlign: TextAlign.center,
                style: ArulTokens.body.copyWith(
                  height: 1.5,
                  color: textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              _StatusChip(label: view.chipLabel, tone: view.tone),
            ],
          ),
        ),
        const SizedBox(height: ArulTokens.contentGap),

        // Billing card — only when there IS a plan to describe.
        if (view.showBilling && sub != null) ...[
          Container(
            decoration: BoxDecoration(
              color: cardBg,
              border: Border.all(color: cardBorder),
              borderRadius: BorderRadius.circular(ArulTokens.rowsCardRadius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _BillingRow(label: 'Plan', value: 'Monthly', isDark: isDark),
                _BillingDivider(isDark: isDark),
                _BillingRow(
                  label: 'Price',
                  value: '₹199 / month',
                  isDark: isDark,
                ),
                _BillingDivider(isDark: isDark),
                _BillingRow(
                  label: 'Payment',
                  value: 'UPI Autopay',
                  isDark: isDark,
                ),
                if (view.dateLabel != null &&
                    _formatDate(view.dateValue(sub)) != null) ...[
                  _BillingDivider(isDark: isDark),
                  _BillingRow(
                    label: view.dateLabel!,
                    value: _formatDate(view.dateValue(sub))!,
                    isDark: isDark,
                    emphasise: true,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          // The reference app notifies 24h before every debit (hourly cron) —
          // say so, so the charge is never a surprise.
          if (view.renews)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                "We'll remind you 24 hours before every renewal.",
                style: ArulTokens.caption.copyWith(color: textSecondary),
              ),
            ),
          const SizedBox(height: ArulTokens.contentGap),
        ],

        // The single action that fits the state.
        if (view.action == _PlanAction.cancel)
          _CancelButton(
            busy: _busy,
            onTap: sub == null ? null : () => _confirmAndCancel(sub),
          )
        else
          CtaButton(
            label: view.ctaLabel,
            height: ArulTokens.ctaHeight52,
            fontSize: 16,
            onPressed: () => context.push('/premium?source=${view.ctaSource}'),
          ),

        const SizedBox(height: 14),
        Text(
          view.footnote,
          textAlign: TextAlign.center,
          style: ArulTokens.caption.copyWith(height: 1.5, color: textSecondary),
        ),
      ],
    );
  }
}

// ─── Plan state → what the screen says ───────────────────────────────────────

enum _PlanAction { cancel, getPremium, resubscribe }

enum _Tone { positive, warning, neutral }

/// The brain: one subscription row in, one full screen's worth of copy out.
/// Kept apart from the widgets so the state→copy mapping is readable in one
/// place — every case below is a state the Worker can actually put us in.
class _PlanView {
  const _PlanView({
    required this.headline,
    required this.subline,
    required this.chipLabel,
    required this.tone,
    required this.showBilling,
    required this.action,
    required this.ctaLabel,
    required this.ctaSource,
    required this.footnote,
    required this.renews,
    this.dateLabel,
  });

  final String headline;
  final String subline;
  final String chipLabel;
  final _Tone tone;
  final bool showBilling;
  final _PlanAction action;
  final String ctaLabel;
  final String ctaSource;
  final String footnote;

  /// Whether a future debit is still scheduled (drives the reminder note).
  final bool renews;

  /// Null hides the date row entirely (a plan with no date is better than a
  /// row reading "—").
  final String? dateLabel;

  DateTime? dateValue(SubscriptionModel sub) => switch (action) {
    // In trial, the meaningful date is when the free ride ends and the ₹199
    // lands — fall back to the period end if trial_end is somehow absent.
    _PlanAction.cancel =>
      sub.status == SubscriptionStatus.trialing
          ? (sub.trialEnd ?? sub.currentPeriodEnd)
          : sub.currentPeriodEnd,
    _ => sub.currentPeriodEnd,
  };

  static _PlanView resolve(Entitlement e) {
    final sub = e.subscription;

    // No usable plan: no row at all, or a terminal status (expired / paused).
    // `isPremium` already folds in the period check, so a lapsed row lands here.
    if (sub == null || !e.isPremium) {
      return const _PlanView(
        headline: 'Go Premium',
        subline:
            'Apply and share every wallpaper — still and live — for ₹199 a month.',
        chipLabel: 'Free plan',
        tone: _Tone.neutral,
        showBilling: false,
        action: _PlanAction.getPremium,
        ctaLabel: 'Get Premium',
        ctaSource: 'manage',
        footnote:
            'Browsing and preview are always free. Cancel anytime — access '
            'continues until the period you paid for ends.',
        renews: false,
      );
    }

    return switch (sub.status) {
      SubscriptionStatus.trialing => const _PlanView(
        headline: "You're on the free trial",
        subline:
            'Full access to every wallpaper. Your first ₹199 payment is charged '
            'when the trial ends.',
        chipLabel: 'Free trial',
        tone: _Tone.positive,
        showBilling: true,
        action: _PlanAction.cancel,
        ctaLabel: 'Cancel subscription',
        ctaSource: 'manage',
        footnote:
            'Cancel before the trial ends and you are never charged. Billed '
            'monthly via UPI Autopay.',
        renews: true,
        dateLabel: 'Trial ends',
      ),
      SubscriptionStatus.active => const _PlanView(
        headline: "You're a member",
        subline:
            'Every wallpaper, still and live, is yours to apply and share.',
        chipLabel: 'Active',
        tone: _Tone.positive,
        showBilling: true,
        action: _PlanAction.cancel,
        ctaLabel: 'Cancel subscription',
        ctaSource: 'manage',
        footnote:
            'Billed monthly via UPI Autopay. Cancel anytime — your access '
            'continues until the current period ends.',
        renews: true,
        dateLabel: 'Renews on',
      ),
      // Cancelled but still inside the paid period — premium, not renewing.
      // This is why `cancelled` is in the entitlement IN-list.
      SubscriptionStatus.cancelled => const _PlanView(
        headline: 'Auto-renew is off',
        subline:
            "You keep full access until your paid period ends. You won't be "
            'charged again.',
        chipLabel: 'Auto-renew off',
        tone: _Tone.warning,
        showBilling: true,
        action: _PlanAction.resubscribe,
        ctaLabel: 'Resubscribe',
        ctaSource: 'manage_resubscribe',
        footnote:
            'Resubscribing sets up a fresh UPI Autopay mandate at ₹199 a month.',
        renews: false,
        dateLabel: 'Access until',
      ),
      // isPremium was true, so pending/paused/expired can't reach here — but the
      // enum is exhaustive and a silent wrong screen is worse than a safe one.
      _ => const _PlanView(
        headline: 'Go Premium',
        subline:
            'Apply and share every wallpaper — still and live — for ₹199 a month.',
        chipLabel: 'Free plan',
        tone: _Tone.neutral,
        showBilling: false,
        action: _PlanAction.getPremium,
        ctaLabel: 'Get Premium',
        ctaSource: 'manage',
        footnote: 'Browsing and preview are always free.',
        renews: false,
      ),
    };
  }
}

/// `14 Jul 2026`. Null in → null out, so callers can hide the row entirely.
String? _formatDate(DateTime? d) {
  if (d == null) return null;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = d.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

// ─── Pieces ──────────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.tone});

  final String label;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final (Color fg, Color bg) = switch (tone) {
      _Tone.positive => (
        ArulTokens.ctaGreen,
        ArulTokens.ctaGreen.withValues(alpha: 0.14),
      ),
      _Tone.warning => (
        ArulTokens.gold,
        ArulTokens.gold.withValues(alpha: 0.16),
      ),
      _Tone.neutral => (
        isDark ? ArulTokens.darkTextSecondary : ArulTokens.lightSecondary,
        (isDark ? ArulTokens.darkTextSecondary : ArulTokens.lightSecondary)
            .withValues(alpha: 0.12),
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        border: Border.all(color: fg.withValues(alpha: 0.45)),
      ),
      child: Text(
        label.toUpperCase(),
        style: ArulTokens.caption.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: fg,
        ),
      ),
    );
  }
}

class _BillingRow extends StatelessWidget {
  const _BillingRow({
    required this.label,
    required this.value,
    required this.isDark,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final bool isDark;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final labelColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    final valueColor = emphasise
        ? (isDark ? ArulTokens.gold : ArulTokens.maroon)
        : (isDark ? ArulTokens.darkText : ArulTokens.lightText);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: ArulTokens.rowSub.copyWith(color: labelColor)),
          Text(
            value,
            style: ArulTokens.rowTitle.copyWith(
              fontWeight: emphasise ? FontWeight.w700 : FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _BillingDivider extends StatelessWidget {
  const _BillingDivider({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    color: isDark ? ArulTokens.rowDividerDark : ArulTokens.dividerLight,
  );
}

/// Cancel is destructive, so it is deliberately NOT the green CTA — an outlined
/// maroon pill, matching the logout button's "quiet but real" weight.
class _CancelButton extends StatefulWidget {
  const _CancelButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  State<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends State<_CancelButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final disabled = widget.onTap == null || widget.busy;

    final bg = _pressed
        ? ArulTokens.maroon.withValues(alpha: isDark ? 0.35 : 0.12)
        : ArulTokens.maroon.withValues(alpha: isDark ? 0.22 : 0.06);
    final border = ArulTokens.maroon.withValues(alpha: isDark ? 0.6 : 0.35);
    final fg = isDark ? const Color(0xFFF0C9BA) : ArulTokens.maroon;

    return Opacity(
      opacity: disabled ? 0.6 : 1,
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: disabled ? null : () => setState(() => _pressed = false),
        onTap: disabled ? null : widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: ArulTokens.ctaHeight52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          ),
          child: widget.busy
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              : Text(
                  'Cancel subscription',
                  style: ArulTokens.button.copyWith(fontSize: 15, color: fg),
                ),
        ),
      ),
    );
  }
}
