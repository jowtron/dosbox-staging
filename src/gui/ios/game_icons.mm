// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/game_icons.h"

#include "gui/ios/game_import.h"

#import <ImageIO/ImageIO.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {

// A chosen picture is shrunk to this many pixels across; an icon chosen
// from a file is kept at its own size, so it stays sharp
constexpr CGFloat CustomIconMaxPixels = 256;

// The deepest batch file calls followed when looking for a game's program
constexpr int MaxBatchDepth = 4;

// Programs games start before the game itself
NSSet<NSString*>* const HelperPrograms = [NSSet setWithArray:@[
	@"choice", @"ctmouse", @"devlod", @"doskey", @"emm386", @"himem", @"keyb",
	@"lh", @"loadfix", @"loadhigh", @"mem", @"mixerset", @"mode", @"mouse",
	@"mscdex", @"runexit", @"setver", @"smartdrv",
]];

NSCache<NSString*, id>* icon_cache()
{
	static NSCache* const cache = [[NSCache alloc] init];
	return cache;
}

bool has_extension(NSString* path, NSString* extension)
{
	return [path.pathExtension caseInsensitiveCompare:extension] == NSOrderedSame;
}

bool is_folder(NSString* path)
{
	BOOL is_dir = NO;
	return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&is_dir] && is_dir;
}

// An item in a folder, matching its name in any case as DOS does
NSString* find_item(NSString* folder, NSString* name)
{
	for (NSString* item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder
	                                                                         error:nil]) {
		if ([item caseInsensitiveCompare:name] == NSOrderedSame) {
			return [folder stringByAppendingPathComponent:item];
		}
	}
	return nil;
}

