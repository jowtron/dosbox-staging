// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/ios/touch_overlay.h"

#include "dosbox.h"

#include "config/config.h"
#include "config/setup.h"
#include "gui/ios/game_import.h"
#include "gui/ios/game_settings.h"
#include "gui/ios/library.h"

#include "hardware/input/joystick.h"
#include "hardware/memory.h"
#include "ints/bios.h"

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <optional>
#include <utility>
#include <vector>

// The overlay feeds the emulator plain SDL events, so everything downstream
// (the mapper, the keyboard and mouse emulation) treats it exactly like a
// hardware keyboard and mouse.

namespace {

SDL_Window* sdl_window = nullptr;

float cursor_x = 0.0f;
float cursor_y = 0.0f;

SDL_MouseButtonFlags mouse_buttons = 0;

// Finger movement in points is multiplied by this to get mouse movement
constexpr float TrackpadSpeed = 1.5f;

// DOS programs often poll the button state rather than counting presses, so
// a tap holds the button down long enough to be seen
constexpr int64_t ClickDurationNs = 60'000'000;

void push_key(const SDL_Scancode scancode, const bool down)
{
	SDL_Event event = {};

	event.type         = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
	event.key.timestamp = SDL_GetTicksNS();
	event.key.windowID  = SDL_GetWindowID(sdl_window);
	event.key.scancode  = scancode;
	event.key.key       = SDL_GetKeyFromScancode(scancode, SDL_KMOD_NONE, false);
	event.key.down      = down;

	SDL_PushEvent(&event);
}

void push_motion(const float dx, const float dy)
{
	int width  = 0;
	int height = 0;
	SDL_GetWindowSize(sdl_window, &width, &height);

	cursor_x = std::clamp(cursor_x + dx, 0.0f, static_cast<float>(width - 1));
	cursor_y = std::clamp(cursor_y + dy, 0.0f, static_cast<float>(height - 1));

	SDL_Event event = {};

	event.type             = SDL_EVENT_MOUSE_MOTION;
	event.motion.timestamp = SDL_GetTicksNS();
	event.motion.windowID  = SDL_GetWindowID(sdl_window);
	event.motion.which     = 1;
	event.motion.state     = mouse_buttons;
	event.motion.x         = cursor_x;
	event.motion.y         = cursor_y;
	event.motion.xrel      = dx;
	event.motion.yrel      = dy;

	SDL_PushEvent(&event);
}

// Moves the pointer to a point in window coordinates
void push_motion_to(const CGPoint point)
{
	push_motion(static_cast<float>(point.x) - cursor_x,
	            static_cast<float>(point.y) - cursor_y);
}

void push_button(const Uint8 button, const bool down)
{
	if (down) {
		mouse_buttons |= SDL_BUTTON_MASK(button);
	} else {
		mouse_buttons &= ~SDL_BUTTON_MASK(button);
	}

	SDL_Event event = {};

	event.type             = down ? SDL_EVENT_MOUSE_BUTTON_DOWN
	                              : SDL_EVENT_MOUSE_BUTTON_UP;
	event.button.timestamp = SDL_GetTicksNS();
	event.button.windowID  = SDL_GetWindowID(sdl_window);
	event.button.which     = 1;
	event.button.button    = button;
	event.button.down      = down;
	event.button.clicks    = 1;
	event.button.x         = cursor_x;
	event.button.y         = cursor_y;

	SDL_PushEvent(&event);
}

void click(const Uint8 button)
{
	push_button(button, true);

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ClickDurationNs),
	               dispatch_get_main_queue(),
	               ^{
		               push_button(button, false);
	               });
}

// Pressing the button the moment the pointer arrives can register the click
// at the old position, so give the guest a moment to see the move first
constexpr int64_t MoveSettleNs = 30'000'000;

void click_at(const CGPoint point, const Uint8 button)
{
	push_motion_to(point);

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MoveSettleNs),
	               dispatch_get_main_queue(),
	               ^{
		               click(button);
	               });
}

// The Game keys go down the left side as a column on screens at least this
// wide for their height (phones in landscape)
constexpr CGFloat WideScreenAspect = 1.9;

// The BIOS keyboard flags in the BIOS data area; Windows keeps them in sync
// for DOS sessions as well
bool is_numlock_on()
{
	constexpr uint8_t NumLockActive = 0x20;
	return (mem_readb(BIOS_KEYBOARD_FLAGS1) & NumLockActive) != 0;
}

void tap_key(const SDL_Scancode scancode)
{
	push_key(scancode, true);

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ClickDurationNs),
	               dispatch_get_main_queue(),
	               ^{
		               push_key(scancode, false);
	               });
}

bool is_modifier(const SDL_Scancode scancode)
{
	switch (scancode) {
	case SDL_SCANCODE_LSHIFT:
	case SDL_SCANCODE_RSHIFT:
	case SDL_SCANCODE_LCTRL:
	case SDL_SCANCODE_RCTRL:
	case SDL_SCANCODE_LALT:
	case SDL_SCANCODE_RALT: return true;
	default: return false;
	}
}

struct KeyDef {
	NSString* label     = nil;
	SDL_Scancode scancode = SDL_SCANCODE_UNKNOWN;
	float width_units   = 1.0f;
	NSString* caption   = nil; // optional second line saying what the key does
	int modifiers       = 0;   // GameKey modifier flags, held with the key
};

// Each row is 15 units wide; an UNKNOWN scancode is an empty gap
std::vector<std::vector<KeyDef>> keyboard_layout()
{
	return {
	        {{@"Esc", SDL_SCANCODE_ESCAPE},
	         {@"F1", SDL_SCANCODE_F1},
	         {@"F2", SDL_SCANCODE_F2},
	         {@"F3", SDL_SCANCODE_F3},
	         {@"F4", SDL_SCANCODE_F4},
	         {@"F5", SDL_SCANCODE_F5},
	         {@"F6", SDL_SCANCODE_F6},
	         {@"F7", SDL_SCANCODE_F7},
	         {@"F8", SDL_SCANCODE_F8},
	         {@"F9", SDL_SCANCODE_F9},
	         {@"F10", SDL_SCANCODE_F10},
	         {@"F11", SDL_SCANCODE_F11},
	         {@"F12", SDL_SCANCODE_F12},
	         {@"PgUp", SDL_SCANCODE_PAGEUP},
	         {@"PgDn", SDL_SCANCODE_PAGEDOWN}},

	        {{@"`", SDL_SCANCODE_GRAVE},
	         {@"1", SDL_SCANCODE_1},
	         {@"2", SDL_SCANCODE_2},
	         {@"3", SDL_SCANCODE_3},
	         {@"4", SDL_SCANCODE_4},
	         {@"5", SDL_SCANCODE_5},
	         {@"6", SDL_SCANCODE_6},
	         {@"7", SDL_SCANCODE_7},
	         {@"8", SDL_SCANCODE_8},
	         {@"9", SDL_SCANCODE_9},
	         {@"0", SDL_SCANCODE_0},
	         {@"-", SDL_SCANCODE_MINUS},
	         {@"=", SDL_SCANCODE_EQUALS},
	         {@"Bksp", SDL_SCANCODE_BACKSPACE, 2.0f}},

	        {{@"Tab", SDL_SCANCODE_TAB, 1.5f},
	         {@"Q", SDL_SCANCODE_Q},
	         {@"W", SDL_SCANCODE_W},
	         {@"E", SDL_SCANCODE_E},
	         {@"R", SDL_SCANCODE_R},
	         {@"T", SDL_SCANCODE_T},
	         {@"Y", SDL_SCANCODE_Y},
	         {@"U", SDL_SCANCODE_U},
	         {@"I", SDL_SCANCODE_I},
	         {@"O", SDL_SCANCODE_O},
	         {@"P", SDL_SCANCODE_P},
	         {@"[", SDL_SCANCODE_LEFTBRACKET},
	         {@"]", SDL_SCANCODE_RIGHTBRACKET},
	         {@"\\", SDL_SCANCODE_BACKSLASH, 1.5f}},

	        {{@"Caps", SDL_SCANCODE_CAPSLOCK, 1.75f},
	         {@"A", SDL_SCANCODE_A},
	         {@"S", SDL_SCANCODE_S},
	         {@"D", SDL_SCANCODE_D},
	         {@"F", SDL_SCANCODE_F},
	         {@"G", SDL_SCANCODE_G},
	         {@"H", SDL_SCANCODE_H},
	         {@"J", SDL_SCANCODE_J},
	         {@"K", SDL_SCANCODE_K},
	         {@"L", SDL_SCANCODE_L},
	         {@";", SDL_SCANCODE_SEMICOLON},
	         {@"'", SDL_SCANCODE_APOSTROPHE},
	         {@"Enter", SDL_SCANCODE_RETURN, 2.25f}},

	        {{@"Shift", SDL_SCANCODE_LSHIFT, 2.0f},
	         {@"Z", SDL_SCANCODE_Z},
	         {@"X", SDL_SCANCODE_X},
	         {@"C", SDL_SCANCODE_C},
	         {@"V", SDL_SCANCODE_V},
	         {@"B", SDL_SCANCODE_B},
	         {@"N", SDL_SCANCODE_N},
	         {@"M", SDL_SCANCODE_M},
	         {@",", SDL_SCANCODE_COMMA},
	         {@".", SDL_SCANCODE_PERIOD},
	         {@"/", SDL_SCANCODE_SLASH},
	         {@"Shift", SDL_SCANCODE_RSHIFT},
	         {@"↑", SDL_SCANCODE_UP},
	         {@"Del", SDL_SCANCODE_DELETE}},

	        {{@"Ctrl", SDL_SCANCODE_LCTRL, 1.5f},
	         {@"Alt", SDL_SCANCODE_LALT, 1.5f},
	         {@"Space", SDL_SCANCODE_SPACE, 7.0f},
	         {@"Alt", SDL_SCANCODE_RALT},
	         {@"Ctrl", SDL_SCANCODE_RCTRL},
	         {@"←", SDL_SCANCODE_LEFT},
	         {@"↓", SDL_SCANCODE_DOWN},
	         {@"→", SDL_SCANCODE_RIGHT}},
	};
}

