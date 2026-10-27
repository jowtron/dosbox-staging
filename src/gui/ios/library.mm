// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/library.h"

#include "gui/ios/game_icons.h"
#include "gui/ios/game_import.h"
#include "gui/ios/game_settings.h"
#include "gui/ios/touch_overlay.h"
#include "gui/ios/windows_display.h"

#include "dosbox.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cmath>
#include <cstdlib>
#include <optional>
#include <string_view>

#include "utils/string_utils.h"

namespace {

// Settings the app needs whatever a game's config says, applied after all
// the config files
const std::vector<std::string> RequiredSettings = {
        // The app is always full screen
        "sdl fullscreen=true",
        // The touch overlay's direct touch mode needs absolute pointing
        "mouse mouse_capture=seamless",
        // Pause while the app is in the background (or the Control Centre
        // or a call covers it)
        "sdl pause_when_inactive=true",
};

// iOS always waits for the display's refresh before handing out the next
// frame, on the emulator's thread. Presenting at the DOS rate (up to 70 Hz)
// on a 60 Hz screen stalls it on every frame, so those screens present at
// the host rate. On a 120 Hz screen the DOS rate leaves frames to spare, so
// the wait rarely happens, whereas presenting at the host rate keeps the
// frame queue full and waits on nearly every frame.
std::string PresentationSetting()
{
	constexpr auto FastScreenHz = 100;
	const auto screen_hz = static_cast<int>(UIScreen.mainScreen.maximumFramesPerSecond);
	return std::string("sdl presentation_mode=") +
	       (screen_hz >= FastScreenHz ? "dos-rate" : "host-rate");
}

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
// - DOSPAD_SET_ICON is 'game=file': a picture, .ico file or program to make
//   the game's icon on launch, as if chosen in its settings.
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

void maybe_set_icon_for_testing()
{
	static bool is_done = false;
	const auto setting  = std::getenv("DOSPAD_SET_ICON");
	if (is_done || !setting) {
		return;
	}
	is_done = true;

	const auto parts = [@(setting) componentsSeparatedByString:@"="];
	if (parts.count != 2) {
		return;
	}
	const auto conf_path = FindGames()[parts[0]];
	const auto is_set    = conf_path &&
	                    SetCustomIcon(conf_path, [NSURL fileURLWithPath:parts[1]]);
	NSLog(@"DOSPAD_SET_ICON: '%@' from '%@': %d", parts[0], parts[1], is_set);
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
	    @"memory, the picture, the shader, music, and the touch controls. "
	    @"They're saved in the game's dosbox.conf. In a game, the same settings "
	    @"are in the ☰ menu.\n\n",
	    body);

	add(@"Settings for every game (⚙)\n", heading);
	add(@"The ⚙ button in the library sets what every game starts with, saved "
	    @"in the shared dosbox.conf. A game's own settings override them.\n\n",
	    body);

	add(@"Shaders\n", heading);
	add(@"A shader draws the screen like an old monitor, with scanlines and "
	    @"glow. Auto CRT picks the look that suits each video mode, from CGA to "
	    @"VGA; you can also choose one of DOSBox Staging's CRT presets or other "
	    @"shaders by name. To use your own, put .glsl shader files in the "
	    @"shaders folder in the Files app. \"Sharp pixels\" turns shaders off "
	    @"and keeps the pixels crisp and even.\n\n",
	    body);

	add(@"Gamepad\n", heading);
	add(@"In a game, the gamepad button (top right) shows a stick and four "
	    @"buttons. The stick presses the arrow keys, or can be a joystick; "
	    @"choose which, and the key each button presses, in the game's "
	    @"settings.\n\n",
	    body);

	add(@"Music\n", heading);
	add(@"Many games play music through a MIDI synthesiser. Put General MIDI "
	    @"SoundFonts (.sf2 files) in the soundfonts folder, and Roland MT-32 "
	    @"ROMs in the mt32-roms folder, both next to the Games folder. Then "
	    @"choose one in a game's Music setting.\n\n",
	    body);

