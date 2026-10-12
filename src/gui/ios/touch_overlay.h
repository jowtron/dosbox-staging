// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_IOS_TOUCH_OVERLAY_H
#define DOSBOX_IOS_TOUCH_OVERLAY_H

#include <SDL3/SDL.h>

// Adds the touch input layer on top of the SDL view: a trackpad-style mouse
// covering the whole screen, and a toggleable on-screen PC keyboard. Input is
// delivered to the emulator as ordinary SDL keyboard and mouse events.
//
// Safe to call again if the SDL window is recreated.
void IOS_InstallTouchOverlay(SDL_Window* window);

#endif // DOSBOX_IOS_TOUCH_OVERLAY_H
