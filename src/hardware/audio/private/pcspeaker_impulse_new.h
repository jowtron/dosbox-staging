// SPDX-FileCopyrightText:  2025 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_PCSPEAKER_IMPULSE_NEW_H
#define DOSBOX_PCSPEAKER_IMPULSE_NEW_H

// Comment out to use the reference implementation.
#define USE_LOOKUP_TABLES 1

#include "pcspeaker.h"
#include "pcspeaker_pit.h"

#ifdef USE_LOOKUP_TABLES
#include <array>
#endif
#include <deque>
#include <string>

#include "audio/channel_names.h"
#include "config/setup.h"
#include "hardware/pic.h"
#include "hardware/port.h"
#include "misc/support.h"
#include "utils/math_utils.h"

class PcSpeakerImpulse final : public PcSpeaker {
public:
	PcSpeakerImpulse();
	~PcSpeakerImpulse() override;

	void SetFilterState(const FilterState filter_state) override;
	bool TryParseAndSetCustomFilter(const std::string& filter_choice) override;
	void SetCounter(const int cntr, const PitMode pit_mode) override;
	void SetPITControl(const PitMode pit_mode) override;
	void SetType(const PpiPortB& port_b) override;
	void PicCallback(const int requested_frames) override;

private:
	void AddImpulse(float index, int16_t amplitude);
	float CalcImpulse(double t) const;
#ifdef USE_LOOKUP_TABLES
	void InitializeLut();
#endif
	void ApplyTransitions(const std::vector<PitCounter::Transition>& transitions,
	                      float index_base, bool speaker_enabled);

	// Wake, advance the PIT to the current position within this 1ms tick,
	// emitting any transitions that occurred since the last sync. Returns the
	// new position (PIC_TickIndex). Shared preamble of the public entry points.
	float SyncPitToTick();

	// Output amplitude for a given speaker-enable and PIT output level.
	static int16_t OutputAmplitude(bool speaker_enabled, bool output);

	// Wake the channel and reset dedup state if we were sleeping. While
	// asleep the mixer emits silence, so prev_amplitude must be reset to
	// neutral on wake or AddImpulse may dedup-skip a legitimate emission.
	// Call at the top of any public entry point that may produce impulses.
	void HandleWakeUp();

	static constexpr auto device_name = ChannelName::PcSpeaker;
	static constexpr auto model_name  = "impulse";

	// Amplitude: manually tuned to roughly match hardware voltage levels.
	// Ref:
	// https://github.com/dosbox-staging/dosbox-staging/files/9494469/3.audio.samples.zip
	static constexpr float pwm_scalar = 0.5f;

	static constexpr int16_t positive_amplitude = static_cast<int16_t>(
	        Max16BitSampleValue * pwm_scalar);
	static constexpr int16_t negative_amplitude = -positive_amplitude;
	static constexpr int16_t neutral_amplitude  = 0;

	// Fixed sample rate; must be a multiple of 1000 so each 1ms PIC callback
	// produces an exact integer number of samples (sample_rate_hz / 1000).
	static constexpr auto sample_rate_hz     = 48000;
	static constexpr auto sample_rate_per_ms = sample_rate_hz / 1000;

	// Minimum PIT count representable at this sample rate (Nyquist)
	static constexpr auto minimum_counter = ceil_sdivide(2 * PIT_TICK_RATE,
	                                                     sample_rate_hz);

	// Reference sample rate of the original impulse model; the cutoff
	// frequency is kept constant (not scaled with sample_rate_hz) so the
	// two models are tonally equivalent.
	static constexpr auto reference_sample_rate_hz = 32000.0;
	static constexpr auto reference_cutoff_margin  = 0.2;
	static constexpr auto cutoff_margin = (sample_rate_hz /
	                                       reference_sample_rate_hz) *
	                                              (2.0 + reference_cutoff_margin) -
	                                      2.0;

	static constexpr float sinc_amplitude_fade = 0.999f;

	// Keep the same 3.125 ms impulse span as the former 32 kHz /
	// 100-tap configuration.
	static constexpr auto sinc_filter_duration_us = 3125;
	static constexpr auto sinc_filter_quality =
	        ceil_sdivide(sample_rate_hz * sinc_filter_duration_us, 1'000'000);

#ifdef USE_LOOKUP_TABLES
	static constexpr auto sinc_oversampling_factor = 32;
	static constexpr auto sinc_lut_size = sinc_filter_quality *
	                                      sinc_oversampling_factor;
#endif

	// Undersampled mode 3: rapid reloads used as a noise source
	static constexpr float max_undersampled_reload_gap_ms = 1.0f;

	PitCounter pit_counter = {};

	// Waveform accumulation buffer; large enough for one ms plus sinc tail
	static constexpr auto waveform_size = sinc_filter_quality + sample_rate_per_ms;
	std::deque<float> waveform = {};

#ifdef USE_LOOKUP_TABLES
	std::array<float, sinc_lut_size> impulse_lut = {};
#endif

	// Position within current tick advanced so far (ms, 0..1)
	float pit_last_index = 0.0f;

	// Running amplitude integrator
	float accumulator = 0.0f;

	// Silence tracking for channel sleep
	int tally_of_silence = 0;

	// Port B state (speaker_output + timer2_gating)
	PpiPortB port_b = {};

	// Undersampled mode 3 reload tracking
	bool have_undersampled_reload = false;
	float undersampled_reload_ms  = 0.0f;

	// Amplitude at last impulse (for same-amplitude deduplication)
	int16_t prev_amplitude = neutral_amplitude;
};

#endif // DOSBOX_PCSPEAKER_IMPULSE_NEW_H
