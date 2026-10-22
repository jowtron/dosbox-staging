// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_SDL_GPU_RENDERER_H
#define DOSBOX_SDL_GPU_RENDERER_H

#include "render_backend.h"

#if C_SDL_GPU

#include <memory>
#include <string>
#include <vector>

#include <SDL3/SDL.h>

#include "private/gpu_shader_pipeline.h"
#include "private/shader_common.h"

#include "dosbox_config.h"
#include "misc/video.h"
#include "utils/rect.h"

// Render backend built on SDL's GPU API (Metal on Apple platforms, Vulkan or
// Direct3D 12 elsewhere). It runs the same GLSL shaders as the OpenGL backend
// by translating them at runtime (see `GpuShaderTranslator`).
//
// The final shader pass renders into an offscreen "canvas" texture the size
// of the window, which is then copied to the window's swapchain texture. The
// canvas has the same memory layout as the OpenGL backbuffer (bottom row
// first), so it's flipped vertically during the copy.
//
class SdlGpuRenderer : public RenderBackend {

public:
	SdlGpuRenderer(const int x, const int y, const int width,
	               const int height, SDL_WindowFlags sdl_window_flags);

	~SdlGpuRenderer() override;

	SDL_Window* GetWindow() override;

	DosBox::Rect GetCanvasSizeInPixels() override;

	void NotifyViewportSizeChanged(const DosBox::Rect viewport_size) override;

	void NotifyRenderSizeChanged(const int new_render_width_px,
	                             const int new_render_height_px) override;

	void NotifyVideoModeChanged(const VideoMode& video_mode) override;

	SetShaderResult SetShader(const std::string& symbolic_shader_descriptor) override;

	void ForceReloadCurrentShader() override;

	ShaderInfo GetCurrentShaderInfo() override;
	ShaderPreset GetCurrentShaderPreset() override;

	std::string GetCurrentSymbolicShaderDescriptor() override;
	ShaderDescriptor GetCurrentShaderDescriptor() override;

	void StartFrame(uint32_t*& pixels_out, int& pitch_out) override;
	void EndFrame() override;

	void PrepareFrame() override;
	void PresentFrame() override;

	void SetVsync(const bool is_enabled) override;

	void SetColorSpace(const ColorSpace color_space) override;
	void EnableImageAdjustments(const bool enable) override;
	void SetImageAdjustmentSettings(const ImageAdjustmentSettings& settings) override;
	void SetDeditheringStrength(const float strength) override;

	RenderedImage ReadPixelsPostShader(const DosBox::Rect output_rect_px) override;

	uint32_t MakePixel(const uint8_t red, const uint8_t green,
	                   const uint8_t blue) override;

	// The graphical mapper draws with an SDL renderer; this hands the window
	// over to one sharing our GPU device, and takes it back afterwards.
	SDL_Renderer* CreateMapperRenderer();
	void DestroyMapperRenderer(SDL_Renderer* renderer);

	// prevent copying
	SdlGpuRenderer(const SdlGpuRenderer&) = delete;
	// prevent assignment
	SdlGpuRenderer& operator=(const SdlGpuRenderer&) = delete;

private:
	bool InitRenderer();

	void SetSwapchainParameters(const SDL_GPUPresentMode present_mode);
	void LogFrameRate();

	void RecreateInputTexture();
	void MaybeRecreateCanvasTexture();

	void MaybeUpdateRenderSize(const int new_render_width_px,
	                           const int new_render_height_px);

	SetShaderResult SetShaderInternal(const std::string& symbolic_shader_descriptor);

	void HandleShaderAndPresetChangeViaNotify(const ShaderDescriptor& new_descriptor);

	SetShaderResult MaybeSwitchShaderAndPreset(const ShaderDescriptor& curr_descriptor,
	                                           const ShaderDescriptor& new_descriptor);

	bool SwitchShader(const std::string& shader_name);

	SDL_Window* window    = nullptr;
	SDL_GPUDevice* device = nullptr;

	// See `OpenGlRenderer` for a description of the framebuffers
	std::vector<uint32_t> curr_framebuf = {};
	std::vector<uint32_t> last_framebuf = {};

	// True if the last framebuffer has been updated since the last upload
	bool last_framebuf_dirty = false;

	// True if the upload transfer buffer holds a frame that hasn't been
	// copied into the input texture yet
	bool upload_pending = false;

	// Frames shown and skipped since the last frame rate log line
	int frames_shown           = 0;
	int frames_skipped         = 0;
	int64_t frame_log_start_ms = 0;

	struct {
		int width                            = 0;
		int height                           = 0;
		int pitch                            = 0;
		SDL_GPUTexture* texture              = nullptr;
		SDL_GPUTransferBuffer* upload_buffer = nullptr;
	} input_texture = {};

	struct {
		int width               = 0;
		int height              = 0;
		SDL_GPUTexture* texture = nullptr;
	} canvas = {};

	SDL_GPUPresentMode present_mode = SDL_GPU_PRESENTMODE_VSYNC;

	std::string curr_symbolic_shader_descriptor = {};

	ShaderDescriptor curr_shader_descriptor = {};

	ShaderInfo main_shader_info     = {};
	ShaderPreset main_shader_preset = {};

	DosBox::Rect curr_viewport_size_px = {};
	VideoMode curr_video_mode          = {};

	std::unique_ptr<GpuShaderPipeline> shader_pipeline = {};
};

#endif // C_SDL_GPU

#endif // DOSBOX_SDL_GPU_RENDERER_H
