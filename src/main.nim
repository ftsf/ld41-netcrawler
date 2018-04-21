import nico
import nico.vec
import nico.ui
import nico.console
import nico.util
import tweaks
import sets
import hashes
import queues
import deques
import sequtils
import debug

import types


{.this:self.}

# CONSTANTS

const cardWidth = 5 * 8
const cardHeight = 5 * 8

# TYPES

# GLOBALS

var nextId = 0

var boids: seq[Boid]
var initialDeck: Pile
var drawPile: Pile
var discardPile: Pile
var hand: seq[Card]
var supply: seq[Card]
var money: int
var incomeRate: int
var downtime: float32
var nextTick: float32
var tickSpeed: float32
var selected: Card
var goals: seq[Vec2f]

var tilemap: Tilemap

var field: array[4*5, Pile]

var serverNames = [
  "COLOSSUS",
  "MULTIVAC",
  "GUARDIAN",
  "PROTEUS"
]



# PROCS

proc isSolid(t: uint8): bool =
  if t in [1.uint8,17,33,34,35,36,66,67,68,82,98]:
    return false
  return true

proc isSolid(x,y: int): bool =
  if x < 0 or x > 4*5 or y < 0 or y > 5*5:
    return true
  return isSolid(mget(x,y))


proc cost(grid: Tilemap, a, b: Tile): int =
  if a.x == b.x or a.y == b.y:
    return 3
  else:
    return 4

proc heuristic(grid: Tilemap, next, goal: Tile): int =
  let dx = next.x - goal.x
  let dy = next.y - goal.y
  return dx*dx + dy*dy

iterator neighbors(grid: Tilemap, node: Tile): Tile =
  let tx = node.x
  let ty = node.y

  if not isSolid(tx-1,ty):
    yield (tx-1,ty,mget(tx-1,ty))
  if not isSolid(tx+1,ty):
    yield (tx+1,ty,mget(tx+1,ty))
  if not isSolid(tx,ty-1):
    yield (tx,ty-1,mget(tx,ty-1))
  if not isSolid(tx,ty+1):
    yield (tx,ty+1,mget(tx,ty+1))

include astar

proc newBoid(pos: Vec2f): Boid =
  result = new(Boid)
  result.id = nextId
  result.hitbox.x = -2
  result.hitbox.y = -2
  result.hitbox.w = 4
  result.hitbox.h = 4
  nextId += 1
  result.toKill = false
  result.pos = pos
  result.ipos = pos.vec2i
  result.health = 10
  result.mass = 1.0
  result.cohesion = 0.1
  result.cohesionRadius = 10.0
  result.separation = 5.5
  result.separationRadius = 4.0
  result.maxForce = 30.0
  result.maxSpeed = 10.0
  result.alignment = 0.5
  result.shootTimeout = 5.0
  result.repathTimeout = 5.0
  result.route = nil
  result.routeIndex = 0

proc getTile(pos: Vec2i): Tile =
  let tx = pos.x div 8
  let ty = pos.y div 8
  return (x: tx, y: ty, t: mget(tx,ty))


proc hash(self: Boid): Hash =
  var h: Hash = 0
  h = h !& self.id
  result = !$h

proc seek(self: Boid, target: Vec2f, weight = 1.0) =
  if (target - pos).sqrMagnitude > 0.01:
    steering += (target - pos).normalized * maxSpeed * weight

proc arrive(self: Boid, target: Vec2f, stoppingDistance = 1.0, weight = 1.0) =
  steering += (target - pos).normalized * maxSpeed * weight

proc isTouchingType(x,y,w,h: int, check: proc(t: uint8): bool): bool =
  for i in x div 8..(x+w-1) div 8:
    for j in y div 8..(y+h-1) div 8:
      let t = mget(i,j)
      if check(t):
        return true
  return false

proc isSolid(self: Boid, ox,oy: int): bool =
  if isTouchingType(ipos.x.int+hitbox.x+ox, ipos.y.int+hitbox.y+oy, hitbox.w, hitbox.h, isSolid):
    return true
  return false

proc moveX(self: Boid, amount: float32) =
  let step = amount.int.sgn
  for i in 0..<abs(amount.int):
    if not self.isSolid(step, 0):
      ipos.x += step
    else:
      # hit something
      echo "hit x wall"
      vel.x = 0
      rem.x = 0
      break

