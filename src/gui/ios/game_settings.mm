// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/game_settings.h"

#include "gui/ios/game_icons.h"
#include "gui/ios/game_import.h"
#include "gui/ios/library.h"
#include "gui/ios/windows_display.h"

#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <SDL3/SDL.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <numeric>
#include <optional>
#include <utility>
#include <vector>

NSString* const GameSettingsChangedNotification = @"DBGameSettingsChanged";

namespace {

NSString* current_game_name = nil;
NSString* current_game_conf = nil;

// App-only settings: a dictionary of each game's settings, by game name
NSString* const AppSettingsKey   = @"GameSettings";
NSString* const DirectTouchKey   = @"DirectTouch";
NSString* const GameKeysKey      = @"GameKeys";
NSString* const NoGameKeys       = @"None";
NSString* const CustomGameKeys   = @"Custom";
NSString* const CustomGameKeysKey = @"CustomGameKeys";
NSString* const GamepadStickKey   = @"GamepadStick";
NSString* const JoystickStick     = @"Joystick";
NSString* const GamepadShownKey   = @"GamepadShown";
NSString* const GamepadButtonsKey = @"GamepadButtons";

NSString* trimmed(NSString* text)
{
	return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

NSDictionary* app_settings(NSString* game)
{
	return [NSUserDefaults.standardUserDefaults dictionaryForKey:AppSettingsKey][game];
}

void set_app_setting(NSString* game, NSString* key, id value)
{
	auto defaults = NSUserDefaults.standardUserDefaults;
	auto all      = [[defaults dictionaryForKey:AppSettingsKey] mutableCopy]
	                    ?: [NSMutableDictionary dictionary];
	auto settings = [all[game] mutableCopy] ?: [NSMutableDictionary dictionary];

	settings[key] = value;
	all[game]     = settings;
	[defaults setObject:all forKey:AppSettingsKey];

	[NSNotificationCenter.defaultCenter postNotificationName:GameSettingsChangedNotification
	                                                  object:nil];
}

void rename_app_settings(NSString* old_name, NSString* new_name)
{
	auto defaults = NSUserDefaults.standardUserDefaults;
	auto all      = [[defaults dictionaryForKey:AppSettingsKey] mutableCopy];
	if (all[old_name]) {
		all[new_name] = all[old_name];
		[all removeObjectForKey:old_name];
		[defaults setObject:all forKey:AppSettingsKey];
	}
}

// Renames a game in the library. A game folder's config mounts the folder
// by its path, so that's updated too.
NSString* rename_game(NSString* old_name, NSString* conf_path, NSString* new_name,
                      NSError** error)
{
	auto files = NSFileManager.defaultManager;

	if (new_name.length == 0 || [new_name hasPrefix:@"."] ||
	    [new_name rangeOfString:@"/"].location != NSNotFound) {
		*error = [NSError errorWithDomain:NSCocoaErrorDomain
		                             code:NSFileWriteInvalidFileNameError
		                         userInfo:@{NSLocalizedDescriptionKey: @"That name can't be used."}];
		return nil;
	}
	if (FindGames()[new_name]) {
		*error = [NSError errorWithDomain:NSCocoaErrorDomain
		                             code:NSFileWriteFileExistsError
		                         userInfo:@{NSLocalizedDescriptionKey: @"Another game already has that name."}];
		return nil;
	}

	NSString* new_conf_path = nil;
	if (IsGameFolder(conf_path)) {
		const auto old_folder = conf_path.stringByDeletingLastPathComponent;
		const auto new_folder = [GamesFolder stringByAppendingPathComponent:new_name];
		if (![files moveItemAtPath:old_folder toPath:new_folder error:error]) {
			return nil;
		}
		new_conf_path = [new_folder stringByAppendingPathComponent:conf_path.lastPathComponent];

		auto conf = [NSString stringWithContentsOfFile:new_conf_path
		                                      encoding:NSUTF8StringEncoding
		                                         error:nil];
		for (NSString* end in @[@"/", @"\""]) {
			conf = [conf stringByReplacingOccurrencesOfString:[old_folder stringByAppendingString:end]
			                                       withString:[new_folder stringByAppendingString:end]];
		}
		[conf writeToFile:new_conf_path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	} else {
		new_conf_path = [GamesFolder
		        stringByAppendingPathComponent:[new_name stringByAppendingPathExtension:@"conf"]];
		if (![files moveItemAtPath:conf_path toPath:new_conf_path error:error]) {
			return nil;
		}
		[files moveItemAtPath:CustomIconPath(conf_path)
		               toPath:CustomIconPath(new_conf_path)
		                error:nil];
	}

	rename_app_settings(old_name, new_name);
	return new_conf_path;
}

// The emulator settings offered for each game. Choosing 'Default' removes
// the setting from the game's config, so the shared config's value applies.

struct Choice {
	NSString* title;
	NSString* value;
	// The line under the title in the menu: short, the menu truncates it
	NSString* subtitle = nil;
	// The explanation under the setting's row while this is the choice
	NSString* detail = nil;
	// A mark beside the title in the menu
	UIImage* image = nil;
};

struct ConfSetting {
	NSString* title;
	NSString* section;
	// All are set to the same value; the first is read back
	NSArray<NSString*>* keys;
	std::vector<Choice> choices;
	// The explanation under the row when no config sets the value
	NSString* default_detail = nil;
};

const std::vector<ConfSetting>& conf_settings()
{
	static const std::vector<ConfSetting> settings = {
	        {@"CPU speed",
	         @"cpu",
	         @[@"cpu_cycles", @"cpu_cycles_protected"],
	         {{@"386SX (3,000)",
	           @"3000",
	           nil,
	           @"About a 386SX: for early games that run too fast on anything quicker."},
	          {@"386DX (8,000)", @"8000", nil, @"About a 386DX: most games up to around 1992."},
	          {@"486 (25,000)", @"25000", nil, @"About a 486: games up to around 1995."},
	          {@"Pentium (50,000)",
	           @"50000",
	           nil,
	           @"About a Pentium: late DOS games, if the device keeps up."},
	          {@"As fast as possible",
	           @"max",
	           nil,
	           @"Everything the device can give, at the DOS prompt and in Windows. Games that "
	           @"pace themselves by the CPU run too fast."}},
	         @"Staging's default: 3,000 cycles at the DOS prompt, 60,000 in Windows and other "
	         @"protected-mode programs."},
	        {@"Memory",
	         @"dosbox",
	         @[@"memsize"],
	         {{@"4 MB", @"4", nil, @"Enough for early games; a few refuse to run with more."},
	          {@"8 MB", @"8", nil, @"Plenty for most DOS games."},
	          {@"16 MB",
	           @"16",
	           nil,
	           @"Staging's default: fine for Windows 3.1 and nearly every game."},
	          {@"32 MB",
	           @"32",
	           nil,
	           @"For the few late games that ask for it. Some take longer to start with more "
	           @"memory."},
	          {@"64 MB", @"64", nil, @"Only for games that need it; starting can take longer."}},
	         @"Staging's default: 16 MB."},
	        {@"Picture",
	         @"render",
	         @[@"aspect"],
	         {{@"4:3, like a CRT",
	           @"on",
	           nil,
	           @"Modes with tall pixels, such as 320x200, are shown as a 4:3 monitor showed "
	           @"them. Square-pixel modes are left alone."},
	          {@"Square pixels",
	           @"square-pixels",
	           nil,
	           @"No correction: 320x200 games look squat, but a few, such as ports of Amiga "
	           @"games, were drawn for this."},
	          {@"Fill the screen",
	           @"stretch",
	           nil,
	           @"Stretches the picture to the screen's shape, whatever the game's."}},
	         @"Staging's default: 4:3 for modes with tall pixels, square-pixel modes as they "
	         @"are."},
	        {@"Integer scaling",
	         @"render",
	         @[@"integer_scaling"],
	         {{@"Even CRT scanlines",
	           @"auto",
	           @"Whole steps for CRT shaders",
	           @"Staging's default. A CRT shader shrinks the picture to a whole number of "
	           @"pixels per line, leaving black bars, so its scanlines are even. Sharp pixels "
	           @"still fill the screen."},
	          {@"Whole steps always",
	           @"vertical",
	           @"Black bars, even pixels",
	           @"Every picture shrinks to a whole number of pixels per line, leaving black "
	           @"bars."},
	          {@"Fill the screen",
	           @"off",
	           @"CRT scanlines may band",
	           @"The picture fills the screen. At a size that doesn't divide the screen evenly, "
	           @"a CRT shader's scanlines band."}},
	         @"Staging's default: a CRT shader shrinks the picture to a whole number of pixels "
	         @"per line, leaving black bars, so its scanlines are even. Sharp pixels still fill "
	         @"the screen."},
	};
	return settings;
}

// The SoundFonts the user has added, and any in Staging's own folder
NSArray<NSString*>* find_soundfonts()
{
	const auto staging_folder = [NSHomeDirectory()
	        stringByAppendingPathComponent:@"Library/Preferences/DOSBox/soundfonts"];

	auto names = [NSMutableSet<NSString*> set];
	for (NSString* folder in @[SoundFontsFolder, staging_folder]) {
		for (NSString* item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder
		                                                                         error:nil]) {
			const auto extension = item.pathExtension.lowercaseString;
			if ([extension isEqualToString:@"sf2"] || [extension isEqualToString:@"sf3"]) {
				[names addObject:item];
			}
		}
	}
	return [names.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

bool has_mt32_roms()
{
	for (NSString* item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:Mt32RomsFolder
	                                                                         error:nil]) {
		if (![item hasPrefix:@"."]) {
			return true;
		}
	}
	return false;
}

// Shaders need the GPU output; without one, the screen is drawn with sharp
// pixels
NSString* const GpuOutput   = @"gpu";
NSString* const SharpOutput = @"texturesharp";

// The shaders in a folder and its subfolders, by the names Staging knows them
// by: their paths without the extension, such as 'crt/vga-1080p'
NSArray<NSString*>* find_shaders(NSString* folder)
{
	auto names = [NSMutableArray<NSString*> array];
	for (NSString* path in [NSFileManager.defaultManager enumeratorAtPath:folder]) {
		if ([path.pathExtension.lowercaseString isEqualToString:@"glsl"] &&
		    ![path hasPrefix:@"_"]) {
			[names addObject:path.stringByDeletingPathExtension];
		}
	}
	return [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

NSString* bundled_resource(NSString* name)
{
	return [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"assets"]
	        stringByAppendingPathComponent:name];
}

// The CRT shader's presets, such as 'vga-4k'
NSArray<NSString*>* find_crt_presets()
{
	auto names = [NSMutableArray<NSString*> array];
	for (NSString* item in [NSFileManager.defaultManager
	             contentsOfDirectoryAtPath:bundled_resource(@"shader-presets/crt/crt-hyllian")
	                                 error:nil]) {
		if ([item.pathExtension isEqualToString:@"preset"]) {
			[names addObject:item.stringByDeletingPathExtension];
		}
	}
	return [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

// A Windows screen size that fills the display. 1.5 pixels per point keeps
// Windows' text readable: 1264x584 on an iPhone 14, 1920x1440 on a 12.9"
// iPad Pro. Staging's custom VESA mode is at most 1920x1440, with the width
// a multiple of 8.
// Staging's largest custom VESA mode
constexpr double MaxCustomWidth  = 1920;
constexpr double MaxCustomHeight = 1440;

UIScreen* app_screen()
{
	for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
		if ([scene isKindOfClass:UIWindowScene.class]) {
			return static_cast<UIWindowScene*>(scene).screen;
		}
	}
	return UIScreen.mainScreen;
}

// The screen's size in pixels, landscape
CGSize screen_pixel_size()
{
	const auto bounds = app_screen().nativeBounds.size;
	return {std::max(bounds.width, bounds.height), std::min(bounds.width, bounds.height)};
}

NSString* fit_screen_size()
{
	const auto screen = app_screen().bounds.size;

	constexpr double PixelsPerPoint = 1.5;

	const auto width  = std::max(screen.width, screen.height) * PixelsPerPoint;
	const auto height = std::min(screen.width, screen.height) * PixelsPerPoint;
	const auto scale  = std::min({1.0, MaxCustomWidth / width, MaxCustomHeight / height});

	const auto round_to_8 = [](const double value) {
		return static_cast<int>(std::lround(value / 8)) * 8;
	};
	return [NSString stringWithFormat:@"%dx%d",
	                                  std::min(round_to_8(width * scale), static_cast<int>(MaxCustomWidth)),
	                                  std::min(round_to_8(height * scale), static_cast<int>(MaxCustomHeight))];
}

// What CRT shaders make of a Windows screen size on this screen. Staging's
// Auto CRT picks a preset from the screen pixels per emulated line
// (auto_shader_switcher.cpp): 4 or more give vga-4k, 3 vga-1440p, 2 vga-1080p
// and fewer show sharp pixels. crt/vga-1080p darkens every second pixel row,
// so it only looks even at exactly 2 pixels per line; the hyllian presets look
// even at whole numbers, at 3.5 and 4.5, and above 5. Anything else makes the
// scanlines beat against the pixel grid (banding). With 'integer_scaling' at
// 'auto' or 'vertical', Staging shrinks a CRT-shaded picture to the nearest
// such step and leaves black bars instead.
struct ScanlineAdvice {
	double pixels_per_line = 0; // 0 when the size can't be read
	double scale           = 0; // after integer scaling, if any
	NSString* auto_shader  = nil; // nil: Auto CRT shows sharp pixels
	bool even              = false; // for Auto CRT's choice
	int bars_percent       = 0; // of the height, when integer scaling shrinks it
};

constexpr double ScaleTolerance = 0.001;

bool is_whole(const double value)
{
	return std::abs(value - std::round(value)) < ScaleTolerance;
}

// Whether a CRT shader's scanlines land evenly at this scale
bool even_scanlines(const double scale, const bool is_vga_1080p)
{
	if (is_vga_1080p) {
		return std::abs(scale - 2) < ScaleTolerance;
	}
	return is_whole(scale) || (scale >= 3 && is_whole(scale * 2)) || scale >= 5;
}

ScanlineAdvice scanline_advice(NSString* size, NSString* conf_path)
{
	const auto parts = [size.lowercaseString componentsSeparatedByString:@"x"];
	if (parts.count != 2 || parts[0].intValue <= 0 || parts[1].intValue <= 0) {
		return {};
	}
	const auto screen = screen_pixel_size();
	const auto height = parts[1].doubleValue;

	ScanlineAdvice advice  = {};
	advice.pixels_per_line = std::min(screen.width / parts[0].doubleValue,
	                                  screen.height / height);
	const auto pixels = advice.pixels_per_line;
	advice.scale      = pixels;
	if (pixels < 2) {
		return advice;
	}
	advice.auto_shader = pixels >= 4 ? @"vga-4k" : pixels >= 3 ? @"vga-1440p" : @"vga-1080p";

	NSString* const integer_scaling =
	        (ReadConfValue(conf_path, @"render", @"integer_scaling")
	                 ?: ReadConfValue(@"dosbox.conf", @"render", @"integer_scaling") ?: @"auto")
	                .lowercaseString;
	if ([integer_scaling isEqualToString:@"vertical"]) {
		advice.scale = std::floor(pixels);
	} else if ([integer_scaling isEqualToString:@"auto"]) {
		// Staging's handle_auto_mode(): whole steps below 3, half steps
		// from 3 to 5, no constraint above 5
		advice.scale = pixels >= 5   ? pixels
		             : pixels >= 3 ? std::floor(pixels * 2) / 2
		                           : std::floor(pixels);
	}
	advice.even = even_scanlines(advice.scale, [advice.auto_shader isEqualToString:@"vga-1080p"]);
	advice.bars_percent = static_cast<int>(
	        std::lround((1 - advice.scale * height / screen.height) * 100));
	return advice;
}

// Whole numbers as such, and enough decimals that a near miss (2.003, which
// bands) doesn't read as a whole number
NSString* pixels_text(const double value)
{
	if (is_whole(value)) {
		return [NSString stringWithFormat:@"%d", static_cast<int>(std::lround(value))];
	}
	const auto near_whole = std::abs(value - std::round(value)) < 0.005;
	return [NSString stringWithFormat:near_whole ? @"%.3f" : @"%.2f", value];
}

// A screen size's line in the Screen size menu: short, the menu truncates it
NSString* size_subtitle(NSString* size, NSString* conf_path)
{
	const auto advice = scanline_advice(size, conf_path);
	if (advice.pixels_per_line <= 0) {
		return nil;
	}
	NSString* const pixels = [NSString stringWithFormat:@"%@ px per line",
	                                                    pixels_text(advice.pixels_per_line)];
	if (!advice.auto_shader) {
		return [pixels stringByAppendingString:@", no CRT shader"];
	}
	if (!advice.even) {
		return [pixels stringByAppendingString:@", CRT bands"];
	}
	if (advice.bars_percent > 0) {
		return [NSString stringWithFormat:@"%@, CRT %d%% bars", pixels, advice.bars_percent];
	}
	return [pixels stringByAppendingString:@", CRT even"];
}

NSArray<NSString*>* whole_pixel_sizes();

// The explanation under the Screen size row for the size in use
NSString* size_detail(NSString* size, NSString* conf_path)
{
	const auto advice = scanline_advice(size, conf_path);
	if (advice.pixels_per_line <= 0) {
		return nil;
	}
	NSString* const gives = [NSString stringWithFormat:@"%@ gives %@ pixels per line on this screen",
	                                                   size,
	                                                   pixels_text(advice.pixels_per_line)];
	if (!advice.auto_shader) {
		return [gives stringByAppendingString:
		                      @", too few for a CRT shader: Auto CRT shows sharp pixels."];
	}
	if (advice.even && advice.bars_percent > 0) {
		return [NSString stringWithFormat:
		                         @"%@. Auto CRT picks %@, shrinking the picture to %@x with "
		                         @"%d%% black bars so the scanlines are even.",
		                         gives,
		                         advice.auto_shader,
		                         pixels_text(advice.scale),
		                         advice.bars_percent];
	}
	if (advice.even) {
		return [NSString stringWithFormat:@"%@. Auto CRT picks %@ and its scanlines land evenly.",
		                                  gives,
		                                  advice.auto_shader];
	}
	auto even_sizes = [NSMutableArray<NSString*> array];
	for (NSString* candidate in whole_pixel_sizes()) {
		if (scanline_advice(candidate, conf_path).even) {
			[even_sizes addObject:candidate];
		}
	}
	NSString* const note = [NSString stringWithFormat:@"%@. Auto CRT picks %@ and its scanlines "
	                                                  @"band.",
	                                                  gives,
	                                                  advice.auto_shader];
	if (even_sizes.count == 0) {
		return note;
	}
	return [NSString stringWithFormat:@"%@ Even on this screen: %@.",
	                                  note,
	                                  [even_sizes componentsJoinedByString:@", "]];
}

// A shader's note in the Shader menu, for a game with a Windows screen size
// How a CRT shader fits a Windows game's screen size
enum class ShaderFit { Unknown, Even, Bands, TooFewLines };

struct ShaderNote {
	NSString* subtitle = nil;
	ShaderFit fit      = ShaderFit::Unknown;
};

ShaderNote shader_note(NSString* shader_name, NSString* windows_size, NSString* conf_path)
{
	if (!windows_size) {
		return {};
	}
	if ([shader_name isEqualToString:@"crt/vga-1080p-fake-double-scan"]) {
		return {@"For 320x200 games"};
	}
	const auto advice = scanline_advice(windows_size, conf_path);
	if (advice.pixels_per_line <= 0) {
		return {};
	}
	NSString* const pixels = pixels_text(advice.pixels_per_line);
	if ([shader_name isEqualToString:@"crt-auto"]) {
		if (!advice.auto_shader) {
			return {[NSString stringWithFormat:@"Sharp pixels at %@", windows_size]};
		}
		return {[NSString stringWithFormat:@"%@ at %@, %@",
		                                   advice.auto_shader,
		                                   windows_size,
		                                   advice.even ? @"even" : @"bands"],
		        advice.even ? ShaderFit::Even : ShaderFit::Bands};
	}
	// The preset names say how many pixels per line they were made for
	const auto needed = [&] {
		if ([shader_name hasSuffix:@"-4k"]) {
			return 4;
		}
		if ([shader_name hasSuffix:@"-1440p"] || [shader_name hasSuffix:@"-720p"]) {
			return 3;
		}
		if ([shader_name hasSuffix:@"-1080p"]) {
			return 2;
		}
		return 0;
	}();
	if (needed == 0) {
		return {};
	}
	const auto is_vga_1080p = [shader_name isEqualToString:@"crt/vga-1080p"];
	if (advice.pixels_per_line < needed) {
		return {[NSString stringWithFormat:@"Needs %d px per line, has %@", needed, pixels],
		        ShaderFit::TooFewLines};
	}
	if (!even_scanlines(advice.scale, is_vga_1080p)) {
		return {[NSString stringWithFormat:@"Bands at %@ px per line", pixels], ShaderFit::Bands};
	}
	if (advice.bars_percent > 0) {
		return {[NSString stringWithFormat:@"Even at %@, %d%% bars", windows_size, advice.bars_percent],
		        ShaderFit::Even};
	}
	return {[NSString stringWithFormat:@"Even at %@", windows_size], ShaderFit::Even};
}

// A menu mark for the fit: green for even scanlines, orange for banding,
// grey when the size has too few lines for the shader
UIImage* fit_image(const ShaderFit fit)
{
	NSString* name = nil;
	UIColor* color = nil;
	switch (fit) {
	case ShaderFit::Even:
		name  = @"checkmark.seal.fill";
		color = UIColor.systemGreenColor;
		break;
	case ShaderFit::Bands:
		name  = @"exclamationmark.triangle.fill";
		color = UIColor.systemOrangeColor;
		break;
	case ShaderFit::TooFewLines:
		name  = @"minus.circle.fill";
		color = UIColor.systemGrayColor;
		break;
	case ShaderFit::Unknown: return nil;
	}
	return [[UIImage systemImageNamed:name] imageWithTintColor:color
	                                             renderingMode:UIImageRenderingModeAlwaysOriginal];
}

// A size's aspect ratio: the familiar form, such as 4:3, when there is one
// (or it is within a percent of one, as 1360x1024 and 904x682 are, since
// widths are rounded to multiples of 8), otherwise to two decimal places, such as 2.16:1
NSString* aspect_ratio(NSString* size)
{
	const auto parts = [size.lowercaseString componentsSeparatedByString:@"x"];
	if (parts.count != 2) {
		return nil;
	}
	const auto width  = parts[0].intValue;
	const auto height = parts[1].intValue;
	if (width <= 0 || height <= 0) {
		return nil;
	}
	constexpr std::pair<int, int> familiar_ratios[] = {
	        {4, 3}, {5, 4}, {3, 2}, {16, 10}, {16, 9}};
	const auto ratio = static_cast<double>(width) / height;
	for (const auto& [a, b] : familiar_ratios) {
		if (std::abs(ratio / (static_cast<double>(a) / b) - 1.0) < 0.01) {
			return [NSString stringWithFormat:@"%d:%d", a, b];
		}
	}
	const auto divisor = std::gcd(width, height);
	if (width / divisor <= 21 && height / divisor <= 21) {
		return [NSString stringWithFormat:@"%d:%d", width / divisor, height / divisor];
	}
	return [NSString stringWithFormat:@"%.2f:1", static_cast<double>(width) / height];
}

// The sizes with a whole number of screen pixels per line (2, 3, 4...), for
// even CRT scanlines, with the width rounded down to a multiple of 8
NSArray<NSString*>* whole_pixel_sizes()
{
	constexpr int MinWidth = 640; // narrower is for DOS games, not a desktop
	const auto screen      = screen_pixel_size();

	auto sizes = [NSMutableArray<NSString*> array];
	for (int pixels_per_line = 2;; ++pixels_per_line) {
		const auto height = static_cast<int>(screen.height / pixels_per_line);
		const auto width  = static_cast<int>(std::min(height * screen.width / screen.height,
		                                              screen.width / pixels_per_line) /
		                                     8) *
		                    8;
		if (width < MinWidth) {
			break;
		}
		if (width <= MaxCustomWidth && height <= MaxCustomHeight) {
			[sizes addObject:[NSString stringWithFormat:@"%dx%d", width, height]];
		}
	}
	return sizes;
}

// A size's mark in the menu: green where Auto CRT's shader fills the screen
// with even scanlines, orange where it bands, none otherwise
UIImage* size_image(NSString* size, NSString* conf_path)
{
	const auto advice = scanline_advice(size, conf_path);
	if (advice.pixels_per_line <= 0 || !advice.auto_shader) {
		return nil;
	}
	if (!advice.even) {
		return fit_image(ShaderFit::Bands);
	}
	return advice.bars_percent > 0 ? nil : fit_image(ShaderFit::Even);
}

ConfSetting screen_size_setting(NSString* conf_path)
{
	const auto fit  = fit_screen_size();
	auto setting    = ConfSetting{@"Screen size", @"dosbox", @[@"vesa_custom_resolution"], {}};
	setting.choices = {{[NSString stringWithFormat:@"Fit the screen (%@, %@)", fit, aspect_ratio(fit)],
	                    fit,
	                    size_subtitle(fit, conf_path),
	                    size_detail(fit, conf_path),
	                    size_image(fit, conf_path)}};

	auto sizes = [NSMutableOrderedSet<NSString*> orderedSetWithArray:whole_pixel_sizes()];
	[sizes addObjectsFromArray:@[@"1280x960", @"1024x768", @"800x600", @"640x480"]];
	[sizes removeObject:fit];
	const auto height_of = [](NSString* size) {
		return [size componentsSeparatedByString:@"x"].lastObject.intValue;
	};
	[sizes sortUsingComparator:^(NSString* a, NSString* b) {
		return [@(height_of(b)) compare:@(height_of(a))];
	}];
	for (NSString* size in sizes) {
		setting.choices.push_back({[NSString stringWithFormat:@"%@ (%@)", size, aspect_ratio(size)],
		                           size,
		                           size_subtitle(size, conf_path),
		                           size_detail(size, conf_path),
		                           size_image(size, conf_path)});
	}
	return setting;
}

UIAction* make_action(NSString* title, const bool is_on, void (^handler)())
{
	auto action  = [UIAction actionWithTitle:title
	                                  image:nil
	                             identifier:nil
	                                handler:^(UIAction*) {
		                                handler();
	                                }];
	action.state = is_on ? UIMenuElementStateOn : UIMenuElementStateOff;
	return action;
}

// The narrowest screen that has room for two columns of settings, in points
constexpr CGFloat TwoColumnWidth = 700;
// The settings column's share of a wide screen; the touch controls get the rest
constexpr CGFloat SettingsColumnShare = 0.6;

// The width of the column a settings row is in
CGFloat settings_column_width()
{
	const auto width = app_screen().bounds.size.width;
	return width >= TwoColumnWidth ? width * SettingsColumnShare : width;
}

UIButton* make_menu_button(UIMenu* menu)
{
	auto config                    = UIButtonConfiguration.plainButtonConfiguration;
	config.indicator               = UIButtonConfigurationIndicatorPopup;
	config.titleLineBreakMode      = NSLineBreakByTruncatingTail;
	auto button                    = [UIButton buttonWithConfiguration:config primaryAction:nil];
	button.menu                    = menu;
	button.showsMenuAsPrimaryAction = YES;
	button.changesSelectionAsPrimaryAction = YES;
	[button sizeToFit];
	// A long title must not run into the row's own text or the next column
	auto frame       = button.frame;
	frame.size.width = std::min(frame.size.width, settings_column_width() / 2);
	button.frame     = frame;
	return button;
}

// Without a choice, the bottom and right buttons are the joystick's buttons
// when the stick is a joystick, and Ctrl and Alt otherwise (the fire buttons
// of many keyboard games)
int default_gamepad_button(const GamepadStick stick, const int button)
{
	const auto is_joystick = (stick == GamepadStick::Joystick);
	switch (button) {
	case 0: return is_joystick ? JoystickButton1 : SDL_SCANCODE_LCTRL;
	case 1: return is_joystick ? JoystickButton2 : SDL_SCANCODE_LALT;
	case 2: return SDL_SCANCODE_SPACE;
	default: return SDL_SCANCODE_RETURN;
	}
}

void set_gamepad_button(NSString* game, const int button, const int action)
{
	auto buttons = [app_settings(game)[GamepadButtonsKey] mutableCopy]
	                       ?: [NSMutableDictionary dictionary];
	buttons[@(button).stringValue] = @(action);
	set_app_setting(game, GamepadButtonsKey, buttons);
}

// The keys a gamepad button or a game key can send, in the groups their
// menus show them
struct KeyGroup {
	NSString* title = nil; // nil for a group shown in the menu itself
	std::vector<int> actions = {};
};

std::vector<KeyGroup> key_groups()
{
	const auto key_range = [](const SDL_Scancode first, const SDL_Scancode last) {
		std::vector<int> keys = {};
		for (int key = first; key <= last; ++key) {
			keys.push_back(key);
		}
		return keys;
	};
	return {{nil,
	         {SDL_SCANCODE_LCTRL,
	          SDL_SCANCODE_LALT,
	          SDL_SCANCODE_LSHIFT,
	          SDL_SCANCODE_SPACE,
	          SDL_SCANCODE_RETURN,
	          SDL_SCANCODE_ESCAPE,
	          SDL_SCANCODE_TAB,
	          SDL_SCANCODE_BACKSPACE}},
	        {@"Letters", key_range(SDL_SCANCODE_A, SDL_SCANCODE_Z)},
	        {@"Numbers", key_range(SDL_SCANCODE_1, SDL_SCANCODE_0)},
	        {@"Function keys", key_range(SDL_SCANCODE_F1, SDL_SCANCODE_F12)},
	        {@"Arrow keys",
	         {SDL_SCANCODE_UP, SDL_SCANCODE_DOWN, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT}},
	        {@"Other keys",
	         {SDL_SCANCODE_HOME,         SDL_SCANCODE_END,          SDL_SCANCODE_PAGEUP,
	          SDL_SCANCODE_PAGEDOWN,     SDL_SCANCODE_INSERT,       SDL_SCANCODE_DELETE,
	          SDL_SCANCODE_MINUS,        SDL_SCANCODE_EQUALS,       SDL_SCANCODE_LEFTBRACKET,
	          SDL_SCANCODE_RIGHTBRACKET, SDL_SCANCODE_BACKSLASH,    SDL_SCANCODE_SEMICOLON,
	          SDL_SCANCODE_APOSTROPHE,   SDL_SCANCODE_GRAVE,        SDL_SCANCODE_COMMA,
	          SDL_SCANCODE_PERIOD,       SDL_SCANCODE_SLASH}}};
}

std::vector<KeyGroup> gamepad_key_groups()
{
	auto groups = key_groups();
	groups.insert(groups.begin(), {nil, {JoystickButton1, JoystickButton2}});
	return groups;
}

// Ready-made sets of game keys. A game with 'match' in its name gets the set
// until another is chosen.
struct KeySet {
	NSString* name            = nil;
	NSString* match           = nil;
	std::vector<GameKey> keys = {};
};

const std::vector<KeySet>& key_sets()
{
	static const std::vector<KeySet> sets = {
	        // Sid Meier's Colonization. The unit order keys come from the
	        // order table in the game's COLTEXT0.DLL.
	        {@"Colonization",
	         @"coloni",
	         {{SDL_SCANCODE_B, 0, @"Build colony"},
	          {SDL_SCANCODE_F, 0, @"Fortify"},
	          {SDL_SCANCODE_S, 0, @"Sentry"},
	          {SDL_SCANCODE_G, 0, @"Go to"},
	          {SDL_SCANCODE_P, 0, @"Clear/plow"},
	          {SDL_SCANCODE_R, 0, @"Road"},
	          {SDL_SCANCODE_T, 0, @"Trade route"},
	          {SDL_SCANCODE_L, 0, @"Live in village"},
	          {SDL_SCANCODE_W, 0, @"Wait"},
	          {SDL_SCANCODE_SPACE, 0, @"No orders"},
	          {SDL_SCANCODE_RETURN},
	          {SDL_SCANCODE_ESCAPE}}},

	        // Sid Meier's CivNet, which has Civilization's orders. The
	        // keys come from its help file, CIVHELP.HLP.
	        {@"CivNet",
	         @"civ",
	         {{SDL_SCANCODE_B, 0, @"Found city"},
	          {SDL_SCANCODE_R, 0, @"Road"},
	          {SDL_SCANCODE_I, 0, @"Irrigate"},
	          {SDL_SCANCODE_M, 0, @"Mine"},
	          {SDL_SCANCODE_F, 0, @"Fortify"},
	          {SDL_SCANCODE_S, 0, @"Sentry"},
	          {SDL_SCANCODE_G, 0, @"Go to"},
	          {SDL_SCANCODE_W, 0, @"Wait"},
	          {SDL_SCANCODE_N, 0, @"No orders"},
	          {SDL_SCANCODE_P, 0, @"Pillage"},
	          {SDL_SCANCODE_H, 0, @"Home city"},
	          {SDL_SCANCODE_U, 0, @"Unload"}}},
	};
	return sets;
}

// The name of the game's set of keys: a ready-made set's, 'Custom' or 'None'
NSString* game_key_set(NSString* game)
{
	if (NSString* name = app_settings(game)[GameKeysKey]) {
		return name;
	}
	for (const auto& set : key_sets()) {
		if ([game.lowercaseString containsString:set.match]) {
			return set.name;
		}
	}
	return NoGameKeys;
}

std::vector<GameKey> custom_game_keys(NSString* game)
{
	std::vector<GameKey> keys = {};
	for (NSDictionary* key in app_settings(game)[CustomGameKeysKey]) {
		keys.push_back({[key[@"key"] intValue], [key[@"modifiers"] intValue], key[@"caption"]});
	}
	return keys;
}

// Changing the keys makes them the game's own, even if they started as a
// ready-made set
void set_custom_game_keys(NSString* game, const std::vector<GameKey>& keys)
{
	auto array = [NSMutableArray array];
	for (const auto& key : keys) {
		auto dict = [NSMutableDictionary dictionary];
		dict[@"key"]       = @(key.scancode);
		dict[@"modifiers"] = @(key.modifiers);
		if (key.caption.length > 0) {
			dict[@"caption"] = key.caption;
		}
		[array addObject:dict];
	}
	set_app_setting(game, CustomGameKeysKey, array);
	set_app_setting(game, GameKeysKey, CustomGameKeys);
}

} // namespace

NSString* CurrentGameName()
{
	return current_game_name;
}

NSString* CurrentGameConfPath()
{
	return current_game_conf;
}

void SetCurrentGame(NSString* name, NSString* conf_path)
{
	current_game_name = name;
	current_game_conf = conf_path;
}

bool IsDirectTouch(NSString* game)
{
	if (const id value = app_settings(game)[DirectTouchKey]) {
		return [value boolValue];
	}
	// Before it was chosen per game, there was one setting for all games
	auto defaults = NSUserDefaults.standardUserDefaults;
	return ([defaults objectForKey:DirectTouchKey] == nil) ||
	       [defaults boolForKey:DirectTouchKey];
}

void SetDirectTouch(NSString* game, bool direct_touch)
{
	set_app_setting(game, DirectTouchKey, @(direct_touch));
}

std::vector<GameKey> GetGameKeys(NSString* game)
{
	NSString* const name = game_key_set(game);
	if ([name isEqualToString:CustomGameKeys]) {
		return custom_game_keys(game);
	}
	for (const auto& set : key_sets()) {
		if ([name isEqualToString:set.name]) {
			return set.keys;
		}
	}
	return {};
}

NSString* GameKeyLabel(const GameKey& key)
{
	auto label = [NSMutableString string];
	if (key.modifiers & GameKeyCtrl) {
		[label appendString:@"Ctrl+"];
	}
	if (key.modifiers & GameKeyAlt) {
		[label appendString:@"Alt+"];
	}
	if (key.modifiers & GameKeyShift) {
		[label appendString:@"Shift+"];
	}
	[label appendString:GamepadButtonLabel(key.scancode)];
	return label;
}

GamepadStick GetGamepadStick(NSString* game)
{
	return [app_settings(game)[GamepadStickKey] isEqual:JoystickStick]
	             ? GamepadStick::Joystick
	             : GamepadStick::ArrowKeys;
}

bool IsGamepadShown(NSString* game)
{
	return [app_settings(game)[GamepadShownKey] boolValue];
}

void SetGamepadShown(NSString* game, const bool shown)
{
	set_app_setting(game, GamepadShownKey, @(shown));
}

int GetGamepadButton(NSString* game, const int button)
{
	if (NSNumber* action = app_settings(game)[GamepadButtonsKey][@(button).stringValue]) {
		return action.intValue;
	}
	return default_gamepad_button(GetGamepadStick(game), button);
}

NSString* GamepadButtonLabel(const int action)
{
	switch (action) {
	case JoystickButton1: return @"Fire 1";
	case JoystickButton2: return @"Fire 2";
	case SDL_SCANCODE_LCTRL: return @"Ctrl";
	case SDL_SCANCODE_LALT: return @"Alt";
	case SDL_SCANCODE_LSHIFT: return @"Shift";
	case SDL_SCANCODE_RETURN: return @"Enter";
	case SDL_SCANCODE_ESCAPE: return @"Esc";
	case SDL_SCANCODE_PAGEUP: return @"PgUp";
	case SDL_SCANCODE_PAGEDOWN: return @"PgDn";
	case SDL_SCANCODE_INSERT: return @"Ins";
	case SDL_SCANCODE_DELETE: return @"Del";
	case SDL_SCANCODE_UP: return @"↑";
	case SDL_SCANCODE_DOWN: return @"↓";
	case SDL_SCANCODE_LEFT: return @"←";
	case SDL_SCANCODE_RIGHT: return @"→";
	default: return @(SDL_GetScancodeName(static_cast<SDL_Scancode>(action)));
	}
}

// Edits one of a game's keys: which key, the keys held with it, and its label

@interface DBGameKeyViewController : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithGame:(NSString*)game index:(size_t)index;
@end

@implementation DBGameKeyViewController {
	NSString* _game;
	size_t _index;
}

enum KeySection { KeyChoiceSection, ModifiersSection, CaptionSection, KeySectionCount };

constexpr NSInteger CaptionFieldTag = 1;

// The modifiers in the order their rows show them
constexpr std::array<int, 3> ModifierFlags = {GameKeyCtrl, GameKeyAlt, GameKeyShift};

- (instancetype)initWithGame:(NSString*)game index:(size_t)index
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		_game  = game;
		_index = index;
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"key"];
	[self refresh];
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];

	// Saves the label being typed
	[self.view endEditing:YES];
}

- (std::optional<GameKey>)key
{
	const auto keys = GetGameKeys(_game);
	if (_index >= keys.size()) {
		return {};
	}
	return keys[_index];
}

- (void)setKey:(const GameKey&)key
{
	auto keys = GetGameKeys(_game);
	if (_index < keys.size()) {
		keys[_index] = key;
		set_custom_game_keys(_game, keys);
	}
	[self refresh];
}

- (void)refresh
{
	if (const auto key = [self key]) {
		self.title = GameKeyLabel(*key);
	}
	[self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView
{
	return KeySectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	switch (section) {
	case KeyChoiceSection: return 1;
	case ModifiersSection: return static_cast<NSInteger>(ModifierFlags.size());
	case CaptionSection: return 1;
	}
	return 0;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section
{
	switch (section) {
	case ModifiersSection: return @"Hold down with it";
	case CaptionSection: return @"Label";
	}
	return nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section
{
	return (section == CaptionSection)
	             ? @"Shown under the key, to say what it does. Keep it short."
	             : nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
	auto cell = [tableView dequeueReusableCellWithIdentifier:@"key" forIndexPath:indexPath];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	cell.accessoryView  = nil;
	[[cell.contentView viewWithTag:CaptionFieldTag] removeFromSuperview];

	const auto key = [self key].value_or(GameKey{});
	auto content   = cell.defaultContentConfiguration;

	switch (indexPath.section) {
	case KeyChoiceSection:
		content.text       = @"Key";
		cell.accessoryView = [self keyMenu:key];
		break;
	case ModifiersSection: {
		const auto flag = ModifierFlags[static_cast<size_t>(indexPath.row)];
		content.text    = @[@"Ctrl", @"Alt", @"Shift"][indexPath.row];

		auto toggle = [[UISwitch alloc] init];
		toggle.on   = (key.modifiers & flag) != 0;
		toggle.tag  = flag;
		[toggle addTarget:self
		              action:@selector(modifierChanged:)
		    forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
	} break;
	case CaptionSection: {
		cell.contentConfiguration = nil;
		auto field = [[UITextField alloc] initWithFrame:CGRectInset(cell.contentView.bounds, 20, 0)];
		field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		field.text             = key.caption;
		field.placeholder      = @"What it does, such as Fortify";
		field.returnKeyType    = UIReturnKeyDone;
		field.clearButtonMode  = UITextFieldViewModeWhileEditing;
		field.delegate         = self;
		field.tag              = CaptionFieldTag;
		[cell.contentView addSubview:field];
		return cell;
	}
	}
	cell.contentConfiguration = content;
	return cell;
}

- (UIButton*)keyMenu:(const GameKey&)key
{
	__weak DBGameKeyViewController* weak_self = self;

	auto items = [NSMutableArray<UIMenuElement*> array];
	for (const auto& group : key_groups()) {
		auto actions = [NSMutableArray<UIMenuElement*> array];
		for (const auto scancode : group.actions) {
			auto new_key     = key;
			new_key.scancode = scancode;
			[actions addObject:make_action(GamepadButtonLabel(scancode),
			                               scancode == key.scancode,
			                               ^{
				                               [weak_self setKey:new_key];
			                               })];
		}
		[items addObject:[UIMenu menuWithTitle:group.title ?: @""
		                                 image:nil
		                            identifier:nil
		                               options:group.title ? 0 : UIMenuOptionsDisplayInline
		                              children:actions]];
	}
	return make_menu_button([UIMenu menuWithChildren:items]);
}

- (void)modifierChanged:(UISwitch*)toggle
{
	if (auto key = [self key]) {
		key->modifiers = toggle.on ? (key->modifiers | static_cast<int>(toggle.tag))
		                           : (key->modifiers & ~static_cast<int>(toggle.tag));
		[self setKey:*key];
	}
}

- (BOOL)textFieldShouldReturn:(UITextField*)field
{
	[field resignFirstResponder];
	return YES;
}

- (void)textFieldDidEndEditing:(UITextField*)field
{
	auto key = [self key];
	if (key && ![trimmed(field.text) isEqualToString:key->caption ?: @""]) {
		key->caption = trimmed(field.text);
		[self setKey:*key];
	}
}

@end

// The game's keys: a ready-made set, or keys of its own, which can be added,
// changed, moved and removed

@interface DBGameKeysViewController : UITableViewController
- (instancetype)initWithGame:(NSString*)game;
@end

@implementation DBGameKeysViewController {
	NSString* _game;
}

enum KeysSection { KeySetSection, KeyListSection, KeysSectionCount };

- (instancetype)initWithGame:(NSString*)game
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		_game      = game;
		self.title = @"Game Keys";
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"keys"];
	self.navigationItem.rightBarButtonItem = self.editButtonItem;
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[self.tableView reloadData];
}

- (bool)hasKeys
{
	return ![game_key_set(_game) isEqualToString:NoGameKeys];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView
{
	return KeysSectionCount;
}

// The keys, then a row to add one
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	if (section == KeySetSection) {
		return 1;
	}
	return [self hasKeys] ? static_cast<NSInteger>(GetGameKeys(_game).size()) + 1 : 0;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section
{
	if (section == KeySetSection) {
		return @"In the game, the Game button shows these keys. Drag the panel "
		       @"with two fingers to move it.";
	}
	return [self hasKeys] ? @"Changing a ready-made set makes a copy for this game." : nil;
}

- (bool)isKeyRow:(NSIndexPath*)indexPath
{
	return indexPath.section == KeyListSection &&
	       static_cast<size_t>(indexPath.row) < GetGameKeys(_game).size();
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
	auto cell = [tableView dequeueReusableCellWithIdentifier:@"keys" forIndexPath:indexPath];
	cell.accessoryView  = nil;
	cell.accessoryType  = UITableViewCellAccessoryNone;
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;

	if (indexPath.section == KeySetSection) {
		auto content              = cell.defaultContentConfiguration;
		content.text              = @"Keys";
		cell.contentConfiguration = content;
		cell.accessoryView        = [self keySetMenu];
		cell.selectionStyle       = UITableViewCellSelectionStyleNone;
		return cell;
	}
	if (![self isKeyRow:indexPath]) {
		auto content              = cell.defaultContentConfiguration;
		content.text              = @"Add Key";
		content.textProperties.color = self.view.tintColor;
		cell.contentConfiguration = content;
		return cell;
	}
	const auto key = GetGameKeys(_game)[static_cast<size_t>(indexPath.row)];

	auto content              = UIListContentConfiguration.valueCellConfiguration;
	content.text              = GameKeyLabel(key);
	content.secondaryText     = key.caption;
	cell.contentConfiguration = content;
	cell.accessoryType        = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}

- (UIButton*)keySetMenu
{
	NSString* const game    = _game;
	NSString* const current = game_key_set(game);

	__weak DBGameKeysViewController* weak_self = self;
	const auto choose = ^(void (^change)()) {
		return ^{
			change();
			[weak_self.tableView reloadData];
		};
	};

	auto actions = [NSMutableArray<UIMenuElement*> array];
	[actions addObject:make_action(@"None", [current isEqualToString:NoGameKeys], choose(^{
		         set_app_setting(game, GameKeysKey, NoGameKeys);
	         }))];
	for (const auto& set : key_sets()) {
		NSString* const name = set.name;
		[actions addObject:make_action(name, [current isEqualToString:name], choose(^{
			         set_app_setting(game, GameKeysKey, name);
		         }))];
	}
	// Starts from the keys shown now, unless the game has keys of its own
	[actions addObject:make_action(@"Custom", [current isEqualToString:CustomGameKeys], choose(^{
		         if (custom_game_keys(game).empty()) {
			         set_custom_game_keys(game, GetGameKeys(game));
		         } else {
			         set_app_setting(game, GameKeysKey, CustomGameKeys);
		         }
	         }))];
	return make_menu_button([UIMenu menuWithChildren:actions]);
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section != KeyListSection) {
		return;
	}
	auto keys = GetGameKeys(_game);
	if (![self isKeyRow:indexPath]) {
		keys.push_back({SDL_SCANCODE_A});
		set_custom_game_keys(_game, keys);
	}
	const auto index = [self isKeyRow:indexPath] ? static_cast<size_t>(indexPath.row)
	                                             : keys.size() - 1;
	[self.navigationController
	        pushViewController:[[DBGameKeyViewController alloc] initWithGame:_game index:index]
	                  animated:YES];
}

- (BOOL)tableView:(UITableView*)tableView canEditRowAtIndexPath:(NSIndexPath*)indexPath
{
	return [self isKeyRow:indexPath];
}

- (BOOL)tableView:(UITableView*)tableView canMoveRowAtIndexPath:(NSIndexPath*)indexPath
{
	return [self isKeyRow:indexPath];
}

- (void)tableView:(UITableView*)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)style
         forRowAtIndexPath:(NSIndexPath*)indexPath
{
	if (style != UITableViewCellEditingStyleDelete) {
		return;
	}
	auto keys = GetGameKeys(_game);
	keys.erase(keys.begin() + indexPath.row);
	set_custom_game_keys(_game, keys);

	[tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
	[tableView reloadSections:[NSIndexSet indexSetWithIndex:KeySetSection]
	         withRowAnimation:UITableViewRowAnimationNone];
}

// Keys stay above the Add Key row
- (NSIndexPath*)tableView:(UITableView*)tableView
        targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath*)source
                             toProposedIndexPath:(NSIndexPath*)proposed
{
	const auto last_key = static_cast<NSInteger>(GetGameKeys(_game).size()) - 1;
	if (proposed.section != KeyListSection) {
		return [NSIndexPath indexPathForRow:(proposed.section < KeyListSection ? 0 : last_key)
		                          inSection:KeyListSection];
	}
	return [NSIndexPath indexPathForRow:std::min(proposed.row, last_key) inSection:KeyListSection];
}

- (void)tableView:(UITableView*)tableView
        moveRowAtIndexPath:(NSIndexPath*)source
               toIndexPath:(NSIndexPath*)destination
{
	auto keys      = GetGameKeys(_game);
	const auto key = keys[static_cast<size_t>(source.row)];
	keys.erase(keys.begin() + source.row);
	keys.insert(keys.begin() + destination.row, key);
	set_custom_game_keys(_game, keys);

	// The set's name changes to Custom; after the move has finished
	dispatch_async(dispatch_get_main_queue(), ^{
		[tableView reloadSections:[NSIndexSet indexSetWithIndex:KeySetSection]
		         withRowAnimation:UITableViewRowAnimationNone];
	});
}

@end

// Settings screen

@interface DBGameSettingsViewController
        : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate,
                            PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property(nonatomic, readonly) UITableView* tableView;
@end

@implementation DBGameSettingsViewController {
	NSString* _game;
	NSString* _conf_path;
	void (^_on_rename)(NSString*);

	// The game's Windows, if it's a Windows game
	NSString* _windows_dir;
	bool _is_installing;

	// On a wide screen, the touch controls are in a second column
	UITableView* _right_table;
	bool _is_wide;

	// Settings in the game's config only take effect when it restarts
	bool _needs_restart;
}

// The Emulator section has the settings in 'conf_settings()', then the
// shader and music. Without a game, the screen edits the shared dosbox.conf
// and has only that section.
// The Windows section has the screen size (only with VBESVGA.DRV), then the
// display driver.
enum Section { NameSection, EmulatorSection, WindowsSection, ControlsSection, SectionCount };

enum NameRow { NameFieldRow, IconRow, NameRowCount };
enum EmulatorExtraRow { ShaderRow, MusicRow, EmulatorExtraRowCount };
constexpr NSInteger NameFieldTag = 1;

// The Controls section ends with a row for each gamepad button
enum ControlsRow { MouseRow, GameKeysRow, GamepadRow, FirstButtonRow };
constexpr NSInteger ControlsRowCount = FirstButtonRow + GamepadButtonCount;


- (instancetype)initWithGame:(NSString*)game
                    confPath:(NSString*)conf_path
                    onRename:(void (^)(NSString*))on_rename
{
	self = [super initWithNibName:nil bundle:nil];
	if (self) {
		_game      = game;
		_conf_path = conf_path;
		_on_rename = on_rename;
		self.title = game ? @"Game Settings" : @"Settings";

		_windows_dir = game ? FindGameWindows(conf_path) : nil;
	}
	return self;
}

- (void)loadView
{
	self.view = [[UIView alloc] init];
	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

	_tableView   = [self makeTable];
	_right_table = [self makeTable];
	_right_table.hidden = YES;
}

- (UITableView*)makeTable
{
	auto table = [[UITableView alloc] initWithFrame:CGRectZero
	                                          style:UITableViewStyleInsetGrouped];
	table.dataSource = self;
	table.delegate   = self;
	[table registerClass:UITableViewCell.class forCellReuseIdentifier:@"setting"];
	[self.view addSubview:table];
	return table;
}

- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];

	const auto bounds  = self.view.bounds;
	const auto is_wide = _game && bounds.size.width >= TwoColumnWidth;
	if (is_wide) {
		CGRect left = {}, right = {};
		CGRectDivide(bounds,
		             &left,
		             &right,
		             std::round(bounds.size.width * SettingsColumnShare),
		             CGRectMinXEdge);
		_tableView.frame   = left;
		_right_table.frame = right;
	} else {
		_tableView.frame = bounds;
	}
	if (is_wide != _is_wide) {
		_is_wide            = is_wide;
		_right_table.hidden = !is_wide;
		[self reloadTables];
	}
}

- (void)reloadTables
{
	[_tableView reloadData];
	[_right_table reloadData];
}

// The section a table's section index shows: on a wide screen, the right
// table has only the touch controls
- (NSInteger)section:(UITableView*)table index:(NSInteger)index
{
	return (table == _right_table) ? ControlsSection : index;
}

- (bool)isRunning
{
	return _game && [CurrentGameName() isEqualToString:_game];
}

// Changes to the game's config take effect when it restarts, so in a game
// they bring a button to restart it
- (void)confChanged
{
	if ([self isRunning] && !_needs_restart) {
		_needs_restart = true;
		self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
		        initWithTitle:@"Restart Game"
		                style:UIBarButtonItemStylePlain
		               target:self
		               action:@selector(confirmRestart)];
	}
	// The rows' descriptions and the shader menu's notes depend on the
	// new value (the screen size's, in particular)
	[self reloadTables];
}

