import nico
import nico.vec
import nico.ui
import nico.console
import nico.util
import utils
import tweaks
import sets
import hashes
import queues
import deques
import sequtils
import strutils
import debug

import types


{.this:self.}

# CONSTANTS

const cardWidth = 5 * 8
const cardHeight = 5 * 8
const maxBoids = 100

# TYPES

# GLOBALS

var nextId = 0

var online: int

var shake: float32
var shakeLevel: int
var boids: seq[Boid]
var initialDeck: Pile
var drawPile: Pile
var discardPile: Pile
var trashPile: Pile
var supplyDiscard: Pile
var hand: seq[Card]
var supply: array[5,Card]
var money: int
var incomeRate: int
var downtime: float32
var selected: Card
var servers: seq[Server]
var entrances: seq[Entrance]
var turrets: seq[Turret]
var bullets: seq[Bullet]
var waveTimer: float32
var wave: int
var cardMoves: seq[CardMove]
var frame: uint16 = 0
var logMessage: string
var logMessageTimeout: float32
var flushed: bool
var maintenanceTime: float32
var score: int
var topScore: int
var bestWaves: int
var gameover: bool

var tilemap: Tilemap

var field: array[4*5, Pile]

var serverNames = [
  "COLOSSUS",
  "MULTIVAC",
  "GUARDIAN",
  "PROTEUS"
]



# PROCS

proc setLogMessage(text: string) =
  logMessage = text
  logMessageTimeout = 5.0

proc shuffle(self: Pile)
proc newPile(label: string = nil): Pile

proc tilePos(col,row: int): Vec2i =
  return vec2i(8 + col * cardWidth, 8 + row * cardHeight)

proc tileBlocked(col,row: int): bool =
  var blocked = false
  var tp = tilePos(col,row)
  for b in boids:
    if b.evil:
      if b.pos.x >= tp.x and b.pos.x < tp.x + cardWidth and b.pos.y >= tp.y and b.pos.y < tp.y + cardHeight:
        blocked = true
        break
  return blocked

proc handPos(): Vec2i =
  return vec2i(screenWidth div 2 - ((hand.len * cardWidth) div 2), screenHeight - cardHeight - 12)

proc supplyPos(index: int = 0): Vec2i =
  return vec2i(screenWidth - cardWidth - 5, 12 + cardHeight * index)


proc selectCard(c: Card) =
  if c != nil:
    c.selected = true
  if selected != nil:
    selected.selected = false
  selected = c

proc moveCard(c: Card, source: Vec2f, dest: Vec2f, onComplete: proc(cm: CardMove)) =
  if c == nil:
    raise newException(Exception, "moveCard with no card")
  var cm = new(CardMove)
  cm.c = c
  cm.source = source
  cm.dest = dest
  cm.onComplete = onComplete
  cm.time = 0.2
  cm.alpha = 0.0

  cardMoves.add(cm)

proc isSolid(t: uint8): bool =
  if t in [1.uint8,6,7,8,9,17,33,34,35,36,37,66,67,68,82,98]:
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
  result.ttl = 60.0
  result.id = nextId
  result.evil = true
  result.hitbox.x = -2
  result.hitbox.y = -2
  result.hitbox.w = 4
  result.hitbox.h = 4
  nextId += 1
  result.pos = pos
  result.ipos = pos.vec2i
  result.health = 2
  result.mass = 1.0
  result.cohesion = 0.1
  result.cohesionRadius = 8.0
  result.separation = 2.0
  result.separationRadius = 4.0
  result.maxForce = 50.0
  result.maxSpeed = 10.0
  result.alignment = 0.5
  result.shootTimeout = 5.0
  result.repathTimeout = 0.0
  result.route = nil
  result.routeIndex = 0

proc newGoodBoid(pos: Vec2f): Boid =
  result = new(Boid)
  result.ttl = 60.0
  result.evil = false
  result.id = nextId
  result.hitbox.x = -2
  result.hitbox.y = -2
  result.hitbox.w = 4
  result.hitbox.h = 4
  nextId += 1
  result.pos = pos
  result.ipos = pos.vec2i
  result.health = 2
  result.mass = 1.0
  result.cohesion = 0.5
  result.cohesionRadius = 8.0
  result.separation = 5.0
  result.separationRadius = 4.0
  result.maxForce = 50.0
  result.maxSpeed = 15.0
  result.alignment = 0.5
  result.shootTimeout = 5.0
  result.repathTimeout = 0.0
  result.route = nil
  result.routeIndex = 0

proc addNewBoid(pos: Vec2f, goal: Server) =
  if boids.len < maxBoids:
    var b = newBoid(pos)
    b.goal = goal
    boids.add(b)

