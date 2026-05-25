// SPDX-FileCopyrightText:  2025 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "private/pcspeaker_impulse_new.h"

#include <algorithm>
#include <cmath>

#include "utils/checks.h"

CHECK_NARROWING();

#if 0
#define SPKR_DEBUGGING 1
#endif

// Unnormalized sinc: sinc(0) = 1, sinc(x) = sin(x)/x
static constexpr double sinc(const double x)
{
	if (x == 0.0) {
		return 1.0;
	}
	return std::sin(x) / x;
}

float PcSpeakerImpulse::CalcImpulse(const double t) const
{
	// Raised-cosine-windowed sinc, identical to the impulse model
	constexpr double fs = sample_rate_hz;
	constexpr double fc = fs / (2.0 + cutoff_margin);
	constexpr double q  = static_cast<double>(sinc_filter_quality);
	float res           = 0.0f;

	if ((0 < t) && (t * fs < q)) {
		constexpr auto midpoint = q / (2.0 * fs);
		const auto window = 1.0 +
		                    std::cos(2.0 * fs * M_PI * (midpoint - t) / q);
		const auto amplitude = window *
		                       sinc(2.0 * fc * M_PI * (t - midpoint)) / 2.0;
		res = static_cast<float>(amplitude);
	}

	return res;
}

void PcSpeakerImpulse::HandleWakeUp()
{
	if (channel->WakeUp()) {
		prev_amplitude = neutral_amplitude;
	}
}

#ifdef USE_LOOKUP_TABLES
void PcSpeakerImpulse::InitializeLut()
{
	for (size_t i = 0; i < impulse_lut.size(); ++i) {
		impulse_lut[i] = CalcImpulse(static_cast<double>(i) /
		                             (static_cast<double>(sample_rate_hz) *
		                              sinc_oversampling_factor));
	}
}
#endif

void PcSpeakerImpulse::AddImpulse(const float index, const int16_t amplitude)
{
	if (amplitude == prev_amplitude) {
		return;
	}
	prev_amplitude = amplitude;

	const auto clamped = std::clamp(index, 0.0f, 1.0f);

#ifdef USE_LOOKUP_TABLES
	const auto base = static_cast<double>(clamped) * sample_rate_per_ms;
	const auto phase_raw = static_cast<int>(base * sinc_oversampling_factor) %
	                       sinc_oversampling_factor;
	const auto offset = static_cast<int>(base) + (phase_raw != 0 ? 1 : 0);
	const auto phase = (phase_raw != 0) ? (sinc_oversampling_factor - phase_raw)
	                                    : 0;
	const auto k_start = (phase_raw == 0) ? 1 : 0;
	const auto k_end = std::min(sinc_filter_quality,
	                            static_cast<int>(waveform.size()) - offset);

	for (auto k = k_start; k < k_end; ++k) {
		waveform[static_cast<size_t>(offset) + static_cast<size_t>(k)] +=
		        amplitude *
		        impulse_lut[static_cast<size_t>(phase) +
		                    static_cast<size_t>(k) * static_cast<size_t>(sinc_oversampling_factor)];
	}
#else
	const auto portion_of_ms = static_cast<double>(clamped) / MillisInSecond;

	for (size_t i = 0; i < waveform.size(); ++i) {
		const auto impulse_time = static_cast<double>(i) / sample_rate_hz -
		                          portion_of_ms;
		waveform[i] += amplitude * CalcImpulse(impulse_time);
	}
#endif
}

int16_t PcSpeakerImpulse::OutputAmplitude(const bool speaker_enabled, const bool output)
{
	if (!speaker_enabled) {
		return negative_amplitude;
	}
	return output ? positive_amplitude : negative_amplitude;
}

void PcSpeakerImpulse::ApplyTransitions(const std::vector<PitCounter::Transition>& transitions,
                                        const float index_base,
                                        const bool speaker_enabled)
{
	for (const auto& t : transitions) {
		const auto index = index_base + t.time_ms;
		AddImpulse(index, OutputAmplitude(speaker_enabled, t.output));
	}
}

float PcSpeakerImpulse::SyncPitToTick()
{
	HandleWakeUp();

	const auto index = static_cast<float>(PIC_TickIndex());
	const auto delta = index - pit_last_index;
	if (delta > 0.0f) {
		const auto t = pit_counter.Advance(delta);
		ApplyTransitions(t, pit_last_index, port_b.speaker_output);
	}
	pit_last_index = index;
	return index;
}