// 4 units wide; gaps keep the familiar shape without tall keys
std::vector<std::vector<KeyDef>> numpad_layout()
{
	return {
	        {{@"Num", SDL_SCANCODE_NUMLOCKCLEAR},
	         {@"/", SDL_SCANCODE_KP_DIVIDE},
	         {@"*", SDL_SCANCODE_KP_MULTIPLY},
	         {@"-", SDL_SCANCODE_KP_MINUS}},
	        {{@"7", SDL_SCANCODE_KP_7},
	         {@"8", SDL_SCANCODE_KP_8},
	         {@"9", SDL_SCANCODE_KP_9},
	         {@"+", SDL_SCANCODE_KP_PLUS}},
	        {{@"4", SDL_SCANCODE_KP_4},
	         {@"5", SDL_SCANCODE_KP_5},
	         {@"6", SDL_SCANCODE_KP_6},
	         {nil, SDL_SCANCODE_UNKNOWN}},
	        {{@"1", SDL_SCANCODE_KP_1},
	         {@"2", SDL_SCANCODE_KP_2},
	         {@"3", SDL_SCANCODE_KP_3},
	         {@"Enter", SDL_SCANCODE_KP_ENTER}},
	        {{@"0", SDL_SCANCODE_KP_0, 2.0f},
	         {@".", SDL_SCANCODE_KP_PERIOD},
	         {nil, SDL_SCANCODE_UNKNOWN}},
	};
}

// A game's keys, in rows of up to six, as even as they'll go
constexpr int MaxGameKeysPerRow = 6;

std::vector<std::vector<KeyDef>> game_keys_layout(const std::vector<GameKey>& keys)
{
	const auto count     = static_cast<int>(keys.size());
	const auto row_count = (count + MaxGameKeysPerRow - 1) / MaxGameKeysPerRow;
	const auto per_row   = (row_count == 0) ? 0 : (count + row_count - 1) / row_count;

	std::vector<std::vector<KeyDef>> rows = {};
	for (int i = 0; i < count; ++i) {
		if (i % per_row == 0) {
			rows.emplace_back();
		}
		const auto& key = keys[static_cast<size_t>(i)];
		rows.back().push_back({GameKeyLabel(key),
		                       static_cast<SDL_Scancode>(key.scancode),
		                       1.0f,
		                       key.caption.length > 0 ? key.caption : nil,
		                       key.modifiers});
	}
	return rows;
}

std::vector<SDL_Scancode> modifier_keys(const int modifiers)
{
	std::vector<SDL_Scancode> keys = {};
	if (modifiers & GameKeyCtrl) {
		keys.push_back(SDL_SCANCODE_LCTRL);
	}
	if (modifiers & GameKeyAlt) {
		keys.push_back(SDL_SCANCODE_LALT);
	}
	if (modifiers & GameKeyShift) {
		keys.push_back(SDL_SCANCODE_LSHIFT);
	}
	return keys;
}

constexpr float KeyboardUnits = 15.0f;
constexpr float NumpadUnits   = 4.0f;

} // namespace

// A key on the on-screen keyboard

@interface DBKeyButton : UIButton
@property(nonatomic) SDL_Scancode scancode;
@property(nonatomic) float widthUnits;
@property(nonatomic, copy) NSString* label;
@property(nonatomic, copy) NSString* caption;
@property(nonatomic) int modifiers;
@end

@implementation DBKeyButton
@end

// An on-screen key panel: the PC keyboard or the number pad. Modifiers are sticky: tap Shift, Ctrl or Alt to
// latch it, and it applies to the next key and then releases. Every key is
// its own control and multi-touch is on, so keys can be held together (an
// arrow key plus Ctrl, for instance).

@interface DBKeyboardView : UIView
- (void)refreshLockKeys;

// Lay each row out as a column instead (for a tall panel down one side)
@property(nonatomic) bool vertical;

// A panel the user can drag around. Its keys are sent when the finger
// lifts rather than when it lands, so a two-finger drag doesn't press
// anything (held keys don't auto-repeat), and it ignores the safe area,
// keeping its size wherever it's placed.
@property(nonatomic) bool movable;
@end

@implementation DBKeyboardView {
	std::vector<std::vector<DBKeyButton*>> _rows;
	float _row_units;
	std::vector<SDL_Scancode> _latched_modifiers;
	std::vector<SDL_Scancode> _applied_modifiers;
}

- (instancetype)initWithLayout:(const std::vector<std::vector<KeyDef>>&)layout
                      rowUnits:(float)row_units
{
	self = [super initWithFrame:CGRectZero];
	if (!self) {
		return self;
	}

	_row_units = row_units;

	self.multipleTouchEnabled = YES;
	self.layer.cornerRadius   = 8.0;
	self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];

	for (const auto& row_defs : layout) {
		std::vector<DBKeyButton*> row = {};

		for (const auto& def : row_defs) {
			auto button = [DBKeyButton buttonWithType:UIButtonTypeCustom];

			button.scancode   = def.scancode;
			button.widthUnits = def.width_units;
			button.modifiers  = def.modifiers;
			button.hidden     = (def.scancode == SDL_SCANCODE_UNKNOWN);
			button.exclusiveTouch       = NO;
			button.multipleTouchEnabled = YES;
			button.layer.cornerRadius   = 6.0;
			button.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.85];
			button.titleLabel.font = [UIFont systemFontOfSize:18.0
			                                           weight:UIFontWeightMedium];
			if (def.caption) {
				// The title is set in -layoutSubviews, where the
				// caption is sized to fit the key
				button.label   = def.label;
				button.caption = def.caption;
				button.titleLabel.numberOfLines = 0;
				button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
				button.titleLabel.textAlignment = NSTextAlignmentCenter;
			} else {
				[button setTitle:def.label forState:UIControlStateNormal];
			}
			[button setTitleColor:UIColor.whiteColor
			             forState:UIControlStateNormal];

			[button addTarget:self
			              action:@selector(touchDown:)
			    forControlEvents:UIControlEventTouchDown];
			[button addTarget:self
			              action:@selector(touchUp:)
			    forControlEvents:UIControlEventTouchUpInside];
			[button addTarget:self
			              action:@selector(touchAbandoned:)
			    forControlEvents:UIControlEventTouchUpOutside |
			                     UIControlEventTouchCancel];

			[self addSubview:button];
			row.push_back(button);
		}
		_rows.push_back(row);
	}
	return self;
}

