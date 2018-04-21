import deques
import nico.vec

type Hitbox* = tuple
  x,y,w,h: int

type Tile* = tuple
  x,y: int
  t: uint8

type Tilemap* = seq[seq[int]]



type Boid* = ref object
  toKill*: bool
  hitbox*: Hitbox
  id*: int
  pos*: Vec2f
  ipos*: Vec2i
  vel*: Vec2f
  rem*: Vec2f
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

type Card* = ref object of RootObj
  down*: bool
  cost*: int
  bought*: bool
  selected*: bool

type TileCard* = ref object of Card
  data*: array[5*5, uint8]
  rotation*: range[0..3]

type ActionCard* = ref object of Card
type UpgradeCard* = ref object of Card

type Pile* = ref object
  label*: string
  cards*: Deque[Card]
