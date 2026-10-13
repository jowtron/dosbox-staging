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

// Where the user puts SoundFonts and MT-32 ROMs; Staging looks there too
extern NSString* const SoundFontsFolder;
extern NSString* const Mt32RomsFolder;

// Creates the folders above, so they show in the Files app
void CreateLibraryFolders();

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

// A setting's value in a config file, or nil if it isn't set there
NSString* ReadConfValue(NSString* path, NSString* section, NSString* key);

// Sets a setting in a config file, or removes it if 'value' is nil. The
// rest of the file (comments, [autoexec]) is left as it is; a new section
// goes ahead of [autoexec].
bool WriteConfValue(NSString* path, NSString* section, NSString* key, NSString* value);

// The same for a Windows .ini file, keeping its line endings and character
// set
NSString* ReadIniValue(NSString* path, NSString* section, NSString* key);
bool WriteIniValue(NSString* path, NSString* section, NSString* key, NSString* value);

#endif // DOSBOX_IOS_GAME_IMPORT_H
