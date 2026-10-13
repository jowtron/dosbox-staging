// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_IOS_GAME_SETTINGS_H
#define DOSBOX_IOS_GAME_SETTINGS_H

#import <UIKit/UIKit.h>

// Each game's settings. Emulator settings (CPU speed, memory, etc.) are
// written into the game's own config file, on top of the shared
// 'dosbox.conf'; settings only the app knows about (mouse mode, game keys,
// the gamepad) are kept in the app's user defaults, by game name.

// Posted when a game's settings change
extern NSString* const GameSettingsChangedNotification;

// The game being played and its config file, or nil in the library
NSString* CurrentGameName();
NSString* CurrentGameConfPath();
void SetCurrentGame(NSString* name, NSString* conf_path);

// Pointer mode: direct touch (the default) or trackpad
bool IsDirectTouch(NSString* game);
void SetDirectTouch(NSString* game, bool direct_touch);

// The game's key panel, or nil for none
NSString* GameKeysPanel(NSString* game);
extern NSString* const ColonizationKeys;

// The on-screen gamepad: a stick and four buttons, shown with its toggle.
// The stick presses the arrow keys or moves the emulated joystick.
enum class GamepadStick { ArrowKeys, Joystick };
GamepadStick GetGamepadStick(NSString* game);
bool IsGamepadShown(NSString* game);
void SetGamepadShown(NSString* game, bool shown);

// The buttons, by position: bottom, right, left, top. Each sends a key (an
// SDL scancode) or presses one of the emulated joystick's two buttons.
constexpr int GamepadButtonCount = 4;
constexpr int JoystickButton1    = -1;
constexpr int JoystickButton2    = -2;
int GetGamepadButton(NSString* game, int button);
NSString* GamepadButtonLabel(int action);

// A screen that edits a game's settings, to be shown in a navigation
// controller. The name can only be changed if 'on_rename' is given (not while
// the game is running); it's called with the game's new name.
UIViewController* MakeGameSettingsController(NSString* game, NSString* conf_path,
                                             void (^on_rename)(NSString* new_name));

#endif // DOSBOX_IOS_GAME_SETTINGS_H
