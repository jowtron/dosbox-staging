// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_IOS_LIBRARY_H
#define DOSBOX_IOS_LIBRARY_H

#include <string>
#include <vector>

// Shows the game library and waits until the user picks a game. Returns the
// command line to start the emulator with for that game.
//
// Games are the config files in 'Documents/Games' (each named after its
// game), layered on top of the shared 'Documents/dosbox.conf'.
std::vector<std::string> IOS_ChooseGame(const std::string& program_path);

#endif // DOSBOX_IOS_LIBRARY_H