- (void)layoutSubviews
{
	[super layoutSubviews];

	constexpr CGFloat Margin = 6.0;
	constexpr CGFloat Gap    = 5.0;

	const auto bounds = self.bounds;

	const auto safe = _movable ? UIEdgeInsetsZero : self.safeAreaInsets;

	const CGFloat left  = safe.left + Margin;

	const CGFloat width = bounds.size.width - safe.left - safe.right - 2 * Margin;
	const CGFloat unit  = width / _row_units;

	const CGFloat top    = Margin;
	const CGFloat height = bounds.size.height - safe.bottom - 2 * Margin;
	const CGFloat row_height = height / static_cast<CGFloat>(_rows.size());

	if (_vertical) {
		[self layoutColumnsLeft:left top:top width:width height:height gap:Gap];
		[self layoutCaptions];
		return;
	}

	CGFloat y = top;
	for (const auto& row : _rows) {
		CGFloat x = left;
		for (DBKeyButton* button : row) {
			const CGFloat key_width = unit * button.widthUnits;
			button.frame = CGRectMake(x + Gap / 2,
			                          y + Gap / 2,
			                          key_width - Gap,
			                          row_height - Gap);
			x += key_width;
		}
		y += row_height;
	}

	[self layoutCaptions];
}

// Sets the titles of the keys that have a caption: the key's letter, and
// below it what the key does, in the largest font size at which every
// caption fits its key (wrapping onto a second line if needed). One size
// for all of them keeps the panel even.
- (void)layoutCaptions
{
	constexpr CGFloat LabelSize      = 14.0;
	constexpr CGFloat MaxCaptionSize = 12.0;
	constexpr CGFloat MinCaptionSize = 7.0;
	constexpr CGFloat Padding        = 4.0;

	auto label_font = [UIFont systemFontOfSize:LabelSize weight:UIFontWeightMedium];

	std::vector<DBKeyButton*> captioned = {};
	for (const auto& row : _rows) {
		for (DBKeyButton* button : row) {
			if (button.caption && button.bounds.size.width > 0) {
				captioned.push_back(button);
			}
		}
	}
	if (captioned.empty()) {
		return;
	}

	auto fits = [&](UIFont* font) {
		NSDictionary* attributes = @{NSFontAttributeName: font};

		for (DBKeyButton* button : captioned) {
			const CGFloat width  = button.bounds.size.width - 2 * Padding;
			const CGFloat height = button.bounds.size.height - 2 * Padding -
			                       label_font.lineHeight;

			// Every word must fit on a line, or it would be broken
			// mid-word
			for (NSString* word in [button.caption componentsSeparatedByString:@" "]) {
				if ([word sizeWithAttributes:attributes].width > width) {
					return false;
				}
			}
			const auto rect = [button.caption
			        boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
			                     options:NSStringDrawingUsesLineFragmentOrigin
			                  attributes:attributes
			                     context:nil];
			if (rect.size.height > height) {
				return false;
			}
		}
		return true;
	};

	auto caption_font = [UIFont systemFontOfSize:MinCaptionSize
	                                      weight:UIFontWeightRegular];
	for (auto size = MaxCaptionSize; size > MinCaptionSize; size -= 0.5) {
		auto font = [UIFont systemFontOfSize:size weight:UIFontWeightRegular];
		if (fits(font)) {
			caption_font = font;
			break;
		}
	}

	for (DBKeyButton* button : captioned) {
		auto title = [[NSMutableAttributedString alloc]
		        initWithString:[button.label stringByAppendingString:@"\n"]
		            attributes:@{NSFontAttributeName: label_font,
		                         NSForegroundColorAttributeName: UIColor.whiteColor}];
		[title appendAttributedString:
		               [[NSAttributedString alloc]
		                       initWithString:button.caption
		                           attributes:@{NSFontAttributeName: caption_font,
		                                        NSForegroundColorAttributeName:
		                                                [UIColor colorWithWhite:1.0
		                                                                  alpha:0.8]}]];
		[button setAttributedTitle:title forState:UIControlStateNormal];
	}
}

// Each row becomes a column; keys are all one unit tall
- (void)layoutColumnsLeft:(CGFloat)left
                      top:(CGFloat)top
                    width:(CGFloat)width
                   height:(CGFloat)height
                      gap:(CGFloat)gap
{
	size_t keys_per_column = 0;
	for (const auto& row : _rows) {
		keys_per_column = std::max(keys_per_column, row.size());
	}
	if (keys_per_column == 0) {
		return;
	}

	const CGFloat column_width = width / static_cast<CGFloat>(_rows.size());
	const CGFloat key_height = height / static_cast<CGFloat>(keys_per_column);

	CGFloat x = left;
	for (const auto& row : _rows) {
		CGFloat y = top;
		for (DBKeyButton* button : row) {
			button.frame = CGRectMake(x + gap / 2,
			                          y + gap / 2,
			                          column_width - gap,
			                          key_height - gap);
			y += key_height;
		}
		x += column_width;
	}
}

- (void)setVertical:(bool)vertical
{
	if (_vertical != vertical) {
		_vertical = vertical;
		[self setNeedsLayout];
	}
}

- (void)touchDown:(DBKeyButton*)button
{
	if (_movable) {
		button.backgroundColor = [UIColor colorWithWhite:0.45 alpha:0.9];
	} else {
		[self keyDown:button];
	}
}

- (void)touchUp:(DBKeyButton*)button
{
	if (!_movable) {
		[self keyUp:button];
		return;
	}

	// Hold the key long enough for programs that poll the keyboard
	[self keyDown:button];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ClickDurationNs),
	               dispatch_get_main_queue(),
	               ^{
		               [self keyUp:button];
	               });
}

- (void)touchAbandoned:(DBKeyButton*)button
{
	if (_movable) {
		button.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.85];
	} else {
		[self keyUp:button];
	}
}

- (bool)isLatched:(SDL_Scancode)scancode
{
	return std::find(_latched_modifiers.begin(), _latched_modifiers.end(), scancode) !=
	       _latched_modifiers.end();
}

- (void)refreshLockKeys
{
	const auto numlock_on = is_numlock_on();

	for (const auto& row : _rows) {
		for (DBKeyButton* button : row) {
			if (button.scancode == SDL_SCANCODE_NUMLOCKCLEAR) {
				button.backgroundColor =
				        numlock_on ? [UIColor colorWithRed:0.2 green:0.45 blue:0.9 alpha:0.9]
				                   : [UIColor colorWithWhite:0.18 alpha:0.85];
			}
		}
	}
}

- (void)refreshModifierColours
{
	for (const auto& row : _rows) {
		for (DBKeyButton* button : row) {
			if (is_modifier(button.scancode)) {
				button.backgroundColor =
				        [self isLatched:button.scancode]
				                ? [UIColor colorWithRed:0.2 green:0.45 blue:0.9 alpha:0.9]
				                : [UIColor colorWithWhite:0.18 alpha:0.85];
			}
		}
	}
}

- (void)keyDown:(DBKeyButton*)button
{
	const auto scancode = button.scancode;

	if (is_modifier(scancode)) {
		if ([self isLatched:scancode]) {
			std::erase(_latched_modifiers, scancode);
		} else {
			_latched_modifiers.push_back(scancode);
		}
		[self refreshModifierColours];
		return;
	}

	button.backgroundColor = [UIColor colorWithWhite:0.45 alpha:0.9];

	for (const auto modifier : _latched_modifiers) {
		push_key(modifier, true);
		_applied_modifiers.push_back(modifier);
	}
	_latched_modifiers.clear();

	for (const auto modifier : modifier_keys(button.modifiers)) {
		push_key(modifier, true);
		_applied_modifiers.push_back(modifier);
	}

	push_key(scancode, true);
}

- (void)keyUp:(DBKeyButton*)button
{
	const auto scancode = button.scancode;

	if (is_modifier(scancode)) {
		return;
	}

	button.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.85];

	// Lock keys show their state rather than a plain released colour
	if (scancode == SDL_SCANCODE_NUMLOCKCLEAR) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200'000'000),
		               dispatch_get_main_queue(),
		               ^{
			               [self refreshLockKeys];
		               });
	}

	push_key(scancode, false);

	for (const auto modifier : _applied_modifiers) {
		push_key(modifier, false);
	}
	_applied_modifiers.clear();

	[self refreshModifierColours];
}

