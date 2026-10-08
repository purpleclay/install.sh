# Generates the ring grid used by ring() in install.sh:
#
#   awk -f scripts/ring.awk
#
# Ray traces a flat band, like a real ring, tilted towards the viewer and lit
# from the top left. Prints one character per pixel: a shade from 1 (lit) to
# 6 (dark), or a dot where there is nothing. Each pair of rows becomes one
# line of half blocks in the terminal, so pixels come out roughly square.
#
# Settings can be overridden with -v, e.g. awk -v TILT=0.52 -f scripts/ring.awk

# sdf X Y Z: signed distance from a point to the band. The band's cross
# section is a rounded rectangle, THICK wide and HEIGHT tall (both halves).
function sdf(x, y, z, lx, ly, lz, qx, qy, ax, ay) {
  lx = x
  ly = y * c + z * s
  lz = -y * s + z * c
  qx = sqrt(lx * lx + lz * lz) - RADIUS
  qy = ly
  ax = (qx < 0 ? -qx : qx) - THICK
  ay = (qy < 0 ? -qy : qy) - HEIGHT
  return sqrt((ax > 0 ? ax : 0)^2 + (ay > 0 ? ay : 0)^2) + (ax > ay ? (ax < 0 ? ax : 0) : (ay < 0 ? ay : 0)) - ROUND
}

function unit(v, l) {
  l = sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
  v[1] /= l
  v[2] /= l
  v[3] /= l
}

BEGIN {
  if (WIDTH == "") WIDTH = 24
  if (ROWS == "") ROWS = 14
  if (TILT == "") TILT = 0.70 # radians, about 40 degrees
  RADIUS = 1.0
  if (THICK == "") THICK = 0.08
  if (HEIGHT == "") HEIGHT = 0.22
  if (ROUND == "") ROUND = 0.04

  c = cos(TILT)
  s = sin(TILT)
  scale = 2.9 / WIDTH
  e = 0.001

  # Light from the top left, and the half vector for the highlight.
  L[1] = -0.6; L[2] = 0.75; L[3] = -0.55; unit(L)
  H[1] = L[1]; H[2] = L[2]; H[3] = L[3] - 1; unit(H)

  for (j = 0; j < ROWS; j++) {
    row = ""
    for (i = 0; i < WIDTH; i++) {
      x = (i - WIDTH / 2 + 0.5) * scale
      y = -(j - ROWS / 2 + 0.5) * scale
      z = -3
      hit = 0
      for (k = 0; k < 128; k++) {
        d = sdf(x, y, z)
        if (d < e) { hit = 1; break }
        z += d
        if (z > 3) break
      }
      if (!hit) { row = row "."; continue }

      n[1] = sdf(x + e, y, z) - sdf(x - e, y, z)
      n[2] = sdf(x, y + e, z) - sdf(x, y - e, z)
      n[3] = sdf(x, y, z + e) - sdf(x, y, z - e)
      unit(n)
      dif = n[1] * L[1] + n[2] * L[2] + n[3] * L[3]
      if (dif < 0) dif = 0
      spec = n[1] * H[1] + n[2] * H[2] + n[3] * H[3]
      if (spec < 0) spec = 0

      light = 0.22 + 0.70 * dif + 0.45 * spec^24
      shade = 7 - int(light * 7)
      if (shade < 1) shade = 1
      if (shade > 6) shade = 6
      row = row shade
    }
    print row
  }
}
