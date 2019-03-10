import nico
import nico/vec
import nico/util
import utils
import sets
import hashes
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
const maxTurretHealth = 4

# TYPES

# GLOBALS

var nextId = 0

var online: int

var nextWaveCooldown: float32
var introMode: bool = true
var logoY: float32 = -15.0
var introTimeout: float32 = 5.0
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
var selected: Card
var servers: seq[Server]
var entrances: seq[Entrance]
var turrets: seq[Turret]
var bullets: seq[Bullet]
var wave: int
var cardMoves: seq[CardMove]
var coinMoves: seq[CoinMove]
var frame: uint16 = 0
var logMessage: string
var logMessageTimeout: float32
var flushed: bool
var maintenanceTime: float32
var score: int
var topScore: int
var bestWaves: int
var gameover: bool
var gameoverTimeout: float32
var nextWaveContents: seq[BoidType]
var waveContents: Deque[BoidType]
var nextSpawnTimeout: float32

var tilemap: Tilemap

var field: array[4*5, Pile]

var serverNames = [
  "COLOSSUS",
  "MULTIVAC",
  "GUARDIAN",
  "PROTEUS"
]



# PROCS

proc endGame() =
    gameover = true
    gameoverTimeout = 2.0
    topScore = try: getConfigValue("save","topScore").parseInt() except: 0
    bestWaves = try: getConfigValue("save","topWaves").parseInt() except: 0
    if score > topScore:
      topScore = score
      updateConfigValue("save","topScore", $topScore)
    if wave - 1 > bestWaves:
      bestWaves = wave - 1
      updateConfigValue("save","bestWaves", $bestWaves)
    saveConfig()

proc setLogMessage(text: string) =
  logMessage = text
  logMessageTimeout = 5.0

proc shuffle(self: Pile)
proc newPile(label: string = ""): Pile

proc tilePos(col,row: int): Vec2i =
  return vec2i(8 + col * cardWidth, 8 + row * cardHeight)

proc fieldPos(): Vec2i =
  return vec2i(screenWidth div 2 - ((4 * cardWidth) div 2), 10)

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

proc moveCoin(source: Vec2f, dest: Vec2f, onComplete: proc()) =
  var cm = new(CoinMove)
  cm.pos = source
  cm.dest = dest
  cm.onComplete = onComplete
  cm.time = 0.2
  cm.alpha = 0.0

  coinMoves.add(cm)

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

iterator neighborsAll(grid: Tilemap, node: Tile): Tile =
  let tx = node.x
  let ty = node.y

  if tx > 0:
    yield (tx-1,ty,mget(tx-1,ty))
  if tx < mapWidth():
    yield (tx+1,ty,mget(tx+1,ty))
  if ty > 0:
    yield (tx,ty-1,mget(tx,ty-1))
  if ty < mapHeight():
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
  result.cohesion = 0.0
  result.cohesionRadius = 8.0
  result.separation = 1.0
  result.separationRadius = 2.0
  result.maxForce = 50.0
  result.maxSpeed = 10.0
  result.alignment = 0.5
  result.shootTimeout = 5.0
  result.repathTimeout = 0.0
  result.route = @[]
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
  result.cohesion = 0.0
  result.cohesionRadius = 1.0
  result.separation = 1.0
  result.separationRadius = 2.0
  result.maxForce = 50.0
  result.maxSpeed = 15.0
  result.alignment = 0.5
  result.shootTimeout = 5.0
  result.repathTimeout = 0.0
  result.route = @[]
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

proc newTurret(pos: Vec2i, level: int): Turret =
  result = new(Turret)
  result.pos = pos
  result.level = level
  result.health = maxTurretHealth

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
  if wave > 0 and online == 0:
    endGame()
    return

  nextWaveCooldown = 10.0
  flushed = false
  wave += 1

  for t in turrets:
    t.health -= 1

  turrets.keepItIf(it.health > 0)

  var online = 0
  var bandwidth = 0
  if wave > 0:
    for s in servers:
      if not s.infected:
        if s.health < 8 and s.reachable:
          s.health += 1
      else:
        online += 1

  for e in entrances:
    if e.myServer == nil and e.connected:
      bandwidth += 1

  discardHand()

  money = 0

  if wave > 1:
    score += online * bandwidth

  for x in nextWaveContents:
    waveContents.addLast(x)

  nextWaveContents = @[]

  let nRed = 5 + wave + rnd(wave)
  for i in 0..<nRed:
    nextWaveContents.add(Basic)

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



