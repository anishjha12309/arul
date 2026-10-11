import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_palette.dart';
import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';

/// The label over a form field, with an optional quieter suffix such as "(optional)".
class ArulFieldLabel extends StatelessWidget {
  const ArulFieldLabel(this.text, {super.key, this.suffix});

  final String text;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    return Text.rich(
      TextSpan(
        style: ArulTokens.fieldLabel.copyWith(color: p.textSecondary),
        children: [
          TextSpan(text: text),
          if (suffix case final suffix?)
            TextSpan(
              text: ' $suffix',
              style: TextStyle(fontWeight: FontWeight.w400, color: p.textFaint),
            ),
        ],
      ),
    );
  }
}

/// The app's one text field: [ArulTokens.fieldHeight] tall, a hairline rim that turns accent on
/// focus. [semanticLabel] names it for TalkBack, since the visible label is a sibling widget.
class ArulTextField extends StatefulWidget {
  const ArulTextField({
    super.key,
    required this.controller,
    required this.semanticLabel,
    this.hint,
    this.icon,
    this.maxLength,
    this.enabled = true,
    this.identifier,
  });

  final TextEditingController controller;
  final String semanticLabel;
  final String? hint;
  final IconData? icon;
  final int? maxLength;
  final bool enabled;
  final String? identifier;

  @override
  State<ArulTextField> createState() => _ArulTextFieldState();
}

class _ArulTextFieldState extends State<ArulTextField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final field = Row(
      children: [
        if (widget.icon case final icon?) ...[
          Icon(icon, size: 20, color: p.accent),
          const SizedBox(width: ArulSpace.s12),
        ],
        Expanded(
          child: Semantics(
            label: widget.semanticLabel,
            identifier: widget.identifier,
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              cursorColor: p.accent,
              textInputAction: TextInputAction.done,
              inputFormatters: [
                if (widget.maxLength case final max?)
                  LengthLimitingTextInputFormatter(max),
              ],
              style: ArulTokens.fieldText.copyWith(color: p.text),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: ArulTokens.fieldText.copyWith(color: p.textFaint),
              ),
            ),
          ),
        ),
      ],
    );
    return GestureDetector(
      // The whole box focuses the field, not only the line of text inside it.
      onTap: widget.enabled ? _focus.requestFocus : null,
      child: ListenableBuilder(
        listenable: _focus,
        builder: (context, child) => _FieldBox(
          focused: _focus.hasFocus,
          child: child ?? const SizedBox.shrink(),
        ),
        child: field,
      ),
    );
  }
}

/// A field that opens a picker instead of a keyboard: same box as [ArulTextField], the current
/// value or a faint placeholder, and a chevron that says "more choices".
class ArulSelectField extends StatefulWidget {
  const ArulSelectField({
    super.key,
    required this.semanticLabel,
    required this.placeholder,
    required this.onTap,
    this.value,
    this.leading,
    this.identifier,
  });

  final String semanticLabel;
  final String placeholder;
  final String? value;
  final Widget? leading;
  final VoidCallback? onTap;
  final String? identifier;

  @override
  State<ArulSelectField> createState() => _ArulSelectFieldState();
}

class _ArulSelectFieldState extends State<ArulSelectField> {
  bool _pressed = false;

  void _press(bool down) {
    if (_pressed != down) setState(() => _pressed = down);
  }

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final value = widget.value;
    final onTap = widget.onTap;
    return Semantics(
      container: true,
      button: true,
      enabled: onTap != null,
      label: '${widget.semanticLabel}, ${value ?? widget.placeholder}',
      identifier: widget.identifier,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onTap == null
            ? null
            : (_) {
                ArulHaptics.tap();
                _press(true);
              },
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: _pressed && !context.reduceMotion ? 0.6 : 1,
          duration: context.reduceMotion ? Duration.zero : Motion.pressDip,
          child: _FieldBox(
            focused: false,
            grows: true,
            child: Row(
              children: [
                if (widget.leading case final leading?) ...[
                  leading,
                  const SizedBox(width: ArulSpace.s12),
                ],
                Expanded(
                  // Two lines, then the box grows: "Choose a category" in Tamil at 1.3× is three
                  // English lengths, and an ellipsis there hides what the field is for.
                  child: Text(
                    value ?? widget.placeholder,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ArulTokens.fieldText.copyWith(
                      color: value == null ? p.textFaint : p.text,
                    ),
                  ),
                ),
                const SizedBox(width: ArulSpace.s8),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 22,
                  color: p.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldBox extends StatelessWidget {
  const _FieldBox({
    required this.focused,
    required this.child,
    this.grows = false,
  });

  final bool focused;
  final Widget child;

  /// [ArulTokens.fieldHeight] is then a floor, not the height: the content may wrap.
  final bool grows;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    return Container(
      height: grows ? null : ArulTokens.fieldHeight,
      constraints: grows
          ? const BoxConstraints(minHeight: ArulTokens.fieldHeight)
          : null,
      padding: EdgeInsets.symmetric(
        horizontal: ArulSpace.s16,
        vertical: grows ? ArulSpace.s12 : 0,
      ),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(ArulTokens.inputRadius),
        border: Border.all(
          color: focused ? p.accent : p.border,
          width: ArulTokens.fieldBorderWidth,
        ),
      ),
      child: child,
    );
  }
}