proc addNewGoodBoid(pos: Vec2f, goal: Server) =
  if boids.len < maxBoids:
    var b = newGoodBoid(pos)
    b.goal = goal
    boids.add(b)

proc newTurret(pos: Vec2i, damage: int, radius: float32, rechargeTime: float32): Turret =
  result = new(Turret)
  result.pos = pos
  result.rechargeTime = rechargeTime
  result.rechargeTimer = result.rechargeTime
  result.damage = damage
  result.radius = radius
  result.health = 3

proc newBullet(pos: Vec2i, vel: Vec2f, damage: int): Bullet =
  result = new(Bullet)
  result.pos = pos.vec2f
  result.ipos = pos
  result.vel = vel
  result.hitbox.x = -1
  result.hitbox.y = -1
  result.hitbox.w = 2
  result.hitbox.h = 2
  result.ttl = 1.0
  result.damage = damage

proc drawCard(count: int = 1)
proc draw(self: Pile): Card

proc discardHand() =
  if hand.len > 0:
    let c = hand[hand.high]
    moveCard(c, c.pos, discardPile.pos) do(cm: CardMove):
      discardPile.cards.addLast(cm.c)
      discardHand()
    hand = hand[0..hand.high-1]
  else:
    # draw new hand
    drawCard(5)

proc flushSupply() =
  for c in supply:
    if c != nil:
      moveCard(c, c.pos, supplyDiscard.pos) do(cm: CardMove):
        supplyDiscard.cards.addLast(cm.c)
  supply = [nil.Card,nil,nil,nil,nil]

  if initialDeck.cards.len == 0:
    # shuffle the discard and fill initialDeck with it
    supplyDiscard.shuffle()
    supplyDiscard.shuffle()
    supplyDiscard.shuffle()
    initialDeck = supplyDiscard
    supplyDiscard = newPile()

  for i in 0..4:
    (proc() =
      let p = i
      let c = initialDeck.draw()
      if c != nil:
        moveCard(c, c.pos, supplyPos(p).vec2f) do(cm: CardMove):
          supply[p] = cm.c
          cm.c.down = false
    )()

proc nextWave() =
  flushed = false
  wave += 1
  var bandwidth = 0
  for e in entrances:
    if e.connected:
      for i in 0..<5+rnd(wave):
        addNewBoid(vec2f(e.pos.x+4+rnd(0.1), e.pos.y+10+rnd(0.1)), rnd(e.servers))

  for e in entrances:
    if e.connected and e.pos.y < 10:
      for i in 0..<online*2:
        addNewGoodBoid(vec2f(e.pos.x+4+rnd(0.1), e.pos.y+10+rnd(0.1)), rnd(e.servers))
      bandwidth += 1
  waveTimer = 30.0

  for t in turrets:
    t.health -= 1

  turrets.keepItIf(it.health > 0)

  for s in servers:
    if not s.infected:
      if s.health < 10:
        s.health += 1

  discardHand()

  money = min(money, online)

  if wave > 1:
    score += online * bandwidth

  selectCard(nil)

proc getTile(pos: Vec2i): Tile =
  let tx = pos.x div 8
  let ty = pos.y div 8
  return (x: tx, y: ty, t: mget(tx,ty))

proc draw(self: Pile): Card =
  if cards.len > 0:
    return cards.popLast()
  else:
    return nil



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

proc isSolid(self: Movable, ox,oy: int): bool =
  if isTouchingType(ipos.x.int+hitbox.x+ox, ipos.y.int+hitbox.y+oy, hitbox.w, hitbox.h, isSolid):
    return true
  return false

proc moveX(self: Movable, amount: float32) =
  let step = amount.int.sgn
  for i in 0..<abs(amount.int):
    if not self.isSolid(step, 0):
      ipos.x += step
    else:
      # hit something
      vel.x = 0
      rem.x = 0
      break

proc moveY(self: Movable, amount: float32) =
  let step = amount.int.sgn
  for i in 0..<abs(amount.int):
    if not self.isSolid(0, step):
      ipos.y += step
    else:
      # hit something
      vel.y = 0
      rem.y = 0
      break