// Control word written (timer.cpp calls this before SetCounter when mode changes)
void PcSpeakerImpulse::SetPITControl(const PitMode pit_mode)
{
#ifdef SPKR_DEBUGGING
	LOG_INFO("SPKR: %.3f ctrl=%s gate=%d m3=%d spk=%d",
	         PIC_FullIndex(),
	         pit_mode_to_string(pit_mode),
	         pit_counter.GetGate(),
	         pit_counter.GetMode3Active(),
	         (int)port_b.speaker_output);
#endif
	const auto index = SyncPitToTick();

	const auto t = pit_counter.WriteControl(pit_mode);
	ApplyTransitions(t, index, port_b.speaker_output);
}

// Count register written
void PcSpeakerImpulse::SetCounter(const int cntr, const PitMode pit_mode)
{
#ifdef SPKR_DEBUGGING
	LOG_INFO("SPKR: %.3f cntr=%d mode=%s gate=%d m3=%d spk=%d under=%d",
	         PIC_FullIndex(),
	         cntr,
	         pit_mode_to_string(pit_mode),
	         pit_counter.GetGate(),
	         pit_counter.GetMode3Active(),
	         (int)port_b.speaker_output,
	         (int)have_undersampled_reload);
#endif
	const auto index = SyncPitToTick();

	const bool is_square = (pit_mode == PitMode::SquareWave ||
	                        pit_mode == PitMode::SquareWaveAlias);

	if (is_square && cntr > 0 && cntr < minimum_counter) {
		// Counter is too high-frequency to represent at our sample
		// rate. Rapid reloads of undersampled counts are used by some
		// programs as a noise source; toggle amplitude for each such
		// reload.
		const auto now_ms = static_cast<float>(PIC_FullIndex());
		const auto previous_reload_gap_ms = now_ms - undersampled_reload_ms;
		const auto is_rapid_reload = have_undersampled_reload &&
		                             previous_reload_gap_ms >= 0.0f &&
		                             previous_reload_gap_ms <=
		                                     max_undersampled_reload_gap_ms;

		if (port_b.timer2_gating_and_speaker_out.all() && is_rapid_reload) {
			// Toggle — emit whatever the opposite of current output is
			const int16_t toggled = (prev_amplitude == positive_amplitude)
			                              ? negative_amplitude
			                              : positive_amplitude;
			AddImpulse(index, toggled);
		}

		// Stop the PIT from producing further output at the old
		// frequency. Without this, Advance() keeps oscillating at the
		// prior valid period.
		pit_counter.Invalidate();

		have_undersampled_reload = true;
		undersampled_reload_ms   = now_ms;
		return;
	}

	have_undersampled_reload = false;

	const auto t = pit_counter.WriteCount(cntr);
	ApplyTransitions(t, index, port_b.speaker_output);

	// If a gate-rising edge was suppressed while in undersampled state,
	// pit_counter.gate is still false. Sync it now so oscillation can start.
	// In the normal path (gate already synced), SetGate(true) is a no-op.
	if (port_b.timer2_gating) {
		const auto gate_t = pit_counter.SetGate(true);
		ApplyTransitions(gate_t, index, port_b.speaker_output);
	}

#ifdef SPKR_DEBUGGING
	LOG_INFO("SPKR: %.3f cntr=%d -> gate=%d m3=%d",
	         PIC_FullIndex(),
	         cntr,
	         pit_counter.GetGate(),
	         pit_counter.GetMode3Active());
#endif
}

// Port B changed (speaker_output and/or timer2_gating bits)
void PcSpeakerImpulse::SetType(const PpiPortB& new_port_b)
{
#ifdef SPKR_DEBUGGING
	LOG_INFO("SPKR: %.3f type spk=%d gate=%d (was spk=%d gate=%d) m3=%d under=%d",
	         PIC_FullIndex(),
	         (int)new_port_b.speaker_output,
	         (int)new_port_b.timer2_gating,
	         (int)port_b.speaker_output,
	         (int)port_b.timer2_gating,
	         pit_counter.GetMode3Active(),
	         (int)have_undersampled_reload);
#endif
	const auto index = SyncPitToTick();

	const bool gate_changed = new_port_b.timer2_gating != port_b.timer2_gating;
	const bool speaker_enabled = new_port_b.speaker_output;
	port_b.data                = new_port_b.data;

	const bool gate_triggered = gate_changed && new_port_b.timer2_gating;

	if (gate_changed) {
		// Don't allow a gate-rising edge to restart the PIT while we
		// are in the undersampled-suppressed state; the stored period
		// is ultrasonic. Gate-falling still propagates so modes 2/3
		// correctly force output HIGH.
		if (!gate_triggered || !have_undersampled_reload) {
			const auto t = pit_counter.SetGate(new_port_b.timer2_gating);
			ApplyTransitions(t, index, speaker_enabled);
		}
	}

	AddImpulse(index, OutputAmplitude(speaker_enabled, pit_counter.GetOutput()));
}

