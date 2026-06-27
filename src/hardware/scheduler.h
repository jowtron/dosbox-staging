// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_SCHEDULER_H
#define DOSBOX_SCHEDULER_H

#include <cstdint>
#include <functional>

// Emulator-time scheduler, decoupled from the 8259 PIC.
//
// Background. The 8259 Programmable Interrupt Controller is the real PC
// chip that arbitrates device IRQ lines (timer, keyboard, COM ports, etc.)
// into the CPU's INT pin. DOSBox emulates the 8259's interrupt routing,
// but the same primitive (`PIC_AddEvent` + `PIC_RunQueue`, and the related
// `TIMER_AddTickHandler`) doubles as a general-purpose emulator-time event
// queue for things that have nothing to do with hardware interrupts:
//
//   - VGA scanout: vertical retrace timer, per-scanline draws, latches
//   - Audio chip ticks: Sound Blaster, GUS, AdLib, PC speaker, Tandy/PS-1
//     (via `TIMER_AddTickHandler`)
//   - NE2000 network polling
//   - ReelMagic MPEG advance
//   - IDE delayed command completion
//
// None of these involve the 8259; they ride PIC's queue because it was
// the existing scheduling primitive. The coupling has two costs:
//
//   1. PIC time and "emulator-internal time" can't be teased apart. The
//      pause path freezes PIC time so the CPU stops -- which by accident
//      also freezes VGA, audio chips, NE2000, ReelMagic, IDE. There's no
//      way to advance one of these without advancing PIC and the CPU
//      with it.
//
//   2. The 8259 emulation code is intertwined with timing concerns it has
//      no business knowing about. Cleaning up the 8259 model (or porting
//      it, or instrumenting it) means picking through unrelated callers.
//
// This Scheduler provides an alternative queue with the same surface area
// as PIC's (function-pointer events, ms-resolution deadlines, bulk
// cancellation by handler) but its own clock that can be driven
// independently. Today only VGA migrates; the rest are TODOs at their
// `PIC_AddEvent` / `TIMER_AddTickHandler` call sites (see pic-plan.md).
//
// The clock runs in milliseconds and is driven by `AdvanceTo` from
// `normal_loop`, kept in lockstep with `PIC_FullIndex()` during normal
// operation. During pause we can advance it explicitly without
// un-pausing the CPU -- e.g. to re-render a VGA frame after the
// auto-shader switcher changes scan-doubling.

namespace Scheduler {

using EventHandle = uint64_t;
inline constexpr EventHandle InvalidHandle = 0;

// PIC-compatible: function pointer with optional uint32 user data.
// Cancellable in bulk by the function pointer.
using EventCallback = void (*)(uint32_t val);

// Lambda-capable: one-off events; cancellable only by handle.
using Handler = std::function<void()>;

void AddEvent(EventCallback fn, double delay_ms, uint32_t val = 0);
void RemoveEvents(EventCallback fn);

EventHandle AddEvent(Handler fn, double delay_ms);
void RemoveEvent(EventHandle handle);

// Current scheduler-time in ms.
double Now();

// Advance the clock to `absolute_time_ms`, firing any events whose
// deadline is at or before that point. Called from `normal_loop` with
// `PIC_FullIndex()` so the two clocks stay in sync during normal
// operation.
void AdvanceTo(double absolute_time_ms);

// Drive forward until VGA emits a frame-complete signal. Used during
// pause to refresh the held framebuffer after a scan-doubling change.
// Stub until VGA migration wires the signal up.
void TickUntilVgaFrameComplete();

}  // namespace Scheduler

#endif
