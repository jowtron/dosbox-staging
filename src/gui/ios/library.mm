// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/library.h"

#include "gui/ios/game_import.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cstdlib>
#include <optional>

#include "utils/string_utils.h"

namespace {

NSString* const ConfExtension = @"conf";

NSArray<NSString*>* find_game_confs()
{
	auto files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:GamesFolder
	                                                               error:nil];
	auto confs = [NSMutableArray<NSString*> array];
	for (NSString* file in files) {
		if ([file.pathExtension.lowercaseString isEqualToString:ConfExtension]) {
			[confs addObject:file];
		}
	}
	[confs sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
	return confs;
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
	const auto name = WriteGameConf(folder.lastPathComponent,
	                                folder,
	                                program,
	                                FindGameCdImage(folder),
	                                &error);
	NSLog(@"DOSPAD_IMPORT: added '%@' starting '%@' (found: %@)", name, program, programs);
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
	    @"iPhone, or on a USB drive. The folder is copied into the app, and "
	    @"you choose which program starts the game. If the folder has a CD "
	    @"image (.cue or .iso), it becomes the CD drive, D:.\n\n"
	    @"The game's folder is drive C:. Quitting the game brings you back "
	    @"to this list.\n\n",
	    body);

	add(@"Doing it by hand\n", heading);
	add(@"Each game in the list is a small DOSBox config file in the Games "
	    @"folder (Files › On My iPhone › DOSBox Staging › Games), named after "
	    @"the game. Its [autoexec] section runs when the game starts, for "
	    @"example:\n\n",
	    body);
	add(@"[autoexec]\nmount c \"Imported/DUKE3D\"\nc:\nDUKE3D.EXE\nexit\n\n", code);
	add(@"The last line, exit, returns to the list when the game quits; "
	    @"leave it out to stay at the DOS prompt instead.\n\n"
	    @"A game's config can also change any DOSBox setting just for that "
	    @"game, such as cpu_cycles in a [cpu] section. Settings for every "
	    @"game go in dosbox.conf in the app's main folder.\n\n",
	    body);

	add(@"Windows 3.1 games\n", heading);
	add(@"Install them inside Windows, then add a config that starts Windows "
	    @"with the game, like the Colonization one.\n\n",
	    body);

	add(@"Removing games\n", heading);
	add(@"Swipe left on a game to remove it from the list. Its files stay in "
	    @"the Imported folder; delete them in the Files app if you don't need "
	    @"them any more.\n",
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
	if (_programs.count == 0) {
		return @"There are no DOS programs in this folder. The folder was copied "
		       @"into the Imported folder; you can add the game by hand (see "
		       @"Adding Games).";
	}
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

	NSError* error       = nil;
	const auto conf_name = WriteGameConf(_folder.lastPathComponent,
	                                     _folder,
	                                     _programs[static_cast<NSUInteger>(indexPath.row)],
	                                     _cd_image,
	                                     &error);
	if (!conf_name) {
		show_error(self, @"Couldn't add the game", error);
		return;
	}
	_completion(conf_name);
}

@end

// The list of games

@interface DBLibraryViewController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSArray<NSString*>* confs;
@property(nonatomic, copy) NSString* chosenConf;
- (void)showHelp;
@end

@implementation DBLibraryViewController

- (instancetype)init
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		self.title = @"Games";
		self.confs = find_game_confs();
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

- (void)reload
{
	self.confs = find_game_confs();
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

	__weak DBLibraryViewController* weak_self = self;
	auto picker = [[DBProgramPickerViewController alloc]
	        initWithFolder:folder
	              programs:FindGamePrograms(folder)
	            completion:^(NSString*) {
		            [weak_self reload];
		            [weak_self.navigationController popToRootViewControllerAnimated:YES];
	            }];
	[self.navigationController pushViewController:picker animated:YES];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	return static_cast<NSInteger>(self.confs.count);
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section
{
	if (self.confs.count == 0) {
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
	content.text  = self.confs[static_cast<NSUInteger>(indexPath.row)]
	                       .stringByDeletingPathExtension;
	content.image = [UIImage systemImageNamed:@"play.rectangle"];
	cell.contentConfiguration = content;
	cell.accessoryType        = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	self.chosenConf = self.confs[static_cast<NSUInteger>(indexPath.row)];
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath
{
	NSString* conf = self.confs[static_cast<NSUInteger>(indexPath.row)];

	auto remove = [UIContextualAction
	        contextualActionWithStyle:UIContextualActionStyleDestructive
	                            title:@"Remove"
	                          handler:^(UIContextualAction*, UIView*, void (^done)(BOOL)) {
		                          const auto path = [GamesFolder
		                                  stringByAppendingPathComponent:conf];
		                          const auto removed = [NSFileManager.defaultManager
		                                  removeItemAtPath:path
		                                             error:nil];
		                          [self reload];
		                          done(removed);
	                          }];
	return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
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

	maybe_import_for_testing();

	auto library = [[DBLibraryViewController alloc] init];

	if (const auto name = next_autopick()) {
		library.chosenConf = [NSString stringWithFormat:@"%s.%@",
		                                                name->c_str(),
		                                                ConfExtension];
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

		// Test hook: open the help page (for screenshots)
		if (std::getenv("DOSPAD_SHOW_HELP")) {
			[library showHelp];
		}

		// The emulator owns the main thread, so run the main run loop
		// here until a game is picked
		while (!library.chosenConf) {
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
		}
		window.hidden = YES;
	}

	const auto conf_path = [GamesFolder stringByAppendingPathComponent:library.chosenConf];

	return {program_path, "--conf", conf_path.UTF8String};
}