proc update(self: Boid, dt: float32) =
  repathTimeout -= dt
  steering = vec2f()

  ttl -= dt
  if ttl < 0:
    health = 0

  if ipos.y < 0:
    ipos.y = 0

  let t = mget(ipos.x div 8, ipos.y div 8)
  if not evil and t != 0 and isSolid(t):
    health = 0
    return
  elif evil and isSolid(t):
    health = 0
    return

  if goal == nil:
    goal = rnd(servers)
    if goal.infected:
      goal = nil

  if repathTimeout <= 0.0 or (route == nil and repathTimeout <= 0.0):
    if goal != nil:
      if goal.health <= 0 or goal.infected:
        goal = nil
        return
      let start = getTile(ipos)
      let sp = getTile(goal.pos)
      route = @[]
      for point in path(tilemap, start, sp):
        route.add(vec2f(point.x*8+4, point.y*8+4))
      routeIndex = 1
      if route.len == 0:
        goal = nil
    repathTimeout = 5.0 + rnd(0.5)

  elif route != nil:

    let ox = screenWidth div 2 - ((4 * cardWidth) div 2) + 8
    let oy = 10 + 8
    let offset = vec2f(ox,oy)
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
    if j != self and j.evil == evil:
      if nearer(pos,j.pos, cohesionRadius):
        avgpos += j.pos
        avgvel += j.vel
        nflockmates += 1
      if nearer(pos,j.pos, separationRadius):
        seek(j.pos, -separation)

  for s in servers:
    if not s.infected:
      if pos.nearer(s.pos.vec2f, 8.0):
        health = 0
        if evil:
          s.health -= 1
          shake += 0.5
          shakeLevel = 2
        else:
          money += 1

  steering = clamp(steering, maxForce)
  vel += steering * (1.0 / mass) * dt
  vel = clamp(vel, maxSpeed)

  rem += vel * dt

  let yAmount = flr(rem.y + 0.5)
  rem.y -= yAmount
  moveY(yAmount)

  let xAmount = flr(rem.x + 0.5)
  rem.x -= xAmount
  moveX(xAmount)

  distTravelled += (vel * dt).length
  if distTravelled > 2.0:
    frame += 1
    if frame > 2:
      frame = 0
    distTravelled -= 2.0

  pos = ipos.vec2f

proc update(self: Turret, dt: float32) =
  if rechargeTimer > 0:
    rechargeTimer -= dt

  if target == nil:
    # pick a target
    for b in boids:
      if b.evil:
        if b.pos.nearer(pos.vec2f, radius):
          target = b
          break

  if target != nil:
    if target.health <= 0:
      target = nil
    elif target.pos.further(pos.vec2f, radius + 0.1):
      target = nil
    else:
      if rechargeTimer <= 0:
        # shoot
        bullets.add(newBullet(pos, (target.pos - pos.vec2f).normalized * 50.0, damage))
        rechargeTimer = rechargeTime

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

method drawFace(self: ActionCard, x,y: int) =
  setColor(22)
  rectfill(x,y,x+cardWidth-1,y+cardHeight-1)
  setColor(11)
  rect(x,y,x+cardWidth-1,y+cardHeight-1)
  rectfill(x,y,x+cardWidth-1,y+8)
  setColor(26)

  printc(title, x+cardWidth div 2, y+2)
  var text = wordWrap(desc, 9, true)
  var y = y + 11
  for line in text.splitLines():
    print(line, x + 2, y)
    y += 7



proc draw(self: Card, x,y: int) =
  pos = vec2f(x,y)
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

    setColor(if bought or cost <= money: 10 else: 24)
    printr($cost, x+cardWidth-2, y+cardHeight-8)

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

proc draw(self: Pile, x,y: int, base: bool = true) =
  pos = vec2f(x,y)
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

proc drawCard(count: int = 1) =
  if drawPile.cards.len == 0:
    discardPile.shuffle()
    discardPile.shuffle()
    discardPile.shuffle()
    drawPile.cards = discardPile.cards
    discardPile.cards = initDeque[Card]()

  if drawPile.cards.len > 0:
    let c = drawPile.cards.popLast()
    moveCard(c, c.pos, handPos().vec2f) do(cm: CardMove):
      hand.add(cm.c)
      cm.c.down = false
      if count > 1:
        drawCard(count - 1)