@end

// Covers the whole SDL view. Touches outside the key panels drive the mouse
// in one of two modes, switched with the pointer toggle:
//
// Direct touch (the default), for programs with absolute pointing, such as
// Windows 3.1 with the VBADOS mouse driver:
//
//   - tap to left-click where the finger is, tap with two fingers to
//     right-click there
//   - drag to drag with the left button held
//
// Trackpad, like a laptop's, for programs that only take relative movement:
//
//   - drag with one finger to move the pointer
//   - tap to left-click, tap with two fingers to right-click
//   - press and hold, then drag, to hold the left button down (dragging)

// The gamepad's stick. As arrow keys, it holds down one or two of them (the
// eight directions); as a joystick, it moves the emulated joystick as far as
// the finger is from the centre.

namespace {

enum Direction { Up = 1, Down = 2, Left = 4, Right = 8 };

constexpr std::array<std::pair<int, SDL_Scancode>, 4> DirectionKeys = {
        {{Up, SDL_SCANCODE_UP},
         {Down, SDL_SCANCODE_DOWN},
         {Left, SDL_SCANCODE_LEFT},
         {Right, SDL_SCANCODE_RIGHT}}
};

// How far out (as a fraction of the stick's radius) the finger has to be
// before the stick presses any key
constexpr double StickDeadZone = 0.3;

// The finger reaches the stick's full travel this far out
constexpr double StickReach = 0.8;

// The keys held for a stick position, which is within the unit circle
int stick_directions(const CGPoint position)
{
	if (std::hypot(position.x, position.y) < StickDeadZone) {
		return 0;
	}
	// Eight 45 degree sectors, counter-clockwise from the right
	constexpr std::array<int, 8> Sectors = {
	        Right, Up | Right, Up, Up | Left, Left, Down | Left, Down, Down | Right};

	const auto angle  = std::atan2(-position.y, position.x);
	const auto sector = static_cast<int>(std::lround(angle / (M_PI / 4)) + 8) % 8;
	return Sectors[sector];
}

int16_t joystick_axis(const CGFloat position)
{
	return static_cast<int16_t>(std::lround(position * 32767));
}

void send_gamepad_action(const int action, const bool down)
{
	if (action == JoystickButton1 || action == JoystickButton2) {
		JOYSTICK_Button(0, (action == JoystickButton1) ? 0 : 1, down);
	} else {
		push_key(static_cast<SDL_Scancode>(action), down);
	}
}

void draw_circle(const CGPoint centre, const CGFloat radius, UIColor* fill)
{
	auto circle = [UIBezierPath
	        bezierPathWithOvalInRect:CGRectMake(centre.x - radius,
	                                            centre.y - radius,
	                                            2 * radius,
	                                            2 * radius)];
	[fill setFill];
	[circle fill];
	[[UIColor colorWithWhite:1.0 alpha:0.35] setStroke];
	circle.lineWidth = 2.0;
	[circle stroke];
}

} // namespace

@interface DBGamepadStick : UIView
@property(nonatomic) bool joystick;
- (void)moveTo:(CGPoint)position;
- (void)recentre;
@end

@implementation DBGamepadStick {
	UITouch* __weak _touch;
	CGPoint _position;
	int _directions;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		self.backgroundColor = UIColor.clearColor;
		self.contentMode     = UIViewContentModeRedraw;
	}
	return self;
}

- (CGFloat)radius
{
	return self.bounds.size.width / 2;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event
{
	return std::hypot(point.x - self.radius, point.y - self.radius) < self.radius;
}

- (void)setJoystick:(bool)joystick
{
	[self recentre];
	_joystick = joystick;
	[self setNeedsDisplay];
}

- (void)moveTo:(CGPoint)position
{
	_position = position;

	if (_joystick) {
		JOYSTICK_Move_X(0, joystick_axis(position.x));
		JOYSTICK_Move_Y(0, joystick_axis(position.y));
	} else {
		const auto directions = stick_directions(position);
		for (const auto& [direction, key] : DirectionKeys) {
			if ((directions ^ _directions) & direction) {
				push_key(key, (directions & direction) != 0);
			}
		}
		_directions = directions;
	}
	[self setNeedsDisplay];
}

- (void)moveToTouch:(UITouch*)touch
{
	const auto point = [touch locationInView:self];
	const auto reach = self.radius * StickReach;

	auto position        = CGPointMake((point.x - self.radius) / reach,
                                    (point.y - self.radius) / reach);
	const auto distance = std::hypot(position.x, position.y);
	if (distance > 1.0) {
		position = CGPointMake(position.x / distance, position.y / distance);
	}
	[self moveTo:position];
}

- (void)recentre
{
	_touch = nil;
	[self moveTo:CGPointZero];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	if (!_touch) {
		_touch = touches.anyObject;
		[self moveToTouch:_touch];
	}
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	if ([touches containsObject:_touch]) {
		[self moveToTouch:_touch];
	}
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	if ([touches containsObject:_touch]) {
		[self recentre];
	}
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	[self touchesEnded:touches withEvent:event];
}

- (void)drawRect:(CGRect)rect
{
	const auto radius = self.radius - 1;
	const auto centre = CGPointMake(self.radius, self.radius);
	draw_circle(centre, radius, [UIColor colorWithWhite:0.0 alpha:0.3]);

	if (_joystick) {
		const auto knob_radius = radius * 0.42;
		const auto travel      = radius - knob_radius;
		const auto knob = CGPointMake(centre.x + _position.x * travel,
		                              centre.y + _position.y * travel);
		draw_circle(knob, knob_radius, [UIColor colorWithWhite:1.0 alpha:_touch ? 0.5 : 0.3]);
		return;
	}

	// An arrow for each direction, lit while its key is held
	const std::array<std::pair<int, CGFloat>, 4> arrows = {
	        {{Right, 0}, {Down, M_PI / 2}, {Left, M_PI}, {Up, 3 * M_PI / 2}}
	};
	for (const auto& [direction, angle] : arrows) {
		const auto tip  = radius * 0.85;
		const auto base = radius * 0.55;
		const auto half = radius * 0.2;

		auto arrow = [UIBezierPath bezierPath];
		[arrow moveToPoint:CGPointMake(tip, 0)];
		[arrow addLineToPoint:CGPointMake(base, -half)];
		[arrow addLineToPoint:CGPointMake(base, half)];
		[arrow closePath];
		[arrow applyTransform:CGAffineTransformMakeRotation(angle)];
		[arrow applyTransform:CGAffineTransformMakeTranslation(centre.x, centre.y)];

		const auto is_held = (_directions & direction) != 0;
		[[UIColor colorWithWhite:1.0 alpha:is_held ? 0.9 : 0.4] setFill];
		[arrow fill];
	}
}

@end

// The gamepad's four buttons, in a diamond. A finger can slide from one
// button to the next, and several can be held at once.

@interface DBGamepadButtons : UIView
- (void)setActions:(const std::array<int, GamepadButtonCount>&)actions;
- (void)releaseAll;
@end

@implementation DBGamepadButtons {
	std::array<int, GamepadButtonCount> _actions;
	std::array<bool, GamepadButtonCount> _pressed;

	// The button each finger is on
	NSMapTable<UITouch*, NSNumber*>* _touch_buttons;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		self.backgroundColor      = UIColor.clearColor;
		self.contentMode          = UIViewContentModeRedraw;
		self.multipleTouchEnabled = YES;
		_actions                  = {};
		_pressed                  = {};
		_touch_buttons            = [NSMapTable strongToStrongObjectsMapTable];
	}
	return self;
}

- (void)setActions:(const std::array<int, GamepadButtonCount>&)actions
{
	[self releaseAll];
	_actions = actions;
	[self setNeedsDisplay];
}

- (CGFloat)buttonRadius
{
	return self.bounds.size.width * 0.19;
}

// Bottom, right, left, top
- (CGPoint)centreOfButton:(int)button
{
	const auto size   = self.bounds.size.width;
	const auto near   = self.buttonRadius + 1;
	const auto far    = size - near;
	const auto middle = size / 2;

	const std::array<CGPoint, GamepadButtonCount> centres = {
	        CGPointMake(middle, far),
	        CGPointMake(far, middle),
	        CGPointMake(near, middle),
	        CGPointMake(middle, near)};
	return centres[button];
}

