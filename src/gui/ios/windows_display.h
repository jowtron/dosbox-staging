// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_IOS_WINDOWS_DISPLAY_H
#define DOSBOX_IOS_WINDOWS_DISPLAY_H

#import <Foundation/Foundation.h>

// The screen size of Windows 3.1 games. Windows' own display drivers only
// offer a few fixed sizes; PluMGMK's VBESVGA.DRV
// (https://github.com/PluMGMK/vbesvga.drv) takes any size from SYSTEM.INI,
// and Staging's 'vesa_custom_resolution' makes the emulated video card offer
// it. The driver has no licence, so it isn't part of the app: the user
// downloads it from its author's releases.

// The Windows folder on a game's C: drive (the folder its config mounts as
// C:), or nil if there's none
NSString* FindGameWindows(NSString* conf_path);

// True if that Windows uses VBESVGA.DRV
bool UsesVbeSvga(NSString* windows_dir);

// Sets the screen size VBESVGA.DRV asks for to the game's
// 'vesa_custom_resolution' (or the shared config's), if it uses the driver
void SyncWindowsScreenSize(NSString* conf_path);

// Downloads the latest release of VBESVGA.DRV and makes it Windows' display
// driver. 'done' is called on the main thread, with nil on success.
void InstallVbeSvga(NSString* windows_dir, void (^done)(NSError* error));

#endif // DOSBOX_IOS_WINDOWS_DISPLAY_H