proc hash(self: Tile): Hash =
  var h: Hash = 0
  h = h !& self.x
  h = h !& self.y
  result = !$h

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

  if repathTimeout <= 0.0 or (route.len == 0 and repathTimeout <= 0.0):
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

  elif route.len > 0:

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
          route = @[]
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
  case level:
  of 1:
    radius = 16.0
    rechargeTime = 1.0
    damage = 1
  of 2:
    radius = 18.0
    rechargeTime = 0.9
    damage = 2
  of 3:
    radius = 20.0
    rechargeTime = 0.75
    damage = 3
  else:
    return

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

proc play(self: Pile, c: Card) =
  cards.addLast(c)


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
  setColor(if playOnField: 11 else: 12)
  rect(x,y,x+cardWidth-1,y+cardHeight-1)
  rectfill(x,y,x+cardWidth-1,y+8)
  setColor(26)

  printc(title, x+cardWidth div 2, y+2)
  var text = wordWrap(desc, 9, true)
  var y = y + 11
  for line in text.splitLines():
    print(line, x + 2, y)
    y += 7


proc removeTile(col, row: int): Card =
  # make the map solid here
  for y in 0..4:
    for x in 0..4:
      mset(1+col*5+x, 1+row*5+y, 0)

  let tp = tilePos(col,row)
  turrets.keepItIf(it.pos.x < tp.x or it.pos.x > tp.x + cardWidth or it.pos.y < tp.y or it.pos.y > tp.y + cardHeight)

  # remove the old card
  let index = row * 4 + col
  let oldCard = field[index].draw()
  return oldCard

proc placeTile(newCard: Card, col, row: int) =
  let oldCard = removeTile(col, row)

  let index = row * 4 + col

  let after = proc() =
    moveCard(newCard, newCard.pos, field[index].pos) do(cm: CardMove):
      field[index].cards.addLast(cm.c)

      # update the map
      let tc = TileCard(cm.c)
      for i,t in tc.data:
        let tx = col * 5 + i mod 5 + 1
        let ty = row * 5 + i div 5 + 1
        mset(tx, ty, t)

        if t == 49:
          turrets.add(newTurret(vec2i(tx*8+4,ty*8+4), 2))
          mset(tx, ty, 81)
        elif t == 65:
          turrets.add(newTurret(vec2i(tx*8+4,ty*8+4), 1))
          mset(tx, ty, 81)
        elif t == 83:
          turrets.add(newTurret(vec2i(tx*8+4,ty*8+4), 3))
          mset(tx, ty, 81)

        if t == 102:
          mset(tx, ty, 103)
          moveCoin(vec2f(tx*8,ty*8) + fieldPos().vec2f, vec2f(screenWidth,0)) do:
            money += 1

  if oldCard != nil:
    moveCard(oldCard, oldCard.pos, discardPile.pos) do(cm: CardMove):
      discardPile.play(cm.c)
      after()
  else:
    after()


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

proc newPile(label: string = ""): Pile =
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

