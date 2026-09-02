import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../theme/arul_tokens.dart';

/// The edit-name sheet, laid out to the mock's spec.
///
/// Resolves to the trimmed new name on Save -> null on dismiss.
Future<String?> showEditNameSheet(BuildContext context, String current) {
  return showArulSheet<String>(
    context,
    builder: (_) => _EditNameSheet(current: current),
  );
}

class _EditNameSheet extends StatefulWidget {
  const _EditNameSheet({required this.current});

  final String current;

  @override
  State<_EditNameSheet> createState() => _EditNameSheetState();
}

class _EditNameSheetState extends State<_EditNameSheet> {
  static const _maxChars = 40;

  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    // The mock shows the field already ringed and caret-ready -> focus it on the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    final focusBorder = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final fieldBg = isDark ? ArulTokens.cardBgDark05 : ArulTokens.cardBgLight;
    final textColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final counterColor = isDark ? ArulTokens.darkFaint : ArulTokens.lightFaint;
    // The mock's field is always ringed (that IS its focused state) -> hairline only if focus is lost.
    final idleBorder = isDark
        ? ArulTokens.cardBorderDark14
        : ArulTokens.cardBorderLight;

    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 26 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.settingsEditNameTitle,
            style: ArulTokens.sheetTitle.copyWith(color: titleColor),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.settingsEditNameSub,
            textAlign: TextAlign.center,
            style: ArulTokens.rowSub.copyWith(fontSize: 13, color: subColor),
          ),
          const SizedBox(height: 16),
          AnimatedBuilder(
            animation: _focus,
            builder: (context, _) => Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: fieldBg,
                border: Border.all(
                  color: _focus.hasFocus ? focusBorder : idleBorder,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(ArulTokens.inputRadius),
              ),
              child: Row(
                children: [
                  Icon(Icons.person, size: 20, color: focusBorder),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      cursorColor: focusBorder,
                      maxLength: _maxChars,
                      maxLengthEnforcement: MaxLengthEnforcement.enforced,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _save(),
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(_maxChars),
                      ],
                      style: ArulTokens.rowTitle.copyWith(
                        fontWeight: FontWeight.w400,
                        color: textColor,
                      ),
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        counterText: '',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${_controller.text.characters.length} / $_maxChars',
              style: ArulTokens.caption.copyWith(
                fontSize: 11.5,
                color: counterColor,
              ),
            ),
          ),
          const SizedBox(height: 16),
          CtaButton(
            label: l10n.save,
            height: ArulTokens.ctaHeight50,
            fontSize: 15.5,
            onPressed: _controller.text.trim().isEmpty ? null : _save,
          ),
        ],
      ),
    );
  }
}