// The nearest button within reach of a point, if any
- (std::optional<int>)buttonAt:(CGPoint)point
{
	std::optional<int> nearest = {};
	auto nearest_distance      = self.buttonRadius * 1.25;
	for (int button = 0; button < GamepadButtonCount; ++button) {
		const auto centre   = [self centreOfButton:button];
		const auto distance = std::hypot(point.x - centre.x, point.y - centre.y);
		if (distance < nearest_distance) {
			nearest          = button;
			nearest_distance = distance;
		}
	}
	return nearest;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event
{
	return [self buttonAt:point].has_value();
}

// Presses and releases buttons to match the fingers on them
- (void)update
{
	std::array<bool, GamepadButtonCount> pressed = {};
	for (UITouch* touch in _touch_buttons) {
		pressed[[_touch_buttons objectForKey:touch].intValue] = true;
	}
	for (int button = 0; button < GamepadButtonCount; ++button) {
		if (pressed[button] != _pressed[button]) {
			send_gamepad_action(_actions[button], pressed[button]);
		}
	}
	_pressed = pressed;
	[self setNeedsDisplay];
}

- (void)releaseAll
{
	[_touch_buttons removeAllObjects];
	[self update];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	[self touchesMoved:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	for (UITouch* touch in touches) {
		if (const auto button = [self buttonAt:[touch locationInView:self]]) {
			[_touch_buttons setObject:@(*button) forKey:touch];
		} else {
			[_touch_buttons removeObjectForKey:touch];
		}
	}
	[self update];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	for (UITouch* touch in touches) {
		[_touch_buttons removeObjectForKey:touch];
	}
	[self update];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
	[self touchesEnded:touches withEvent:event];
}

- (void)drawRect:(CGRect)rect
{
	const auto radius = self.buttonRadius;
	for (int button = 0; button < GamepadButtonCount; ++button) {
		const auto centre = [self centreOfButton:button];
		draw_circle(centre,
		            radius,
		            _pressed[button] ? [UIColor colorWithWhite:1.0 alpha:0.5]
		                             : [UIColor colorWithWhite:0.0 alpha:0.3]);

		NSString* const label = GamepadButtonLabel(_actions[button]);
		NSDictionary* const attributes = @{
			NSFontAttributeName: [UIFont systemFontOfSize:std::min(radius * 0.5, 18.0)
			                                       weight:UIFontWeightSemibold],
			NSForegroundColorAttributeName: UIColor.whiteColor,
		};
		const auto size = [label sizeWithAttributes:attributes];
		[label drawAtPoint:CGPointMake(centre.x - size.width / 2, centre.y - size.height / 2)
		    withAttributes:attributes];
	}
}

@end

@interface DBTouchOverlay : UIView <UIGestureRecognizerDelegate>
- (void)shutDown;
@end

@implementation DBTouchOverlay {
	DBKeyboardView* _keyboard;
	DBKeyboardView* _numpad;
	DBKeyboardView* _gameKeys; // nil if the game has no keys of its own
	int _game_key_rows;
	int _game_key_columns;
	DBGamepadStick* _stick;
	DBGamepadButtons* _gamepadButtons;
	UIButton* _keyboardToggle;
	UIButton* _gamepadToggle;
	UIButton* _numpadToggle;
	UIButton* _gameKeysToggle;
	UIButton* _pointerToggle;
	UIButton* _menuButton;
	NSTimer* _lock_keys_timer;
	UILongPressGestureRecognizer* _hold;
	CGPoint _last_drag_point;
	bool _direct_touch;
	bool _shows_gamepad;
	bool _enabled_joystick;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (!self) {
		return self;
	}

	self.multipleTouchEnabled = YES;
	self.backgroundColor      = UIColor.clearColor;

	auto pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
	                                                   action:@selector(onPan:)];
	pan.maximumNumberOfTouches = 1;
	pan.delegate               = self;
	[self addGestureRecognizer:pan];

	auto tap = [[UITapGestureRecognizer alloc] initWithTarget:self
	                                                   action:@selector(onTap:)];
	tap.delegate = self;
	[self addGestureRecognizer:tap];

	auto two_finger_tap = [[UITapGestureRecognizer alloc]
	        initWithTarget:self
	                action:@selector(onTwoFingerTap:)];
	two_finger_tap.numberOfTouchesRequired = 2;
	two_finger_tap.delegate                = self;
	[self addGestureRecognizer:two_finger_tap];

	auto hold = [[UILongPressGestureRecognizer alloc]
	        initWithTarget:self
	                action:@selector(onHold:)];
	hold.minimumPressDuration = 0.35;
	hold.delegate             = self;
	[self addGestureRecognizer:hold];
	_hold = hold;

	_keyboard = [[DBKeyboardView alloc] initWithLayout:keyboard_layout()
	                                          rowUnits:KeyboardUnits];
	_keyboard.hidden = YES;
	[self addSubview:_keyboard];

	_numpad = [[DBKeyboardView alloc] initWithLayout:numpad_layout()
	                                        rowUnits:NumpadUnits];
	_numpad.hidden  = YES;
	_numpad.movable = true;
	[self addSubview:_numpad];
	[self makeMovable:_numpad];

	_stick          = [[DBGamepadStick alloc] initWithFrame:CGRectZero];
	_gamepadButtons = [[DBGamepadButtons alloc] initWithFrame:CGRectZero];
	[self addSubview:_stick];
	[self addSubview:_gamepadButtons];

	// Keep the Num key's light in step with the emulated NumLock state,
	// which the guest can also change
	__weak DBTouchOverlay* weak_self = self;
	_lock_keys_timer = [NSTimer
	        scheduledTimerWithTimeInterval:0.5
	                               repeats:YES
	                                 block:^(NSTimer*) {
		                                 auto strong_self = weak_self;
		                                 if (strong_self &&
		                                     !strong_self->_numpad.hidden) {
			                                 [strong_self->_numpad refreshLockKeys];
		                                 }
	                                 }];

	_keyboardToggle = [self makeToggle:nil action:@selector(toggleKeyboard)];
	_numpadToggle   = [self makeToggle:@"123" action:@selector(toggleNumpad)];
	_gameKeysToggle = [self makeToggle:@"Game" action:@selector(toggleGameKeys)];
	_gamepadToggle  = [self makeToggle:nil action:@selector(toggleGamepad)];
	_pointerToggle  = [self makeToggle:nil action:@selector(togglePointerMode)];
	_menuButton     = [self makeToggle:nil action:nil];
	_menuButton.menu = [self makeMenu];
	_menuButton.showsMenuAsPrimaryAction = YES;

	[self refreshGameSettings];

	// Test hook: start with the Game keys showing
	if (std::getenv("DOSPAD_SHOW_GAME_KEYS")) {
		_gameKeys.hidden = NO;
	}

	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(refreshGameSettings)
	                                           name:GameSettingsChangedNotification
	                                         object:nil];

	auto symbol_config = [UIImageSymbolConfiguration
	        configurationWithPointSize:22.0
	                            weight:UIImageSymbolWeightSemibold];
	[_keyboardToggle setImage:[UIImage systemImageNamed:@"keyboard"
	                                    withConfiguration:symbol_config]
	                 forState:UIControlStateNormal];
	[_menuButton setImage:[UIImage systemImageNamed:@"line.3.horizontal"
	                                   withConfiguration:symbol_config]
	                forState:UIControlStateNormal];
	[_gamepadToggle setImage:[UIImage systemImageNamed:@"gamecontroller"
	                                   withConfiguration:symbol_config]
	                forState:UIControlStateNormal];

	// Test hook: after 8 seconds, hold the stick up and right and the
	// bottom button for 4 seconds
	if (std::getenv("DOSPAD_GAMEPAD_TEST")) {
		const auto after = [](const int64_t seconds, void (^block)()) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC),
			               dispatch_get_main_queue(),
			               block);
		};
		DBGamepadStick* const stick = _stick;
		after(8, ^{
			[stick moveTo:CGPointMake(0.7, -0.7)];
			send_gamepad_action(GetGamepadButton(CurrentGameName(), 0), true);
		});
		after(12, ^{
			[stick recentre];
			send_gamepad_action(GetGamepadButton(CurrentGameName(), 0), false);
		});
	}

	return self;
}

