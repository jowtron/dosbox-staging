// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "scheduler.h"

#include <queue>
#include <unordered_set>
#include <vector>

namespace Scheduler {

namespace {

struct Event {
	double        deadline_ms{0.0};
	EventHandle   handle{InvalidHandle};
	EventCallback callback{nullptr};  // non-null = PIC-style; identity via fn ptr
	uint32_t      val{0};
	Handler fn = {}; // populated when callback is null

	bool operator>(const Event& other) const
	{
		return deadline_ms > other.deadline_ms;
	}
};

std::priority_queue<Event, std::vector<Event>, std::greater<>> queue;
std::unordered_set<EventHandle>                                cancelled;

double      clock_now_ms = 0.0;
EventHandle next_handle  = 1;  // 0 is InvalidHandle

}  // namespace

void AddEvent(const EventCallback fn, const double delay_ms, const uint32_t val)
{
	Event e;
	e.deadline_ms = clock_now_ms + delay_ms;
	e.handle      = next_handle++;
	e.callback    = fn;
	e.val         = val;
	queue.push(std::move(e));
}

void RemoveEvents(const EventCallback fn)
{
	// priority_queue lacks in-place iteration; drain, drop matches, push back.
	std::vector<Event> kept;
	kept.reserve(queue.size());
	while (!queue.empty()) {
		auto e = queue.top();
		queue.pop();
		if (e.callback != fn) {
			kept.push_back(std::move(e));
		}
	}
	for (auto& e : kept) {
		queue.push(std::move(e));
	}
}

EventHandle AddEvent(Handler fn, const double delay_ms)
{
	Event e;
	e.deadline_ms = clock_now_ms + delay_ms;
	e.handle      = next_handle++;
	e.fn          = std::move(fn);
	queue.push(std::move(e));
	return e.handle;
}

void RemoveEvent(const EventHandle handle)
{
	if (handle == InvalidHandle) {
		return;
	}
	cancelled.insert(handle);
}

double Now()
{
	return clock_now_ms;
}

void AdvanceTo(const double absolute_time_ms)
{
	if (absolute_time_ms < clock_now_ms) {
		return;
	}
	while (!queue.empty() && queue.top().deadline_ms <= absolute_time_ms) {
		auto e = queue.top();
		queue.pop();
		clock_now_ms = e.deadline_ms;

		if (cancelled.erase(e.handle)) {
			continue;
		}
		if (e.callback) {
			e.callback(e.val);
		} else if (e.fn) {
			e.fn();
		}
	}
	clock_now_ms = absolute_time_ms;
}

void AdvanceBy(const double delta_ms)
{
	// Fired events mutate emulator state (vga.draw,
	// render.render_in_progress, scanout addresses); we deliberately don't
	// snapshot/restore that, so the queue is left in its post-AdvanceBy
	// state and stays consistent with the mutated state on resume.
	// Pause-time AdvanceBy may therefore shift capture timing by one frame;
	// bit-identical capture is preserved across passive pause/unpause
	// cycles (no AdvanceBy runs).
	AdvanceTo(clock_now_ms + delta_ms);
}

}  // namespace Scheduler
