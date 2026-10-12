// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_IOS_GAME_IMPORT_H
#define DOSBOX_IOS_GAME_IMPORT_H

#import <Foundation/Foundation.h>

// Adding games to the library. Paths are relative to the working directory,
// the app's Documents folder.

// Folder of the game configs shown in the library
extern NSString* const GamesFolder;

// Copies a game's folder into the 'Imported' folder. Returns the copy's
// path, or nil on failure.
NSString* ImportGameFolder(NSURL* source, NSError** error);

// DOS programs in a game's folder (and one level of subfolders) that could
// start it, most likely first. Paths are relative to the folder.
NSArray<NSString*>* FindGamePrograms(NSString* folder);

// The first CD image (.cue or .iso) in a game's folder, relative to it, or
// nil if there's none.
NSString* FindGameCdImage(NSString* folder);

// Writes the library config that starts a game: mounts its folder as C:
// (and its CD image as D:), runs the program, and returns to the library
// when it quits. Returns the config's name, which is the game's name in the
// library, or nil on failure.
NSString* WriteGameConf(NSString* name, NSString* folder, NSString* program,
                        NSString* cd_image, NSError** error);

#endif // DOSBOX_IOS_GAME_IMPORT_H