- (void)confirmRestart
{
	auto alert = [UIAlertController
	        alertControllerWithTitle:@"Restart the game?"
	                         message:@"Anything not saved in the game will be lost."
	                  preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
	                                          style:UIAlertActionStyleCancel
	                                        handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Restart"
	                                          style:UIAlertActionStyleDestructive
	                                        handler:^(UIAlertAction*) {
		                                        [self dismissViewControllerAnimated:YES
		                                                                 completion:nil];
		                                        IOS_RestartGame();
	                                        }]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	// Shown on its own over a game, it needs a way to close
	if (self.navigationController.viewControllers.firstObject == self) {
		self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
		        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
		                             target:self
		                             action:@selector(close)];
	}

	// A gamepad button's default follows the stick
	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(reloadTables)
	                                           name:GameSettingsChangedNotification
	                                         object:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];

	// Test hook: scroll down this many points (for screenshots)
	if (const auto points = std::getenv("DOSPAD_SETTINGS_SCROLL")) {
		[self.tableView setContentOffset:CGPointMake(0, std::atof(points)) animated:NO];
	}

	// Test hook: open the game keys, and with a number, that key's screen
	static bool has_opened_keys = false;
	if (const auto key = std::getenv("DOSPAD_SETTINGS_KEYS"); key && _game && !has_opened_keys) {
		has_opened_keys = true;
		[self.navigationController
		        pushViewController:[[DBGameKeysViewController alloc] initWithGame:_game]
		                  animated:NO];
		if (const auto index = std::atoi(key); index > 0) {
			[self.navigationController
			        pushViewController:[[DBGameKeyViewController alloc]
			                                   initWithGame:_game
			                                          index:static_cast<size_t>(index - 1)]
			                  animated:NO];
		}
	}
}

