// SPDX-FileCopyrightText:  2025 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_PCSPEAKER_PIT_H
#define DOSBOX_PCSPEAKER_PIT_H

#include "hardware/timer.h"

#include <vector>

// Pure hardware emulation of PIT counter 2 as wired to the PC speaker.
//
// Tracks output transitions in continuous time (milliseconds). Callers drive
// it with WriteControl / WriteCount / SetGate, interleaved with Advance()
// calls to collect the transitions that occurred during each time window.
//
// All timestamps in Transition are relative to the start of the Advance() call
// that produced them.
class PitCounter {
public:
	struct Transition {
		float time_ms = 0.0f;
		bool output   = false; // true = HIGH, false = LOW
	};

	// Control word written. Output changes immediately; no count loaded yet.
	std::vector<Transition> WriteControl(PitMode mode);

	// Count register written. May start counting depending on mode + gate.
	std::vector<Transition> WriteCount(int count);

	// Gate signal changed (port B bit 0).
	std::vector<Transition> SetGate(bool gate);

	// Advance by duration_ms, returning transitions that occurred within.
	std::vector<Transition> Advance(float duration_ms);

	// Stop counting without changing mode. Used when a count arrives that
	// can't be represented (e.g. ultrasonic mode 3 reload).
	void Invalidate();

	bool GetOutput() const
	{
		return output_high;
	}
	PitMode GetMode() const
	{
		return mode;
	}
	bool GetMode3Active() const
	{
		return mode3_active;
	}
	bool GetGate() const
	{
		return gate;
	}

private:
	void Emit(bool hi, float time_ms, std::vector<Transition>& out);

	// Per-mode Advance() helpers (dispatched on the canonical mode).
	void AdvanceCountdown(float passed, std::vector<Transition>& out);
	void AdvanceStrobe(float passed, std::vector<Transition>& out);
	void AdvanceOscillator(float passed, std::vector<Transition>& out, bool square);

	// Modes 6 and 7 are hardware aliases of modes 2 and 3; fold them so the
	// rest of the class only ever deals with RateGenerator / SquareWave.
	static PitMode Canonical(PitMode m);

	static constexpr float ms_per_tick   = 1000.0f / PIT_TICK_RATE;
	static constexpr float max_period_ms = ms_per_tick * 0x10000;

	PitMode mode     = PitMode::SquareWave;
	bool gate        = false;
	bool output_high = true;
	bool counting    = false;

	float phase_ms      = 0.0f;
	float period_ms     = max_period_ms;
	float half_ms       = max_period_ms / 2.0f;
	float new_period_ms = max_period_ms;
	float new_half_ms   = max_period_ms / 2.0f;

	// Mode 1 (OneShot)
	bool mode1_awaiting_count   = false;
	bool mode1_awaiting_trigger = false;
	float mode1_pending_ms      = 0.0f;

	// Mode 3 (SquareWave): gate must have been high to begin oscillating
	bool mode3_active = false;
	// Set by Invalidate() so WriteCount can resume without resetting phase
	bool mode3_retain_phase = false;
};

#endif // DOSBOX_PCSPEAKER_PIT_H
