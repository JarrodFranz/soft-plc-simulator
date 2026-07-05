// Generates the app launcher icon + adaptive foreground as PNGs.
// Run: dart run tool/generate_icon.dart
//
// A neutral, brand-free mark: a ladder-logic rung — two power rails (green L1,
// blue L2) joined by a rung carrying a normally-open contact and a coil — on
// the app's dark background. Regenerate any time; the source of truth is here.
import 'dart:io';
import 'package:image/image.dart' as img;

const int size = 1024;

// App palette. (ColorRgb8 is not a const constructor.)
final bg = img.ColorRgb8(0x0F, 0x17, 0x2A); // slate-950 background
final l1 = img.ColorRgb8(0x22, 0xC5, 0x5E); // green rail (L1)
final l2 = img.ColorRgb8(0x3B, 0x82, 0xF6); // blue rail (L2)
final rung = img.ColorRgb8(0x22, 0xD3, 0xEE); // cyan rung/logic

void drawMark(img.Image im, {required bool transparentBg}) {
  if (!transparentBg) {
    img.fill(im, color: bg);
  }
  // Layout within a centered content box (leave margin for adaptive masking).
  const margin = 232; // ~22% padding so the mark survives round/adaptive masks
  final left = margin;
  final right = size - margin;
  final top = margin;
  final bottom = size - margin;
  final midY = size ~/ 2;
  const railW = 30;
  const rungW = 26;

  // Vertical power rails.
  img.fillRect(im, x1: left, y1: top, x2: left + railW, y2: bottom, color: l1);
  img.fillRect(im, x1: right - railW, y1: top, x2: right, y2: bottom, color: l2);

  // Horizontal rung across the middle.
  img.fillRect(im,
      x1: left + railW, y1: midY - rungW ~/ 2, x2: right - railW, y2: midY + rungW ~/ 2, color: rung);

  // Normally-open contact ( -| |- ) on the left third of the rung.
  final cx = left + (right - left) ~/ 3;
  const gap = 46;
  const barH = 150;
  img.fillRect(im, x1: cx - gap - railW, y1: midY - barH ~/ 2, x2: cx - gap, y2: midY + barH ~/ 2, color: rung);
  img.fillRect(im, x1: cx + gap, y1: midY - barH ~/ 2, x2: cx + gap + railW, y2: midY + barH ~/ 2, color: rung);

  // Coil ( -( )- ) on the right third: two arcs approximated by ring segments.
  final coilX = left + 2 * (right - left) ~/ 3 + 40;
  const coilR = 92;
  for (var t = 1; t <= 3; t++) {
    img.drawCircle(im, x: coilX, y: midY, radius: coilR - t, color: rung);
  }
  // Punch the coil ring's left/right open so it reads as ( ) not a full O.
  img.fillRect(im, x1: coilX - 24, y1: midY - coilR - 6, x2: coilX + 24, y2: midY - coilR + 40, color: transparentBg ? img.ColorRgba8(0, 0, 0, 0) : bg);
  img.fillRect(im, x1: coilX - 24, y1: midY + coilR - 40, x2: coilX + 24, y2: midY + coilR + 6, color: transparentBg ? img.ColorRgba8(0, 0, 0, 0) : bg);
}

void main() {
  final dir = Directory('assets/icon')..createSync(recursive: true);

  // Full icon (opaque dark background).
  final icon = img.Image(width: size, height: size, numChannels: 4);
  drawMark(icon, transparentBg: false);
  File('${dir.path}/app_icon.png').writeAsBytesSync(img.encodePng(icon));

  // Adaptive foreground (transparent background, same mark).
  final fg = img.Image(width: size, height: size, numChannels: 4);
  img.fill(fg, color: img.ColorRgba8(0, 0, 0, 0));
  drawMark(fg, transparentBg: true);
  File('${dir.path}/app_icon_foreground.png').writeAsBytesSync(img.encodePng(fg));

  stdout.writeln('Wrote assets/icon/app_icon.png and app_icon_foreground.png (${size}x$size).');
}
