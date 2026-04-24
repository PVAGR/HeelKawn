extends Node

## Global priority-ordered job queue. Any system can post jobs; any idle pawn
## can claim the best-fitting one. Kept deliberately simple (O(N) scans) while
## the total job count is small (<= ~1000). Swap to a heap once we need to.

signal job_posted(job: Job)
signal job_claimed(job: Job, pawn: Pawn)
signal job_completed(job: Job)
signal job_cancelled(job: Job)

var _next_id: int = 1

## All currently-known, non-retired jobs.
var _open: Array[Job] = []
var _claimed: Array[Job] = []

## tile(Vector2i) -> Job. Prevents posting two jobs on the same tile.
var _jobs_by_tile: Dictionary = {}

## Lifetime counters (stats only).
var posted_count: int = 0
var completed_count: int = 0
var cancelled_count: int = 0


## Create-and-post helper: returns the new Job (or null if the tile already has one).
## work_tile defaults to `tile`; callers that need a different standing tile
## (e.g. MINE on an impassable mountain) should set job.work_tile after posting.
func post(type: int, tile: Vector2i, priority: int = 0, work_ticks: int = 20) -> Job:
	if _jobs_by_tile.has(tile):
		return null
	var job := Job.new()
	job.id = _next_id
	_next_id += 1
	job.type = type
	job.tile = tile
	job.work_tile = tile
	job.priority = priority
	job.work_ticks_needed = work_ticks
	job.state = Job.State.OPEN
	_open.append(job)
	_jobs_by_tile[tile] = job
	posted_count += 1
	job_posted.emit(job)
	return job


## Return the best open job for this pawn, or null. "Best" = highest priority
## (plus optional `priority_bonus` offset), then Chebyshev distance. `filter`
## rejects ineligible jobs; `priority_bonus` can bias toward colony labor stance.
func claim_next_for(
		pawn: Pawn, filter: Callable = Callable(), priority_bonus: Callable = Callable()
	) -> Job:
	var pd: PawnData = pawn.get_pawn_data() if pawn != null else null
	if _open.is_empty() or pawn == null or pd == null:
		return null
	var pawn_tile: Vector2i = pd.tile_pos
	var best_idx: int = -1
	var best_eff: int = -0x7FFFFFFF
	var best_dist: int = 0x7FFFFFFF
	for i in range(_open.size()):
		var j: Job = _open[i]
		if filter.is_valid() and not filter.call(j):
			continue
		var bonus: int = 0
		if priority_bonus.is_valid():
			bonus = int(priority_bonus.call(j))
		var eff: int = j.priority + bonus
		var d: int = _chebyshev(pawn_tile, j.work_tile)
		if eff > best_eff or (eff == best_eff and d < best_dist):
			best_idx = i
			best_eff = eff
			best_dist = d
	if best_idx < 0:
		return null
	var job: Job = _open[best_idx]
	_open.remove_at(best_idx)
	_claimed.append(job)
	job.state = Job.State.CLAIMED
	job.assigned_pawn = pawn
	job_claimed.emit(job, pawn)
	return job


## Pawn gave up on a job (couldn't reach it, or was freed). Puts it back in
## the open queue so another pawn can claim. Resets work progress.
func abandon(job: Job) -> void:
	if job == null:
		return
	if not _claimed.has(job):
		return
	_claimed.erase(job)
	job.state = Job.State.OPEN
	job.assigned_pawn = null
	job.work_ticks_done = 0
	_open.append(job)


## Mark a job finished. Removes it from the claimed list and drops its tile lock.
func complete(job: Job) -> void:
	if job == null:
		return
	_claimed.erase(job)
	_jobs_by_tile.erase(job.tile)
	job.state = Job.State.COMPLETED
	completed_count += 1
	job_completed.emit(job)
	# NOTE: `BUILD_WALL` path reservation is cleared in `World.build_wall` when
	# the feature is committed — not here (job may complete without build on edge cases).


## Abort a job. Useful if the target becomes invalid, the pawn dies, or the world
## is regenerated. Idempotent -- calling cancel() on an already-retired job is
## a no-op, so "two owners both call cancel" (clear_all + pawn.release) is safe.
func cancel(job: Job) -> void:
	if job == null or job.state == Job.State.CANCELLED or job.state == Job.State.COMPLETED:
		return
	_open.erase(job)
	_claimed.erase(job)
	_jobs_by_tile.erase(job.tile)
	_notify_path_reservation_released(job)
	job.state = Job.State.CANCELLED
	job.assigned_pawn = null
	cancelled_count += 1
	job_cancelled.emit(job)


## Cancel every job. Called when the world is regenerated so we don't keep
## jobs pointing at tiles whose features no longer exist.
func clear_all() -> void:
	var all: Array[Job] = []
	all.append_array(_open)
	all.append_array(_claimed)
	_open.clear()
	_claimed.clear()
	_jobs_by_tile.clear()
	for j in all:
		_notify_path_reservation_released(j)
		j.state = Job.State.CANCELLED
		j.assigned_pawn = null
		cancelled_count += 1
		job_cancelled.emit(j)


func open_count() -> int:
	return _open.size()


func claimed_count() -> int:
	return _claimed.size()


## True if there is already a job (open or claimed) at this tile. Used by
## reactive job seeders to avoid duplicate posts.
func has_job_at(tile: Vector2i) -> bool:
	return _jobs_by_tile.has(tile)


## Count of currently-active (open + claimed) jobs of a given type.
func active_count_of_type(type: int) -> int:
	var n: int = 0
	for j in _open:
		if j.type == type:
			n += 1
	for j in _claimed:
		if j.type == type:
			n += 1
	return n


func stats() -> Dictionary:
	return {
		"open":       _open.size(),
		"claimed":    _claimed.size(),
		"posted":     posted_count,
		"completed":  completed_count,
		"cancelled":  cancelled_count,
	}


## Dump the queue state + first N open jobs. Hotkeyed to J in Main.gd.
func print_debug(max_rows: int = 10) -> void:
	var s := stats()
	print("[Jobs] open=%d claimed=%d  (posted=%d completed=%d cancelled=%d)" % [
		s.open, s.claimed, s.posted, s.completed, s.cancelled
	])
	var shown: int = 0
	for j in _open:
		if shown >= max_rows:
			break
		print("[Jobs]   %s" % j.describe())
		shown += 1
	for j in _claimed:
		if shown >= max_rows * 2:
			break
		var who: String = j.assigned_pawn.get_pawn_name_for_log() if j.assigned_pawn else "?"
		print("[Jobs]   %s  <- %s" % [j.describe(), who])
		shown += 1


static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return max(abs(a.x - b.x), abs(a.y - b.y))


## `abandon` keeps the open job: construction reservations on tiles stay. Only
## a full `cancel` (no longer any job) releases them.
func _notify_path_reservation_released(j: Job) -> void:
	if j == null or j.type != Job.Type.BUILD_WALL:
		return
	var tr: SceneTree = get_tree()
	if tr == null:
		return
	for w in tr.get_nodes_in_group("colony_world"):
		if w is World:
			(w as World).on_construction_path_job_ended(j)
			return