NSArray<NSString*>* lines_of(NSString* text)
{
	return [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

NSString* trimmed(NSString* text)
{
	return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

// The lines of a config file's [autoexec] section
NSArray<NSString*>* autoexec_lines(NSString* conf_path)
{
	const auto conf = [NSString stringWithContentsOfFile:conf_path
	                                            encoding:NSUTF8StringEncoding
	                                               error:nil];
	auto lines      = [NSMutableArray<NSString*> array];
	bool in_autoexec = false;
	for (NSString* line in lines_of(conf)) {
		if ([trimmed(line) hasPrefix:@"["]) {
			in_autoexec = [trimmed(line).lowercaseString isEqualToString:@"[autoexec]"];
		} else if (in_autoexec) {
			[lines addObject:line];
		}
	}
	return lines;
}

// The words of a command line, with quotes removed
NSMutableArray<NSString*>* words_of(NSString* line)
{
	static NSRegularExpression* const word =
	        [NSRegularExpression regularExpressionWithPattern:@"\"([^\"]*)\"|(\\S+)"
	                                                  options:0
	                                                    error:nil];
	auto words = [NSMutableArray<NSString*> array];
	for (NSTextCheckingResult* match in [word matchesInString:line
	                                                  options:0
	                                                    range:NSMakeRange(0, line.length)]) {
		const auto quoted = [match rangeAtIndex:1];
		[words addObject:[line substringWithRange:(quoted.location != NSNotFound)
		                                                  ? quoted
		                                                  : [match rangeAtIndex:2]]];
	}
	return words;
}

// Follows a game's start-up commands to find the program it runs, keeping
// track of the drives mounted and the current folder of each, as DOS does
class StartupReader {
public:
	explicit StartupReader(NSString* conf_path)
	{
		Run(autoexec_lines(conf_path), 0);
	}

	// The last program started, other than helpers. Windows itself counts
	// only if it's started without a program: its Program Manager stands in.
	NSString* Program() const
	{
		if (program) {
			return program;
		}
		return windows ? find_item(windows.stringByDeletingLastPathComponent, @"PROGMAN.EXE")
		               : nil;
	}

	NSString* DriveC() const
	{
		return roots[@"C"];
	}

private:
	void Run(NSArray<NSString*>* lines, const int depth)
	{
		for (NSString* line in lines) {
			auto words = words_of(line);
			if (words.count == 0) {
				continue;
			}
			auto command = [words.firstObject lowercaseString];
			if ([command hasPrefix:@"@"]) {
				command = [command substringFromIndex:1];
			}

			if ([command isEqualToString:@"mount"] && words.count >= 3 &&
			    ![words[1] hasPrefix:@"-"]) {
				const auto letter = [words[1] substringToIndex:1].uppercaseString;
				roots[letter]     = words[2];
				[folders removeObjectForKey:letter];
			} else if (command.length == 2 && [command hasSuffix:@":"]) {
				drive = [command substringToIndex:1].uppercaseString;
			} else if ([command isEqualToString:@"cd"] || [command hasPrefix:@"cd\\"] ||
			           [command hasPrefix:@"cd.."]) {
				ChangeFolder(command.length > 2 ? [words.firstObject substringFromIndex:2]
				             : words.count > 1  ? words[1]
				                                : @"");
			} else {
				if ([command isEqualToString:@"call"]) {
					[words removeObjectAtIndex:0];
				}
				RunCommand(words, depth);
			}
		}
	}

	void RunCommand(NSArray<NSString*>* words, const int depth)
	{
		for (NSUInteger i = 0; i < words.count; ++i) {
			const auto path = FindProgram(words[i], i == 0);
			if (!path) {
				continue;
			}
			const auto name = path.lastPathComponent.lowercaseString;
			if (has_extension(name, @"bat")) {
				if (i == 0 && depth < MaxBatchDepth) {
					const auto batch = [NSString stringWithContentsOfFile:path
					                                             encoding:NSWindowsCP1252StringEncoding
					                                                error:nil];
					Run(lines_of(batch), depth + 1);
				}
			} else if ([name isEqualToString:@"win.com"]) {
				windows = path;
			} else if (![HelperPrograms containsObject:name.stringByDeletingPathExtension]) {
				program = path;
			}
		}
	}

	// A command's program. The command itself can leave out the extension;
	// its arguments only count if they name a program in full.
	NSString* FindProgram(NSString* word, const bool is_command) const
	{
		if ([word hasPrefix:@"@"]) {
			word = [word substringFromIndex:1];
		}
		for (NSString* extension in @[@"com", @"exe", @"bat"]) {
			if (has_extension(word, extension)) {
				const auto path = Resolve(word);
				return (path && !is_folder(path)) ? path : nil;
			}
		}
		if (!is_command) {
			return nil;
		}
		for (NSString* extension in @[@"com", @"exe", @"bat"]) {
			const auto path = Resolve([word stringByAppendingPathExtension:extension]);
			if (path && !is_folder(path)) {
				return path;
			}
		}
		return nil;
	}

	void ChangeFolder(NSString* dos_path)
	{
		const auto letter = DriveOf(dos_path);
		const auto path   = Resolve(dos_path);
		if (letter && path && is_folder(path)) {
			folders[letter] = path;
		}
	}

	NSString* DriveOf(NSString* dos_path) const
	{
		if (dos_path.length >= 2 && [dos_path characterAtIndex:1] == ':') {
			return [dos_path substringToIndex:1].uppercaseString;
		}
		return drive;
	}

	// The file or folder a DOS path names, or nil
	NSString* Resolve(NSString* dos_path) const
	{
		const auto letter = DriveOf(dos_path);
		NSString* const root = letter ? roots[letter] : nil;
		if (!root) {
			return nil;
		}
		auto rest = dos_path;
		if (rest.length >= 2 && [rest characterAtIndex:1] == ':') {
			rest = [rest substringFromIndex:2];
		}
		auto path = [rest hasPrefix:@"\\"] ? root : (folders[letter] ?: root);
		for (NSString* part in [rest componentsSeparatedByString:@"\\"]) {
			if (part.length == 0 || [part isEqualToString:@"."]) {
				continue;
			}
			if ([part isEqualToString:@".."]) {
				if (path.length > root.length) {
					path = path.stringByDeletingLastPathComponent;
				}
				continue;
			}
			path = find_item(path, part);
			if (!path) {
				return nil;
			}
		}
		return path;
	}

	NSMutableDictionary<NSString*, NSString*>* roots   = [NSMutableDictionary dictionary];
	NSMutableDictionary<NSString*, NSString*>* folders = [NSMutableDictionary dictionary];
	NSString* drive   = nil;
	NSString* program = nil;
	NSString* windows = nil;
};

// Little-endian numbers in a file, reading as 0 past its end
class Bytes {
public:
	explicit Bytes(NSData* data)
	        : bytes(static_cast<const uint8_t*>(data.bytes)),
	          size(data.length)
	{}

	bool Has(const int64_t offset, const int64_t length) const
	{
		return offset >= 0 && length >= 0 && offset + length <= static_cast<int64_t>(size);
	}

	int U8(const int64_t offset) const
	{
		return Has(offset, 1) ? bytes[offset] : 0;
	}

	int U16(const int64_t offset) const
	{
		return U8(offset) | (U8(offset + 1) << 8);
	}

	int64_t U32(const int64_t offset) const
	{
		return U16(offset) | (static_cast<int64_t>(U16(offset + 2)) << 16);
	}

	NSData* Slice(const int64_t offset, const int64_t length) const
	{
		return Has(offset, length) ? [NSData dataWithBytes:bytes + offset
		                                            length:static_cast<NSUInteger>(length)]
		                           : nil;
	}

private:
	const uint8_t* bytes = nullptr;
	size_t size          = 0;
};

// A resource in a Windows program; a resource with a name has no number
struct Resource {
	int type       = 0;
	int id         = 0;
	int64_t offset = 0;
	int64_t length = 0;
};

constexpr int IconResource      = 3;
constexpr int IconGroupResource = 14;

// The resources of a Windows 3.x program (the 'NE' format)
std::vector<Resource> ne_resources(const Bytes& file, const int64_t header)
{
	std::vector<Resource> resources = {};

	const auto table = header + file.U16(header + 0x24);
	// The resident names follow; at the same offset, there are no resources
	if (table == header + file.U16(header + 0x26)) {
		return resources;
	}
	const auto shift = file.U16(table);
	auto position    = table + 2;
	while (file.Has(position, 8)) {
		const auto type  = file.U16(position);
		const auto count = file.U16(position + 2);
		position += 8;
		if (type == 0) {
			break;
		}
		for (int i = 0; i < count && file.Has(position, 12); ++i) {
			const auto id = file.U16(position + 6);
			resources.push_back({(type & 0x8000) ? (type & 0x7fff) : -1,
			                     (id & 0x8000) ? (id & 0x7fff) : -1,
			                     static_cast<int64_t>(file.U16(position)) << shift,
			                     static_cast<int64_t>(file.U16(position + 2)) << shift});
			position += 12;
		}
	}
	return resources;
}

// The resources of a Windows 95 or later program (the 'PE' format)
std::vector<Resource> pe_resources(const Bytes& file, const int64_t header)
{
	std::vector<Resource> resources = {};

	const auto coff         = header + 4;
	const auto optional     = coff + 20;
	const auto is_64_bit    = (file.U16(optional) == 0x20b);
	const auto directories  = optional + (is_64_bit ? 112 : 96);
	const auto resource_rva = file.U32(directories + 2 * 8);
	if (resource_rva == 0) {
		return resources;
	}

	// Where an address in the loaded program is in the file
	const auto sections      = optional + file.U16(coff + 16);
	const auto section_count = file.U16(coff + 2);
	const auto file_offset   = [&](const int64_t rva) -> int64_t {
		for (int i = 0; i < section_count; ++i) {
			const auto section = sections + 40 * i;
			const auto start   = file.U32(section + 12);
			const auto length  = std::max(file.U32(section + 8), file.U32(section + 16));
			if (rva >= start && rva < start + length) {
				return rva - start + file.U32(section + 20);
			}
		}
		return -1;
	};

	// The resources are in a tree: by type, then number, then language.
	// Each entry is a number (or a name) and either a subtree or the data.
	struct Entry {
		int id         = 0;
		bool is_tree   = false;
		int64_t offset = 0;
	};
	const auto root    = file_offset(resource_rva);
	const auto entries = [&](const int64_t tree) {
		std::vector<Entry> list = {};
		const auto count = file.U16(tree + 12) + file.U16(tree + 14);
		for (int i = 0; i < count && file.Has(tree + 16 + 8 * i, 8); ++i) {
			const auto name = file.U32(tree + 16 + 8 * i);
			const auto data = file.U32(tree + 20 + 8 * i);
			list.push_back({(name & 0x80000000) ? -1 : static_cast<int>(name),
			                (data & 0x80000000) != 0,
			                root + (data & 0x7fffffff)});
		}
		return list;
	};
	if (root < 0) {
		return resources;
	}
	for (const auto& type : entries(root)) {
		if (!type.is_tree) {
			continue;
		}
		for (const auto& id : entries(type.offset)) {
			if (!id.is_tree) {
				continue;
			}
			const auto languages = entries(id.offset);
			if (languages.empty() || languages.front().is_tree) {
				continue;
			}
			const auto data = languages.front().offset;
			resources.push_back({type.id, id.id, file_offset(file.U32(data)), file.U32(data + 4)});
		}
	}
	return resources;
}

// A Windows program's first icon, as the contents of an .ico file, or nil
NSData* program_icon(NSData* data)
{
	const Bytes file(data);
	if (file.U16(0) != 0x5a4d) { // 'MZ'
		return nil;
	}
	const auto header = file.U32(0x3c);

	std::vector<Resource> resources = {};
	if (file.U16(header) == 0x454e) { // 'NE'
		resources = ne_resources(file, header);
	} else if (file.U32(header) == 0x4550) { // 'PE\0\0'
		resources = pe_resources(file, header);
	}

	const auto group = std::find_if(resources.begin(), resources.end(), [](const auto& resource) {
		return resource.type == IconGroupResource;
	});
	if (group == resources.end()) {
		return nil;
	}

	// An icon group lists its images like an .ico file does, but by
	// resource number instead of by where they are in the file
	const auto entry_count = file.U16(group->offset + 4);
	std::vector<std::pair<int64_t, NSData*>> images = {};
	for (int i = 0; i < entry_count; ++i) {
		const auto entry = group->offset + 6 + 14 * i;
		const auto id    = file.U16(entry + 12);
		const auto image = std::find_if(resources.begin(), resources.end(), [&](const auto& resource) {
			return resource.type == IconResource && resource.id == id;
		});
		if (image != resources.end()) {
			if (auto bytes = file.Slice(image->offset, image->length)) {
				images.emplace_back(entry, bytes);
			}
		}
	}
	if (images.empty()) {
		return nil;
	}

	auto ico = [NSMutableData data];
	const auto append_u16 = [&](const int value) {
		const uint8_t bytes[] = {static_cast<uint8_t>(value), static_cast<uint8_t>(value >> 8)};
		[ico appendBytes:bytes length:sizeof(bytes)];
	};
	const auto append_u32 = [&](const int64_t value) {
		append_u16(static_cast<int>(value & 0xffff));
		append_u16(static_cast<int>(value >> 16));
	};
	append_u16(0);
	append_u16(1);
	append_u16(static_cast<int>(images.size()));
	auto offset = static_cast<int64_t>(6 + 16 * images.size());
	for (const auto& [entry, bytes] : images) {
		[ico appendData:file.Slice(entry, 8)];
		append_u32(static_cast<int64_t>(bytes.length));
		append_u32(offset);
		offset += static_cast<int64_t>(bytes.length);
	}
	for (const auto& [entry, bytes] : images) {
		[ico appendData:bytes];
	}
	return ico;
}

// The biggest, most colourful picture in an image file (an .ico file can
// hold several), or nil
UIImage* best_picture(NSData* data)
{
	if (!data) {
		return nil;
	}
	const auto source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
	if (!source) {
		return nil;
	}
	size_t best       = 0;
	int64_t best_size = -1;
	for (size_t i = 0; i < CGImageSourceGetCount(source); ++i) {
		NSDictionary* const properties = CFBridgingRelease(
		        CGImageSourceCopyPropertiesAtIndex(source, i, nullptr));
		const auto size = [properties[(__bridge NSString*)kCGImagePropertyPixelWidth] longLongValue] *
		                          [properties[(__bridge NSString*)kCGImagePropertyPixelHeight] longLongValue] *
		                          64 +
		                  [properties[(__bridge NSString*)kCGImagePropertyDepth] longLongValue];
		if (size > best_size) {
			best      = i;
			best_size = size;
		}
	}
	UIImage* picture = nil;
	if (const auto image = CGImageSourceCreateImageAtIndex(source, best, nullptr)) {
		picture = [UIImage imageWithCGImage:image];
		CGImageRelease(image);
	}
	CFRelease(source);
	return picture;
}

// The picture in a file: an image, an .ico file or a Windows program
UIImage* picture_in_file(NSString* path)
{
	NSData* const data = [NSData dataWithContentsOfFile:path
	                                            options:NSDataReadingMappedIfSafe
	                                              error:nil];
	if (has_extension(path, @"exe") || has_extension(path, @"dll")) {
		return best_picture(program_icon(data));
	}
	return best_picture(data);
}

// The .ico files in a folder, in name order
NSArray<NSString*>* ico_files(NSString* folder)
{
	auto icons = [NSMutableArray<NSString*> array];
	const auto items = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil]
	        sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
	for (NSString* item in items) {
		if (has_extension(item, @"ico")) {
			[icons addObject:[folder stringByAppendingPathComponent:item]];
		}
	}
	return icons;
}

UIImage* first_picture(NSArray<NSString*>* paths)
{
	for (NSString* path in paths) {
		if (const auto picture = picture_in_file(path)) {
			return picture;
		}
	}
	return nil;
}

UIImage* find_icon(NSString* conf_path)
{
	if (const auto custom = [UIImage imageWithContentsOfFile:CustomIconPath(conf_path)]) {
		return custom;
	}

	if (const auto program = StartupReader(conf_path).Program()) {
		const auto folder = program.stringByDeletingLastPathComponent;
		const auto named  = find_item(folder,
                                             [program.lastPathComponent.stringByDeletingPathExtension
                                                     stringByAppendingPathExtension:@"ico"]);
		if (const auto picture = named ? picture_in_file(named) : nil) {
			return picture;
		}
		if (const auto picture = picture_in_file(program)) {
			return picture;
		}
		if (const auto picture = first_picture(ico_files(folder))) {
			return picture;
		}
	}

	if (IsGameFolder(conf_path)) {
		const auto folder = conf_path.stringByDeletingLastPathComponent;
		if (const auto picture = first_picture(ico_files(folder))) {
			return picture;
		}
		for (NSString* item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder
		                                                                         error:nil]) {
			const auto subfolder = [folder stringByAppendingPathComponent:item];
			if (const auto picture = is_folder(subfolder) ? first_picture(ico_files(subfolder))
			                                              : nil) {
				return picture;
			}
		}
	}
	return nil;
}

// A picture fitted into an icon-sized square. Small pictures (most icons)
// are enlarged by whole numbers without smoothing, so their pixels stay
// sharp and even.
UIImage* fit_icon(UIImage* picture)
{
	auto scale = UITraitCollection.currentTraitCollection.displayScale;
	if (scale <= 0) {
		scale = 2;
	}
	const auto box_px   = GameIconSize * scale;
	const auto width_px  = picture.size.width * picture.scale;
	const auto height_px = picture.size.height * picture.scale;
	auto zoom            = std::min(box_px / width_px, box_px / height_px);
	const bool is_small  = (zoom >= 1);
	if (is_small) {
		zoom = std::floor(zoom);
	}
	const auto drawn_width_px  = std::round(width_px * zoom);
	const auto drawn_height_px = std::round(height_px * zoom);
	const auto rect = CGRectMake(std::floor((box_px - drawn_width_px) / 2) / scale,
	                             std::floor((box_px - drawn_height_px) / 2) / scale,
	                             drawn_width_px / scale,
	                             drawn_height_px / scale);

	auto format     = [UIGraphicsImageRendererFormat preferredFormat];
	format.scale    = scale;
	auto renderer   = [[UIGraphicsImageRenderer alloc]
	        initWithSize:CGSizeMake(GameIconSize, GameIconSize)
	              format:format];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
		CGContextSetInterpolationQuality(context.CGContext,
		                                 is_small ? kCGInterpolationNone
		                                          : kCGInterpolationHigh);
		[picture drawInRect:rect];
	}];
}

} // namespace

