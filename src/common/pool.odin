package common

import "intrinsics"
import "core:sync"
import "core:mem"
import "core:thread"

Task_Status :: enum i32 {
	Ready,
	Busy,
	Waiting,
	Term,
}

Task_Proc :: proc(task: ^Task);

Task :: struct {
	procedure:  Task_Proc,
	data:       rawptr,
	user_index: int,
}

Task_Id         :: distinct i32;
INVALID_TASK_ID :: Task_Id(-1);

Pool :: struct {
	allocator:             mem.Allocator,
	mutex:                 sync.Mutex,
	sem_available:         sync.Semaphore,
	processing_task_count: int, // atomic
	is_running:            bool,
	threads:               []^thread.Thread,
	tasks:                 [dynamic]Task,
}

pool_init :: proc(pool: ^Pool, thread_count: int, allocator := context.allocator) {
	worker_thread_internal :: proc(t: ^thread.Thread) {
		pool := (^Pool)(t.data);

		temp_allocator: Scratch_Allocator;

		scratch_allocator_init(&temp_allocator, mem.megabytes(6));

		context.temp_allocator = scratch_allocator(&temp_allocator);

		for pool.is_running {
			sync.semaphore_wait_for(&pool.sem_available);

			if task, ok := pool_try_and_pop_task(pool); ok {
				pool_do_work(pool, &task);
			}

			free_all(context.temp_allocator);
		}

		scratch_allocator_destroy(&temp_allocator);

		sync.semaphore_post(&pool.sem_available, 1);
	};

	context.allocator = allocator;
	pool.allocator    = allocator;
	pool.tasks        = make([dynamic]Task);
	pool.threads      = make([]^thread.Thread, thread_count);

	sync.mutex_init(&pool.mutex);
	sync.semaphore_init(&pool.sem_available);
	pool.is_running = true;

	for _, i in pool.threads {
		t := thread.create(worker_thread_internal);
		t.user_index    = i;
		t.data          = pool;
		pool.threads[i] = t;
	}
}

pool_destroy :: proc(pool: ^Pool) {
	delete(pool.tasks);

	for t in &pool.threads {
		thread.destroy(t);
	}

	delete(pool.threads, pool.allocator);

	sync.mutex_destroy(&pool.mutex);
	sync.semaphore_destroy(&pool.sem_available);
}

pool_start :: proc(pool: ^Pool) {
	for t in pool.threads {
		thread.start(t);
	}
}

pool_join :: proc(pool: ^Pool) {
	pool.is_running = false;

	sync.semaphore_post(&pool.sem_available, len(pool.threads));

	thread.yield();

	for t in pool.threads {
		thread.join(t);
	}
}

pool_add_task :: proc(pool: ^Pool, procedure: Task_Proc, data: rawptr, user_index: int = 0) {
	sync.mutex_lock(&pool.mutex);
	defer sync.mutex_unlock(&pool.mutex);

	task: Task;
	task.procedure  = procedure;
	task.data       = data;
	task.user_index = user_index;

	append(&pool.tasks, task);
	sync.semaphore_post(&pool.sem_available, 1);
}

pool_try_and_pop_task :: proc(pool: ^Pool) -> (task: Task, got_task: bool = false) {
	if sync.mutex_try_lock(&pool.mutex) {
		if len(pool.tasks) != 0 {
			intrinsics.atomic_add(&pool.processing_task_count, 1);
			task     = pop_front(&pool.tasks);
			got_task = true;
		}
		sync.mutex_unlock(&pool.mutex);
	}
	return;
}

pool_do_work :: proc(pool: ^Pool, task: ^Task) {
	task.procedure(task);
	intrinsics.atomic_sub(&pool.processing_task_count, 1);
}

pool_wait_and_process :: proc(pool: ^Pool) {
	for len(pool.tasks) != 0 || intrinsics.atomic_load(&pool.processing_task_count) != 0 {
		if task, ok := pool_try_and_pop_task(pool); ok {
			pool_do_work(pool, &task);
		}

		// Safety kick
		if len(pool.tasks) != 0 && intrinsics.atomic_load(&pool.processing_task_count) == 0 {
			sync.mutex_lock(&pool.mutex);
			sync.semaphore_post(&pool.sem_available, len(pool.tasks));
			sync.mutex_unlock(&pool.mutex);
		}

		thread.yield();
	}

	pool_join(pool);
}
