// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/library.h"

#include "gui/ios/game_import.h"
#include "gui/ios/game_settings.h"
#include "gui/ios/windows_display.h"

#include "dosbox.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cstdlib>
#include <optional>

#include "utils/string_utils.h"

namespace {

// Settings the app needs whatever a game's config says, applied after all
// the config files
const std::vector<std::string> RequiredSettings = {
        // The app is always full screen
        "sdl fullscreen=true",
        // iOS always waits for the display's refresh; presenting at the DOS
        // rate stalls the emulator on 60 Hz screens
        "sdl presentation_mode=host-rate",
        // The touch overlay's direct touch mode needs absolute pointing
        "mouse mouse_capture=seamless",
        // Pause while the app is in the background (or the Control Centre
        // or a call covers it)
        "sdl pause_when_inactive=true",
};

// The game to start again without showing the library
NSString* restarting_game = nil;

NSArray<NSString*>* sorted_names(NSDictionary<NSString*, NSString*>* games)
{
	return [games.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

// Test hooks for driving the library without taps (e.g., in the iOS
// Simulator, with 'SIMCTL_CHILD_' prefixed variables):
//
// - DOSPAD_AUTOPICK lists game names separated by ';', which are picked one
//   after another each time the library is shown.
//
// - DOSPAD_IMPORT is a game folder to add to the library on launch, started
//   by DOSPAD_IMPORT_PROGRAM (or the most likely program).
//
std::optional<std::string> next_autopick()
{
	static std::vector<std::string> names = {};
	static size_t next                    = 0;
	static bool is_read                   = false;

	if (!is_read) {
		is_read = true;
		if (const auto list = std::getenv("DOSPAD_AUTOPICK")) {
			names = split(list, ";");
		}
	}
	if (next >= names.size()) {
		return {};
	}
	return names[next++];
}

void maybe_import_for_testing()
{
	static bool is_done = false;
	const auto source   = std::getenv("DOSPAD_IMPORT");
	if (is_done || !source) {
		return;
	}
	is_done = true;

	NSError* error    = nil;
	const auto folder = ImportGameFolder([NSURL fileURLWithPath:@(source)], &error);
	if (!folder) {
		NSLog(@"DOSPAD_IMPORT failed: %@", error);
		return;
	}
	const auto programs = FindGamePrograms(folder);
	const auto program  = std::getenv("DOSPAD_IMPORT_PROGRAM")
	                            ? @(std::getenv("DOSPAD_IMPORT_PROGRAM"))
	                            : programs.firstObject;
	const auto written = WriteGameConf(folder, program, FindGameCdImage(folder), &error);
	NSLog(@"DOSPAD_IMPORT: added '%@' (%d) starting '%@' (found: %@)",
	      folder,
	      written,
	      program,
	      programs);
}

void show_error(UIViewController* presenter, NSString* title, NSError* error)
{
	auto alert = [UIAlertController alertControllerWithTitle:title
	                                                 message:error.localizedDescription
	                                          preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK"
	                                          style:UIAlertActionStyleDefault
	                                        handler:nil]];
	[presenter presentViewController:alert animated:YES completion:nil];
}

} // namespace

// Explains how games get into the library

@interface DBHelpViewController : UIViewController
@end

@implementation DBHelpViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title                = @"Adding Games";
	self.view.backgroundColor = UIColor.systemBackgroundColor;

	auto text = [[UITextView alloc] init];
	text.editable           = NO;
	text.textContainerInset = UIEdgeInsetsMake(16, 16, 32, 16);
	text.attributedText     = [self helpText];
	[self.view addSubview:text];