proc moveY(self: Boid, amount: float32) =
  let step = amount.int.sgn
  for i in 0..<abs(amount.int):
    if not self.isSolid(0, step):
      ipos.y += step
    else:
      # hit something
      echo "hit y wall"
      vel.y = 0
      rem.y = 0
      break

proc update(self: Boid, dt: float32) =
  repathTimeout -= dt
  steering = vec2f()
  if repathTimeout <= 0.0 or (route == nil and repathTimeout <= 0.0):
    for goal in goals:
      let start = getTile(ipos)
      let goal = getTile(goal.vec2i)
      route = @[]
      for point in path(tilemap, start, goal):
        route.add(vec2f(point.x*8+4, point.y*8+4))
      routeIndex = 1
      if route.len > 0:
        repathTimeout = 5.0 + rnd(0.5)
        break
      else:
        repathTimeout = 1.0 + rnd(0.5)

  elif route != nil:

    #let ox = screenWidth div 2 - ((4 * cardWidth) div 2)
    #let oy = 10
    #let offset = vec2f(ox,oy)
    #for i in 1..<route.len:
    #  debugLine(offset+route[i-1], offset+route[i], if i == routeIndex: 13 else: 3)

    if routeIndex < route.len:
      var t = route[routeIndex]
      if pos.nearer(t, 8.0):
        routeIndex += 1
        if routeIndex == route.len:
          route = nil
          routeIndex = 0
      else:
        seek(t, 1.0)

  var avgpos = pos
  var avgvel = vel
  var nflockmates = 1

  for j in boids:
    if j != self:
      if nearer(pos,j.pos, cohesionRadius):
        avgpos += j.pos
        avgvel += j.vel
        nflockmates += 1
      if nearer(pos,j.pos, separationRadius):
        seek(j.pos, -separation)

  steering = clamp(steering, maxForce)
  vel += steering * (1.0 / mass) * dt
  vel = clamp(vel, maxSpeed)

  rem.y += vel.y * dt
  let yAmount = flr(rem.y + 0.5)
  rem.y -= yAmount
  moveY(yAmount)

  rem.x += vel.x * dt
  let xAmount = flr(rem.x + 0.5)
  rem.x -= xAmount
  moveX(xAmount)

  pos = ipos.vec2f


method drawFace(self: Card, x,y: int) {.base.} =
  discard

method drawFace(self: TileCard, x,y: int) =
  setColor(22)
  rectfill(x,y,x+cardWidth-1,y+cardHeight-1)
  setColor(28)
  rect(x,y,x+cardWidth-1,y+cardHeight-1)

  for i,t in data.pairs():
    let tx = i mod 5
    let ty = i div 5
    spr(t, x + tx * 8, y + ty * 8)

  if not bought:
    setColor(10)
    printr($cost, x+cardWidth-2, y+cardHeight-8)

method drawFace(self: ActionCard, x,y: int) =
  setColor(22)
  rectfill(x,y,x+cardWidth-1,y+cardHeight-1)
  setColor(11)
  rect(x,y,x+cardWidth-1,y+cardHeight-1)
  rectfill(x,y,x+cardWidth-1,y+8)
  setColor(26)
  printc("ACTION", x+cardWidth div 2, y+2)

  setColor(10)
  printr($cost, x+cardWidth-2, y+cardHeight-8)

method drawFace(self: UpgradeCard, x,y: int) =
  setColor(22)
  rectfill(x,y,x+cardWidth-1,y+cardHeight-1)
  setColor(17)
  rect(x,y,x+cardWidth-1,y+cardHeight-1)
  rectfill(x,y,x+cardWidth-1,y+8)
  setColor(26)
  printc("UPGRADE", x+cardWidth div 2, y+2)

  setColor(10)
  printr($cost, x+cardWidth-2, y+cardHeight-8)

proc draw(self: Card, x,y: int) =
  if down:
    setColor(27)
    rectfill(x,y,x+cardWidth-1,y+cardHeight-1)
    setColor(28)
    rect(x,y,x+cardWidth-1,y+cardHeight-1)
  else:
    setColor(22)
    rectfill(x,y,x+cardWidth-1,y+cardHeight-1)
    setColor(27)
    rect(x,y,x+cardWidth-1,y+cardHeight-1)
    # draw contents
    self.drawFace(x,y)
  if selected:
    setColor(19)
    rect(x-1,y-1,x+cardWidth,y+cardHeight)

proc newPile(label: string = nil): Pile =
  result = new(Pile)
  result.label = label
  result.cards = initDeque[Card]()

