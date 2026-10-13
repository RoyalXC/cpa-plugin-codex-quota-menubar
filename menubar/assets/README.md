# 应用图标

- `QuotaMenubar.png`：内置 Image Generation 工具生成并经用户确认的石墨银灰方形原图，使用双层额度环，不含文字或百分号。
- `QuotaMenubar.icns`：使用 macOS `sips` 与 `iconutil` 封装的多尺寸应用图标，覆盖 16/32/128/256/512pt 及其 @2x。
- 仅用于 Finder、应用程序及系统应用图标；不会替换菜单栏动态百分比胶囊。

## 生成提示词

Refine the supplied graphite macOS quota-monitor app icon DESIGN PREVIEW. The user specifically dislikes the oversized '%' in the center: it is visually intrusive. REMOVE the percent glyph COMPLETELY. Replace the typography-led composition with a carefully crafted abstract TWO-RING QUOTA EMBLEM, no words, no numbers, no letters, no percentage signs, no dots, no arrows. Preserve the tasteful graphite/silver palette, full edge-to-edge opaque square background, subtle tone-on-tone curved background sheet and front-on layout of the supplied reference. One square standalone icon, not a mockup or contact sheet. Keep the outer progress ring approximately as it is, centered, perfectly circular, outer diameter around 76 percent of canvas, pearl silver long arc and a muted blue-grey translucent short remainder at upper right. Refine its highlights to be quieter, satin not inflated plastic. INSIDE it, replace the old percent symbol with ONE second perfectly concentric progress ring, outside diameter about 49 percent of canvas, stroke width about 6.5 percent of canvas, consistent clean circular geometry and beautifully rounded caps. This inner ring has a long softly silver-lit arc covering about two thirds of the circle, and a darker subtle translucent remainder at LOWER LEFT, so its transition is offset from the outer ring and gives a calm visual rhythm. The inner ring should be slightly lower contrast than the outer ring, cool silver-grey rather than brilliant white, so there is a clear visual hierarchy. Both rings have very narrow, deliberate separations between bright and dim arcs, not huge gaps. Balance the spacing between the concentric rings optically. The result should feel like a single coherent abstract quota/usage-meter mark, not a dashboard widget or a bullseye with many lines. No third ring, no ticks, no chart bars, no central symbol. A small quiet dark negative-space center is intentional; the two rings should still occupy the icon strongly, not shrink to a little mark. Materials: restrained macOS-native layered depth, soft fine edge illumination and tiny contact shadows, extremely smooth clean surfaces. Avoid neon, glow, chrome, heavy drop shadows, bevels and texture. Color field fills all four edges of the square; no outer whitespace and no transparency. Keep the visual elegance and legibility of a native utility app icon. DESIGN PREVIEW ONLY.

## 重新封装

从仓库根目录执行，仅做尺寸转换与 ICNS 封装，不改变原图设计。

```sh
assets="menubar/assets"
staging="$(mktemp -d)"
iconset="$staging/QuotaMenubar.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$assets/QuotaMenubar.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$assets/QuotaMenubar.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$assets/QuotaMenubar.icns"
```

使用 `scripts/build_release.py` 构建和签名完整应用后嵌入插件；不要单独修改已签名应用内的资源。修改图标后须重新构建发布包。