proc draw(self: Pile, x,y: int, base: bool = true, topLabel: string = "", flash: bool = false) =
  pos = vec2f(x,y)
  setColor(16)
  if base:
    rect(x-1,y-1,x+cardWidth,y+cardHeight)
  else:
    rect(x,y,x+cardWidth-1,y+cardHeight-1)

  if label != "":
    printc(label, x + cardWidth div 2, y + cardHeight + 2)

  let tight = cards.len > 10
  var yi = y
  for c in cards:
    c.draw(x,yi)
    yi -= (if tight: 1 else: 2)

  if topLabel != "":
    setColor(if flash and frame mod 30 < 15: 27 else: 28)
    printc(topLabel, x + cardWidth div 2, yi + cardHeight div 2)

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
  loadMap(0, "cards.json")
  setMap(0)

  gameover = false
  gameoverTimeout = 2.0

  money = 0

  flushed = false

  wave = 0

  cardMoves = @[]
  coinMoves = @[]
  turrets = @[]
  bullets = @[]
  entrances = @[]
  servers = @[]

  for i in 0..3:
    var s = new(Server)
    s.pos = vec2i(cardWidth*i + cardWidth div 2 + 8, cardHeight*4 + cardHeight div 2)
    s.health = 8
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
              turrets.add(newTurret(vec2i(x*8+4,y*8+4), 1))
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 5
    c.title = "GC PAUSE"
    c.desc = "PAUSE ALL PACKETS FOR 5 SECONDS"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      maintenanceTime = 5
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<1:
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

  for i in 0..<2:
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
    c.cost = 2
    c.title = "CREDIT+=2"
    c.desc = "GET 2 CREDITS"
    c.playOnField = false
    c.action = proc(col,row: int): bool =
      money+=2
      return true
    initialDeck.cards.addLast(c)

  for i in 0..<4:
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

  for i in 0..<2:
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
    c.cost = 3
    c.title = "REPR.DEF"
    c.desc = "REPAIR DEFENCES ON A MODULE"
    c.playOnField = true
    c.action = proc(col,row: int): bool =
      # find any turrets on tile and refill their health
      let start = tilePos(col,row)
      var hasTurrets = false
      for t in turrets:
        if t.pos.x >= start.x and t.pos.x < start.x + cardWidth and t.pos.y >= start.y and t.pos.y < start.y + cardHeight:
          if t.health < maxTurretHealth:
            t.health += 1
            hasTurrets = true
      if not hasTurrets:
        setLogMessage("NO DECAYED DEFENCES ON MODULE")
      return hasTurrets
    initialDeck.cards.addLast(c)

  for i in 0..<3:
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
          if t.level < 3:
            hasTurrets = true
            t.level += 1
      if not hasTurrets:
        setLogMessage("NO UPGRADABLE DEFENCES ON MODULE")
      return hasTurrets
    initialDeck.cards.addLast(c)

  for i in 0..<2:
    var c = new(ActionCard)
    c.cost = 2
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
    c.playOnServer = true
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
                  break
          elif s.health < 8:
            hasInfection = true
            s.health += 5
            if s.health > 8:
              s.health = 8
      if not hasInfection:
        setLogMessage("HOST NOT INFECTED")
      return hasInfection
    initialDeck.cards.addLast(c)

  # shuffle the deck
  initialDeck.shuffle()
  initialDeck.shuffle()
  initialDeck.shuffle()
  initialDeck.shuffle()
  initialDeck.shuffle()
  initialDeck.shuffle()

  # shuffle the player's draw pile
  drawPile.shuffle()
  drawPile.shuffle()
  drawPile.shuffle()

  newMap(0, 4*5+2,5*5+2, 8, 8)
  for x in 0..<4*5:
    if x mod 5 == 0 or x mod 5 == 4:
      continue
    for y in 4*5..<5*5-1:
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

  #discardHand()

  # boids stuff

  boids = newSeq[Boid]()

  waveContents = initDeque[BoidType]()
  nextWaveContents = newSeq[BoidType]()
  for i in 0..<5:
    nextWaveContents.add(Basic)

