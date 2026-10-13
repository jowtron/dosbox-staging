// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_IOS_GAME_IMPORT_H
#define DOSBOX_IOS_GAME_IMPORT_H

#import <Foundation/Foundation.h>

// The games in the library, and adding to it. Paths are relative to the
// working directory, the app's Documents folder.
//
// A game is either a folder in 'Games' holding the game's files and its
// 'dosbox.conf', or a single config file in 'Games' (for games whose files
// live elsewhere, such as those installed in a shared Windows drive). Either
// way, the game's config is an overlay on the shared 'dosbox.conf'.

extern NSString* const GamesFolder;

// The config file of each game in the library, keyed by the game's name
NSDictionary<NSString*, NSString*>* FindGames();

// True if the game is a folder holding its files, not just a config file
bool IsGameFolder(NSString* conf_path);

// Copies a game's folder into the library as a new game folder. Returns the
// copy's path, or nil on failure.
NSString* ImportGameFolder(NSURL* source, NSError** error);

// DOS programs in a game's folder (and one level of subfolders) that could
// start it, most likely first. Paths are relative to the folder.
NSArray<NSString*>* FindGamePrograms(NSString* folder);

// The first CD image (.cue or .iso) in a game's folder, relative to it, or
// nil if there's none.
NSString* FindGameCdImage(NSString* folder);

// Writes the game folder's config: mounts the folder as C: (and its CD
// image as D:), runs the program, and returns to the library when it quits.
// A config the folder already had is kept as 'dosbox-original.conf'.
bool WriteGameConf(NSString* folder, NSString* program, NSString* cd_image,
                   NSError** error);

#endif // DOSBOX_IOS_GAME_IMPORT_H