	// Keep the text clear of the notch in landscape
	text.translatesAutoresizingMaskIntoConstraints = NO;
	const auto safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
		[text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
		[text.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[text.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];
}

- (NSAttributedString*)helpText
{
	auto body = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	auto heading = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
	auto code = [UIFont monospacedSystemFontOfSize:body.pointSize * 0.9
	                                        weight:UIFontWeightRegular];

	auto result = [[NSMutableAttributedString alloc] init];
	auto add = ^(NSString* string, UIFont* font) {
		[result appendAttributedString:[[NSAttributedString alloc]
		                                       initWithString:string
		                                           attributes:@{
		                                                   NSFontAttributeName: font,
		                                                   NSForegroundColorAttributeName:
		                                                           UIColor.labelColor}]];
	};

	add(@"Add Game (+)\n", heading);
	add(@"Tap + and choose the folder a DOS game is in: in iCloud Drive, On My "
	    @"iPhone, or on a USB drive. The folder is copied into the Games "
	    @"folder, and you choose which program starts the game. If the folder "
	    @"has a CD image (.cue or .iso), it becomes the CD drive, D:.\n\n"
	    @"The game's folder is drive C:. Quitting the game brings you back "
	    @"to this list.\n\n",
	    body);

	add(@"How games are set up\n", heading);
	add(@"Each game has its own folder in the Games folder (Files › On My "
	    @"iPhone › DOSBox Staging › Games), holding the game's files and its "
	    @"settings in a file called dosbox.conf. Its [autoexec] section runs "
	    @"when the game starts, for example:\n\n",
	    body);
	add(@"[autoexec]\nmount c \"Games/Duke Nukem 3D\"\nc:\nDUKE3D.EXE\nexit\n\n", code);
	add(@"The last line, exit, returns to the list when the game quits; "
	    @"leave it out to stay at the DOS prompt instead.\n\n"
	    @"Settings are applied in layers. dosbox.conf in the app's main folder "
	    @"holds the starting settings for every game, and a game's own "
	    @"dosbox.conf can change any of them just for that game, such as "
	    @"cpu_cycles in a [cpu] section. A few settings the app needs (full "
	    @"screen, and the mouse and display modes) always apply.\n\n"
	    @"A game can also be just a settings file in the Games folder, named "
	    @"after the game, when its files are somewhere else.\n\n",
	    body);

	add(@"Game settings (ⓘ)\n", heading);
	add(@"Tap ⓘ next to a game to rename it or change its settings: CPU speed, "
	    @"memory, the picture, music, and the touch controls. They're saved "
	    @"in the game's dosbox.conf. In a game, the same settings are in the ☰ "
	    @"menu.\n\n",
	    body);

	add(@"Music\n", heading);
	add(@"Many games play music through a MIDI synthesiser. Put General MIDI "
	    @"SoundFonts (.sf2 files) in the soundfonts folder, and Roland MT-32 "
	    @"ROMs in the mt32-roms folder, both next to the Games folder. Then "
	    @"choose one in a game's Music setting.\n\n",
	    body);

	add(@"Windows 3.1 games\n", heading);
	add(@"Install them inside Windows, then add a settings file that starts "
	    @"Windows with the game, like the Colonization one.\n\n"
	    @"Windows can fill the screen with VBESVGA, a free display driver by "
	    @"PluMGMK. A Windows game's settings can download and install it, and "
	    @"then set Windows' screen size.\n\n",
	    body);

	add(@"Removing games\n", heading);
	add(@"Swipe left on a game to remove it. For a game added with +, that "
	    @"deletes its folder and everything in it, including saved games.\n",
	    body);
	return result;
}

@end

// Asks which program starts a newly added game, then adds it to the library

@interface DBProgramPickerViewController : UITableViewController
- (instancetype)initWithFolder:(NSString*)folder
                      programs:(NSArray<NSString*>*)programs
                    completion:(void (^)(NSString* conf_name))completion;
@end

@implementation DBProgramPickerViewController {
	NSString* _folder;
	NSArray<NSString*>* _programs;
	NSString* _cd_image;
	void (^_completion)(NSString*);
	bool _is_done;
}

- (instancetype)initWithFolder:(NSString*)folder
                      programs:(NSArray<NSString*>*)programs
                    completion:(void (^)(NSString*))completion
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		_folder     = folder;
		_programs   = programs;
		_cd_image   = FindGameCdImage(folder);
		_completion = completion;
		self.title  = folder.lastPathComponent;
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"program"];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	return static_cast<NSInteger>(_programs.count);
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section
{
	return _programs.count > 0 ? @"Which program starts the game?" : nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section
{
	if (_cd_image) {
		return [NSString stringWithFormat:@"%@ will be the CD drive, D:.", _cd_image];
	}
	return nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
	auto cell    = [tableView dequeueReusableCellWithIdentifier:@"program"
	                                            forIndexPath:indexPath];
	auto content = cell.defaultContentConfiguration;
	content.text = _programs[static_cast<NSUInteger>(indexPath.row)];
	content.image = [UIImage systemImageNamed:@"terminal"];
	cell.contentConfiguration = content;
	return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	NSError* error = nil;
	if (!WriteGameConf(_folder,
	                   _programs[static_cast<NSUInteger>(indexPath.row)],
	                   _cd_image,
	                   &error)) {
		show_error(self, @"Couldn't add the game", error);
		return;
	}
	_is_done = true;
	_completion(_folder.lastPathComponent);
}

// Going back without choosing a program cancels adding the game
- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
	if (!_is_done && self.isMovingFromParentViewController) {
		[NSFileManager.defaultManager removeItemAtPath:_folder error:nil];
	}
}

@end

// The list of games

@interface DBLibraryViewController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* games;
@property(nonatomic, copy) NSArray<NSString*>* names;
@property(nonatomic, copy) NSString* chosenGame;
- (void)showHelp;
- (void)addGame;
- (void)showSettings:(NSString*)name;
@end

@implementation DBLibraryViewController

- (instancetype)init
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		self.title = @"Games";
		[self loadGames];
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"game"];

	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
	        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
	                             target:self
	                             action:@selector(addGame)];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
	        initWithImage:[UIImage systemImageNamed:@"questionmark.circle"]
	                style:UIBarButtonItemStylePlain
	               target:self
	               action:@selector(showHelp)];
}

