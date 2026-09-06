import QtQuick

// The MakerWorld "stacked cubes" mark, painted in one colour so it takes the
// bar's foreground tint. Three isometric cubes: two side by side, one resting
// on top. Faces are alpha-shaded (not a darker colour) so it reads on light
// and dark bars alike.
Canvas {
  id: root

  property color color: "#e0e0e0"

  antialiasing: true
  renderStrategy: Canvas.Cooperative
  renderTarget: Canvas.Image

  onColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  function _poly(ctx, pts) {
    ctx.beginPath()
    ctx.moveTo(pts[0][0], pts[0][1])
    for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1])
    ctx.closePath()
    ctx.fill()
  }

  // One cube from its top vertex (tx,ty), edge length s.
  function _cube(ctx, tx, ty, s) {
    var ex = s * 0.866, ey = s * 0.5, dy = s
    var T = [tx, ty]
    var A = [tx + ex, ty + ey]
    var B = [tx - ex, ty + ey]
    var C = [tx, ty + 2 * ey]
    var Td = [tx, ty + dy]
    var Ad = [tx + ex, ty + ey + dy]
    var Bd = [tx - ex, ty + ey + dy]

    ctx.globalAlpha = 1.0;  _poly(ctx, [T, A, C, B])     // top
    ctx.globalAlpha = 0.70; _poly(ctx, [T, A, Ad, Td])   // right
    ctx.globalAlpha = 0.44; _poly(ctx, [T, B, Bd, Td])   // left
    ctx.globalAlpha = 1.0
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.fillStyle = root.color

    var W = width, H = height
    var pad = Math.max(1, Math.min(W, H) * 0.08)

    // Cluster bounding box is 4*ex wide (= 3.464 s) and 2 s tall. Fit both.
    var s = Math.min((W - 2 * pad) / 3.464, (H - 2 * pad) / 2.0)
    var ex = s * 0.866, ey = s * 0.5, dy = s

    var cx = W / 2
    var topY = (H - 2 * s) / 2

    // front-left, front-right, then the top cube last so it overlaps cleanly
    _cube(ctx, cx - ex, topY + dy - ey, s)
    _cube(ctx, cx + ex, topY + dy - ey, s)
    _cube(ctx, cx, topY, s)
  }
}