proc shuffle(self: Pile) =
  var stacks: array[3,Deque[Card]]
  var nStacks = 3
  for i in 0..<nStacks:
    stacks[i] = initDeque[Card]()

  var stack = 0
  while cards.len > 0:
    let c = cards.popLast()
    c.down = true
    stacks[stack].addLast(c)
    stack += rnd(2)
    stack = stack mod nStacks

  for i in 0..<nStacks:
    while stacks[i].len > 0:
      cards.addLast(stacks[i].popLast())

proc play(self: Pile, c: Card) =
  cards.addLast(c)

proc draw(self: Pile): Card =
  if cards.len > 0:
    return cards.popLast()
  else:
    return nil

proc draw(self: Pile, x,y: int, base: bool = true) =
  setColor(16)
  if base:
    rect(x-1,y-1,x+cardWidth,y+cardHeight)
  else:
    rect(x,y,x+cardWidth-1,y+cardHeight-1)

  if label != nil:
    printc(label, x + cardWidth div 2, y + cardHeight + 2)

  let tight = cards.len > 10
  var yi = y
  for c in cards:
    c.draw(x,yi)
    yi -= (if tight: 1 else: 2)

proc newRandomCard(): Card =
  let t = rnd(20)
  if t == 0:
    result = new(ActionCard)
  elif t == 1:
    result = new(UpgradeCard)
  else:
    result = new(TileCard)

  result.cost = rnd(5)
  result.down = true

proc drawCard() =
  if drawPile.cards.len == 0:
    discardPile.shuffle()
    discardPile.shuffle()
    discardPile.shuffle()
    drawPile.cards = discardPile.cards
    discardPile.cards = initDeque[Card]()

  if drawPile.cards.len > 0:
    let c = drawPile.cards.popLast()
    hand.add(c)
    c.selected = false
    c.down = false
    selected = nil

proc gameInit() =
  tickSpeed = 5.0
  money = 0
  incomeRate = 1

  goals = @[]
  for i in 0..3:
    goals.add(vec2f(cardWidth*i + cardWidth div 2, cardHeight*4 + cardHeight div 2))

  initialDeck = newPile()
  # load all cards from map
  let mw = mapWidth()
  let mh = mapHeight()
  let nCards = (mw div 5) * (mh div 5)
  for i in 0..<nCards:
    let cy = i div (mw div 5)
    let cx = i mod (mw div 5)
    var c = new(TileCard)
    c.down = true
    c.cost = cy
    for y in 0..4:
      for x in 0..4:
        let j = y * 5 + x
        c.data[j] = mget(cx * 5 + x, cy * 5 + y)
    initialDeck.cards.addLast(c)
  initialDeck.shuffle()
  initialDeck.shuffle()
  initialDeck.shuffle()

  newMap(4*5,5*5)
  for x in 0..<4*5:
    if x mod 5 == 0 or x mod 5 == 4:
      continue
    for y in 4*5..5*5+4:
      mset(x, y, 1)

  drawPile = newPile("DEQUE")
  for i in 0..<16:
    var c = initialDeck.draw()
    c.bought = true
    drawPile.play(c)

  discardPile = newPile("HEAP")

  for i in 0..<4*5:
    if i > 15:
      field[i] = newPile(serverNames[i mod 4])
    else:
      field[i] = newPile()

  hand = newSeq[Card]()
  supply = newSeq[Card]()
  selected = nil

  for i in 0..4:
    var c = initialDeck.draw()
    c.down = false
    supply.add(c)

  for i in 0..4:
    var c = drawPile.draw()
    c.down = false
    hand.add(c)

  # boids stuff

  boids = newSeq[Boid]()

