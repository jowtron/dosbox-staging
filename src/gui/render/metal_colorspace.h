// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_METAL_COLORSPACE_H
#define DOSBOX_METAL_COLORSPACE_H

#include <SDL3/SDL.h>

// Tag the CAMetalLayer of an SDL window with the Display P3 colour space
// (macOS and iOS). The window must have been claimed by an SDL_GPU device,
// which creates the layer.
void set_metal_layer_display_p3_color_space(SDL_Window* sdl_window);

#endif // DOSBOX_METAL_COLORSPACE_H
