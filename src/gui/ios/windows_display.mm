// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/windows_display.h"

#include "gui/ios/game_import.h"

#include <compression.h>

#include <cstdint>
#include <optional>

namespace {

NSString* const SharedConf = @"dosbox.conf";

NSString* const LatestRelease =
        @"https://api.github.com/repos/PluMGMK/vbesvga.drv/releases/latest";

// The driver, its virtual device for DOS boxes, and its screen grabber
NSArray<NSString*>* const DriverFiles = @[@"VBESVGA.DRV", @"VDDVBE.386", @"VBEVMDIB.3GR"];

NSError* make_error(NSString* message)
{
	return [NSError errorWithDomain:@"VBESVGA"
	                           code:1
	                       userInfo:@{NSLocalizedDescriptionKey: message}];
}

} // namespace

// An item in a folder, matching its name in any case as DOS does
static NSString* find_item(NSString* folder, NSString* name)
{
	for (NSString* item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder
	                                                                         error:nil]) {
		if ([item caseInsensitiveCompare:name] == NSOrderedSame) {
			return [folder stringByAppendingPathComponent:item];
		}
	}
	return nil;
}

// The folder a game's config mounts as C:, or nil
static NSString* find_c_drive(NSString* conf_path)
{
	const auto conf = [NSString stringWithContentsOfFile:conf_path
	                                            encoding:NSUTF8StringEncoding
	                                               error:nil];
	if (!conf) {
		return nil;
	}
	const auto mount = [NSRegularExpression
	        regularExpressionWithPattern:@"^\\s*mount\\s+c:?\\s+(?:\"([^\"]+)\"|(\\S+))"
	                             options:NSRegularExpressionCaseInsensitive |
	                                     NSRegularExpressionAnchorsMatchLines
	                               error:nil];
	const auto match = [mount firstMatchInString:conf
	                                     options:0
	                                       range:NSMakeRange(0, conf.length)];
	if (!match) {
		return nil;
	}
	const auto quoted = [match rangeAtIndex:1];
	return [conf substringWithRange:(quoted.location != NSNotFound) ? quoted
	                                                                : [match rangeAtIndex:2]];
}

NSString* FindGameWindows(NSString* conf_path)
{
	const auto drive = find_c_drive(conf_path);
	if (!drive) {
		return nil;
	}
	auto folders = [NSMutableArray<NSString*> array];
	if (const auto windows = find_item(drive, @"WINDOWS")) {
		[folders addObject:windows];
	}
	for (NSString* item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:drive
	                                                                         error:nil]) {
		[folders addObject:[drive stringByAppendingPathComponent:item]];
	}
	for (NSString* folder in folders) {
		if (find_item(folder, @"WIN.COM") && find_item(folder, @"SYSTEM.INI")) {
			return folder;
		}
	}
	return nil;
}

bool UsesVbeSvga(NSString* windows_dir)
{
	const auto system_ini = find_item(windows_dir, @"SYSTEM.INI");
	const auto driver     = system_ini ? ReadIniValue(system_ini, @"boot", @"display.drv")
	                                   : nil;
	return driver && [driver caseInsensitiveCompare:@"vbesvga.drv"] == NSOrderedSame;
}

void SyncWindowsScreenSize(NSString* conf_path)
{
	const auto windows_dir = FindGameWindows(conf_path);
	if (!windows_dir || !UsesVbeSvga(windows_dir)) {
		return;
	}
	NSString* const size = ReadConfValue(conf_path, @"dosbox", @"vesa_custom_resolution")
	                               ?: ReadConfValue(SharedConf, @"dosbox", @"vesa_custom_resolution");
	const auto parts = [size.lowercaseString componentsSeparatedByString:@"x"];
	if (parts.count != 2 || parts[0].intValue <= 0 || parts[1].intValue <= 0) {
		return;
	}
	const auto system_ini = find_item(windows_dir, @"SYSTEM.INI");
	const auto set        = ^(NSString* key, NSString* value) {
		if (![ReadIniValue(system_ini, @"vbesvga.drv", key) isEqualToString:value]) {
			WriteIniValue(system_ini, @"vbesvga.drv", key, value);
		}
	};
	set(@"Width", @(parts[0].intValue).stringValue);
	set(@"Height", @(parts[1].intValue).stringValue);
}

// Reading the release's zip archive

// A little-endian number, or nothing if it's past the end of the data
static std::optional<uint32_t> read_le(NSData* data, NSUInteger offset, int num_bytes)
{
	if (offset + static_cast<NSUInteger>(num_bytes) > data.length) {
		return {};
	}
	const auto bytes = static_cast<const uint8_t*>(data.bytes) + offset;
	uint32_t value   = 0;
	for (int i = num_bytes - 1; i >= 0; --i) {
		value = (value << 8) | bytes[i];
	}
	return value;
}