proc gameUpdate(dt: float32) =
  nextTick -= dt
  if nextTick < 0:
    nextTick = tickSpeed
    money += incomeRate

  if boids.len < 50:
    let col = rnd(3)
    let x = col * cardWidth + 20
    boids.add(newBoid(vec2f(x+rnd(0.1), 8+rnd(0.1))))

  when false:
    downtime += dt


  # move boids
  for b in boids:
    b.update(dt)

  let (mx,my) = mouse()
  if mousebtnp(0):
    # check which area the mouse is in
    block:
      # supply
      let x = screenWidth - cardWidth - 5
      let y = 5
      let w = cardWidth
      let h = cardHeight * 5
      if mx >= x and mx <= x + w and my >= y and my <= y + h:
        let index = (my - y) div (cardHeight + 1)
        if index < 0 or index > supply.high:
          return
        let c = supply[index]
        if c == nil:
          return
        if not c.selected:
          if selected != nil:
            selected.selected = false
          c.selected = true
          selected = c
        else:
          if selected != nil:
            if money >= selected.cost:
              supply[index] = initialDeck.draw()
              supply[index].down = false
              c.selected = false
              selected.bought = true
              money -= selected.cost
              selected = nil
              discardPile.cards.addLast(c)
            else:
              c.selected = false
              selected = nil
    block:
      # hand
      if hand.len > 0:
        let x = screenWidth div 2 - ((hand.len * cardWidth) div 2)
        let y = screenHeight - cardHeight - 2
        let w = (cardWidth + 1) * hand.len
        let h = cardHeight
        if mx >= x and mx <= x + w and my >= y and my <= y + h:
          let index = (mx - x) div (cardWidth + 1)
          if index < 0 or index > hand.high:
            return
          let c = hand[index]
          if not c.selected:
            if selected != nil:
              selected.selected = false
            c.selected = true
            selected = c
          else:
            hand.del(index)
            c.selected = false
            selected = nil
            discardPile.cards.addLast(c)
    block:
      # draw
      let x = 5
      let y = screenHeight - 9 * 8
      let w = cardWidth
      let h = cardHeight + drawPile.cards.len * 2
      if mx >= x and mx <= x + w and my >= y and my <= y + h:
        if hand.len == 0:
          drawCard()
          drawCard()
          drawCard()
          drawCard()
          drawCard()

    block:
      # field
      var x = screenWidth div 2 - ((4 * cardWidth) div 2)
      let y = 10
      let w = cardWidth * 4
      let h = cardHeight * 4
      if mx >= x and mx <= x + w and my >= y and my <= y + h:
        let col = (mx - x) div cardWidth
        let row = (my - y) div cardHeight
        let index = row * 4 + col
        if selected != nil and selected of TileCard:
          # card selected, place it on field at location
          let i = hand.find(selected)
          if i > -1:
            hand.del(i)
            var oldCard = field[index].draw()
            if oldCard != nil:
              discardPile.play(oldCard)
            field[index].cards.addLast(selected)
            # update the map
            let tc = TileCard(selected)
            for i,t in tc.data:
              let tx = i mod 5
              let ty = i div 5
              mset(col * 5 + tx, row * 5 + ty, t)
            selected.selected = false
            selected = nil

proc gameDraw() =
  clip()
  setCamera()
  setColor(26)
  rectfill(0,0,screenWidth,screenHeight)

  drawPile.draw(5, screenHeight - 9 * 8)
  discardPile.draw(50, screenHeight - 9 * 8)

  block:
    # field
    let x = screenWidth div 2 - ((4 * cardWidth) div 2)
    let y = 10
    setCamera(-x,-y)
    for i in 0..<4*4:
      let row = i div 4
      let col = i mod 4
      setColor(16)
      rect(col*cardWidth, row * cardHeight, col*cardWidth+cardWidth-1, row*cardHeight+cardHeight-1)
    mapDraw(0,0,4*5,5*5,0,0)

    for b in boids:
      setColor(25)
      rect(b.pos.x - 2, b.pos.y - 2, b.pos.x + 1, b.pos.y + 1)

    for g in goals:
      setColor(12)
      circ(g.x, g.y, 2)

  setCamera()

  # supply
  block:
    var xi = screenWidth - cardWidth - 5
    var yi = 5
    for c in supply:
      c.draw(xi, yi)
      yi += cardHeight + 1


  # hand
  if hand.len > 0:
    var xi = screenWidth div 2 - ((hand.len * cardWidth) div 2)
    for c in hand:
      c.draw(xi, screenHeight - cardHeight - 2)
      xi += cardWidth + 1

  setColor(10)
  print("$" & $money, 5, 5)

  debugDraw()

  # mouse
  let (mx,my) = mouse()


nico.init("impbox", "ld41")

tileSize(8,8)

loadPaletteFromGPL("palette.gpl")
palt(26,false)
palt(0,true)
loadSpritesheet("spritesheet.png")
loadMap("cards.json")

fixedSize(true)
integerScale(true)
nico.createWindow("ld41", 1920 div 4 , 1080 div 4, 4)
nico.run(gameInit, gameUpdate, gameDraw)