	add(@"Game keys\n", heading);
	add(@"A game can have a panel of its own keys, shown with the Game button. "
	    @"Choose them under Game keys in the game's settings: add the keys the "
	    @"game uses, each labelled with what it does, or start from a "
	    @"ready-made set.\n\n",
	    body);

	add(@"Windows 3.1 games\n", heading);
	add(@"Install them inside Windows, then add a settings file for each game "
	    @"to the Games folder, which starts Windows with the game's program. "
	    @"If Windows is in a folder called Windows next to the Games folder:"
	    @"\n\n",
	    body);
	add(@"[autoexec]\nmount c Windows\nc:\nwin c:\\mygame\\game.exe\nexit\n\n", code);
	add(@"Windows can fill the screen with VBESVGA, a free display driver by "
	    @"PluMGMK. A Windows game's settings can download and install it, and "
	    @"then set Windows' screen size.\n\n",
	    body);

	add(@"Removing games\n", heading);
	add(@"Press and hold a game to remove it. For a game added with +, that "
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

@interface DBLibraryViewController
        : UICollectionViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* games;
@property(nonatomic, copy) NSArray<NSString*>* names;
@property(nonatomic, copy) NSString* chosenGame;
- (void)showHelp;
- (void)showSharedSettings;
- (void)addGame;
- (void)showSettings:(NSString*)name;
@end

@implementation DBLibraryViewController

// The narrowest screen that has room for two columns, in points
constexpr CGFloat TwoColumnWidth = 700;

// One scrolling list of games, two to a row on a wide screen
static UICollectionViewLayout* make_library_layout()
{
	return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^(
	        NSInteger, id<NSCollectionLayoutEnvironment> environment) {
		const auto width   = environment.container.effectiveContentSize.width;
		const auto columns = (width >= TwoColumnWidth) ? 2 : 1;

		const auto height = [NSCollectionLayoutDimension estimatedDimension:56];
		auto item         = [NSCollectionLayoutItem
                itemWithLayoutSize:[NSCollectionLayoutSize
		                                   sizeWithWidthDimension:[NSCollectionLayoutDimension
		                                                                  fractionalWidthDimension:1.0 / columns]
		                                          heightDimension:height]];
		auto group = [NSCollectionLayoutGroup
		        horizontalGroupWithLayoutSize:[NSCollectionLayoutSize
		                                              sizeWithWidthDimension:[NSCollectionLayoutDimension
		                                                                             fractionalWidthDimension:1]
		                                                     heightDimension:height]
		                     repeatingSubitem:item
		                                count:columns];
		group.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:16];

		auto section                    = [NSCollectionLayoutSection sectionWithGroup:group];
		section.interGroupSpacing       = 12;
		section.contentInsetsReference  = UIContentInsetsReferenceLayoutMargins;
		section.contentInsets           = NSDirectionalEdgeInsetsMake(16, 0, 16, 0);
		return section;
	}];
}

- (instancetype)init
{
	self = [super initWithCollectionViewLayout:make_library_layout()];
	if (self) {
		self.title = @"Games";
		[self loadGames];
	}
	return self;
}

- (void)reloadTables
{
	[self.collectionView reloadData];
	[self showEmptyMessage];
}

- (void)showEmptyMessage
{
	if (self.names.count > 0) {
		self.collectionView.backgroundView = nil;
		return;
	}
	auto label           = [[UILabel alloc] init];
	label.text           = @"No games yet. Tap + to add one, or ? to see how.";
	label.textColor      = UIColor.secondaryLabelColor;
	label.textAlignment  = NSTextAlignmentCenter;
	label.numberOfLines  = 0;
	self.collectionView.backgroundView = label;
}

