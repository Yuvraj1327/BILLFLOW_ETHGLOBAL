import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';

/// The "B" symbol of the logo (assets/brand). The artwork is navy on transparent, so in dark mode it sits on a white tile.
class BillflowLogo extends StatelessWidget {
  const BillflowLogo({super.key, this.height = 40, this.mark = true, this.tile = false});
  final double height;
  final bool mark;
  /// Force the white tile (use on dark/gradient backgrounds).
  final bool tile;

  @override
  Widget build(BuildContext context) {
    final img = Image.asset(mark ? 'assets/brand/billflow_mark.png' : 'assets/brand/billflow_logo.png',
        height: height, fit: BoxFit.contain, semanticLabel: 'NEXA BILLFLOW');
    if (!tile && Theme.of(context).brightness == Brightness.light) return img;
    return Container(
      padding: EdgeInsets.all(height * .12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(height * .22)),
      child: img,
    );
  }
}

/// Primary brand lockup: logo mark + NEXA BILLFLOW wordmark. `height` is the mark height; the text scales with it.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.height = 36, this.showText = true, this.stacked = false, this.onDark = false});
  final double height;
  final bool showText, stacked;
  /// Use on dark or gradient backgrounds: white logo tile and light text.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final dark = onDark || Theme.of(context).brightness == Brightness.dark;
    final style = TextStyle(fontSize: height * (stacked ? .5 : .46), fontWeight: FontWeight.w900, letterSpacing: height * .04, height: 1);
    final text = Text.rich(TextSpan(children: [
      TextSpan(text: 'NEXA ', style: style.copyWith(color: dark ? Colors.white : Tokens.blue)),
      TextSpan(text: 'BILLFLOW', style: style.copyWith(color: dark ? const Color(0xFF2CC4B7) : Tokens.teal)),
    ]), maxLines: 1, softWrap: false);
    final mark = BillflowLogo(height: height, tile: onDark);
    if (!showText) return mark;
    return stacked
        ? Column(mainAxisSize: MainAxisSize.min, children: [mark, SizedBox(height: height * .3), text])
        : Row(mainAxisSize: MainAxisSize.min, children: [mark, SizedBox(width: height * .3), Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: text))]);
  }
}

/// App bar title: logo mark + text.
class BrandTitle extends StatelessWidget {
  const BrandTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        const BillflowLogo(height: 28),
        const SizedBox(width: 10),
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
      ]);
}
