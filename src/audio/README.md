# Audio mixer overview

This is an entry point for understanding the DOSBox Staging audio mixer. It
describes the *pull model* the mixer is built on, how normal playback and
capture flow through it, and the multithreading rules you must respect —
especially around pause. For the details, read the code; this document is the
map, not the territory.

Key files:

- `src/audio/mixer.cpp` / `src/audio/mixer.h` — the mixer thread, channels,
  effects, capture feed, pause/mute, SDL device setup.
- `src/audio/audio_frame.h` — `AudioFrame` (a stereo `{left, right}` float
  sample).
- `src/misc/rwqueue.cpp` — `RWQueue`, the bounded blocking queue everything is
  paced by.
- `src/midi/*.cpp` — the software synths (FluidSynth, MT-32, SoundCanvas),
  each a mixer channel fed by its own renderer thread.


## The mental model: a pull chain paced by one real clock

There is exactly **one real clock in the system: the sound card.** SDL pulls a
fixed number of sample frames off the mixer's output every real second (48000
Hz, say — it's hardware, it never speeds up or slows down). Everything
upstream is paced by *back-pressure* from that single consumer.

Think of a **conveyor belt of fixed length** between each producer and
consumer:

```
  emulated                mixer                      SDL / sound card
  devices    ─push─▶  [ channel queues ] ─pull─▶  mixer thread ─push─▶ [ final_output ] ─pull─▶ SDL
  (CPU thread)                                    (mix + effects)        (bounded queue)      (real-time)
                                                        ▲
  MIDI synth ─push─▶ [ audio_frame_fifo ] ─pull────────┘
  renderer                (bounded queue)
  (own thread)
```

Each belt (`RWQueue`) is **bounded and blocks when full**. So when SDL takes
one block off `final_output`, the mixer thread can put one block on — and not
before. The mixer, blocked on a full `final_output`, is therefore throttled to
exactly real time. In turn the mixer draining a channel's queue lets that
channel's producer run, and so on up the chain.

**Real time propagates backwards through "the belt is full, wait your turn."**
This is why there is almost no explicit timing code in the hot path: the
queues *are* the clock. Keep this in mind — most of the subtle bugs in this
subsystem come from a belt unexpectedly running empty and letting a producer
sprint ahead of real time.

## Threads

| Thread | Role |
|---|---|
| **Emulator (main/CPU)** | Runs the DOS program and the emulated audio devices (Sound Blaster, GUS, OPL, PC Speaker, …). Pushes samples into channel queues, sends MIDI events, drives PIC timing. Also runs PIC tick handlers, including the capture drain. All pause-state changes happen here. |
| **Mixer thread** (`mixer_thread_loop`) | The heart of the pull model. Each iteration pulls a block from every channel, mixes, applies effects and gain, feeds the capture queue, applies the pause/mute fade, and enqueues to `final_output`. |
| **SDL audio callback** | Dequeues from `final_output` at the device rate and hands it to the OS. If the queue is short, SDL backfills the device with silence itself — we do **not** pad. |
| **MIDI synth renderers** (one per active synth) | Each renders audio into its own `audio_frame_fifo` ahead of the mixer's consumption. Halted independently on pause (see below). |

## Normal playback flow

1. An emulated device produces samples on the **emulator thread** and hands
   them to its `MixerChannel` (e.g. `AddSamples_*`), which buffers them.
2. The **mixer thread** calls `mix_samples(blocksize)`: it pulls a block from
   every channel (`channel->Mix()`), sums them into the master buffer, then
   applies the master gain, reverb/chorus sends, high-pass filter and
   compressor.
3. The block is copied to the **capture feed** (see below) at full level.
4. The pause/mute **fade** (`playback_gain`) is applied to the SDL-bound copy
   only.
5. The block is enqueued to `final_output`; the **SDL callback** pulls it out
   at real time.

Channels can be enabled/disabled and will "sleep" when idle to save work; a
sleeping channel wakes when its device produces again.

## Capture (WAV / video recording)

Capture is a **tap on the mixer's output**, fed from inside `mix_samples()`:

- It is taken **before the pause/mute fade** is applied, so recordings contain
  full-level audio regardless of what the fade is doing to playback. What you
  record is not affected by muting or by the resume fade-in.