- (UIButton*)makeToggle:(NSString*)title action:(SEL)action
{
	auto toggle = [UIButton buttonWithType:UIButtonTypeCustom];
	[toggle setTitle:title forState:UIControlStateNormal];
	toggle.titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
	toggle.tintColor       = UIColor.whiteColor;
	toggle.backgroundColor = [UIColor colorWithWhite:0.3 alpha:0.5];
	toggle.layer.cornerRadius = 10.0;
	if (action) {
		[toggle addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	}
	[self addSubview:toggle];
	return toggle;
}

- (void)layoutSubviews
{
	[super layoutSubviews];

	const auto bounds = self.bounds;
	const auto safe   = self.safeAreaInsets;

	// Keep the keys a usable size on phones, where the screen is short
	const CGFloat keyboard_height = std::clamp(bounds.size.height * 0.32,
	                                           std::min(220.0, bounds.size.height * 0.55),
	                                           bounds.size.height * 0.55);

	constexpr CGFloat ToggleWidth  = 66.0;
	constexpr CGFloat ToggleHeight = 44.0;
	constexpr CGFloat ToggleGap    = 10.0;

	// The number pad sits in the bottom-right corner, above the keyboard
	// when both are showing. On a phone there's no room above it, so the
	// keyboard narrows and the number pad sits beside it instead.
	const CGFloat numpad_width  = std::min(bounds.size.width * 0.18, 240.0);
	const CGFloat numpad_height = numpad_width * 1.15;

	const CGFloat keyboard_top     = bounds.size.height - keyboard_height;
	const CGFloat toggles_bottom   = safe.top + 12 + ToggleHeight;
	const bool numpad_beside_keyboard = !_keyboard.hidden && !_numpad.hidden &&
	                                    (keyboard_top - 8 - numpad_height <
	                                     toggles_bottom + 8);

	const CGFloat keyboard_width = numpad_beside_keyboard
	                                     ? bounds.size.width - safe.right -
	                                               numpad_width - 12
	                                     : bounds.size.width;

	_keyboard.frame = CGRectMake(0, keyboard_top, keyboard_width, keyboard_height);

	const CGFloat numpad_bottom = (_keyboard.hidden || numpad_beside_keyboard)
	                                    ? bounds.size.height - safe.bottom - 12
	                                    : keyboard_top - 8;
	const CGFloat numpad_shown_height =
	        numpad_beside_keyboard
	                ? std::min(numpad_height, numpad_bottom - keyboard_top - 6)
	                : numpad_height;

	_numpad.frame = CGRectMake(bounds.size.width - safe.right - numpad_width - 12,
	                           numpad_bottom - numpad_shown_height,
	                           numpad_width,
	                           numpad_shown_height);

	const CGFloat panels_bottom = _keyboard.hidden ? numpad_bottom
	                                               : keyboard_top - 8;

	// The game keys sit in the bottom-left corner, likewise above the
	// keyboard. On a wide screen with the keyboard closed they make a column
	// down the left side instead.
	const bool wide_screen = bounds.size.width >=
	                         bounds.size.height * WideScreenAspect;
	_gameKeys.vertical = wide_screen && _keyboard.hidden;

	// Each row of keys becomes a column
	if (_gameKeys.vertical) {
		const CGFloat column_width = 68.0;
		const CGFloat game_keys_width = _game_key_rows * column_width + 12;
		const CGFloat game_keys_height = std::min(
		        _game_key_columns * 50.0 + 12, panels_bottom - toggles_bottom - 8);

		_gameKeys.frame = CGRectMake(safe.left + 12,
		                             panels_bottom - game_keys_height,
		                             game_keys_width,
		                             game_keys_height);
	} else {
		// Six keys fill this width
		const CGFloat full_width = std::min(bounds.size.width * 0.42, 540.0);
		const CGFloat row_height = std::min(full_width * 0.13, 70.0);

		const CGFloat game_keys_width = full_width * _game_key_columns / MaxGameKeysPerRow;
		const CGFloat game_keys_height = std::min(_game_key_rows * row_height,
		                                          panels_bottom - toggles_bottom - 8);

		_gameKeys.frame = CGRectMake(safe.left + 12,
		                             panels_bottom - game_keys_height,
		                             game_keys_width,
		                             game_keys_height);
	}

	// Panels the user has dragged elsewhere go back where they were left,
	// except while the keyboard is open, which needs the default spots
	if (_keyboard.hidden) {
		[self restorePosition:_numpad];
		[self restorePosition:_gameKeys];
	}

	// The gamepad's stick and buttons sit in the bottom corners. The
	// keyboard covers them, so they're hidden while it's open.
	const auto gamepad_visible = _shows_gamepad && _keyboard.hidden;
	if (!gamepad_visible && !_stick.hidden) {
		[_stick recentre];
		[_gamepadButtons releaseAll];
	}
	_stick.hidden          = !gamepad_visible;
	_gamepadButtons.hidden = !gamepad_visible;

	const CGFloat gamepad_size = std::min(bounds.size.height * 0.4, 190.0);
	const CGFloat gamepad_top  = bounds.size.height - safe.bottom - 20 - gamepad_size;
	_stick.frame = CGRectMake(safe.left + 20, gamepad_top, gamepad_size, gamepad_size);
	_gamepadButtons.frame = CGRectMake(bounds.size.width - safe.right - 20 - gamepad_size,
	                                   gamepad_top,
	                                   gamepad_size,
	                                   gamepad_size);

	// The toggles, from the right
	CGFloat toggle_left = bounds.size.width - safe.right - 12;
	for (UIButton* toggle in @[_keyboardToggle,
	                           _numpadToggle,
	                           _gameKeysToggle,
	                           _gamepadToggle,
	                           _pointerToggle]) {
		if (!toggle.hidden) {
			toggle_left -= ToggleWidth;
			toggle.frame = CGRectMake(toggle_left, safe.top + 12, ToggleWidth, ToggleHeight);
			toggle_left -= ToggleGap;
		}
	}

	// The menu (settings, restart, back to the library), away from the
	// other toggles in the top-left corner
	_menuButton.frame = CGRectMake(safe.left + 12,
	                                  safe.top + 12,
	                                  ToggleWidth,
	                                  ToggleHeight);
}

// The in-game menu. It's rebuilt each time it opens, so Pause shows the
// current state.
- (UIMenu*)makeMenu
{
	__weak DBTouchOverlay* weak_self = self;
	auto items = [UIDeferredMenuElement
	        elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement*>*)) {
		        completion([weak_self menuItems]);
	        }];
	return [UIMenu menuWithChildren:@[items]];
}

- (NSArray<UIMenuElement*>*)menuItems
{
	__weak DBTouchOverlay* weak_self = self;

	auto settings = [UIAction actionWithTitle:@"Game Settings"
	                                    image:[UIImage systemImageNamed:@"gearshape"]
	                               identifier:nil
	                                  handler:^(UIAction*) {
		                                  [weak_self showGameSettings];
	                                  }];
	settings.attributes = CurrentGameName() ? 0 : UIMenuElementAttributesDisabled;

	const auto is_paused = DOSBOX_IsPaused();
	auto pause = [UIAction actionWithTitle:is_paused ? @"Resume" : @"Pause"
	                                 image:[UIImage systemImageNamed:is_paused ? @"play" : @"pause"]
	                            identifier:nil
	                               handler:^(UIAction*) {
		                               if (DOSBOX_IsPaused()) {
			                               DOSBOX_RequestUserResume();
		                               } else {
			                               DOSBOX_RequestUserPause();
		                               }
	                               }];

	auto restart = [UIAction actionWithTitle:@"Restart Game"
	                                   image:[UIImage systemImageNamed:@"arrow.counterclockwise"]
	                              identifier:nil
	                                 handler:^(UIAction*) {
		                                 [weak_self confirm:@"Restart the game?"
		                                             action:@"Restart"
		                                            handler:^{
			                                            IOS_RestartGame();
		                                            }];
	                                 }];
	restart.attributes = CurrentGameName() ? 0 : UIMenuElementAttributesDisabled;

	auto quit = [UIAction actionWithTitle:@"Quit to Library"
	                                image:[UIImage systemImageNamed:@"square.grid.2x2"]
	                           identifier:nil
	                              handler:^(UIAction*) {
		                              [weak_self confirm:@"Quit to the library?"
		                                          action:@"Quit"
		                                         handler:^{
			                                         DOSBOX_RequestShutdown();
		                                         }];
	                              }];
	quit.attributes = UIMenuElementAttributesDestructive;

	return @[settings, pause, restart, quit];
}