- (void)close
{
	[self.view endEditing:YES];
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView
{
	if (tableView == _right_table) {
		return 1;
	}
	return _is_wide ? ControlsSection : SectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	switch ([self section:tableView index:section]) {
	case NameSection: return _game ? NameRowCount : 0;
	case EmulatorSection:
		return static_cast<NSInteger>(conf_settings().size()) + EmulatorExtraRowCount;
	case WindowsSection:
		return _windows_dir ? (UsesVbeSvga(_windows_dir) ? 2 : 1) : 0;
	case ControlsSection: return _game ? ControlsRowCount : 0;
	}
	return 0;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section
{
	switch ([self section:tableView index:section]) {
	case NameSection: return _game ? @"Name and icon" : nil;
	case EmulatorSection: return _game ? @"Emulator" : @"Emulator, for every game";
	case WindowsSection: return _windows_dir ? @"Windows" : nil;
	case ControlsSection: return _game ? @"Touch controls" : nil;
	}
	return nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section
{
	switch ([self section:tableView index:section]) {
	case NameSection:
		if (!_game) {
			return nil;
		}
		return [NSString stringWithFormat:@"%@Windows games show their program's icon. "
		                                  @"DOS programs have none: choose a picture "
		                                  @"from Photos, or an .ico file from Files.",
		                                  _on_rename ? @""
		                                             : @"The name can be changed from "
		                                               @"the library.\n\n"];
	case EmulatorSection:
		return [NSString stringWithFormat:
		                         @"%@\n\n"
		                         @"Shaders draw the screen like an old monitor, with "
		                         @"scanlines and glow; Auto CRT picks the look that "
		                         @"suits each video mode. Your own shaders (.glsl) go in "
		                         @"the shaders folder.\n\n"
		                         @"For music, put SoundFonts (.sf2) in the soundfonts "
		                         @"folder and MT-32 ROMs in the mt32-roms folder.\n\n"
		                         @"These folders are in Files › On My %@ › DOSBox Staging.",
		                         !_game ? @"Each game uses these unless its own settings "
		                                  @"choose otherwise. They take effect the next time "
		                                  @"a game starts."
		                         : [self isRunning]
		                                 ? @"Changes here and under Windows take effect when "
		                                   @"the game restarts: tap Restart Game once you've "
		                                   @"made them, or quit and start it again. Default "
		                                   @"uses the settings for every game, in the "
		                                   @"library's ⚙ button."
		                                 : @"These take effect the next time the game starts. "
		                                   @"Default uses the settings for every game, in the "
		                                   @"library's ⚙ button.",
		                         UIDevice.currentDevice.model];
	case WindowsSection:
		if (!_windows_dir) {
			return nil;
		}
		if (UsesVbeSvga(_windows_dir)) {
			return @"Windows is set to this size each time the game starts. "
			       @"Games using WinG, like Colonization, test the display for a "
			       @"few minutes the first time they run at a new size.";
		}
		return [NSString stringWithFormat:
		                         @"Windows' own display drivers only offer a few fixed "
		                         @"sizes. VBESVGA, a free driver by PluMGMK, lets Windows "
		                         @"fill the screen. It isn't part of this app: Install "
		                         @"downloads it from github.com/PluMGMK/vbesvga.drv.%@",
		                         CurrentGameName() ? @"\n\nQuit the game to install it." : @""];
	case ControlsSection:
		if (!_game) {
			return nil;
		}
		return @"Direct touch clicks where your finger is. Trackpad moves the "
		       @"pointer like a laptop's trackpad, for games that need it.\n\n"
		       @"The gamepad button (top right) shows a stick and four buttons. "
		       @"The stick presses the arrow keys, or works as a joystick; DOS "
		       @"games look for a joystick when they start, so choose Joystick "
		       @"before starting the game.";
	}
	return nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
	auto cell = [tableView dequeueReusableCellWithIdentifier:@"setting"
	                                            forIndexPath:indexPath];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	cell.accessoryView  = nil;
	cell.accessoryType  = UITableViewCellAccessoryNone;
	// Only the name's row has a field of its own. Removing the content
	// view's other subviews would take a reused row's label with them.
	[[cell.contentView viewWithTag:NameFieldTag] removeFromSuperview];
	auto content = cell.defaultContentConfiguration;

	switch ([self section:tableView index:indexPath.section]) {
	case NameSection: {
		if (indexPath.row == IconRow) {
			content.text  = @"Icon";
			content.image = GameIcon(_conf_path)
			                     ?: [UIImage systemImageNamed:@"play.rectangle"];
			content.imageProperties.reservedLayoutSize = CGSizeMake(GameIconSize,
			                                                        GameIconSize);
			cell.contentConfiguration = content;
			cell.accessoryView        = [self iconMenu];
			return cell;
		}
		cell.contentConfiguration = nil;
		auto field = [[UITextField alloc] initWithFrame:CGRectInset(cell.contentView.bounds, 20, 0)];
		field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		field.text             = _game;
		field.enabled          = (_on_rename != nil);
		field.textColor = field.enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
		field.returnKeyType      = UIReturnKeyDone;
		field.clearButtonMode    = UITextFieldViewModeWhileEditing;
		field.autocorrectionType = UITextAutocorrectionTypeNo;
		field.delegate           = self;
		field.tag                = NameFieldTag;
		[cell.contentView addSubview:field];
		return cell;
	}
	case EmulatorSection: {
		const auto row = static_cast<size_t>(indexPath.row);
		if (row == conf_settings().size() + ShaderRow) {
			content.text              = @"Shader";
			content.secondaryText     = [self shaderDetail];
			cell.contentConfiguration = content;
			cell.accessoryView        = [self shaderMenu];
			return cell;
		}
		if (row == conf_settings().size() + MusicRow) {
			content.text              = @"Music";
			content.secondaryText     = [self musicDetail];
			cell.contentConfiguration = content;
			cell.accessoryView        = [self musicMenu];
			return cell;
		}
		const auto& setting       = conf_settings()[row];
		content.text              = setting.title;
		content.secondaryText     = [self detailForSetting:setting];
		cell.contentConfiguration = content;
		cell.accessoryView        = [self menuForSetting:setting];
		return cell;
	}
	case WindowsSection: {
		if (indexPath.row == 0 && UsesVbeSvga(_windows_dir)) {
			const auto setting        = screen_size_setting(_conf_path);
			content.text              = setting.title;
			content.secondaryText     = [self detailForSetting:setting];
			cell.contentConfiguration = content;
			cell.accessoryView        = [self menuForSetting:setting];
			return cell;
		}
		content.text              = @"Display driver";
		cell.contentConfiguration = content;
		cell.accessoryView        = [self displayDriverAccessory];
		return cell;
	}
	case ControlsSection: {
		switch (indexPath.row) {
		case MouseRow:
			content.text       = @"Mouse";
			cell.accessoryView = [self mouseMenu];
			break;
		case GameKeysRow: {
			NSString* const set = game_key_set(_game);
			content = UIListContentConfiguration.valueCellConfiguration;
			content.text          = @"Game keys";
			content.secondaryText = [set isEqualToString:CustomGameKeys] ? @"Own keys" : set;
			cell.accessoryType    = UITableViewCellAccessoryDisclosureIndicator;
			cell.selectionStyle   = UITableViewCellSelectionStyleDefault;
		} break;
		case GamepadRow:
			content.text       = @"Gamepad stick";
			cell.accessoryView = [self gamepadStickMenu];
			break;
		default: {
			const auto button = static_cast<int>(indexPath.row - FirstButtonRow);
			NSArray* const names = @[@"Bottom", @"Right", @"Left", @"Top"];
			content.text = [NSString stringWithFormat:@"%@ button", names[button]];
			cell.accessoryView = [self gamepadButtonMenu:button];
		} break;
		}
		cell.contentConfiguration = content;
		return cell;
	}
	}
	return cell;
}

// The explanation of the choice in force: the game's, else the shared config's
- (NSString*)detailForSetting:(const ConfSetting&)setting
{
	for (NSString* key in setting.keys) {
		NSString* const value = ReadConfValue(_conf_path, setting.section, key)
		                                ?: ReadConfValue(@"dosbox.conf", setting.section, key);
		if (!value) {
			continue;
		}
		for (const auto& choice : setting.choices) {
			if ([choice.value caseInsensitiveCompare:value] == NSOrderedSame) {
				return choice.detail;
			}
		}
		return [key isEqualToString:@"vesa_custom_resolution"] ? size_detail(value, _conf_path)
		                                                       : nil;
	}
	return setting.default_detail;
}

// The explanation under the Shader row, for the shader in force
- (NSString*)shaderDetail
{
	NSString* const output = (ReadConfValue(_conf_path, @"sdl", @"output")
	                                  ?: ReadConfValue(@"dosbox.conf", @"sdl", @"output"))
	                                 .lowercaseString;
	NSString* const shader = ReadConfValue(_conf_path, @"render", @"shader")
	                                 ?: ReadConfValue(@"dosbox.conf", @"render", @"shader");
	if (!output && !shader) {
		return nil;
	}
	if ([output isEqualToString:SharpOutput] || !shader) {
		return @"Sharp pixels: the fastest, with every pixel crisp.";
	}
	NSString* const name = shader.lowercaseString;
	NSString* const what = [&]() -> NSString* {
		if ([name isEqualToString:@"crt-auto"]) {
			return @"Picks a monitor look to suit each video mode.";
		}
		if ([name isEqualToString:@"crt-auto-machine"]) {
			return @"Picks the look of the emulated machine's own monitor for each video mode.";
		}
		if ([name hasPrefix:@"crt-auto-arcade"]) {
			return @"Picks an arcade monitor look to suit each video mode.";
		}
		if ([name hasPrefix:@"crt/crt-hyllian"]) {
			return @"A CRT monitor look with scanlines and glow.";
		}
		if ([name isEqualToString:@"crt/vga-1080p"]) {
			return @"A light VGA monitor look for 2 pixels per line.";
		}
		if ([name isEqualToString:@"crt/vga-1080p-fake-double-scan"]) {
			return @"A light VGA monitor look for 320x200 games on small screens.";
		}
		if ([name hasPrefix:@"interpolation/"]) {
			return @"Smooth scaling without a monitor look.";
		}
		if ([name hasPrefix:@"scaler/"]) {
			return @"A pixel-art scaler.";
		}
		return nil;
	}();
	NSString* const windows_size =
	        _windows_dir ? (ReadConfValue(_conf_path, @"dosbox", @"vesa_custom_resolution")
	                                ?: ReadConfValue(@"dosbox.conf", @"dosbox", @"vesa_custom_resolution"))
	                     : nil;
	NSString* const note = shader_note(shader, windows_size, _conf_path).subtitle;
	if (what && note) {
		return [NSString stringWithFormat:@"%@ %@.", what, note];
	}
	return what ?: (note ? [note stringByAppendingString:@"."] : nil);
}

// The explanation under the Music row, for the MIDI device in force
- (NSString*)musicDetail
{
	NSString* const device = (ReadConfValue(_conf_path, @"midi", @"mididevice")
	                                  ?: ReadConfValue(@"dosbox.conf", @"midi", @"mididevice"))
	                                 .lowercaseString;
	if ([device isEqualToString:@"fluidsynth"]) {
		NSString* const soundfont = ReadConfValue(_conf_path, @"fluidsynth", @"soundfont")
		                                    ?: ReadConfValue(@"dosbox.conf", @"fluidsynth", @"soundfont");
		return soundfont ? [NSString stringWithFormat:@"MIDI music through FluidSynth with the "
		                                               @"SoundFont %@.",
		                                               soundfont.stringByDeletingPathExtension]
		                 : @"MIDI music through FluidSynth with its own SoundFont.";
	}
	if ([device isEqualToString:@"mt32"]) {
		return @"Roland MT-32 emulation, with the ROMs in the mt32-roms folder.";
	}
	if ([device isEqualToString:@"none"]) {
		return @"No MIDI music. Sound effects still play.";
	}
	if (!device) {
		return @"Staging's default sends MIDI to a port, and iOS has none, so there is no "
		       @"music: choose FluidSynth or the MT-32.";
	}
	return nil;
}

- (UIButton*)menuForSetting:(const ConfSetting&)setting
{
	NSString* const current = ReadConfValue(_conf_path, setting.section, setting.keys.firstObject);

	auto choices = setting.choices;
	choices.insert(choices.begin(), {@"Default", nil});

	// A value set by hand in the config file stays selectable
	const auto is_known = std::any_of(choices.begin(), choices.end(), [&](const Choice& c) {
		return [c.value isEqualToString:current];
	});
	if (current && !is_known) {
		const auto is_size = [setting.keys.firstObject isEqualToString:@"vesa_custom_resolution"];
		const auto ratio   = is_size ? aspect_ratio(current) : nil;
		choices.push_back({ratio ? [NSString stringWithFormat:@"%@ (%@)", current, ratio] : current,
		                   current,
		                   is_size ? size_subtitle(current, _conf_path) : nil,
		                   is_size ? size_detail(current, _conf_path) : nil,
		                   is_size ? size_image(current, _conf_path) : nil});
	}

	auto actions = [NSMutableArray<UIMenuElement*> array];
	for (const auto& choice : choices) {
		NSString* const section    = setting.section;
		NSArray<NSString*>* keys   = setting.keys;
		NSString* const value      = choice.value;
		NSString* const conf_path  = _conf_path;
		__weak DBGameSettingsViewController* weak_self = self;

		auto action = [UIAction actionWithTitle:choice.title
		                                  image:nil
		                             identifier:nil
		                                handler:^(UIAction*) {
			                                for (NSString* key in keys) {
				                                WriteConfValue(conf_path, section, key, value);
			                                }
			                                [weak_self confChanged];
		                                }];
		const auto is_current = (value == nil) ? (current == nil)
		                                       : [value isEqualToString:current];
		action.state    = is_current ? UIMenuElementStateOn : UIMenuElementStateOff;
		action.subtitle = choice.subtitle;
		action.image    = choice.image;
		[actions addObject:action];
	}
	return make_menu_button([UIMenu menuWithChildren:actions]);
}

- (UIButton*)shaderMenu
{
	NSString* const conf_path = _conf_path;
	NSString* const output    = ReadConfValue(conf_path, @"sdl", @"output").lowercaseString;
	NSString* const shader    = ReadConfValue(conf_path, @"render", @"shader");
	const auto is_sharp       = [output isEqualToString:SharpOutput];

	__weak DBGameSettingsViewController* weak_self = self;

	const auto choose = ^(NSString* new_output, NSString* new_shader) {
		return ^{
			WriteConfValue(conf_path, @"sdl", @"output", new_output);
			WriteConfValue(conf_path, @"render", @"shader", new_shader);
			[weak_self confChanged];
		};
	};
	// A Windows game's screen size says how each CRT shader will look
	NSString* const windows_size =
	        _windows_dir ? (ReadConfValue(conf_path, @"dosbox", @"vesa_custom_resolution")
	                                ?: ReadConfValue(@"dosbox.conf", @"dosbox", @"vesa_custom_resolution"))
	                     : nil;
	const auto shader_action = ^(NSString* title, NSString* name) {
		auto action = make_action(title,
		                          !is_sharp && [shader caseInsensitiveCompare:name] == NSOrderedSame,
		                          choose(GpuOutput, name));
		const auto note = shader_note(name, windows_size, conf_path);
		action.subtitle = note.subtitle;
		action.image    = fit_image(note.fit);
		return action;
	};
	const auto submenu = ^(NSString* title, NSArray<UIMenuElement*>* children) {
		return [UIMenu menuWithTitle:title image:nil identifier:nil options:0 children:children];
	};

	auto items = [NSMutableArray<UIMenuElement*> array];
	[items addObject:make_action(@"Default", !output && !shader, choose(nil, nil))];
	[items addObject:make_action(@"Sharp pixels, no shader", is_sharp, choose(SharpOutput, nil))];

	auto automatic = [NSMutableArray<UIMenuElement*> array];
	[automatic addObject:shader_action(@"Auto CRT", @"crt-auto")];
	[automatic addObject:shader_action(@"Auto CRT, like the machine", @"crt-auto-machine")];
	[automatic addObject:shader_action(@"Auto CRT, arcade", @"crt-auto-arcade")];
	[automatic addObject:shader_action(@"Auto CRT, sharp arcade", @"crt-auto-arcade-sharp")];
	[items addObject:[UIMenu menuWithTitle:@""
	                                 image:nil
	                            identifier:nil
	                               options:UIMenuOptionsDisplayInline
	                              children:automatic]];

	auto known = [NSMutableSet<NSString*> setWithArray:@[
		@"crt-auto", @"crt-auto-machine", @"crt-auto-arcade", @"crt-auto-arcade-sharp"
	]];

	auto presets = [NSMutableArray<UIMenuElement*> array];
	for (NSString* preset in find_crt_presets()) {
		NSString* const name = [@"crt/crt-hyllian:" stringByAppendingString:preset];
		[presets addObject:shader_action(preset, name)];
		[known addObject:name.lowercaseString];
	}
	// The bundle's other CRT shaders (vga-1080p and its fake double scan
	// variant) belong with the presets; the bare crt-hyllian doesn't
	auto others = [NSMutableArray<UIMenuElement*> array];
	for (NSString* name in find_shaders(bundled_resource(@"shaders"))) {
		const auto is_crt = [name hasPrefix:@"crt/"] &&
		                    ![name isEqualToString:@"crt/crt-hyllian"];
		[is_crt ? presets : others addObject:shader_action(name.lastPathComponent, name)];
		[known addObject:name.lowercaseString];
	}
	if (presets.count > 0) {
		[items addObject:submenu(@"CRT presets", presets)];
	}
	if (others.count > 0) {
		[items addObject:submenu(@"Other shaders", others)];
	}

	auto own = [NSMutableArray<UIMenuElement*> array];
	for (NSString* name in find_shaders(ShadersFolder)) {
		[own addObject:shader_action(name, name)];
		[known addObject:name.lowercaseString];
	}
	if (own.count == 0) {
		auto none = [UIAction actionWithTitle:@"No shaders in the shaders folder"
		                                image:nil
		                           identifier:nil
		                              handler:^(UIAction*) {}];
		none.attributes = UIMenuElementAttributesDisabled;
		[own addObject:none];
	}
	[items addObject:submenu(@"Your shaders", own)];

	// A shader set by hand in the config file stays selectable
	if (shader && !is_sharp && ![known containsObject:shader.lowercaseString]) {
		[items addObject:shader_action(shader, shader)];
	}
	return make_menu_button([UIMenu menuWithChildren:items]);
}

- (UIButton*)musicMenu
{
	NSString* const conf_path = _conf_path;
	NSString* const device    = ReadConfValue(conf_path, @"midi", @"mididevice").lowercaseString;
	NSString* const soundfont = ReadConfValue(conf_path, @"fluidsynth", @"soundfont");

	__weak DBGameSettingsViewController* weak_self = self;

	const auto choose = ^(NSString* new_device, NSString* new_soundfont) {
		return ^{
			WriteConfValue(conf_path, @"midi", @"mididevice", new_device);
			WriteConfValue(conf_path, @"fluidsynth", @"soundfont", new_soundfont);
			[weak_self confChanged];
		};
	};
	const auto is_fluidsynth = [device isEqualToString:@"fluidsynth"];

	auto soundfonts = [NSMutableArray<UIMenuElement*> array];
	auto names      = [find_soundfonts() mutableCopy];
	if (is_fluidsynth && soundfont && ![names containsObject:soundfont]) {
		[names addObject:soundfont];
	}
	if (is_fluidsynth && !soundfont) {
		[soundfonts addObject:make_action(@"Shared SoundFont", true, choose(@"fluidsynth", nil))];
	}
	for (NSString* name in names) {
		const auto is_on = is_fluidsynth &&
		                   ([soundfont caseInsensitiveCompare:name] == NSOrderedSame ||
		                    [soundfont caseInsensitiveCompare:name.stringByDeletingPathExtension] ==
		                            NSOrderedSame);
		[soundfonts addObject:make_action(name.stringByDeletingPathExtension,
		                                  is_on,
		                                  choose(@"fluidsynth", name))];
	}
	if (soundfonts.count == 0) {
		auto none = [UIAction actionWithTitle:@"No SoundFonts in the soundfonts folder"
		                                image:nil
		                           identifier:nil
		                              handler:^(UIAction*) {}];
		none.attributes = UIMenuElementAttributesDisabled;
		[soundfonts addObject:none];
	}

	auto mt32 = make_action(@"Roland MT-32", [device isEqualToString:@"mt32"], choose(@"mt32", nil));
	if (!has_mt32_roms()) {
		mt32.subtitle = @"Needs ROMs in the mt32-roms folder";
	}

	auto items = [NSMutableArray<UIMenuElement*> array];
	[items addObject:make_action(@"Default", !device && !soundfont, choose(nil, nil))];
	[items addObject:[UIMenu menuWithTitle:@"SoundFont"
	                                 image:nil
	                            identifier:nil
	                               options:UIMenuOptionsDisplayInline
	                              children:soundfonts]];
	[items addObject:mt32];
	[items addObject:make_action(@"Off", [device isEqualToString:@"none"], choose(@"none", nil))];

	// Another device set by hand in the config file stays selectable
	if (device && !is_fluidsynth && ![@[@"mt32", @"none"] containsObject:device]) {
		[items addObject:make_action(device, true, choose(device, nil))];
	}
	return make_menu_button([UIMenu menuWithChildren:items]);
}

- (UIView*)displayDriverAccessory
{
	if (UsesVbeSvga(_windows_dir) || CurrentGameName() || _is_installing) {
		auto label = [[UILabel alloc] init];
		label.text = UsesVbeSvga(_windows_dir) ? @"VBESVGA"
		             : _is_installing          ? @"Installing…"
		                                       : @"Windows standard";
		label.textColor = UIColor.secondaryLabelColor;
		[label sizeToFit];
		return label;
	}
	auto button = [UIButton
	        buttonWithConfiguration:UIButtonConfiguration.plainButtonConfiguration
	                  primaryAction:[UIAction actionWithTitle:@"Install VBESVGA"
	                                                    image:nil
	                                               identifier:nil
	                                                  handler:^(UIAction*) {
		                                                  [self confirmInstall];
	                                                  }]];
	[button sizeToFit];
	return button;
}

- (void)confirmInstall
{
	auto alert = [UIAlertController
	        alertControllerWithTitle:@"Install VBESVGA?"
	                         message:@"This downloads the latest release of PluMGMK's "
	                                 @"VBESVGA.DRV from github.com/PluMGMK/vbesvga.drv and "
	                                 @"makes it Windows' display driver. Windows' old "
	                                 @"settings are kept in SYSTEM.BAK."
	                  preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
	                                          style:UIAlertActionStyleCancel
	                                        handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Install"
	                                          style:UIAlertActionStyleDefault
	                                        handler:^(UIAlertAction*) {
		                                        [self install];
	                                        }]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)install
{
	_is_installing = true;
	[self reloadTables];

	NSString* const conf_path = _conf_path;
	InstallVbeSvga(_windows_dir, ^(NSError* error) {
		self->_is_installing = false;
		[self reloadTables];
		if (error) {
			auto alert = [UIAlertController alertControllerWithTitle:@"Couldn't install VBESVGA"
			                                                 message:error.localizedDescription
			                                          preferredStyle:UIAlertControllerStyleAlert];
			[alert addAction:[UIAlertAction actionWithTitle:@"OK"
			                                          style:UIAlertActionStyleDefault
			                                        handler:nil]];
			[self presentViewController:alert animated:YES completion:nil];
			return;
		}
		// Without a size, the driver picks 1024x768
		if (!ReadConfValue(conf_path, @"dosbox", @"vesa_custom_resolution") &&
		    !ReadConfValue(@"dosbox.conf", @"dosbox", @"vesa_custom_resolution")) {
			WriteConfValue(conf_path, @"dosbox", @"vesa_custom_resolution", fit_screen_size());
			[self reloadTables];
		}
	});
}

- (UIButton*)iconMenu
{
	__weak DBGameSettingsViewController* weak_self = self;
	NSString* const conf_path                      = _conf_path;

	auto actions = [NSMutableArray<UIMenuElement*> array];
	[actions addObject:[UIAction actionWithTitle:@"Photos"
	                                       image:[UIImage systemImageNamed:@"photo"]
	                                  identifier:nil
	                                     handler:^(UIAction*) {
		                                     [weak_self choosePhoto];
	                                     }]];
	[actions addObject:[UIAction actionWithTitle:@"Files"
	                                       image:[UIImage systemImageNamed:@"folder"]
	                                  identifier:nil
	                                     handler:^(UIAction*) {
		                                     [weak_self chooseIconFile];
	                                     }]];
	if ([NSFileManager.defaultManager fileExistsAtPath:CustomIconPath(conf_path)]) {
		[actions addObject:[UIAction actionWithTitle:@"Use the game's own icon"
		                                       image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
		                                  identifier:nil
		                                     handler:^(UIAction*) {
			                                     RemoveCustomIcon(conf_path);
			                                     [weak_self iconChanged];
		                                     }]];
	}

	auto config   = UIButtonConfiguration.plainButtonConfiguration;
	config.title  = @"Choose";
	auto button   = [UIButton buttonWithConfiguration:config primaryAction:nil];
	button.menu   = [UIMenu menuWithChildren:actions];
	button.showsMenuAsPrimaryAction = YES;
	[button sizeToFit];
	return button;
}

- (void)iconChanged
{
	// The library shows the icon too
	[NSNotificationCenter.defaultCenter postNotificationName:GameSettingsChangedNotification
	                                                  object:nil];
}

- (void)choosePhoto
{
	auto config           = [[PHPickerConfiguration alloc] init];
	config.filter         = PHPickerFilter.imagesFilter;
	config.selectionLimit = 1;

	auto picker      = [[PHPickerViewController alloc] initWithConfiguration:config];
	picker.delegate  = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController*)picker didFinishPicking:(NSArray<PHPickerResult*>*)results
{
	[picker dismissViewControllerAnimated:YES completion:nil];

	NSItemProvider* const provider = results.firstObject.itemProvider;
	if (![provider canLoadObjectOfClass:UIImage.class]) {
		return;
	}
	__weak DBGameSettingsViewController* weak_self = self;
	NSString* const conf_path                      = _conf_path;
	[provider loadObjectOfClass:UIImage.class
	          completionHandler:^(id<NSItemProviderReading> object, NSError*) {
		          dispatch_async(dispatch_get_main_queue(), ^{
			          if ([(NSObject*)object isKindOfClass:UIImage.class] &&
			              SetCustomIconImage(conf_path, (UIImage*)object)) {
				          [weak_self iconChanged];
			          }
		          });
	          }];
}

- (void)chooseIconFile
{
	auto picker = [[UIDocumentPickerViewController alloc]
	        initForOpeningContentTypes:@[UTTypeData]
	                            asCopy:YES];
	picker.delegate = self;
	if (const auto folder = GameFilesFolder(_conf_path)) {
		picker.directoryURL = [NSURL fileURLWithPath:folder isDirectory:YES].absoluteURL;
	}
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
        didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
{
	if (SetCustomIcon(_conf_path, urls.firstObject)) {
		[self iconChanged];
		return;
	}
	auto alert = [UIAlertController
	        alertControllerWithTitle:@"No icon in that file"
	                         message:@"Choose a picture, an .ico file or a Windows program. "
	                                 @"DOS programs have no icons."
	                  preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK"
	                                          style:UIAlertActionStyleDefault
	                                        handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (UIButton*)mouseMenu
{
	NSString* const game = _game;
	const auto direct    = IsDirectTouch(game);

	auto direct_action = [UIAction actionWithTitle:@"Direct touch"
	                                         image:nil
	                                    identifier:nil
	                                       handler:^(UIAction*) {
		                                       SetDirectTouch(game, true);
	                                       }];
	auto trackpad_action = [UIAction actionWithTitle:@"Trackpad"
	                                           image:nil
	                                      identifier:nil
	                                         handler:^(UIAction*) {
		                                         SetDirectTouch(game, false);
	                                         }];
	direct_action.state   = direct ? UIMenuElementStateOn : UIMenuElementStateOff;
	trackpad_action.state = direct ? UIMenuElementStateOff : UIMenuElementStateOn;
	return make_menu_button([UIMenu menuWithChildren:@[direct_action, trackpad_action]]);
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if ([self section:tableView index:indexPath.section] == ControlsSection &&
	    indexPath.row == GameKeysRow) {
		[self.navigationController
		        pushViewController:[[DBGameKeysViewController alloc] initWithGame:_game]
		                  animated:YES];
	}
}

- (UIButton*)gamepadStickMenu
{
	NSString* const game = _game;
	const auto stick     = GetGamepadStick(game);

	const auto choose = ^(NSString* value) {
		return ^{
			set_app_setting(game, GamepadStickKey, value);
		};
	};
	return make_menu_button([UIMenu menuWithChildren:@[
		make_action(@"Arrow keys", stick == GamepadStick::ArrowKeys, choose(@"ArrowKeys")),
		make_action(@"Joystick", stick == GamepadStick::Joystick, choose(JoystickStick)),
	]]);
}

- (UIButton*)gamepadButtonMenu:(int)button
{
	NSString* const game = _game;
	const auto current   = GetGamepadButton(game, button);

	auto items = [NSMutableArray<UIMenuElement*> array];
	for (const auto& group : gamepad_key_groups()) {
		auto actions = [NSMutableArray<UIMenuElement*> array];
		for (const auto action : group.actions) {
			[actions addObject:make_action(GamepadButtonLabel(action), action == current, ^{
				         set_gamepad_button(game, button, action);
			         })];
		}
		[items addObject:[UIMenu menuWithTitle:group.title ?: @""
		                                 image:nil
		                            identifier:nil
		                               options:group.title ? 0 : UIMenuOptionsDisplayInline
		                              children:actions]];
	}
	return make_menu_button([UIMenu menuWithChildren:items]);
}

- (BOOL)textFieldShouldReturn:(UITextField*)field
{
	[field resignFirstResponder];
	return YES;
}

- (void)textFieldDidEndEditing:(UITextField*)field
{
	NSString* const new_name = trimmed(field.text);
	if ([new_name isEqualToString:_game]) {
		return;
	}

	NSError* error          = nil;
	const auto new_conf_path = rename_game(_game, _conf_path, new_name, &error);
	if (!new_conf_path) {
		field.text = _game;

		auto alert = [UIAlertController alertControllerWithTitle:@"Couldn't rename the game"
		                                                 message:error.localizedDescription
		                                          preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK"
		                                          style:UIAlertActionStyleDefault
		                                        handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}
	_game        = new_name;
	_conf_path   = new_conf_path;
	_windows_dir = FindGameWindows(new_conf_path);
	_on_rename(new_name);

	// The menus hold the old name and path
	[self reloadTables];
}

@end

UIViewController* MakeGameSettingsController(NSString* game, NSString* conf_path,
                                             void (^on_rename)(NSString* new_name))
{
	return [[DBGameSettingsViewController alloc] initWithGame:game
	                                                 confPath:conf_path
	                                                 onRename:on_rename];
}

UIViewController* MakeSharedSettingsController()
{
	// A new install has no shared config until something is set in it
	NSString* const conf_path = @"dosbox.conf";
	if (![NSFileManager.defaultManager fileExistsAtPath:conf_path]) {
		[NSFileManager.defaultManager createFileAtPath:conf_path contents:[NSData data] attributes:nil];
	}
	return [[DBGameSettingsViewController alloc] initWithGame:nil confPath:conf_path onRename:nil];
}
