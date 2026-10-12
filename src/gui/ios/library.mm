// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/library.h"

#import <UIKit/UIKit.h>

#include <cstdlib>
#include <optional>

#include "utils/string_utils.h"

namespace {

// Relative to the working directory, the app's Documents folder
NSString* const GamesFolder = @"Games";

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

// Test hook for driving the library without taps (e.g., in the iOS
// Simulator): DOSPAD_AUTOPICK lists game names separated by ';', which are
// picked one after another each time the library is shown.
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

} // namespace

@interface DBLibraryViewController : UITableViewController
@property(nonatomic, copy) NSArray<NSString*>* confs;
@property(nonatomic, copy) NSString* chosenConf;
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
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
	return static_cast<NSInteger>(self.confs.count);
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section
{
	if (self.confs.count == 0) {
		return @"No games yet. Put a DOSBox config file for each game in the "
		       @"Games folder (Files › On My iPhone › dosbox › Games); its "
		       @"[autoexec] section starts the game.";
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