proc gameInit() =
  loadMap("cards.json")

  gameover = false

  money = 0

  flushed = false

  downtime = 0

  wave = 0
  waveTimer = 0.0

  cardMoves = @[]
  turrets = @[]
  bullets = @[]
  entrances = @[]
  servers = @[]

  for i in 0..3:
    var s = new(Server)
    s.pos = vec2i(cardWidth*i + cardWidth div 2 + 8, cardHeight*4 + cardHeight div 2 + 16)
    s.health = 10
    s.infected = false
    servers.add(s)

  initialDeck = newPile()
  drawPile = newPile("DEQUE")

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
    if cy == 0:
      c.bought = true
      drawPile.cards.addLast(c)
    else:
      initialDeck.cards.addLast(c)

  for i in 0..<1:
    var c = new(ActionCard)
    c.cost = 3
    c.title = "REBOOT"
    c.desc = "TRASH ALL MODULES IN CONSOLE"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      for tc in hand:
        moveCard(tc, tc.pos, trashPile.pos) do(cm: CardMove):
          trashPile.play(tc)
      hand = @[]
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<1:
    var c = new(ActionCard)
    c.cost = 5
    c.title = "RSTR.BKP"
    c.desc = "RESTORE ALL OLD DEFENCES"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      for y in 1..<4*5:
        for x in 1..<4*5:
          let t = mget(x,y)
          if t == 81:
            var stillExists = false
            for t in turrets:
              if t.pos.x == x*8+4 and t.pos.y == y*8+4:
                stillExists = true
                break
            if not stillExists:
              turrets.add(newTurret(vec2i(x*8+4,y*8+4), 1, 32.0, 2.0))
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 5
    c.title = "GC PAUSE"
    c.desc = "PAUSE ALL PACKETS FOR 10 SECONDS"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      maintenanceTime = 10
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 4
    c.title = "QOS.SLOW"
    c.desc = "SLOW ALL PACKETS ON A MODULE"
    c.playOnField = true
    c.action = proc(col,row: int): bool =
      let sp = tilePos(col,row)
      for b in boids:
        if b.pos.x >= sp.x and b.pos.x < sp.x + cardWidth and b.pos.y >= sp.y and b.pos.y < sp.y + cardHeight:
          b.maxSpeed *= 0.5
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<3:
    var c = new(ActionCard)
    c.cost = 2
    c.title = "DRAW.2"
    c.desc = "DRAW 2 MODULES"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      drawCard(2)
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<5:
    var c = new(ActionCard)
    c.cost = 1
    c.title = "CREDIT++"
    c.desc = "GET 1 CREDIT"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      money+=1
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<3:
    var c = new(ActionCard)
    c.cost = 2
    c.title = "CREDIT+=2"
    c.desc = "GET 2 CREDITS"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      money+=2
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 3
    c.title = "CREDIT+=3"
    c.desc = "GET 3 CREDITS"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      money+=3
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 2
    c.title = "STK2DEQUE"
    c.desc = "STACK TOP ON TO DEQUE"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      var dc = discardPile.draw()
      if dc == nil:
        setLogMessage("NO MODULE ON STACK")
        return false
      moveCard(dc, dc.pos, drawPile.pos) do(cm: CardMove):
        dc.down = true
        drawPile.play(dc)
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 4
    c.title = "STK2CON"
    c.desc = "STACK TOP ON TO CONSOLE"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      var dc = discardPile.draw()
      if dc == nil:
        setLogMessage("NO MODULE ON STACK")
        return false
      moveCard(dc, dc.pos, handPos().vec2f) do(cm: CardMove):
        dc.down = false
        hand.add(dc)
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<3:
    var c = new(ActionCard)
    c.cost = 1
    c.title = "STK.TRASH"
    c.desc = "TRASH TOP OF STACK"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      # trash the top of the discard pile
      if discardPile.cards.len > 0:
        var tc = discardPile.draw()
        moveCard(tc, tc.pos, trashPile.pos) do(cm: CardMove):
          trashPile.play(cm.c)
        return true
      setLogMessage("EMPTY STACK")
      return false
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 2
    c.title = "REPR.DEF"
    c.desc = "REPAIR DEFENCES ON A MODULE"
    c.playOnField = true
    c.action = proc(col,row: int): bool =
      # find any turrets on tile and refill their health
      let start = tilePos(col,row)
      var hasTurrets = false
      for t in turrets:
        if t.pos.x >= start.x and t.pos.x < start.x + cardWidth and t.pos.y >= start.y and t.pos.y < start.y + cardHeight:
          if t.health < 3:
            t.health += 1
            hasTurrets = true
      if not hasTurrets:
        setLogMessage("NO DECAYED DEFENCES ON MODULE")
      return hasTurrets
    initialDeck.cards.addLast(c)

  for i in 0..<4:
    var c = new(ActionCard)
    c.cost = 2
    c.title = "UPGRD.DEF"
    c.desc = "UPGRADE DEFENCES ON A MODULE"
    c.playOnField = true
    c.action = proc(col,row: int): bool =
      # find any turrets on tile and refill their health
      let start = tilePos(col,row)
      var hasTurrets = false
      for t in turrets:
        if t.pos.x >= start.x and t.pos.x < start.x + cardWidth and t.pos.y >= start.y and t.pos.y < start.y + cardHeight:
          if t.damage < 3:
            hasTurrets = true
            t.damage += 1
      if not hasTurrets:
        setLogMessage("NO UPGRADABLE DEFENCES ON MODULE")
      return hasTurrets
    initialDeck.cards.addLast(c)

  for i in 0..<3:
    var c = new(ActionCard)
    c.cost = 2
    c.unblockable = true
    c.title = "FORK.BOMB"
    c.desc = "TRASH MODULE W/ PACKETS"
    c.playOnField = true
    c.action = proc(col,row: int): bool =
      let index = row * 4 + col
      # make the map solid here
      let oldCard = field[index].draw()
      if oldCard != nil:
        moveCard(oldCard, oldCard.pos, trashPile.pos) do(cm: CardMove):
          trashPile.play(cm.c)
      else:
        setLogMessage("NO MODULE TO BOMB")
        return false

      for y in 0..4:
        for x in 0..4:
          mset(1+col*5+x, 1+row*5+y, 113)
      let tp = tilePos(col,row)
      for i,t in turrets:
        if t.pos.x >= tp.x and t.pos.x < tp.x + cardWidth and t.pos.y >= tp.y and t.pos.y < tp.y + cardHeight:
          turrets.delete(i)
          break

      return true
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 4
    c.title = "ANTI.VIR"
    c.desc = "REMOVE INFECTION FROM HOST"
    c.playOnField = true
    c.action = proc(col,row: int): bool =
      # remove infection from servers on rack
      let start = tilePos(col,row)
      var hasInfection = false
      for s in servers:
        if s.pos.x >= start.x and s.pos.x < start.x + cardWidth:
          if s.infected:
            hasInfection = true
            s.infected = false
            s.health = 5
            for e in entrances:
              if e.myServer == s:
                let tmp = entrances.find(e)
                if tmp > -1:
                  entrances.delete(tmp)
          elif s.health < 10:
            hasInfection = true
            s.health += 5
            if s.health > 10:
              s.health = 10
      if not hasInfection:
        setLogMessage("HOST NOT INFECTED")
      return hasInfection
    initialDeck.cards.addLast(c)

  # shuffle the deck
  initialDeck.shuffle()
  initialDeck.shuffle()
  initialDeck.shuffle()

  # shuffle the player's draw pile
  drawPile.shuffle()
  drawPile.shuffle()
  drawPile.shuffle()

  newMap(4*5+2,5*5+2)
  for x in 0..<4*5:
    if x mod 5 == 0 or x mod 5 == 4:
      continue
    for y in 4*5..5*5+4:
      mset(x+1, y+1, 1)
  for x in 0..<mapWidth():
    if x mod 5 == 3:
      mset(x, 0, 6)
      var e = new(Entrance)
      e.pos = vec2i(x * 8, 0 * 8)
      e.connected = false
      entrances.add(e)

  discardPile = newPile("STACK")
  trashPile = newPile("RECYCLING")
  supplyDiscard = newPile()

  for i in 0..<4*5:
    if i > 15:
      field[i] = newPile(serverNames[i mod 4])
    else:
      field[i] = newPile()

  hand = newSeq[Card]()
  supply = [nil.Card,nil,nil,nil,nil]
  selected = nil

  for i in 0..4:
    var c = initialDeck.draw()
    if c != nil:
      c.down = false
      supply[i] = c

  discardHand()

  # boids stuff

  boids = newSeq[Boid]()