proc gameUpdate(dt: float32) =
  if nextWaveCooldown > 0:
    nextWaveCooldown -= dt

  if introTimeout > 0:
    introTimeout -= dt

  if shake > 0:
    shake -= dt
  else:
    shakeLevel = 1

  if logMessageTimeout > 0:
    logMessageTimeout -= dt

  if gameover:
    if gameoverTimeout <= 0:
      let (mx,my) = mouse()
      if mousebtnp(0):
        gameInit()
    else:
      gameoverTimeout -= dt
    return

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
  for si, s in servers:
    if not s.infected:
      s.reachable = false
      for ei, e in entrances:
        for point in path(tilemap, getTile(e.pos), getTile(s.pos)):
          if e.myServer == nil:
            s.reachable = true
          e.connected = true
          e.servers.add(s)
          break
      if s.reachable:
        online += 1

  var connectedEntrances = newSeq[Entrance]()

  for ei, e in entrances:
    if e.connected:

      connectedEntrances.add(e)

      var queue = initDeque[Tile]()
      var seen = initSet[Tile]()
      queue.addFirst(getTile(e.pos))

      while queue.len > 0:
        let current = queue.popLast()

        mset(current.x, current.y, 37)

        for n in neighborsAll(tilemap, current):
          if not seen.contains(n):
            seen.incl(n)

            if not isSolid(n.t):
              queue.addFirst(n)

  if nextSpawnTimeout > 0:
    nextSpawnTimeout -= dt
  else:
    if connectedEntrances.len > 0 and waveContents.len > 0:
      let next = waveContents.popLast()
      let e = rnd(connectedEntrances)
      addNewBoid(vec2f(e.pos.x+4+rnd(0.1), e.pos.y+10+rnd(0.1)), rnd(e.servers))
      nextSpawnTimeout = 0.5

  if online == 0 and wave > 0 and hand.len == 0 and cardMoves.len == 0:
    endGame()

  for e in entrances:
    mset(e.pos.x div 8, e.pos.y div 8, if e.connected: 6 else: 7)

  for s in servers:
    if not s.infected:
      mset(s.pos.x div 8, s.pos.y div 8, if s.reachable: 8 else: 9)
      #mset(s.pos.x div 8, s.pos.y div 8 + 1, if s.reachable: 8 else: 9)

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
        if o.health <= 0:
          score += 1
        break

  for i in 0..<cardMoves.len:
    let cm = cardMoves[i]
    cm.alpha += dt / cm.time
    if cm.alpha >= 1.0:
      cm.onComplete(cm)
      cm.completed = true

  cardMoves.keepItIf(not it.completed)

  for i in 0..<coinMoves.len:
    let cm = coinMoves[i]
    cm.alpha += dt / cm.time
    if cm.alpha >= 1.0:
      cm.onComplete()
      cm.completed = true

  coinMoves.keepItIf(not it.completed)

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
        let hp = handPos()
        let x = hp.x
        let y = hp.y
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
                  shakeLevel = max(1,shakeLevel)
                  shake += 0.1
              else:
                shakeLevel = max(1,shakeLevel)
                shake += 0.1
                setLogMessage("MUST USE EXE ON GRID")
            selectCard(nil)
    block:
      # deck
      let x = 5
      let y = screenHeight - 9 * 8 - drawPile.cards.len * 2
      let w = cardWidth
      let h = cardHeight + drawPile.cards.len * 2
      if mx >= x and mx <= x + w and my >= y and my <= y + h:
        if cardMoves.len == 0:
          if wave > 0 and online == 0:
            endGame()
          elif online > 0 and nextWaveCooldown <= 0:
            nextWave()
          elif wave == 0 and hand.len == 0 and online == 0:
            introMode = false
            discardHand()
            return
          elif wave == 0 and online == 0:
            setLogMessage("MUST CONNECT A HOST TO THE NET TO START")
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
      let fp = fieldPos()
      let x = fp.x
      let y = fp.y

      let w = cardWidth * 4 + 16
      let h = cardHeight * 4 + 16

      if mx >= x and mx <= x + w and my >= y and my <= y + h:
        let col = ((mx - 8) - x) div cardWidth
        let row = ((my - 8) - y) div cardHeight

        let index = row * 4 + col

        if selected != nil and index >= 0 and index < 16 + (if selected of ActionCard and ActionCard(selected).playOnServer: 4 else: 0):
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
                  shakeLevel = max(1, shakeLevel)
                  shake += 0.2

            elif selected of TileCard:
              # place tile card on field
              if tileBlocked(col,row):
                  shake += 0.2
                  shakeLevel = max(shakeLevel,1)
                  setLogMessage("MODULE BLOCKED BY ATTACKERS")
                  return
              else:
                hand.delete(i)
                placeTile(selected, col, row)

          selectCard(nil)

