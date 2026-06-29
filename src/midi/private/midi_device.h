// SPDX-FileCopyrightText:  2020-2026 The DOSBox Staging Team
// SPDX-FileCopyrightText:  2002-2021 The DOSBox Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_MIDI_DEVICE_H
#define DOSBOX_MIDI_DEVICE_H

#include "midi/midi.h"

#include <cstdint>

namespace MidiDeviceName {
// Internal synths
constexpr auto FluidSynth  = "fluidsynth";
constexpr auto SoundCanvas = "soundcanvas";
constexpr auto Mt32        = "mt32";

// External devices
constexpr auto Alsa      = "alsa";
constexpr auto CoreAudio = "coreaudio";
constexpr auto CoreMidi  = "coremidi";
constexpr auto Win32     = "win32";
} // namespace MidiDeviceName

class MidiDevice {
public:
	enum class Type { Internal, External };

	virtual ~MidiDevice() = default;

	virtual std::string GetName() const = 0;
	virtual Type GetType() const        = 0;

	virtual void SendMidiMessage(const MidiMessage& msg)      = 0;
	virtual void SendSysExMessage(uint8_t* sysex, size_t len) = 0;

	// Pause / resume hooks for software synths with their own renderer
	// thread (FluidSynth, MT-32, SoundCanvas). Halts the renderer so it
	// stops advancing the synth's internal state past the pause boundary;
	// on resume the channel's `audio_frame_fifo` gives up the buffered
	// pre-pause continuation rather than stale post-pause synth state.
	// External devices have no renderer to halt -- their pause path is
	// `MIDI_Mute()`'s volume-zero broadcast.
	virtual void Pause() {}
	virtual void Resume() {}
};

void MIDI_Reset(MidiDevice* device);
MidiDevice* MIDI_GetCurrentDevice();

#endif // DOSBOX_MIDI_DEVICE_H