- (void)loadGames
{
	self.games = FindGames();
	self.names = sorted_names(self.games);
}

- (void)reload
{
	[self loadGames];
	[self.tableView reloadData];
}

- (void)showHelp
{
	[self.navigationController pushViewController:[[DBHelpViewController alloc] init]
	                                     animated:YES];
}

- (void)addGame
{
	auto picker = [[UIDocumentPickerViewController alloc]
	        initForOpeningContentTypes:@[UTTypeFolder]];
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];

	// The picker's own close button is only on its top level, so add one
	// that's always there
	auto config        = UIButtonConfiguration.filledButtonConfiguration;
	config.title       = @"Cancel";
	config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
	__weak UIDocumentPickerViewController* weak_picker = picker;
	auto cancel = [UIButton buttonWithConfiguration:config
	                                  primaryAction:[UIAction actionWithHandler:^(UIAction*) {
		                                  [weak_picker dismissViewControllerAnimated:YES
		                                                                  completion:nil];
	                                  }]];
	cancel.translatesAutoresizingMaskIntoConstraints = NO;
	[picker.view addSubview:cancel];
	const auto guide = picker.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[cancel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
		[cancel.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-8],
	]];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
        didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
{
	NSURL* source = urls.firstObject;
	if (!source) {
		return;
	}

	auto copying = [UIAlertController
	        alertControllerWithTitle:[NSString stringWithFormat:@"Copying %@…",
	                                                            source.lastPathComponent]
	                         message:nil
	                  preferredStyle:UIAlertControllerStyleAlert];
	[self presentViewController:copying animated:YES completion:nil];

	// Games can be large; copy off the main thread
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError* error    = nil;
		const auto folder = ImportGameFolder(source, &error);

		dispatch_async(dispatch_get_main_queue(), ^{
			[copying dismissViewControllerAnimated:YES
			                            completion:^{
				                            [self finishAdding:folder error:error];
			                            }];
		});
	});
}

