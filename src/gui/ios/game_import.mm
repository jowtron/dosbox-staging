// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/game_import.h"

NSString* const GamesFolder = @"Games";

static NSString* const GameConfName     = @"dosbox.conf";
static NSString* const OriginalConfName = @"dosbox-original.conf";

static bool has_extension(NSString* file, NSString* extension)
{
	return [file.pathExtension.lowercaseString isEqualToString:extension];
}

NSDictionary<NSString*, NSString*>* FindGames()
{
	auto files = NSFileManager.defaultManager;
	auto games = [NSMutableDictionary<NSString*, NSString*> dictionary];

	for (NSString* item in [files contentsOfDirectoryAtPath:GamesFolder error:nil]) {
		const auto path = [GamesFolder stringByAppendingPathComponent:item];

		BOOL is_dir = NO;
		[files fileExistsAtPath:path isDirectory:&is_dir];

		if (is_dir) {
			const auto conf = [path stringByAppendingPathComponent:GameConfName];
			if ([files fileExistsAtPath:conf]) {
				games[item] = conf;
			}
		} else if (has_extension(item, @"conf")) {
			games[item.stringByDeletingPathExtension] = path;
		}
	}
	return games;
}

bool IsGameFolder(NSString* conf_path)
{
	return [conf_path.lastPathComponent isEqualToString:GameConfName];
}

NSString* ImportGameFolder(NSURL* source, NSError** error)
{
	auto files = NSFileManager.defaultManager;

	if (![files createDirectoryAtPath:GamesFolder
	      withIntermediateDirectories:YES
	                       attributes:nil
	                            error:error]) {
		return nil;
	}

	// A name no other game in the library has
	const auto games = FindGames();
	auto name        = source.lastPathComponent;
	for (int n = 2; games[name] ||
	                [files fileExistsAtPath:[GamesFolder stringByAppendingPathComponent:name]];
	     ++n) {
		name = [NSString stringWithFormat:@"%@ %d", source.lastPathComponent, n];
	}
	const auto destination = [GamesFolder stringByAppendingPathComponent:name];

	// Folders picked in the Files app are outside the app's sandbox
	const auto is_scoped = [source startAccessingSecurityScopedResource];
	const auto copied    = [files copyItemAtURL:source
	                                   toURL:[NSURL fileURLWithPath:destination]
	                                   error:error];
	if (is_scoped) {
		[source stopAccessingSecurityScopedResource];
	}
	return copied ? destination : nil;
}

// DOS can only run programs with 8.3 names
static bool is_dos_program(NSString* file)
{
	if (!(has_extension(file, @"exe") || has_extension(file, @"com") ||
	      has_extension(file, @"bat"))) {
		return false;
	}
	const auto base = file.stringByDeletingPathExtension;
	return base.length > 0 && base.length <= 8 &&
	       [base rangeOfString:@" "].location == NSNotFound;
}

// Lower is more likely to start the game: a program named after its folder
// first, set-up and install programs last
static int program_rank(NSString* program, NSString* folder_name)
{
	const auto base = program.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
	const auto folder = folder_name.lowercaseString;

	if ([folder hasPrefix:base] || [base hasPrefix:folder]) {
		return 0;
	}
	for (NSString* word in @[@"setup", @"install", @"inst", @"config", @"setsound", @"uninst"]) {
		if ([base hasPrefix:word]) {
			return 2;
		}
	}
	return 1;
}

NSArray<NSString*>* FindGamePrograms(NSString* folder)
{
	auto files    = NSFileManager.defaultManager;
	auto programs = [NSMutableArray<NSString*> array];

	for (NSString* item in [files contentsOfDirectoryAtPath:folder error:nil]) {
		const auto path = [folder stringByAppendingPathComponent:item];

		BOOL is_dir = NO;
		[files fileExistsAtPath:path isDirectory:&is_dir];

		if (!is_dir) {
			if (is_dos_program(item)) {
				[programs addObject:item];
			}
			continue;
		}
		for (NSString* sub_item in [files contentsOfDirectoryAtPath:path error:nil]) {
			if (is_dos_program(sub_item)) {
				[programs addObject:[item stringByAppendingPathComponent:sub_item]];
			}
		}
	}

	const auto folder_name = folder.lastPathComponent;
	[programs sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
		const auto rank_a = program_rank(a, folder_name);
		const auto rank_b = program_rank(b, folder_name);
		if (rank_a != rank_b) {
			return rank_a < rank_b ? NSOrderedAscending : NSOrderedDescending;
		}
		return [a localizedCaseInsensitiveCompare:b];
	}];
	return programs;
}

NSString* FindGameCdImage(NSString* folder)
{
	auto items = [NSFileManager.defaultManager subpathsOfDirectoryAtPath:folder error:nil];
	items      = [items sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
	for (NSString* item in items) {
		if (has_extension(item, @"cue") || has_extension(item, @"iso")) {
			return item;
		}
	}
	return nil;
}

bool WriteGameConf(NSString* folder, NSString* program, NSString* cd_image, NSError** error)
{
	auto files = NSFileManager.defaultManager;

	// Keep a config that came with the game (e.g., from eXoDOS)
	const auto conf_path = [folder stringByAppendingPathComponent:GameConfName];
	if ([files fileExistsAtPath:conf_path]) {
		const auto original = [folder stringByAppendingPathComponent:OriginalConfName];
		[files removeItemAtPath:original error:nil];
		if (![files moveItemAtPath:conf_path toPath:original error:error]) {
			return false;
		}
	}

	// A program in a subfolder whose name DOS can't use as-is gets that
	// subfolder mounted as C: instead
	auto drive_c            = folder;
	auto program_dir        = program.stringByDeletingLastPathComponent;
	const auto program_file = program.lastPathComponent;
	if (program_dir.length > 8 || [program_dir rangeOfString:@" "].location != NSNotFound) {
		drive_c     = [folder stringByAppendingPathComponent:program_dir];
		program_dir = @"";
	}

	auto conf = [NSMutableString string];
	[conf appendString:@"# This game's settings, on top of the shared dosbox.conf\n"];
	[conf appendString:@"[autoexec]\n"];
	[conf appendFormat:@"mount c \"%@\"\n", drive_c];
	if (cd_image) {
		[conf appendFormat:@"imgmount d \"%@\" -t cdrom\n",
		                   [folder stringByAppendingPathComponent:cd_image]];
	}
	[conf appendString:@"c:\n"];
	if (program_dir.length > 0) {
		[conf appendFormat:@"cd \\%@\n", program_dir];
	}
	[conf appendFormat:@"%@%@\n",
	                   has_extension(program_file, @"bat") ? @"call " : @"",
	                   program_file];
	[conf appendString:@"exit\n"];

	return [conf writeToFile:conf_path atomically:YES encoding:NSUTF8StringEncoding error:error];
}
