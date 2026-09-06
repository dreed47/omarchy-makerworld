import QtQuick

// The MakerWorld "stacked cubes" mark: three isometric cubes - two in front,
// one resting on top - drawn as a small inline SVG so it stays crisp at bar
// size. Each cube shows a bright top face and two dimmer side faces (opacity
// steps of `color`), so adjacent cubes read as separate blocks and the whole
// thing tints with the bar foreground on light and dark themes alike.
Image {
  id: root

  property color color: "#e6e6e6"

  fillMode: Image.PreserveAspectFit
  smooth: true
  sourceSize.width: width > 0 ? Math.round(width * 2) : 40
  sourceSize.height: height > 0 ? Math.round(height * 2) : 40
  source: _svg(String(color))

  function _svg(col) {
    var u = 26, ex = u * 0.866, ey = u * 0.5
    var W = 100, H = 100

    // Cube cells as [col, row, height] on an isometric grid; two on the
    // ground (front-right, front-left) and one stacked on top.
    var cells = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

    // Painter's order: lower first, then back-to-front.
    cells.sort(function (p, q) {
      return (p[2] - q[2]) || ((q[0] + q[1]) - (p[0] + p[1])) || (q[0] - p[0])
    })

    var cx = W / 2
    var baseY = 44

    function f(x, y) { return x.toFixed(1) + "," + y.toFixed(1) }
    function face(pts, opacity) {
      var d = pts.map(function (p) { return f(p[0], p[1]) }).join(" ")
      return '<polygon points="' + d + '" fill="' + col + '" fill-opacity="' + opacity
        + '" stroke="' + col + '" stroke-opacity="0.35" stroke-width="1"'
        + ' stroke-linejoin="round"/>'
    }

    var body = ""
    for (var i = 0; i < cells.length; i++) {
      var c = cells[i][0], r = cells[i][1], h = cells[i][2]
      var tx = cx + (c - r) * ex
      var ty = baseY + (c + r) * ey - h * u
      var T = [tx, ty]
      var A = [tx + ex, ty + ey], B = [tx - ex, ty + ey], C = [tx, ty + 2 * ey]
      var Td = [tx, ty + u], Ad = [tx + ex, ty + ey + u], Bd = [tx - ex, ty + ey + u]
      body += face([T, A, C, B], "1")        // top face
      body += face([T, A, Ad, Td], "0.55")   // right face
      body += face([T, B, Bd, Td], "0.28")   // left face
    }

    return "data:image/svg+xml;utf8," + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + W + ' ' + H + '">'
      + body + '</svg>')
  }
}