proc gameDraw() =
  frame += 1
  clip()
  setCamera()
  setColor(26)
  rectfill(0,0,screenWidth,screenHeight)

  drawPile.draw(5, screenHeight - 9 * 8, true, if nextWaveCooldown <= 0: (if wave == 0: "BEGIN" elif online == 0: "END GAME" else: "NEXT WAVE") else: "WAIT...", introMode and introTimeout <= 0)
  discardPile.draw(50, screenHeight - 9 * 8)

  block:
    # draw field

    let fp = fieldPos()
    let x = fp.x
    let y = fp.y
    let (mx,my) = mouse()

    let mcol = (mx - x - 8) div cardWidth
    let mrow = (my - y - 8) div cardHeight

    setCamera(-x + (if shake > 0 and shakeLevel > 0: rnd(shakeLevel*2)-shakeLevel else: 0), -y + (if shake > 0: rnd(shakeLevel*2)-shakeLevel else: 0))

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
        spr(136, s.pos.x - 4, s.pos.y - 4, 1, 2)
      else:
        if not s.reachable:
          pal(18,16)
        palt(26,false)
        spr(128 + (8 - s.health), s.pos.x - 4, s.pos.y - 4, 1, 2)
        palt(26,true)
        pal()

    for e in entrances:
      if e.connected:
        setColor(25)
        if e.myServer == nil:
          setColor(18)

    for t in turrets:
      case t.level:
      of 1:
        spr(70, t.pos.x - 4, t.pos.y - 4)
      of 2:
        spr(71, t.pos.x - 4, t.pos.y - 4)
      of 3:
        spr(72, t.pos.x - 4, t.pos.y - 4)
      else:
        spr(72, t.pos.x - 4, t.pos.y - 4)

      if t.health == 1 and frame mod 30 < 15:
        pal(11,24)
      spr(54 + maxTurretHealth - t.health, t.pos.x - 3, t.pos.y)
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
  supplyDiscard.draw(-cardWidth - 2, screenHeight - cardHeight - 10)

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

  for i in 0..<coinMoves.len:
    let cm = coinMoves[i]
    cm.pos = lerp(cm.pos, cm.dest, cm.alpha)
    spr(11, cm.pos.x, cm.pos.y)

  setColor(10)
  printr($money, screenWidth - cardWidth - 5, 10, 4)

  if wave > 0:
    setColor(18)
    print("SCORE: " & $score, 5, 30)

  setColor(25)
  print("NEXT WAVE: " & $nextWaveContents.len, 5, 40)

  if gameover:
    setColor(25)
    printShadowC("GAME OVER!", screenWidth div 2, screenHeight div 2 - 30)
    setColor(19)
    printShadowC("WAVES SURVIVED: " & $(wave-1), screenWidth div 2, screenHeight div 2 - 10)
    printShadowC("SCORE: " & $score, screenWidth div 2, screenHeight div 2)
    printShadowC("BEST SCORE: " & $topScore, screenWidth div 2, screenHeight div 2 + 10)
    if gameoverTimeout <= 0:
      setColor(if frame mod 60 < 30: 18 else: 19)
      printShadowC("CLICK TO RESTART", screenWidth div 2, screenHeight div 2 + 50)

  else:
    if wave > 0 and online == 0 and cardMoves.len == 0:
      setColor(25)
      printShadowC("SYSTEM OFFLINE!", screenWidth div 2, screenHeight div 2)

    if wave > 0:
      setColor(18)
      print("WAVE: " & $wave, 5, 10)

  if introTimeout < 1.0 and introMode:
      printShadowC("CLICK ON YOUR DEQUE TO START", screenWidth div 2, screenHeight div 2 + 30)

  setColor(21)
  printc("THE NET", screenWidth div 2, 2)
  printr("CACHE", screenWidth - 10, 2)
  printc("CONSOLE", screenWidth div 2, screenHeight - 8)
  if logMessageTimeout > 0 and logMessage != "":
    setColor(28)
    print(logMessage, 5, screenHeight - 10)

  if wave == 0 and bestWaves == 0:
    setColor(20)
    var y = 5
    print("INSTRUCTIONS", 5, y)
    y += 12
    setColor(21)
    richPrint("PLEASE READ BELOW BEFORE PLAYING", 5, y)

  if introMode:
    palt(26,true)
    logoY = lerp(logoY, (screenHeight div 2 - 15 div 2).float32, 0.01)
  else:
    logoY = lerp(logoY, -30.0, 0.05)
  sspr(0,97,96,15,screenWidth div 2 - 97 div 2, logoY)

  # mouse
  let (mx,my) = mouse()
  setColor(1)
  circfill(mx, my, 2)
  setColor(21)
  circfill(mx, my, 1)


nico.init("impbox", "ld41")

loadConfig()

loadPaletteFromGPL("palette.gpl")
palt(26,false)
palt(0,true)
loadSpritesheet(0, "spritesheet.png", 8, 8)
setSpritesheet(0)

loadFont(0, "font.png")
setFont(0)

#fixedSize(true)
#integerScale(true)
nico.createWindow("ld41", 1920 div 4 , 1080 div 4, 3)
nico.run(gameInit, gameUpdate, gameDraw)
