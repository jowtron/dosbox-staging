// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/game_settings.h"

#include "gui/ios/game_import.h"
#include "gui/ios/windows_display.h"

#include <SDL3/SDL.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <vector>

NSString* const GameSettingsChangedNotification = @"DBGameSettingsChanged";
NSString* const ColonizationKeys                = @"Colonization";

namespace {

NSString* current_game_name = nil;
NSString* current_game_conf = nil;

// App-only settings: a dictionary of each game's settings, by game name
NSString* const AppSettingsKey   = @"GameSettings";
NSString* const DirectTouchKey   = @"DirectTouch";
NSString* const GameKeysKey      = @"GameKeys";
NSString* const NoGameKeys       = @"None";
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
	}

	rename_app_settings(old_name, new_name);
	return new_conf_path;
}

// The emulator settings offered for each game. Choosing 'Default' removes
// the setting from the game's config, so the shared config's value applies.

struct Choice {
	NSString* title;
	NSString* value;
};

struct ConfSetting {
	NSString* title;
	NSString* section;
	// All are set to the same value; the first is read back
	NSArray<NSString*>* keys;
	std::vector<Choice> choices;
};

const std::vector<ConfSetting>& conf_settings()
{
	static const std::vector<ConfSetting> settings = {
	        {@"CPU speed",
	         @"cpu",
	         @[@"cpu_cycles", @"cpu_cycles_protected"],
	         {{@"386SX (3,000)", @"3000"},
	          {@"386DX (8,000)", @"8000"},
	          {@"486 (25,000)", @"25000"},
	          {@"Pentium (50,000)", @"50000"},
	          {@"As fast as possible", @"max"}}},
	        {@"Memory",
	         @"dosbox",
	         @[@"memsize"],
	         {{@"4 MB", @"4"}, {@"8 MB", @"8"}, {@"16 MB", @"16"}, {@"32 MB", @"32"}, {@"64 MB", @"64"}}},
	        {@"Picture",
	         @"render",
	         @[@"aspect"],
	         {{@"4:3, like a CRT", @"on"},
	          {@"Square pixels", @"square-pixels"},
	          {@"Fill the screen", @"stretch"}}},
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

// A Windows screen size that fills the display. 1.5 pixels per point keeps
// Windows' text readable: 1264x584 on an iPhone 14, 1920x1440 on a 12.9"
// iPad Pro. Staging's custom VESA mode is at most 1920x1440, with the width
// a multiple of 8.
NSString* fit_screen_size()
{
	CGSize screen = {1024, 768};
	for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
		if ([scene isKindOfClass:UIWindowScene.class]) {
			screen = static_cast<UIWindowScene*>(scene).screen.bounds.size;
			break;
		}
	}
	constexpr double PixelsPerPoint = 1.5;
	constexpr double MaxWidth       = 1920;
	constexpr double MaxHeight      = 1440;

	const auto width  = std::max(screen.width, screen.height) * PixelsPerPoint;
	const auto height = std::min(screen.width, screen.height) * PixelsPerPoint;
	const auto scale  = std::min({1.0, MaxWidth / width, MaxHeight / height});

	const auto round_to_8 = [](const double value) {
		return static_cast<int>(std::lround(value / 8)) * 8;
	};
	return [NSString stringWithFormat:@"%dx%d",
	                                  std::min(round_to_8(width * scale), static_cast<int>(MaxWidth)),
	                                  std::min(round_to_8(height * scale), static_cast<int>(MaxHeight))];
}

ConfSetting screen_size_setting()
{
	const auto fit   = fit_screen_size();
	auto setting     = ConfSetting{@"Screen size", @"dosbox", @[@"vesa_custom_resolution"], {}};
	setting.choices  = {{[NSString stringWithFormat:@"Fit the screen (%@)", fit], fit}};
	for (NSString* size in @[@"640x480", @"800x600", @"1024x768", @"1280x960"]) {
		if (![size isEqualToString:fit]) {
			setting.choices.push_back({size, size});
		}
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

UIButton* make_menu_button(UIMenu* menu)
{
	auto config                    = UIButtonConfiguration.plainButtonConfiguration;
	config.indicator               = UIButtonConfigurationIndicatorPopup;
	auto button                    = [UIButton buttonWithConfiguration:config primaryAction:nil];
	button.menu                    = menu;
	button.showsMenuAsPrimaryAction = YES;
	button.changesSelectionAsPrimaryAction = YES;
	[button sizeToFit];
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

// The keys a gamepad button can send, in the groups its menu shows them
struct KeyGroup {
	NSString* title = nil; // nil for a group shown in the menu itself
	std::vector<int> actions = {};
};

std::vector<KeyGroup> gamepad_key_groups()
{
	const auto key_range = [](const SDL_Scancode first, const SDL_Scancode last) {
		std::vector<int> keys = {};
		for (int key = first; key <= last; ++key) {
			keys.push_back(key);
		}
		return keys;
	};
	return {{nil, {JoystickButton1, JoystickButton2}},
	        {nil,
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
	         {SDL_SCANCODE_UP, SDL_SCANCODE_DOWN, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT}}};
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

NSString* GameKeysPanel(NSString* game)
{
	if (NSString* panel = app_settings(game)[GameKeysKey]) {
		return [panel isEqualToString:ColonizationKeys] ? ColonizationKeys : nil;
	}
	// Until chosen, Colonization gets its keys
	return [game.lowercaseString containsString:@"coloni"] ? ColonizationKeys : nil;
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
	case SDL_SCANCODE_UP: return @"↑";
	case SDL_SCANCODE_DOWN: return @"↓";
	case SDL_SCANCODE_LEFT: return @"←";
	case SDL_SCANCODE_RIGHT: return @"→";
	default: return @(SDL_GetScancodeName(static_cast<SDL_Scancode>(action)));
	}
}

// Settings screen

@interface DBGameSettingsViewController : UITableViewController <UITextFieldDelegate>
@end

@implementation DBGameSettingsViewController {
	NSString* _game;
	NSString* _conf_path;
	void (^_on_rename)(NSString*);

	// The game's Windows, if it's a Windows game
	NSString* _windows_dir;
	bool _is_installing;
}

// The Emulator section has the settings in 'conf_settings()', then music.
// The Windows section has the screen size (only with VBESVGA.DRV), then the
// display driver.
enum Section { NameSection, EmulatorSection, WindowsSection, ControlsSection, SectionCount };

// The Controls section ends with a row for each gamepad button
enum ControlsRow { MouseRow, GameKeysRow, GamepadRow, FirstButtonRow };
constexpr NSInteger ControlsRowCount = FirstButtonRow + GamepadButtonCount;

- (instancetype)initWithGame:(NSString*)game
                    confPath:(NSString*)conf_path
                    onRename:(void (^)(NSString*))on_rename
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		_game      = game;
		_conf_path = conf_path;
		_on_rename = on_rename;
		self.title = @"Game Settings";

		_windows_dir = FindGameWindows(conf_path);
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"setting"];

	// Shown on its own over a game, it needs a way to close
	if (self.navigationController.viewControllers.firstObject == self) {
		self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
		        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
		                             target:self
		                             action:@selector(close)];
	}

	// A gamepad button's default follows the stick
	[NSNotificationCenter.defaultCenter addObserver:self.tableView
	                                       selector:@selector(reloadData)
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
}

- (void)close
{
	[self.view endEditing:YES];
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView
{
	return SectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	switch (section) {
	case NameSection: return 1;
	case EmulatorSection: return static_cast<NSInteger>(conf_settings().size()) + 1;
	case WindowsSection:
		return _windows_dir ? (UsesVbeSvga(_windows_dir) ? 2 : 1) : 0;
	case ControlsSection: return ControlsRowCount;
	}
	return 0;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section
{
	switch (section) {
	case NameSection: return @"Name";
	case EmulatorSection: return @"Emulator";
	case WindowsSection: return _windows_dir ? @"Windows" : nil;
	case ControlsSection: return @"Touch controls";
	}
	return nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section
{
	switch (section) {
	case NameSection:
		return _on_rename ? nil : @"The name can be changed from the library.";
	case EmulatorSection:
		return [NSString stringWithFormat:
		                         @"These take effect the next time the game starts. "
		                         @"Default uses the shared dosbox.conf.\n\n"
		                         @"For music, put SoundFonts (.sf2) in the soundfonts "
		                         @"folder and MT-32 ROMs in the mt32-roms folder, in "
		                         @"Files › On My %@ › DOSBox Staging.",
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
	for (UIView* view in cell.contentView.subviews) {
		[view removeFromSuperview];
	}
	auto content = cell.defaultContentConfiguration;

	switch (indexPath.section) {
	case NameSection: {
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
		[cell.contentView addSubview:field];
		return cell;
	}
	case EmulatorSection: {
		const auto row = static_cast<size_t>(indexPath.row);
		if (row == conf_settings().size()) {
			content.text              = @"Music";
			cell.contentConfiguration = content;
			cell.accessoryView        = [self musicMenu];
			return cell;
		}
		const auto& setting       = conf_settings()[row];
		content.text              = setting.title;
		cell.contentConfiguration = content;
		cell.accessoryView        = [self menuForSetting:setting];
		return cell;
	}
	case WindowsSection: {
		if (indexPath.row == 0 && UsesVbeSvga(_windows_dir)) {
			const auto setting        = screen_size_setting();
			content.text              = setting.title;
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
		case GameKeysRow:
			content.text       = @"Game keys";
			cell.accessoryView = [self gameKeysMenu];
			break;
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
		choices.push_back({current, current});
	}

	auto actions = [NSMutableArray<UIMenuElement*> array];
	for (const auto& choice : choices) {
		NSString* const section    = setting.section;
		NSArray<NSString*>* keys   = setting.keys;
		NSString* const value      = choice.value;
		NSString* const conf_path  = _conf_path;

		auto action = [UIAction actionWithTitle:choice.title
		                                  image:nil
		                             identifier:nil
		                                handler:^(UIAction*) {
			                                for (NSString* key in keys) {
				                                WriteConfValue(conf_path, section, key, value);
			                                }
		                                }];
		const auto is_current = (value == nil) ? (current == nil)
		                                       : [value isEqualToString:current];
		action.state = is_current ? UIMenuElementStateOn : UIMenuElementStateOff;
		[actions addObject:action];
	}
	return make_menu_button([UIMenu menuWithChildren:actions]);
}

- (UIButton*)musicMenu
{
	NSString* const conf_path = _conf_path;
	NSString* const device    = ReadConfValue(conf_path, @"midi", @"mididevice").lowercaseString;
	NSString* const soundfont = ReadConfValue(conf_path, @"fluidsynth", @"soundfont");

	const auto choose = ^(NSString* new_device, NSString* new_soundfont) {
		return ^{
			WriteConfValue(conf_path, @"midi", @"mididevice", new_device);
			WriteConfValue(conf_path, @"fluidsynth", @"soundfont", new_soundfont);
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
	[self.tableView reloadData];

	NSString* const conf_path = _conf_path;
	InstallVbeSvga(_windows_dir, ^(NSError* error) {
		self->_is_installing = false;
		[self.tableView reloadData];
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
			[self.tableView reloadData];
		}
	});
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

- (UIButton*)gameKeysMenu
{
	NSString* const game = _game;
	const auto has_keys  = (GameKeysPanel(game) != nil);

	auto colonization = [UIAction actionWithTitle:@"Colonization"
	                                        image:nil
	                                   identifier:nil
	                                      handler:^(UIAction*) {
		                                      set_app_setting(game, GameKeysKey, ColonizationKeys);
	                                      }];
	auto none = [UIAction actionWithTitle:@"None"
	                                image:nil
	                           identifier:nil
	                              handler:^(UIAction*) {
		                              set_app_setting(game, GameKeysKey, NoGameKeys);
	                              }];
	colonization.state = has_keys ? UIMenuElementStateOn : UIMenuElementStateOff;
	none.state         = has_keys ? UIMenuElementStateOff : UIMenuElementStateOn;
	return make_menu_button([UIMenu menuWithChildren:@[colonization, none]]);
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
	[self.tableView reloadData];
}

@end

UIViewController* MakeGameSettingsController(NSString* game, NSString* conf_path,
                                             void (^on_rename)(NSString* new_name))
{
	return [[DBGameSettingsViewController alloc] initWithGame:game
	                                                 confPath:conf_path
	                                                 onRename:on_rename];
}