- (void)confirm:(NSString*)title action:(NSString*)action_title handler:(void (^)())handler
{
	auto alert = [UIAlertController
	        alertControllerWithTitle:title
	                         message:@"Anything not saved in the game will be lost."
	                  preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
	                                          style:UIAlertActionStyleCancel
	                                        handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:action_title
	                                          style:UIAlertActionStyleDestructive
	                                        handler:^(UIAlertAction*) {
		                                        handler();
	                                        }]];
	[self.window.rootViewController presentViewController:alert
	                                             animated:YES
	                                           completion:nil];
}

- (void)showGameSettings
{
	auto settings = MakeGameSettingsController(CurrentGameName(), CurrentGameConfPath(), nil, nil);
	auto navigation = [[UINavigationController alloc] initWithRootViewController:settings];
	navigation.modalPresentationStyle = UIModalPresentationFormSheet;
	// On an iPad, wide enough for the settings' two columns
	if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
		const auto screen = self.window.bounds.size;
		navigation.preferredContentSize = CGSizeMake(std::min(screen.width - 80, 960.0),
		                                             std::min(screen.height - 80, 800.0));
	}
	[self.window.rootViewController presentViewController:navigation
	                                             animated:YES
	                                           completion:nil];
}

// Mouse mode and game keys are chosen per game
- (void)refreshGameSettings
{
	NSString* const game = CurrentGameName();

	_direct_touch = IsDirectTouch(game);
	[self refreshPointerToggle];

	[self rebuildGameKeys:GetGameKeys(game)];

	// Outside a game there's nowhere to keep it, so it stays as it was
	if (game) {
		_shows_gamepad = IsGamepadShown(game);
	}
	_stick.joystick = (GetGamepadStick(game) == GamepadStick::Joystick);

	std::array<int, GamepadButtonCount> actions = {};
	for (int button = 0; button < GamepadButtonCount; ++button) {
		actions[button] = GetGamepadButton(game, button);
	}
	[_gamepadButtons setActions:actions];

	// DOS sees a joystick only when the gamepad acts as one
	const auto uses_joystick = _stick.joystick ||
	                           std::any_of(actions.begin(), actions.end(), [](const int action) {
		                           return action == JoystickButton1 ||
		                                  action == JoystickButton2;
	                           });
	if (uses_joystick) {
		JOYSTICK_Enable(0, true);
	} else {
		[self disableJoystick];
	}
	_enabled_joystick = uses_joystick;

	[self setNeedsLayout];
}

// Replaces the Game panel with one holding these keys, keeping it shown or
// hidden as it was
- (void)rebuildGameKeys:(const std::vector<GameKey>&)keys
{
	const auto was_hidden = !_gameKeys || _gameKeys.hidden;
	[_gameKeys removeFromSuperview];
	_gameKeys = nil;

	_gameKeysToggle.hidden = keys.empty();
	if (keys.empty()) {
		return;
	}

	const auto layout = game_keys_layout(keys);
	_game_key_rows    = static_cast<int>(layout.size());
	_game_key_columns = static_cast<int>(layout.front().size());

	_gameKeys = [[DBKeyboardView alloc] initWithLayout:layout
	                                          rowUnits:static_cast<float>(_game_key_columns)];
	_gameKeys.hidden  = was_hidden;
	_gameKeys.movable = true;
	[self insertSubview:_gameKeys belowSubview:_stick];
	[self makeMovable:_gameKeys];
}

// Turns off the emulated joystick if the gamepad turned it on, unless a
// real controller is using it
- (void)disableJoystick
{
	if (_enabled_joystick && joytype == JOY_NONE_FOUND) {
		JOYSTICK_Enable(0, false);
	}
	_enabled_joystick = false;
}

// Stops the timer, which reads the emulated BIOS data area, before the
// emulator shuts down
- (void)shutDown
{
	[_stick recentre];
	[_gamepadButtons releaseAll];
	[self disableJoystick];

	[_lock_keys_timer invalidate];
	_lock_keys_timer = nil;
	[NSNotificationCenter.defaultCenter removeObserver:self];
	[self removeFromSuperview];
}

// Panels can be dragged around with two fingers
- (void)makeMovable:(UIView*)panel
{
	auto drag = [[UIPanGestureRecognizer alloc] initWithTarget:self
	                                                    action:@selector(onPanelDrag:)];
	drag.minimumNumberOfTouches = 2;
	drag.maximumNumberOfTouches = 2;
	[panel addGestureRecognizer:drag];
}

// Where a panel was left is saved separately for each of its layouts, as
// a fraction of the screen so it survives a change of screen size
- (NSString*)positionDefaultsKey:(UIView*)panel
{
	if (panel == _numpad) {
		return @"PanelPosition.Numpad";
	}
	return _gameKeys.vertical ? @"PanelPosition.GameKeys.Vertical"
	                          : @"PanelPosition.GameKeys.Horizontal";
}

// Keeps the whole panel on screen
- (CGPoint)clampedCenter:(CGPoint)center forPanel:(UIView*)panel
{
	const auto bounds = self.bounds;
	const auto size   = panel.bounds.size;

	center.x = std::clamp(center.x, size.width / 2, bounds.size.width - size.width / 2);
	center.y = std::clamp(center.y, size.height / 2, bounds.size.height - size.height / 2);
	return center;
}

- (void)restorePosition:(UIView*)panel
{
	NSArray* saved = [NSUserDefaults.standardUserDefaults
	        arrayForKey:[self positionDefaultsKey:panel]];
	if (saved.count != 2) {
		return;
	}

	const auto bounds = self.bounds;
	const CGPoint center = CGPointMake([saved[0] doubleValue] * bounds.size.width,
	                                   [saved[1] doubleValue] * bounds.size.height);
	panel.center = [self clampedCenter:center forPanel:panel];
}

- (void)onPanelDrag:(UIPanGestureRecognizer*)drag
{
	UIView* panel = drag.view;

	const auto translation = [drag translationInView:self];
	[drag setTranslation:CGPointZero inView:self];

	panel.center = [self clampedCenter:CGPointMake(panel.center.x + translation.x,
	                                               panel.center.y + translation.y)
	                          forPanel:panel];

	// Only remember positions chosen with the keyboard closed, the layout
	// they're restored in
	if (drag.state == UIGestureRecognizerStateEnded && _keyboard.hidden) {
		const auto bounds = self.bounds;
		[NSUserDefaults.standardUserDefaults
		        setObject:@[@(panel.center.x / bounds.size.width),
		                    @(panel.center.y / bounds.size.height)]
		           forKey:[self positionDefaultsKey:panel]];
	}
}

- (void)togglePointerMode
{
	_direct_touch = !_direct_touch;
	[self refreshPointerToggle];
	if (CurrentGameName()) {
		SetDirectTouch(CurrentGameName(), _direct_touch);
	}
}

// The toggle shows the current mode: a tapping hand for direct touch, a
// trackpad for trackpad mode
- (void)refreshPointerToggle
{
	// In direct touch a plain drag already drags, so press-and-hold is off
	_hold.enabled = !_direct_touch;

	auto symbol_config = [UIImageSymbolConfiguration
	        configurationWithPointSize:22.0
	                            weight:UIImageSymbolWeightSemibold];
	auto symbol = _direct_touch ? @"hand.tap" : @"rectangle.and.hand.point.up.left";
	[_pointerToggle setImage:[UIImage systemImageNamed:symbol
	                                   withConfiguration:symbol_config]
	                forState:UIControlStateNormal];
}

- (void)toggleKeyboard
{
	_keyboard.hidden = !_keyboard.hidden;
	[self setNeedsLayout];
}

- (void)toggleGamepad
{
	_shows_gamepad = !_shows_gamepad;
	if (CurrentGameName()) {
		SetGamepadShown(CurrentGameName(), _shows_gamepad);
	}
	[self setNeedsLayout];
}

