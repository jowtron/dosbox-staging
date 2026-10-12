// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/game_import.h"

NSString* const GamesFolder = @"Games";

static NSString* const ImportedFolder = @"Imported";

// Adds " 2", " 3" and so on to a name until 'exists' is false for it
static NSString* unique_name(NSString* name, BOOL (^exists)(NSString*))
{
	auto candidate = name;
	for (int n = 2; exists(candidate); ++n) {
		candidate = [NSString stringWithFormat:@"%@ %d", name, n];
	}
	return candidate;
}

NSString* ImportGameFolder(NSURL* source, NSError** error)
{
	auto files = NSFileManager.defaultManager;

	if (![files createDirectoryAtPath:ImportedFolder
	      withIntermediateDirectories:YES
	                       attributes:nil
	                            error:error]) {
		return nil;
	}

	const auto name = unique_name(source.lastPathComponent, ^BOOL(NSString* candidate) {
		return [files fileExistsAtPath:[ImportedFolder
		                                       stringByAppendingPathComponent:candidate]];
	});
	const auto destination = [ImportedFolder stringByAppendingPathComponent:name];

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
	const auto extension = file.pathExtension.lowercaseString;
	if (!([extension isEqualToString:@"exe"] || [extension isEqualToString:@"com"] ||
	      [extension isEqualToString:@"bat"])) {
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
		const auto extension = item.pathExtension.lowercaseString;
		if ([extension isEqualToString:@"cue"] || [extension isEqualToString:@"iso"]) {
			return item;
		}
	}
	return nil;
}

NSString* WriteGameConf(NSString* name, NSString* folder, NSString* program,
                        NSString* cd_image, NSError** error)
{
	auto files = NSFileManager.defaultManager;

	if (![files createDirectoryAtPath:GamesFolder
	      withIntermediateDirectories:YES
	                       attributes:nil
	                            error:error]) {
		return nil;
	}

	const auto conf_name = unique_name(name, ^BOOL(NSString* candidate) {
		return [files fileExistsAtPath:[[GamesFolder stringByAppendingPathComponent:candidate]
		                                       stringByAppendingPathExtension:@"conf"]];
	});

	// A program in a subfolder whose name DOS can't use as-is gets that
	// subfolder mounted as C: instead
	auto drive_c          = folder;
	auto program_dir      = program.stringByDeletingLastPathComponent;
	const auto program_file = program.lastPathComponent;
	if (program_dir.length > 8 || [program_dir rangeOfString:@" "].location != NSNotFound) {
		drive_c     = [folder stringByAppendingPathComponent:program_dir];
		program_dir = @"";
	}

	auto conf = [NSMutableString string];
	[conf appendFormat:@"# Added to the library from the '%@' folder\n", folder.lastPathComponent];
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
	const auto is_batch = [program_file.pathExtension.lowercaseString isEqualToString:@"bat"];
	[conf appendFormat:@"%@%@\n", is_batch ? @"call " : @"", program_file];
	[conf appendString:@"exit\n"];

	const auto conf_path = [[GamesFolder stringByAppendingPathComponent:conf_name]
	        stringByAppendingPathExtension:@"conf"];
	if (![conf writeToFile:conf_path atomically:YES encoding:NSUTF8StringEncoding error:error]) {
		return nil;
	}
	return conf_name;
}