- Frames go into `capture_queue`, drained by `capture_callback()` — a PIC tick
  handler on the emulator thread. It drains whatever is present and **never
  zero-pads**; the two ends run on independent clocks, so momentary emptiness
  is normal and is not spliced with silence.
- The guiding criteria: **a capture made while pausing should be
  bit-identical to one made without pausing.** Because `mix_samples()` does
  not run while paused (see below), the capture simply freezes and resumes —
  no frozen state and no pause-time silence leak into the file.

## Pause and mute

Two orthogonal notions of "go quiet":

- **Mute** (`MixerMuteState`): `mix_samples()` keeps running (so capture is
  still fed at full level); only the SDL-bound output is faded to silence.
- **Pause** (`DOSBOX_IsPaused()`): the whole emulator freezes. The mixer
  thread **short-circuits before `mix_samples()`**, so nothing is produced and
  nothing is captured.

To avoid clicks, pausing is **deferred until a short fade-out completes**. The
pause FSM (see `dosbox.cpp` / `dosbox_pause_fsm.h`) parks in a *pending* state
while `playback_gain` ramps to zero; only then does it flip to *paused* and
halt the subsystems. During *pending*, everything still runs so the fade has
real audio to work against.

### Gotchas (this is where the bugs live)

1. **Resume back-pressure — the belt runs empty.** While paused the mixer
   stops feeding `final_output`, so SDL drains it empty (SDL self-silences the
   device meanwhile). On resume the belt is empty, so nothing back-pressures
   the mixer: it sprints, producing blocks as fast as the CPU allows until the
   queue refills — and every one of those blocks is also pushed into the
   capture feed with no real time elapsed. That stretches recordings by ~one
   bufferful per pause/resume cycle. Fix: `prime_output_queue_on_resume()`
   refills `final_output` with silence on the resume edge so the first real
   enqueue blocks immediately. The prime runs **on the mixer thread**, keyed
   off its own pause→resume edge, so there is no cross-thread race.

2. **Synth renderer ordering.** A software synth's renderer runs ahead of the
   mixer, filling its `audio_frame_fifo`. On **pause, halt the renderer
   first** (before the mixer stops draining) or it rushes to fill the fifo
   headroom that opens up, advancing the synth's clock and leaking extra
   samples into the next capture. On **resume, wake the renderer first**
   (before `MIXER_Resume()`) or the mixer can enter `mix_samples()`, block on
   an empty fifo while holding `mixer.mutex`, and deadlock the resume.
   `MIDI_Pause()` additionally halts the renderer under
   `MIXER_LockMixerThread()` so any in-flight `mix_samples()` drains first.
   See the ordering comments in `set_subsystems_paused()`.

3. The pause fade is gated on `playback_gain` actually reaching zero, not on a
   wall-clock timer. `nosound` mode snaps the gain to target so the gate still
   fires.

## Multithreading rules

- **`final_output` has exactly one producer (the mixer thread) and one
  consumer (SDL).** Do not enqueue to it from anywhere else. Priming on resume
  is done by the mixer thread precisely to keep this true.

- **`playback_gain` is written only by the mixer thread.** It is atomic solely
  so the pause FSM can read it to know when the fade finished.

- **Take `mixer.mutex` only via `MIXER_LockMixerThread()` /
  `MIXER_UnlockMixerThread…()`, never raw.** That protocol first *stops* the
  channel queues, which unblocks the mixer thread from a `BulkDequeue()` so it
  can release the mutex. A raw lock can deadlock: the main thread waits for
  `mixer.mutex` while the mixer thread holds it inside a `BulkDequeue()`
  waiting for samples only the main thread can produce. `mixer.mutex` is
  recursive so nested lockers (e.g. `MIDI_Pause()` then `MIXER_Pause()`)
  compose.

- **Bounded queues block — mind who waits on whom.** A blocking
  enqueue/dequeue is a place two threads rendezvous; if the other end is
  parked (e.g. a halted synth renderer, or a paused mixer), a naive blocking
  call there will hang. This is the root of both pause deadlocks and the
  resume-burst bug above.

- **Pause state is owned by the emulator thread.** Other threads may only
  *read* it via the `DOSBOX_Is*()` queries; never store `pause_state`
  off-thread.