proc gameUpdate(dt: float32) =
  if shake > 0:
    shake -= dt
  else:
    shakeLevel = 0

  if logMessageTimeout > 0:
    logMessageTimeout -= dt

  if gameover:
    if mousebtnp(0):
      gameInit()
    return

  if wave > 0:
    waveTimer -= dt
    if waveTimer < 0:
      nextWave()


  for s in servers:
    if not s.infected and s.health <= 0:
      mset(s.pos.x div 8, s.pos.y div 8, 10)
      var e = new(Entrance)
      e.pos = s.pos
      s.infected = true
      e.myServer = s
      entrances.add(e)

  for e in entrances:
    e.connected = false
    e.servers = @[]

  for y in 1..4*8:
    for x in 1..4*8:
      if mget(x,y) == 37:
        mset(x,y,36)

  online = 0
  for s in servers:
    if not s.infected:
      s.reachable = false
      for e in entrances:
        if e.myServer == nil:
          # check if server is reachable from an entrance
          for point in path(tilemap, getTile(e.pos), getTile(s.pos)):
            s.reachable = true
            e.connected = true
            e.servers.add(s)
            mset(point.x, point.y, 37)
      if s.reachable:
        online += 1

  if online == 0 and wave > 0:
    downtime += dt
    if downtime > 1.0:
      shake = 0.1
      shakeLevel = 1
  elif downtime > 0:
    downtime -= dt * 0.1
    if downtime < 0:
      downtime = 0

  if downtime > 10.0:
    gameover = true
    return

  for e in entrances:
    mset(e.pos.x div 8, e.pos.y div 8, if e.connected: 6 else: 7)

  for s in servers:
    if not s.infected:
      mset(s.pos.x div 8, s.pos.y div 8, if s.reachable: 8 else: 9)

  # move boids
  if maintenanceTime > 0:
    maintenanceTime -= dt
    for b in boids:
      b.update(0.0)
  else:
    for b in boids:
      b.update(dt)

  for t in turrets:
    t.update(dt)

  for b in bullets:
    b.ttl -= dt
    b.pos += b.vel * dt
    b.ipos = b.pos.vec2i

    for o in boids:
      if o.evil and o.pos.nearer(b.pos,2.0):
        b.ttl = 0
        o.health -= b.damage
        break

  for i in 0..<cardMoves.len:
    let cm = cardMoves[i]
    cm.alpha += dt / cm.time
    if cm.alpha >= 1.0:
      cm.onComplete(cm)
      cm.completed = true

  cardMoves.keepItIf(not it.completed)

  bullets.keepItIf(it.ttl > 0)
  boids.keepItIf(it.health > 0)

  let (mx,my) = mouse()
  if mousebtnp(0):
    # check which area the mouse is in
    block:
      # supply
      let sp = supplyPos()
      let x = sp.x
      let y = sp.y

      let w = cardWidth
      let h = cardHeight * 5 + cardHeight div 2
      if mx >= x and mx <= x + w and my >= y and my <= y + h:
        let index = (my - y) div (cardHeight + 1)
        if index == supply.len:
          if flushed:
            setLogMessage("CAN ONLY FLUSH ONCE PER WAVE")
            return
          if money < 1:
            setLogMessage("NOT ENOUGH CREDITS")
            return
          money -= 1
          flushSupply()
          flushed = true
          return

        if index < 0 or index > supply.high:
          return

        let c = supply[index]
        if c == nil:
          return

        if selected != c:
          selectCard(c)
        elif c == selected:
          if money < c.cost:
            setLogMessage("NOT ENOUGH CREDITS")
            return
          c.bought = true
          money -= c.cost

          let oldPos = c.pos
          supply[index] = nil
          moveCard(c, c.pos, discardPile.pos) do(cm: CardMove):
            discardPile.cards.addLast(cm.c)
            # replace card
            var nc = initialDeck.draw()
            if nc != nil:
              moveCard(nc, initialDeck.pos, oldPos) do(cm: CardMove):
                cm.c.down = false
                supply[index] = cm.c
          selectCard(nil)
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
            selectCard(c)
          else:
            if c of ActionCard:
              let ac = ActionCard(c)
              if not ac.playOnField:
                if ac.action(0,0):
                  hand.delete(index)
                  moveCard(c, c.pos, discardPile.pos) do(cm: CardMove):
                    discardPile.play(cm.c)
                else:
                  shakeLevel = min(1,shakeLevel)
                  shake += 0.1
              else:
                shakeLevel = min(1,shakeLevel)
                shake += 0.1
                setLogMessage("MUST USE EXE ON GRID")
            selectCard(nil)
    block:
      # draw
      let x = 5
      let y = screenHeight - 9 * 8
      let w = cardWidth
      let h = cardHeight + drawPile.cards.len * 2
      if mx >= x and mx <= x + w and my >= y and my <= y + h:
        if waveTimer < 20.0 and online > 0:
          nextWave()
        elif wave == 0 and online == 0:
          setLogMessage("MUST CONNECT TO BEGIN")
          for i in 0..15:
            var c = field[i].draw()
            if c != nil:
              moveCard(c, c.pos, handPos().vec2f) do(cm: CardMove):
                hand.add(cm.c)
          for y in 1..<1+4*5:
            for x in 1..<1+4*5:
              mset(x,y,0)
          turrets = @[]

    block:
      # update field
      var x = screenWidth div 2 - (((4 * cardWidth) + 8) div 2)
      let y = 10 + 8
      let w = cardWidth * 4 + 16
      let h = cardHeight * 4 + 16

      if mx >= x and mx <= x + w and my >= y and my <= y + h:
        let col = ((mx - 8) - x) div cardWidth
        let row = (my - y) div cardHeight

        let index = row * 4 + col

        if selected != nil and index >= 0 and index < 16:
          let i = hand.find(selected)
          if i > -1:
            if selected of ActionCard:
              var ac = ActionCard(selected)
              if ac.playOnField:
                if ac.action(col,row):
                  hand.delete(i)
                  moveCard(selected, selected.pos, field[index].pos) do(cm: CardMove):
                    moveCard(cm.c, cm.c.pos, discardPile.pos) do(cm: CardMove):
                      discardPile.cards.addLast(cm.c)
                else:
                  shakeLevel = min(1, shakeLevel)
                  shake += 0.2

            elif selected of TileCard:
              # place tile card on field

                if tileBlocked(col,row):
                  shake += 0.2
                  shakeLevel = max(shakeLevel,1)
                  setLogMessage("MODULE BLOCKED BY ATTACKERS")
                  return

                # make the map solid here
                for y in 0..4:
                  for x in 0..4:
                    mset(1+col*5+x, 1+row*5+y, 0)

                # remove the old card
                let oldCard = field[index].draw()

                let newCard = selected

                hand.delete(i)
                let after = proc() =
                  moveCard(newCard, newCard.pos, field[index].pos) do(cm: CardMove):
                    field[index].cards.addLast(cm.c)

                    # update the map
                    let tc = TileCard(cm.c)
                    for i,t in tc.data:
                      let tx = col * 5 + i mod 5 + 1
                      let ty = row * 5 + i div 5 + 1
                      mset(tx, ty, t)
                      # if turret at location, remove it first
                      for i,t in turrets:
                        if t.pos.x div 8 == tx and t.pos.y div 8 == ty:
                          turrets.delete(i)
                          break

                      if t == 49:
                        turrets.add(newTurret(vec2i(tx*8+4,ty*8+4), 2, 16.0, 1.0))
                        mset(tx, ty, 81)
                      elif t == 65:
                        turrets.add(newTurret(vec2i(tx*8+4,ty*8+4), 1, 32.0, 2.0))
                        mset(tx, ty, 81)

                if oldCard != nil:
                  moveCard(oldCard, oldCard.pos, discardPile.pos) do(cm: CardMove):
                    discardPile.play(cm.c)
                    after()
                else:
                  after()

          selectCard(nil)

