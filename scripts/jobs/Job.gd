class_name Job
extends RefCounted

## A single unit of work to be performed by a pawn at a specific tile.
## Jobs are created by game systems (world generation, designations, events),
## posted to JobManager, claimed by idle pawns, and retired on completion.

enum Type {
	FORAGE,     # harvest a FERTILE_SOIL tile -> berry (food)
	MINE,       # mine an ORE_VEIN tile       -> stone (and clears the feature)
	MINE_WALL,  # mine a MOUNTAIN edge tile   -> stone, converts tile to STONE_FLOOR
	CHOP,       # chop a TREE tile            -> wood (and clears the feature)
	HUNT,       # hunt a RABBIT/DEER tile     -> meat (clears the feature; respawns)
	BUILD_BED,  # consume 1 wood, place a BED feature on the target tile
	BUILD_WALL, # consume 2 wood, place a WALL feature, marks tile impassable
	BUILD_DOOR, # consume 1 wood, place a DOOR feature (passable)
}

enum State {
	OPEN,       # not yet assigned
	CLAIMED,    # a pawn is walking to or performing this job
	COMPLETED,  # finished successfully
	CANCELLED,  # aborted (e.g. tile became impassable, world regen, pawn died)
}

var id: int = 0
var type: int = Type.FORAGE

## Target tile: the thing being worked on (feature tile). May be impassable
## (e.g. an ore vein on a mountain).
var tile: Vector2i = Vector2i.ZERO

## Where the pawn actually stands while performing the work. For FORAGE this
## equals `tile`; for MINE it's an adjacent passable neighbor.
var work_tile: Vector2i = Vector2i.ZERO

## Higher priority jobs are claimed first. Default 0; food runs can use higher.
var priority: int = 0

## Ticks of work the pawn must spend ON the target tile to finish. Move time
## is separate; this is only the "doing the thing" phase.
var work_ticks_needed: int = 20
var work_ticks_done: int = 0

var state: int = State.OPEN
var assigned_pawn: Pawn = null


static func describe_type(t: int) -> String:
	match t:
		Type.FORAGE:     return "Forage"
		Type.MINE:       return "Mine"
		Type.MINE_WALL:  return "MineWall"
		Type.CHOP:       return "Chop"
		Type.HUNT:       return "Hunt"
		Type.BUILD_BED:  return "BuildBed"
		Type.BUILD_WALL: return "BuildWall"
		Type.BUILD_DOOR: return "BuildDoor"
	return "Unknown"


static func describe_state(s: int) -> String:
	match s:
		State.OPEN:      return "open"
		State.CLAIMED:   return "claimed"
		State.COMPLETED: return "completed"
		State.CANCELLED: return "cancelled"
	return "?"


func describe() -> String:
	return "Job#%d %s target=(%d,%d) work=(%d,%d) %s p=%d (%d/%d)" % [
		id, describe_type(type), tile.x, tile.y, work_tile.x, work_tile.y,
		describe_state(state), priority, work_ticks_done, work_ticks_needed
	]