- (void)toggleGameKeys
{
	_gameKeys.hidden = !_gameKeys.hidden;
	[self setNeedsLayout];
}

- (void)toggleNumpad
{
	_numpad.hidden = !_numpad.hidden;

	// The pad is for typing numbers, so switch NumLock on when it opens
	if (!_numpad.hidden && !is_numlock_on()) {
		tap_key(SDL_SCANCODE_NUMLOCKCLEAR);
	}
	[_numpad refreshLockKeys];
	[self setNeedsLayout];
}

// The trackpad gestures ignore touches that land on the key panels, the
// gamepad or the toggle buttons
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer
       shouldReceiveTouch:(UITouch*)touch
{
	return !([touch.view isDescendantOfView:_keyboard] ||
	         [touch.view isDescendantOfView:_numpad] ||
	         [touch.view isDescendantOfView:_gameKeys] ||
	         [touch.view isDescendantOfView:_stick] ||
	         [touch.view isDescendantOfView:_gamepadButtons] ||
	         [touch.view isDescendantOfView:_gamepadToggle] ||
	         [touch.view isDescendantOfView:_keyboardToggle] ||
	         [touch.view isDescendantOfView:_numpadToggle] ||
	         [touch.view isDescendantOfView:_gameKeysToggle] ||
	         [touch.view isDescendantOfView:_pointerToggle] ||
	         [touch.view isDescendantOfView:_menuButton]);
}

- (void)onPan:(UIPanGestureRecognizer*)pan
{
	if (_direct_touch) {
		[self onDirectDrag:pan];
		return;
	}

	const auto translation = [pan translationInView:self];
	[pan setTranslation:CGPointZero inView:self];

	push_motion(static_cast<float>(translation.x) * TrackpadSpeed,
	            static_cast<float>(translation.y) * TrackpadSpeed);
}

// The gesture recognizers above see every touch first. Don't pass touches
// on up the responder chain: SDL's view would turn them into mouse events of
// its own at the finger's position, which in seamless mode jump the pointer
// and add stray presses and drags.
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
}

// Direct touch: press where the finger first landed, follow it, and
// release where it lifts
- (void)onDirectDrag:(UIPanGestureRecognizer*)pan
{
	const auto point = [pan locationInView:self];

	switch (pan.state) {
	case UIGestureRecognizerStateBegan: {
		// The pan only begins once the finger has moved a little, so
		// start the drag from where it first touched
		const auto translation = [pan translationInView:self];
		push_motion_to(CGPointMake(point.x - translation.x,
		                           point.y - translation.y));
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MoveSettleNs),
		               dispatch_get_main_queue(),
		               ^{
			               push_button(SDL_BUTTON_LEFT, true);
			               push_motion_to(point);
		               });
	} break;

	case UIGestureRecognizerStateChanged: push_motion_to(point); break;

	case UIGestureRecognizerStateEnded:
	case UIGestureRecognizerStateCancelled:
	case UIGestureRecognizerStateFailed:
		// After the delayed press above, so a quick flick still
		// releases the button
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MoveSettleNs),
		               dispatch_get_main_queue(),
		               ^{
			               push_motion_to(point);
			               push_button(SDL_BUTTON_LEFT, false);
		               });
		break;

	default: break;
	}
}

- (void)onTap:(UITapGestureRecognizer*)tap
{
	if (_direct_touch) {
		click_at([tap locationInView:self], SDL_BUTTON_LEFT);
	} else {
		click(SDL_BUTTON_LEFT);
	}
}

- (void)onTwoFingerTap:(UITapGestureRecognizer*)tap
{
	if (_direct_touch) {
		click_at([tap locationInView:self], SDL_BUTTON_RIGHT);
	} else {
		click(SDL_BUTTON_RIGHT);
	}
}

- (void)onHold:(UILongPressGestureRecognizer*)hold
{
	const auto point = [hold locationInView:self];

	switch (hold.state) {
	case UIGestureRecognizerStateBegan:
		_last_drag_point = point;
		push_button(SDL_BUTTON_LEFT, true);
		break;

	case UIGestureRecognizerStateChanged:
		push_motion(static_cast<float>(point.x - _last_drag_point.x) * TrackpadSpeed,
		            static_cast<float>(point.y - _last_drag_point.y) * TrackpadSpeed);
		_last_drag_point = point;
		break;

	case UIGestureRecognizerStateEnded:
	case UIGestureRecognizerStateCancelled:
	case UIGestureRecognizerStateFailed:
		push_button(SDL_BUTTON_LEFT, false);
		break;

	default: break;
	}
}

@end

static DBTouchOverlay* overlay = nil;

bool IOS_KeyboardAttached()
{
	return GCKeyboard.coalescedKeyboard != nil || std::getenv("DOSPAD_KEYBOARD");
}

// The mapper file the game's config asks for, if any (the Keyboard setting)
static NSString* conf_mapperfile()
{
	NSString* const conf = CurrentGameConfPath();
	return (conf ? ReadConfValue(conf, @"sdl", @"mapperfile") : nil)
	        ?: ReadConfValue(@"dosbox.conf", @"sdl", @"mapperfile");
}

// The Keyboard setting is for an attached keyboard; it would turn the
// on-screen keyboard's letters into numpad keys too, so the mapping follows
// the keyboard: on while one is attached, off otherwise. The library sets
// the starting state (IOS_ChooseGame); this handles a keyboard arriving or
// leaving during a game, the way 'config -set' changes a setting
static void follow_keyboard(const bool attached)
{
	NSString* const wanted = conf_mapperfile();
	if (!overlay || !wanted || !control) {
		return;
	}
	auto section = static_cast<SectionProp*>(control->GetSection("sdl"));
	auto property = section ? section->GetProperty("mapperfile") : nullptr;
	if (!property) {
		return;
	}
	const std::string value = attached ? wanted.UTF8String : "";
	LOG_MSG("DOSPAD: Keyboard %s, mapper file '%s'",
	        attached ? "attached" : "detached",
	        value.c_str());
	property->SetValue(value);
	section->ExecuteUpdate(*property);
}

static void watch_keyboard()
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		auto center = NSNotificationCenter.defaultCenter;
		[center addObserverForName:GCKeyboardDidConnectNotification
		                    object:nil
		                     queue:NSOperationQueue.mainQueue
		                usingBlock:^(NSNotification*) {
			                follow_keyboard(true);
		                }];
		[center addObserverForName:GCKeyboardDidDisconnectNotification
		                    object:nil
		                     queue:NSOperationQueue.mainQueue
		                usingBlock:^(NSNotification*) {
			                follow_keyboard(IOS_KeyboardAttached());
		                }];
	});
}

void IOS_RemoveTouchOverlay()
{
	[overlay shutDown];
	overlay = nil;
	UIApplication.sharedApplication.idleTimerDisabled = NO;
}

void IOS_InstallTouchOverlay(SDL_Window* window)
{
	sdl_window = window;
	watch_keyboard();
	LOG_MSG("DOSPAD: Keyboard %s at start", IOS_KeyboardAttached() ? "attached" : "not attached");

	// A game being watched rather than touched mustn't lock the screen
	UIApplication.sharedApplication.idleTimerDisabled = YES;

	const auto properties = SDL_GetWindowProperties(window);
	auto ui_window = (__bridge UIWindow*)SDL_GetPointerProperty(
	        properties, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);

	UIView* root_view = ui_window.rootViewController.view;
	if (!root_view) {
		return;
	}

	if (!overlay || overlay.superview != root_view) {
		[overlay removeFromSuperview];

		overlay = [[DBTouchOverlay alloc] initWithFrame:root_view.bounds];
		overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
		                           UIViewAutoresizingFlexibleHeight;
		[root_view addSubview:overlay];

		cursor_x = static_cast<float>(root_view.bounds.size.width / 2);
		cursor_y = static_cast<float>(root_view.bounds.size.height / 2);

		// Turn to landscape if the library was in portrait; the game's
		// window only allows landscape, but iOS doesn't turn by itself
		[ui_window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
		[ui_window.windowScene
		        requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc]
		                                                     initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape]
		                                errorHandler:nil];
	}

	// The renderer may add its Metal view after us; stay on top of it
	[root_view bringSubviewToFront:overlay];
}