- (NSString*)nameAt:(NSIndexPath*)index_path
{
	return self.names[static_cast<NSUInteger>(index_path.item)];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.collectionView.backgroundColor = UIColor.systemGroupedBackgroundColor;
	[self.collectionView registerClass:UICollectionViewListCell.class
	        forCellWithReuseIdentifier:@"game"];
	[self showEmptyMessage];

	// Icons can be changed in a game's settings
	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(reloadTables)
	                                           name:GameSettingsChangedNotification
	                                         object:nil];

	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
	        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
	                             target:self
	                             action:@selector(addGame)];
	self.navigationItem.leftBarButtonItems = @[
		[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"questionmark.circle"]
		                                 style:UIBarButtonItemStylePlain
		                                target:self
		                                action:@selector(showHelp)],
		[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
		                                 style:UIBarButtonItemStylePlain
		                                target:self
		                                action:@selector(showSharedSettings)],
	];
}

- (void)showSharedSettings
{
	[self.navigationController pushViewController:MakeSharedSettingsController() animated:YES];
}

- (void)loadGames
{
	self.games = FindGames();
	self.names = sorted_names(self.games);
	ForgetGameIcons();
}

- (void)reload
{
	[self loadGames];
	[self reloadTables];
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

- (NSInteger)collectionView:(UICollectionView*)collectionView
     numberOfItemsInSection:(NSInteger)section
{
	return static_cast<NSInteger>(self.names.count);
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)collectionView
                 cellForItemAtIndexPath:(NSIndexPath*)indexPath
{
	auto cell = static_cast<UICollectionViewListCell*>(
	        [collectionView dequeueReusableCellWithReuseIdentifier:@"game" forIndexPath:indexPath]);
	NSString* const name = [self nameAt:indexPath];

	auto content  = cell.defaultContentConfiguration;
	content.text  = name;
	content.image = GameIcon(self.games[name]) ?: [UIImage systemImageNamed:@"play.rectangle"];
	content.imageProperties.reservedLayoutSize = CGSizeMake(GameIconSize, GameIconSize);
	cell.contentConfiguration = content;

	auto background         = UIBackgroundConfiguration.listGroupedCellConfiguration;
	background.cornerRadius = 12;
	cell.backgroundConfiguration = background;

	// The (i) button opens the game's settings. Our own button rather than
	// the system detail accessory, whose small target made taps beside the
	// symbol start the game instead
	__weak DBLibraryViewController* weak_self = self;
	auto button        = [UIButton buttonWithType:UIButtonTypeSystem];
	auto config        = UIButtonConfiguration.plainButtonConfiguration;
	config.image       = [UIImage systemImageNamed:@"info.circle"];
	config.preferredSymbolConfigurationForImage =
	        [UIImageSymbolConfiguration configurationWithPointSize:24];
	config.contentInsets = NSDirectionalEdgeInsetsMake(14, 28, 14, 20);
	button.configuration = config;
	[button addAction:[UIAction actionWithHandler:^(UIAction*) {
		        [weak_self showSettings:name];
	        }]
	        forControlEvents:UIControlEventTouchUpInside];
	auto info = [[UICellAccessoryCustomView alloc] initWithCustomView:button
	                                                        placement:UICellAccessoryPlacementTrailing];
	cell.accessories = @[info];
	return cell;
}

- (void)collectionView:(UICollectionView*)collectionView
        didSelectItemAtIndexPath:(NSIndexPath*)indexPath
{
	[collectionView deselectItemAtIndexPath:indexPath animated:YES];
	self.chosenGame = [self nameAt:indexPath];
}

- (void)showSettings:(NSString*)name
{
	__weak DBLibraryViewController* weak_self = self;
	auto settings = MakeGameSettingsController(
	        name,
	        self.games[name],
	        ^(NSString*) {
		        [weak_self reload];
	        },
	        ^(NSString* game) {
		        weak_self.chosenGame = game;
	        });
	[self.navigationController pushViewController:settings animated:YES];
}

// Pressing and holding a game offers its settings and removing it
- (UIContextMenuConfiguration*)collectionView:(UICollectionView*)collectionView
    contextMenuConfigurationForItemsAtIndexPaths:(NSArray<NSIndexPath*>*)indexPaths
                                           point:(CGPoint)point
{
	if (indexPaths.count != 1) {
		return nil;
	}
	NSString* const name      = [self nameAt:indexPaths.firstObject];
	NSString* const conf_path = self.games[name];

	__weak DBLibraryViewController* weak_self = self;
	return [UIContextMenuConfiguration
	        configurationWithIdentifier:nil
	                    previewProvider:nil
	                     actionProvider:^(NSArray<UIMenuElement*>*) {
		                     auto settings = [UIAction
		                             actionWithTitle:@"Settings"
		                                       image:[UIImage systemImageNamed:@"info.circle"]
		                                  identifier:nil
		                                     handler:^(UIAction*) {
			                                     [weak_self showSettings:name];
		                                     }];
		                     auto remove = [UIAction
		                             actionWithTitle:@"Remove"
		                                       image:[UIImage systemImageNamed:@"trash"]
		                                  identifier:nil
		                                     handler:^(UIAction*) {
			                                     [weak_self confirmRemoving:name
			                                                       confPath:conf_path
			                                                     completion:^(BOOL) {}];
		                                     }];
		                     remove.attributes = UIMenuElementAttributesDestructive;
		                     return [UIMenu menuWithChildren:@[settings, remove]];
	                     }];
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
		                                        if (removed && !is_folder) {
			                                        RemoveCustomIcon(conf_path);
		                                        }
		                                        [self reload];
		                                        done(removed);
	                                        }]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end