// The stored and deflated files in a zip archive, by upper case name
static NSDictionary<NSString*, NSData*>* unzip(NSData* zip)
{
	constexpr uint32_t EndSignature   = 0x06054b50;
	constexpr uint32_t EntrySignature = 0x02014b50;
	constexpr uint32_t LocalSignature = 0x04034b50;
	constexpr NSUInteger EndSize      = 22;
	constexpr uint32_t Stored         = 0;
	constexpr uint32_t Deflated       = 8;

	auto files = [NSMutableDictionary<NSString*, NSData*> dictionary];
	if (zip.length < EndSize) {
		return files;
	}

	// The end record is last, unless the archive has a comment
	auto end = zip.length - EndSize;
	while (end > 0 && read_le(zip, end, 4) != EndSignature) {
		--end;
	}
	const auto num_entries = read_le(zip, end + 10, 2);
	const auto directory   = read_le(zip, end + 16, 4);
	if (read_le(zip, end, 4) != EndSignature || !num_entries || !directory) {
		return files;
	}

	NSUInteger entry = *directory;
	for (uint32_t i = 0; i < *num_entries; ++i) {
		const auto method       = read_le(zip, entry + 10, 2);
		const auto packed_size  = read_le(zip, entry + 20, 4);
		const auto size         = read_le(zip, entry + 24, 4);
		const auto name_length  = read_le(zip, entry + 28, 2);
		const auto extra_length = read_le(zip, entry + 30, 2);
		const auto comment_size = read_le(zip, entry + 32, 2);
		const auto local        = read_le(zip, entry + 42, 4);
		if (read_le(zip, entry, 4) != EntrySignature || !comment_size || !local ||
		    read_le(zip, *local, 4) != LocalSignature ||
		    entry + 46 + *name_length > zip.length) {
			break;
		}
		const auto name = [[NSString alloc]
		        initWithData:[zip subdataWithRange:NSMakeRange(entry + 46, *name_length)]
		            encoding:NSISOLatin1StringEncoding];

		const auto local_name  = read_le(zip, *local + 26, 2);
		const auto local_extra = read_le(zip, *local + 28, 2);
		const auto start = *local + 30 + local_name.value_or(0) + local_extra.value_or(0);
		if (start + *packed_size > zip.length) {
			break;
		}
		const auto packed = [zip subdataWithRange:NSMakeRange(start, *packed_size)];

		if (method == Stored) {
			files[name.uppercaseString] = packed;
		} else if (method == Deflated && *size > 0) {
			auto data = [NSMutableData dataWithLength:*size];
			const auto unpacked_size = compression_decode_buffer(
			        static_cast<uint8_t*>(data.mutableBytes), *size,
			        static_cast<const uint8_t*>(packed.bytes), packed.length,
			        nullptr, COMPRESSION_ZLIB);
			if (unpacked_size == *size) {
				files[name.uppercaseString] = data;
			}
		}
		entry += 46 + *name_length + *extra_length + *comment_size;
	}
	return files;
}

// Installing the driver

static NSURL* release_zip_url(NSData* release_json)
{
	NSDictionary* const release = release_json
	                                    ? [NSJSONSerialization JSONObjectWithData:release_json
	                                                                      options:0
	                                                                        error:nil]
	                                    : nil;
	if (![release isKindOfClass:NSDictionary.class]) {
		return nil;
	}
	// There's also a debug build
	for (NSDictionary* asset in release[@"assets"]) {
		NSString* const name = [asset[@"name"] lowercaseString];
		if ([name hasSuffix:@".zip"] && [name containsString:@"release"]) {
			return [NSURL URLWithString:asset[@"browser_download_url"]];
		}
	}
	return nil;
}

static bool is_dos_executable(NSData* data)
{
	return data.length > 2 && [[data subdataWithRange:NSMakeRange(0, 2)]
	                                  isEqualToData:[@"MZ" dataUsingEncoding:NSASCIIStringEncoding]];
}

static NSError* install_files(NSString* windows_dir, NSData* zip)
{
	auto files            = NSFileManager.defaultManager;
	const auto drivers    = unzip(zip);
	const auto system_dir = find_item(windows_dir, @"SYSTEM");
	const auto system_ini = find_item(windows_dir, @"SYSTEM.INI");

	if (!system_dir || !system_ini) {
		return make_error(@"This Windows has no SYSTEM folder or SYSTEM.INI.");
	}
	for (NSString* name in DriverFiles) {
		if (!is_dos_executable(drivers[name])) {
			return make_error(@"The download didn't contain the driver.");
		}
	}

	// Keep the old settings, in the first free backup
	for (NSString* backup in @[@"SYSTEM.BAK", @"SYSTEM.BK1", @"SYSTEM.BK2", @"SYSTEM.BK3"]) {
		if (!find_item(windows_dir, backup)) {
			[files copyItemAtPath:system_ini
			               toPath:[windows_dir stringByAppendingPathComponent:backup]
			                error:nil];
			break;
		}
	}

	for (NSString* name in DriverFiles) {
		const auto path = find_item(system_dir, name)
		                          ?: [system_dir stringByAppendingPathComponent:name];
		NSError* error  = nil;
		if (![drivers[name] writeToFile:path options:NSDataWritingAtomic error:&error]) {
			return error;
		}
	}

	const auto ok = WriteIniValue(system_ini, @"boot", @"display.drv", @"vbesvga.drv") &&
	                WriteIniValue(system_ini, @"boot", @"386grabber", @"vbevmdib.3gr") &&
	                WriteIniValue(system_ini, @"boot.description", @"display.drv",
	                              @"Modern Generic SVGA (VBESVGA.DRV)") &&
	                WriteIniValue(system_ini, @"386Enh", @"display", @"vddvbe.386");
	return ok ? nil : make_error(@"Couldn't change SYSTEM.INI.");
}

void InstallVbeSvga(NSString* windows_dir, void (^done)(NSError* error))
{
	const auto finish = ^(NSError* error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			done(error);
		});
	};
	const auto session = NSURLSession.sharedSession;

	const auto get_zip = ^(NSData* release, NSURLResponse*, NSError* error) {
		const auto zip_url = release_zip_url(release);
		if (!zip_url) {
			finish(error ?: make_error(@"Couldn't find the driver's latest release."));
			return;
		}
		const auto install = ^(NSData* zip, NSURLResponse*, NSError* zip_error) {
			finish(zip_error ?: install_files(windows_dir, zip));
		};
		[[session dataTaskWithURL:zip_url completionHandler:install] resume];
	};
	[[session dataTaskWithURL:[NSURL URLWithString:LatestRelease] completionHandler:get_zip]
	        resume];
}
