// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/game_settings.h"

#include "gui/ios/game_import.h"

#include <algorithm>
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
	        {@"Music",
	         @"midi",
	         @[@"mididevice"],
	         {{@"SoundFont", @"fluidsynth"}, {@"Roland MT-32", @"mt32"}, {@"Off", @"none"}}},
	        {@"Picture",
	         @"render",
	         @[@"aspect"],
	         {{@"4:3, like a CRT", @"on"},
	          {@"Square pixels", @"square-pixels"},
	          {@"Fill the screen", @"stretch"}}},
	};
	return settings;
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

// Settings screen

@interface DBGameSettingsViewController : UITableViewController <UITextFieldDelegate>
@end

@implementation DBGameSettingsViewController {
	NSString* _game;
	NSString* _conf_path;
	void (^_on_rename)(NSString*);
}

enum Section { NameSection, EmulatorSection, ControlsSection, SectionCount };

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
	case EmulatorSection: return static_cast<NSInteger>(conf_settings().size());
	case ControlsSection: return 2;
	}
	return 0;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section
{
	switch (section) {
	case NameSection: return @"Name";
	case EmulatorSection: return @"Emulator";
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
		return @"These take effect the next time the game starts. Default uses "
		       @"the shared dosbox.conf.";
	case ControlsSection:
		return @"Direct touch clicks where your finger is. Trackpad moves the "
		       @"pointer like a laptop's trackpad, for games that need it.";
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
		const auto& setting = conf_settings()[static_cast<size_t>(indexPath.row)];
		content.text        = setting.title;
		cell.contentConfiguration = content;
		cell.accessoryView = [self menuForSetting:setting];
		return cell;
	}
	case ControlsSection: {
		content.text = (indexPath.row == 0) ? @"Mouse" : @"Game keys";
		cell.contentConfiguration = content;
		cell.accessoryView = (indexPath.row == 0) ? [self mouseMenu] : [self gameKeysMenu];
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
	_game      = new_name;
	_conf_path = new_conf_path;
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