- (void)finishAdding:(NSString*)folder error:(NSError*)error
{
	if (!folder) {
		show_error(self, @"Couldn't copy the game", error);
		return;
	}

	const auto programs = FindGamePrograms(folder);
	if (programs.count == 0) {
		[NSFileManager.defaultManager removeItemAtPath:folder error:nil];

		auto alert = [UIAlertController
		        alertControllerWithTitle:@"No DOS programs found"
		                         message:[NSString stringWithFormat:
		                                                   @"There's nothing in %@ that DOS can run. "
		                                                   @"For a Windows 3.1 game, see Adding Games (?).",
		                                                   folder.lastPathComponent]
		                  preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK"
		                                          style:UIAlertActionStyleDefault
		                                        handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	__weak DBLibraryViewController* weak_self = self;
	auto picker = [[DBProgramPickerViewController alloc]
	        initWithFolder:folder
	              programs:programs
	            completion:^(NSString*) {
		            [weak_self reload];
		            [weak_self.navigationController popToRootViewControllerAnimated:YES];
	            }];
	[self.navigationController pushViewController:picker animated:YES];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	return static_cast<NSInteger>(self.names.count);
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section
{
	if (self.names.count == 0) {
		return @"No games yet. Tap + to add one, or ? to see how.";
	}
	return nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
	auto cell = [tableView dequeueReusableCellWithIdentifier:@"game"
	                                            forIndexPath:indexPath];
	auto content  = cell.defaultContentConfiguration;
	content.text  = self.names[static_cast<NSUInteger>(indexPath.row)];
	content.image = [UIImage systemImageNamed:@"play.rectangle"];
	cell.contentConfiguration = content;
	cell.accessoryType        = UITableViewCellAccessoryDetailButton;
	return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	self.chosenGame = self.names[static_cast<NSUInteger>(indexPath.row)];
}

// The (i) button opens the game's settings
- (void)tableView:(UITableView*)tableView
        accessoryButtonTappedForRowWithIndexPath:(NSIndexPath*)indexPath
{
	[self showSettings:self.names[static_cast<NSUInteger>(indexPath.row)]];
}

- (void)showSettings:(NSString*)name
{
	__weak DBLibraryViewController* weak_self = self;
	auto settings = MakeGameSettingsController(name, self.games[name], ^(NSString*) {
		[weak_self reload];
	});
	[self.navigationController pushViewController:settings animated:YES];
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath
{
	NSString* name      = self.names[static_cast<NSUInteger>(indexPath.row)];
	NSString* conf_path = self.games[name];

	auto remove = [UIContextualAction
	        contextualActionWithStyle:UIContextualActionStyleDestructive
	                            title:@"Remove"
	                          handler:^(UIContextualAction*, UIView*, void (^done)(BOOL)) {
		                          [self confirmRemoving:name
		                                       confPath:conf_path
		                                     completion:done];
	                          }];
	return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

// A game folder holds the game's files and saved games, so ask first
- (void)confirmRemoving:(NSString*)name
               confPath:(NSString*)conf_path
             completion:(void (^)(BOOL))done
{
	const auto is_folder = IsGameFolder(conf_path);
	const auto target    = is_folder ? conf_path.stringByDeletingLastPathComponent
	                                 : conf_path;

	auto alert = [UIAlertController
	        alertControllerWithTitle:[NSString stringWithFormat:@"Remove %@?", name]
	                         message:is_folder ? @"This deletes the game's folder, with all its "
	                                             @"files and saved games."
	                                           : @"This deletes the game's settings file; the "
	                                             @"game's files stay where they are."
	                  preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
	                                          style:UIAlertActionStyleCancel
	                                        handler:^(UIAlertAction*) {
		                                        done(NO);
	                                        }]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Remove"
	                                          style:UIAlertActionStyleDestructive
	                                        handler:^(UIAlertAction*) {
		                                        const auto removed = [NSFileManager.defaultManager
		                                                removeItemAtPath:target
		                                                           error:nil];
		                                        [self reload];
		                                        done(removed);
	                                        }]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end

static UIWindowScene* active_window_scene()
{
	for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
		if ([scene isKindOfClass:UIWindowScene.class]) {
			return static_cast<UIWindowScene*>(scene);
		}
	}
	return nil;
}

std::vector<std::string> IOS_ChooseGame(const std::string& program_path)
{
	static UIWindow* window = nil;

	CreateLibraryFolders();
	maybe_import_for_testing();
	SetCurrentGame(nil, nil);

	auto library = [[DBLibraryViewController alloc] init];

	if (restarting_game) {
		library.chosenGame = restarting_game;
		restarting_game    = nil;
	} else if (const auto name = next_autopick()) {
		library.chosenGame = @(name->c_str());
	} else {
		// Wait for the window scene; on first launch the library can be
		// shown before UIKit has connected it
		auto scene = active_window_scene();
		while (!scene) {
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
			scene = active_window_scene();
		}
		if (!window) {
			window = [[UIWindow alloc] initWithWindowScene:scene];
		}
		window.rootViewController = [[UINavigationController alloc]
		        initWithRootViewController:library];
		[window makeKeyAndVisible];

		// Test hooks: open the help page, the folder picker or a game's
		// settings (for screenshots)
		if (std::getenv("DOSPAD_SHOW_HELP")) {
			[library showHelp];
		}
		if (std::getenv("DOSPAD_SHOW_PICKER")) {
			[library addGame];
		}
		if (const auto name = std::getenv("DOSPAD_SHOW_SETTINGS")) {
			[library showSettings:@(name)];
		}

		// The emulator owns the main thread, so run the main run loop
		// here until a game is picked
		while (!library.chosenGame) {
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
		}
		window.hidden = YES;
	}

	std::vector<std::string> args = {program_path};

	if (NSString* conf_path = library.games[library.chosenGame]) {
		args.insert(args.end(), {"--conf", conf_path.UTF8String});
		SetCurrentGame(library.chosenGame, conf_path);
		SyncWindowsScreenSize(conf_path);
	}
	for (const auto& setting : RequiredSettings) {
		args.insert(args.end(), {"--set", setting});
	}
	return args;
}

void IOS_RestartGame()
{
	restarting_game = CurrentGameName();
	DOSBOX_RequestShutdown();
}
