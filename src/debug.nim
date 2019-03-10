import nico/vec
import nico
import nico/util
import sequtils

type DebugLine = tuple
  a,b: Vec2f
  color: ColorId
  ttl: float

type DebugCircles = tuple
  a: Vec2f
  r: float
  color: ColorId
  ttl: float

var debugLines = newSeq[DebugLine]()
var debugCircles = newSeq[DebugCircles]()

proc debugLine*(a,b: Vec2f, color: ColorId = 3, ttl: float = 1.0/60.0) =
  debugLines.add((a, b, color, ttl))

proc debugCircle*(a: Vec2f, r: float, color: ColorId = 3, ttl: float = 1.0/60.0) =
  debugCircles.add((a, r, color, ttl))

proc debugDraw*() =
  for line in mitems(debugLines):
    line.ttl -= (1.0/60.0)
    setColor(line.color)
    line(line.a, line.b)

  for c in mitems(debugCircles):
    c.ttl -= (1.0/60.0)
    setColor(c.color)
    circ(c.a.x, c.a.y, c.r)

  debugLines = debugLines.filterIt(it.ttl > 0)
  debugCircles = debugCircles.filterIt(it.ttl > 0)
