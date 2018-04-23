import deques
import nico.vec

type Hitbox* = tuple
  x,y,w,h: int

type Tile* = tuple
  x,y: int
  t: uint8

type Tilemap* = seq[seq[int]]

type Movable* = ref object of RootObj
  vel*: Vec2f
  ipos*: Vec2i
  pos*: Vec2f
  rem*: Vec2f
  hitbox*: Hitbox

type Bullet* = ref object of Movable
  ttl*: float32
  damage*: int

type Server* = ref object
  pos*: Vec2i
  health*: int
  reachable*: bool
  infected*: bool

type Entrance* = ref object
  pos*: Vec2i
  connected*: bool
  servers*: seq[Server]
  myServer*: Server

type Boid* = ref object of Movable
  id*: int
  ttl*: float32
  evil*: bool
  distTravelled*: float32
  frame*: int
  goal*: Server
  steering*: Vec2f
  angle*: float32
  mass*: float32
  cohesion*: float32
  cohesionRadius*: float32
  separation*: float32
  separationRadius*: float32
  alignment*: float32
  maxForce*: float32
  maxSpeed*: float32
  shootTimeout*: float32
  health*: int
  repathTimeout*: float32
  route*: seq[Vec2f]
  routeIndex*: int

type Turret* = ref object of RootObj
  level*: int
  pos*: Vec2i
  rechargeTimer*: float32
  rechargeTime*: float32
  damage*: int
  health*: int
  radius*: float32
  target*: Boid

type Card* = ref object of RootObj
  pos*: Vec2f
  down*: bool
  cost*: int
  bought*: bool
  selected*: bool

type CardMove* = ref object
  c*: Card
  completed*: bool
  source*: Vec2f
  dest*: Vec2f
  time*: float32
  alpha*: float32
  onComplete*: proc(cm: CardMove)

type TileCard* = ref object of Card
  data*: array[5*5, uint8]
  rotation*: range[0..3]

type ActionCard* = ref object of Card
  playOnField*: bool
  action*: proc(x,y: int): bool
  title*: string
  desc*: string
  playOnServer*: bool

type Pile* = ref object
  pos*: Vec2f
  label*: string
  cards*: Deque[Card]
