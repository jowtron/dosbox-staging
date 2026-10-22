// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_IOS_GAME_ICONS_H
#define DOSBOX_IOS_GAME_ICONS_H

#import <UIKit/UIKit.h>

// Each game's icon in the library. It's the first of: a picture the user
// chose, an .ico file named after the game's program, the icon inside the
// program (Windows programs have them, DOS programs don't), or another .ico
// file beside the program or in the game's folder. The game's program is
// found by following its config's [autoexec] and the batch files it calls.

// The size icons are shown at, in points
constexpr CGFloat GameIconSize = 32;

// The game's icon, sized for a list row, or nil if it has none
UIImage* GameIcon(NSString* conf_path);

// Forgets the icons found so far, so they're looked up again
void ForgetGameIcons();

// Where a picture chosen for the game is kept: 'icon.png' in a game folder,
// or beside a single config file with the game's name
NSString* CustomIconPath(NSString* conf_path);

// Makes a picture, an .ico file or a Windows program's icon the game's icon.
// Returns false if there's no picture in the file.
bool SetCustomIcon(NSString* conf_path, NSURL* file);
bool SetCustomIconImage(NSString* conf_path, UIImage* image);
void RemoveCustomIcon(NSString* conf_path);

// The folder holding the game's files: its game folder, or the folder its
// config mounts as C:
NSString* GameFilesFolder(NSString* conf_path);

#endif // DOSBOX_IOS_GAME_ICONS_H