void PcSpeakerImpulse::PicCallback(const int requested_frames)
{
	HandleWakeUp();

	// Advance PIT to end of this 1 ms tick
	const auto remaining = 1.0f - pit_last_index;
	if (remaining > 0.0f) {
		const auto t = pit_counter.Advance(remaining);
		ApplyTransitions(t, pit_last_index, port_b.speaker_output);
	}
	pit_last_index = 0.0f;

	int remaining_frames = requested_frames;

	while (remaining_frames > 0 && !waveform.empty()) {
		accumulator += waveform.front();
		waveform.pop_front();
		waveform.push_back(0.0f);

		auto sample = accumulator;
		output_queue.NonblockingEnqueue(std::move(sample));
		--remaining_frames;

		tally_of_silence = (std::abs(accumulator) > 1.0f)
		                         ? 0
		                         : tally_of_silence + 1;

		accumulator *= sinc_amplitude_fade;
	}

	// Pad with silence if waveform deque ran out
	if (remaining_frames > 0) {
		prev_amplitude = neutral_amplitude;
	}
	while (remaining_frames > 0) {
		output_queue.NonblockingEnqueue(neutral_amplitude);
		++tally_of_silence;
		--remaining_frames;
	}
}

void PcSpeakerImpulse::SetFilterState(const FilterState filter_state)
{
	assert(channel);

	if (filter_state == FilterState::On) {
		constexpr auto hp_order          = 3;
		constexpr auto hp_cutoff_freq_hz = 120;
		channel->ConfigureHighPassFilter(hp_order, hp_cutoff_freq_hz);
		channel->SetHighPassFilter(FilterState::On);

		constexpr auto lp_order          = 3;
		constexpr auto lp_cutoff_freq_hz = 4300;
		channel->ConfigureLowPassFilter(lp_order, lp_cutoff_freq_hz);
		channel->SetLowPassFilter(FilterState::On);
	} else {
		channel->SetHighPassFilter(FilterState::Off);
		channel->SetLowPassFilter(FilterState::Off);
	}
}

bool PcSpeakerImpulse::TryParseAndSetCustomFilter(const std::string& filter_choice)
{
	assert(channel);
	return channel->TryParseAndSetCustomFilter(filter_choice);
}

PcSpeakerImpulse::PcSpeakerImpulse()
{
	static_assert(sample_rate_hz > 0 && sample_rate_hz % 8000 == 0,
	              "Sample rate must be a multiple of 8000 to avoid artifacts");

#ifdef USE_LOOKUP_TABLES
	InitializeLut();
#endif
	waveform.resize(waveform_size, 0.0f);

	constexpr bool Stereo      = false;
	constexpr bool SignedData  = true;
	constexpr bool NativeOrder = true;

	const auto callback = [this](int frames) {
		MIXER_PullFromQueueCallback<PcSpeakerImpulse, float, Stereo, SignedData, NativeOrder>(
		        frames, this);
	};

	channel = MIXER_AddChannel(callback,
	                           sample_rate_hz,
	                           device_name,
	                           {ChannelFeature::Sleep,
	                            ChannelFeature::ChorusSend,
	                            ChannelFeature::ReverbSend,
	                            ChannelFeature::Synthesizer});
	assert(channel);

	channel->SetPeakAmplitude(positive_amplitude);

	LOG_MSG("%s: Initialised %s model", device_name, model_name);
}

PcSpeakerImpulse::~PcSpeakerImpulse()
{
	LOG_MSG("%s: Shutting down %s model", device_name, model_name);

	assert(channel);
	MIXER_DeregisterChannel(channel);
}