// The way up the device is held, if the screen can turn that way. The
// device's left is the screen's right.
static UIInterfaceOrientationMask held_orientation(const UIInterfaceOrientationMask allowed)
{
	auto held = allowed;
	switch (UIDevice.currentDevice.orientation) {
	case UIDeviceOrientationPortrait: held = UIInterfaceOrientationMaskPortrait; break;
	case UIDeviceOrientationPortraitUpsideDown:
		held = UIInterfaceOrientationMaskPortraitUpsideDown;
		break;
	case UIDeviceOrientationLandscapeLeft: held = UIInterfaceOrientationMaskLandscapeRight; break;
	case UIDeviceOrientationLandscapeRight: held = UIInterfaceOrientationMaskLandscapeLeft; break;
	default: break;
	}
	return (held & allowed) ? held : allowed;
}

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
	// So the library knows how the device is held when a game ends
	[UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
	maybe_import_for_testing();
	maybe_set_icon_for_testing();
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

		// After a game, which is always landscape, turn back to however
		// the device is held
		[window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
		[scene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc]
		                                                    initWithInterfaceOrientations:held_orientation(
		                                                                                          window.rootViewController
		                                                                                                  .supportedInterfaceOrientations)]
		                               errorHandler:nil];

		// Test hooks: open the help page, the folder picker or a game's
		// settings, or with '*' the settings for every game (for screenshots)
		if (std::getenv("DOSPAD_SHOW_HELP")) {
			[library showHelp];
		}
		if (std::getenv("DOSPAD_SHOW_PICKER")) {
			[library addGame];
		}
		if (const auto name = std::getenv("DOSPAD_SHOW_SETTINGS")) {
			if (std::string_view(name) == "*") {
				[library showSharedSettings];
			} else {
				[library showSettings:@(name)];
			}
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
	args.insert(args.end(), {"--set", PresentationSetting()});
	// A game's Keyboard setting remaps keys for an attached keyboard; it
	// would catch the on-screen keyboard's keys too, so without one the
	// mapper starts with its defaults (the overlay follows the keyboard
	// from there)
	if (!IOS_KeyboardAttached()) {
		args.insert(args.end(), {"--set", "sdl mapperfile="});
	}
	return args;
}

void IOS_RestartGame()
{
	restarting_game = CurrentGameName();
	DOSBOX_RequestShutdown();
}