UIImage* GameIcon(NSString* conf_path)
{
	id icon = [icon_cache() objectForKey:conf_path];
	if (!icon) {
		const auto picture = find_icon(conf_path);
		icon               = picture ? fit_icon(picture) : NSNull.null;
		[icon_cache() setObject:icon forKey:conf_path];
	}
	return (icon == NSNull.null) ? nil : icon;
}

void ForgetGameIcons()
{
	[icon_cache() removeAllObjects];
}

NSString* CustomIconPath(NSString* conf_path)
{
	if (IsGameFolder(conf_path)) {
		return [conf_path.stringByDeletingLastPathComponent
		        stringByAppendingPathComponent:@"icon.png"];
	}
	return [conf_path.stringByDeletingPathExtension stringByAppendingPathExtension:@"png"];
}

bool SetCustomIconImage(NSString* conf_path, UIImage* picture)
{
	if (!picture) {
		return false;
	}
	// Drawing it again also turns a photo the right way up
	const auto width_px  = picture.size.width * picture.scale;
	const auto height_px = picture.size.height * picture.scale;
	const auto shrink = std::min(1.0, CustomIconMaxPixels / std::max(width_px, height_px));

	auto format     = [UIGraphicsImageRendererFormat preferredFormat];
	format.scale    = 1;
	auto renderer   = [[UIGraphicsImageRenderer alloc]
	        initWithSize:CGSizeMake(std::round(width_px * shrink), std::round(height_px * shrink))
	              format:format];
	const auto png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext* context) {
		[picture drawInRect:context.format.bounds];
	}];
	ForgetGameIcons();
	return [png writeToFile:CustomIconPath(conf_path) atomically:YES];
}

bool SetCustomIcon(NSString* conf_path, NSURL* file)
{
	return SetCustomIconImage(conf_path, picture_in_file(file.path));
}

void RemoveCustomIcon(NSString* conf_path)
{
	[NSFileManager.defaultManager removeItemAtPath:CustomIconPath(conf_path) error:nil];
	ForgetGameIcons();
}

NSString* GameFilesFolder(NSString* conf_path)
{
	if (IsGameFolder(conf_path)) {
		return conf_path.stringByDeletingLastPathComponent;
	}
	return StartupReader(conf_path).DriveC();
}
