import QtQuick

// The MakerWorld "stacked cubes" mark, painted in a single colour so it takes
// the bar's foreground tint. Three isometric cubes in a cluster: two in front,
// one resting on top. Face shading is done with alpha (not a darker colour) so
// it reads correctly on both light and dark bars.
Canvas {
  id: root

  property color color: "#e0e0e0"
  // Fraction of the shorter side one cube edge spans.
  property real cubeScale: 0.30

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

  // One cube from its top-front vertex (tx,ty), edge length s.
  function _cube(ctx, tx, ty, s) {
    var ex = s * 0.866, ey = s * 0.5, dy = s
    var T = [tx, ty]
    var A = [tx + ex, ty + ey]
    var B = [tx - ex, ty + ey]
    var C = [tx, ty + 2 * ey]
    var Td = [tx, ty + dy]
    var Ad = [A[0], A[1] + dy]
    var Bd = [B[0], B[1] + dy]

    ctx.globalAlpha = 1.0;  _poly(ctx, [T, A, C, B])     // top face
    ctx.globalAlpha = 0.68; _poly(ctx, [T, A, Ad, Td])   // right face
    ctx.globalAlpha = 0.42; _poly(ctx, [T, B, Bd, Td])   // left face
    ctx.globalAlpha = 1.0
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.fillStyle = root.color

    var side = Math.min(width, height)
    var s = side * root.cubeScale
    var ex = s * 0.866, ey = s * 0.5, dy = s

    // Cluster bounds are about (4*ex) wide and (dy + 3*ey) tall; centre it.
    var cx = width / 2
    var top = (height - (dy + 3 * ey)) / 2

    // top cube, then the two front cubes it sits between
    _cube(ctx, cx, top, s)
    _cube(ctx, cx - ex, top + dy - ey, s)
    _cube(ctx, cx + ex, top + dy - ey, s)
  }
}
