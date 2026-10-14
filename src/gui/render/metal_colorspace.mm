// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "metal_colorspace.h"

#import <QuartzCore/CAMetalLayer.h>

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
using PlatformView = UIView;
#else
#import <Cocoa/Cocoa.h>
using PlatformView = NSView;
#endif

// SDL_GPU adds its Metal view as a subview of the window's content view
static CAMetalLayer* find_metal_layer(PlatformView* view)
{
	if ([view.layer isKindOfClass:[CAMetalLayer class]]) {
		return (CAMetalLayer*)view.layer;
	}
	for (PlatformView* subview in view.subviews) {
		if (auto layer = find_metal_layer(subview)) {
			return layer;
		}
	}
	return nil;
}

void set_metal_layer_display_p3_color_space(SDL_Window* sdl_window)
{
	const auto props = SDL_GetWindowProperties(sdl_window);

#if TARGET_OS_IPHONE
	auto window = (__bridge UIWindow*)SDL_GetPointerProperty(
	        props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
	if (!window) {
		return;
	}
	auto layer = find_metal_layer(window);
#else
	auto window = (__bridge NSWindow*)SDL_GetPointerProperty(
	        props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
	if (!window) {
		return;
	}
	auto layer = find_metal_layer(window.contentView);
#endif

	if (!layer) {
		return;
	}

	// The shader pipeline outputs Display P3 on Apple platforms; tagging
	// the layer lets the OS convert it to the display's colour space
	auto color_space = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
	layer.colorspace = color_space;
	CGColorSpaceRelease(color_space);
}