proc gameDraw() =
  frame += 1
  clip()
  setCamera()
  setColor(26)
  rectfill(0,0,screenWidth,screenHeight)

  drawPile.draw(5, screenHeight - 9 * 8)
  discardPile.draw(50, screenHeight - 9 * 8)

  block:
    # draw field
    let x = screenWidth div 2 - ((4 * cardWidth) div 2)
    let y = 10
    let (mx,my) = mouse()

    let mcol = (mx - x - 8) div cardWidth
    let mrow = (my - y - 8) div cardHeight

    setCamera(-x + (if shake > 0: rnd(shakeLevel*2)-shakeLevel else: 0), -y + (if shake > 0: rnd(shakeLevel*2)-shakeLevel else: 0))

    for i in 0..<4*4:
      let row = i div 4
      let col = i mod 4
      setColor(16)
      rect(col*cardWidth + 8, row * cardHeight + 8, col*cardWidth+cardWidth-1 + 8, row*cardHeight+cardHeight-1 + 8)
    mapDraw(0,0,4*5+2,5*5+2,0,0)
    for i in 0..<4*4:
      let row = i div 4
      let col = i mod 4
      field[i].pos.x = (x + col * cardWidth + 8).float32
      field[i].pos.y = (y + row * cardHeight + 8).float32

      if mcol == col and mrow == row:
        let tb = tileBlocked(col,row)
        setColor(if tb: 25 else: 19)
        rect(col*cardWidth + 8, row * cardHeight + 8, col*cardWidth+cardWidth-1 + 8, row*cardHeight+cardHeight-1 + 8)

    palt(26,true)
    for b in boids:
      spr((if b.evil: 22 else: 38) + b.frame, b.pos.x - 4, b.pos.y - 4)

    for s in servers:
      if s.infected:
        spr(10, s.pos.x - 4, s.pos.y - 4)
      else:
        if not s.reachable:
          pal(18,16)
        spr(128 + (10 - s.health), s.pos.x - 4, s.pos.y - 4)
        pal()

    for t in turrets:
      case t.damage:
      of 1:
        spr(70, t.pos.x - 4, t.pos.y - 4)
      of 2:
        spr(71, t.pos.x - 4, t.pos.y - 4)
      of 3:
        spr(72, t.pos.x - 4, t.pos.y - 4)
      else:
        spr(72, t.pos.x - 4, t.pos.y - 4)

      if t.health == 1 and frame mod 30 < 15:
        pal(11,if waveTimer < 5: 25 else: 24)
      spr(54 + 3 - t.health, t.pos.x - 3, t.pos.y)
      pal()

    for b in bullets:
      setColor(19)
      circfill(b.pos.x, b.pos.y, 1)

  setCamera()

  # supply
  block:
    let sp = supplyPos()
    var xi = sp.x
    var yi = sp.y
    initialDeck.draw(xi, -cardHeight)
    for c in supply:
      if c != nil:
        c.draw(xi, yi)
      yi += cardHeight + 1
    setColor(if flushed: 23 else: 17)
    rect(xi,yi,xi+cardWidth,yi+cardHeight div 2)
    printc("FLUSH", xi + cardWidth div 2, yi + 2)
    if not flushed:
      setColor(if money >= 1: 10 else: 24)
    printr("1", xi + cardWidth-2, yi + 10)

  trashPile.draw(-cardWidth - 2, 20)
  supplyDiscard.draw(-cardWidth - 2, screenHeight - cardHeight)

  # hand
  if hand.len > 0:
    let handPos = handPos()
    var xi = handPos.x
    for c in hand:
      c.draw(xi, handPos.y)
      xi += cardWidth + 1

  for i in 0..<cardMoves.len:
    let cm = cardMoves[i]
    let p = lerp(cm.c.pos, cm.dest, cm.alpha)
    cm.c.draw(p.x.int, p.y.int)

  setColor(10)
  if not gameover and (money > online and frame mod 30 < 15):
    setColor(25)
  print("CREDITS " & $money & "/" & $(online), screenWidth - cardWidth - 20, screenHeight - 10)

  if wave > 0:
    setColor(18)
    print("SCORE: " & $score, 5, 30)

  if online > 0:
    setColor(12)
    print("ONLINE " & $online & "/4", 5, 5)
  elif wave == 0:
    setColor(18)
    print("INSTALLATION PHASE", 5, 5)
  else:
    setColor(25)
    print("OFFLINE: " & $(10 - downtime.int), 5, 5)

  if gameover:
    setColor(25)
    printShadowC("GAME OVER!", screenWidth div 2, screenHeight div 2)
    setColor(19)
    printShadowC("WAVES SURVIVED: " & $(wave-1), screenWidth div 2, screenHeight div 2 + 20)
    printShadowC("SCORE: " & $score, screenWidth div 2, screenHeight div 2 + 30)
    setColor(if frame mod 60 < 30: 18 else: 19)
    printShadowC("CLICK TO RESTART", screenWidth div 2, screenHeight div 2 + 60)

  else:
    if wave > 0 and online == 0 and downtime > 1.0:
      setColor(25)
      printShadowC("SYSTEM OFFLINE!", screenWidth div 2, screenHeight div 2)
      printShadowC($(10 - downtime.int), screenWidth div 2, screenHeight div 2 + 30)

    if wave > 0 and waveTimer < 3:
      setColor(28)
      printShadowC("WAVE INCOMING : " & $(waveTimer.int), screenWidth div 2, screenHeight div 2 - 30)

    if wave > 0:
      setColor(18)
      print("WAVE: " & $wave, 5, screenHeight - 20)
      if waveTimer < 3:
        if frame mod 10 < 5:
          setColor(25)
      elif waveTimer < 10:
        if frame mod 60 < 30:
          setColor(10)
      print("NEXT WAVE IN " & $(waveTimer.int), 5, screenHeight - 10)

  setColor(21)
  printc("THE NET", screenWidth div 2, 2)
  printr("THE PIPE", screenWidth - 10, 2)
  printc("CONSOLE", screenWidth div 2, screenHeight - 8)
  if logMessageTimeout > 0 and logMessage != nil:
    setColor(28)
    print(logMessage, 5, screenHeight - 8)

  if wave == 0:
    setColor(20)
    var y = 30
    print("INSTRUCTIONS", 5, y)
    y += 12
    setColor(21)
    print("HELLO, TECHNICIAN.", 5, y)
    y += 7
    print("YOU HAVE 4 RACKS EACH WITH A HOST", 5, y)
    y += 7
    print("CONNECT HOSTS TO THE NET TO ACCEPT", 5, y)
    y += 7
    print("PACKETS", 5, y)
    y += 12
    print("PLACE MODULES FROM THE CONSOLE ON RACKS", 5, y)
    y += 7
    print("MODULES HAVE BOTH LINKS AND DEFENCES", 5, y)
    y += 7
    print("DEFENCES DECAY OVER 3 WAVES", 5, y)
    y += 10
    print("BUY NEW MODULES FROM THE PIPE", 5, y)
    y += 12
    print("DEFEND YOUR HOSTS AGAINST WAVES", 5, y)
    y += 7
    print("OF ATTACKERS", 5, y)
    y += 10
    print("HOSTS HAVE FIREWALLS AND CAN STOP", 5, y)
    y += 7
    print("10 ATTACKERS BEFORE THEY ARE INFECTED", 5, y)
    y += 12
    print("IF YOU HAVE NO HOSTS REMAINING ONLINE", 5, y)
    y += 7
    print("YOU FAIL", 5, y)
    y += 12
    print("DRAW FROM DEQUE TO START THE WAVE", 5, y)
    y += 7
    print("ANY UNUSED MODULES WILL BE DISCARDED", 5, y)
    y += 7
    print("", 5, y)

  debugDraw()

  # mouse
  let (mx,my) = mouse()


nico.init("impbox", "ld41")

tileSize(8,8)

loadPaletteFromGPL("palette.gpl")
palt(26,false)
palt(0,true)
loadSpritesheet("spritesheet.png")

fixedSize(true)
integerScale(true)
nico.createWindow("ld41", 1920 div 4 , 1080 div 4, 4)
nico.run(gameInit, gameUpdate, gameDraw)
