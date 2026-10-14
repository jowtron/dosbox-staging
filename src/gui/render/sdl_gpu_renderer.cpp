// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "sdl_gpu_renderer.h"

#if C_SDL_GPU

#include <cstring>

#include "gui/private/common.h"
#include "private/auto_shader_switcher.h"
#include "private/shader_manager.h"

#include "capture/capture.h"
#include "dosbox_config.h"
#include "misc/support.h"
#include "misc/video.h"
#include "utils/checks.h"
#include "utils/math_utils.h"

#if defined(MACOSX)
#include "metal_colorspace.h"
#endif

CHECK_NARROWING();

// The emulated framebuffer is stored in BGRX byte order (see `MakePixel()`)
static constexpr auto InputTextureFormat = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;

static constexpr auto CanvasFormat = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;

static constexpr auto BytesPerPixel = 4;

SdlGpuRenderer::SdlGpuRenderer(const int x, const int y, const int width,
                               const int height, SDL_WindowFlags sdl_window_flags)
{
	SDL_PropertiesID props = SDL_CreateProperties();
	SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_X_NUMBER, x);
	SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_Y_NUMBER, y);
	SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, width);
	SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, height);
	SDL_SetNumberProperty(props,
	                      SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER,
	                      sdl_window_flags);

	window = SDL_CreateWindowWithProperties(props);
	SDL_DestroyProperties(props);

	if (!window) {
		const auto msg = format_str("SDLGPU: Error creating window: %s",
		                            SDL_GetError());
		LOG_ERR("%s", msg.c_str());
		throw std::runtime_error(msg);
	}

	if (!InitRenderer()) {
		if (device) {
			SDL_DestroyGPUDevice(device);
			device = nullptr;
		}
		SDL_DestroyWindow(window);
		window = nullptr;

		const auto msg = format_str("SDLGPU: Error creating renderer");
		LOG_ERR("%s", msg.c_str());
		throw std::runtime_error(msg);
	}
}

bool SdlGpuRenderer::InitRenderer()
{
	constexpr auto ShaderFormats = SDL_GPU_SHADERFORMAT_SPIRV |
	                               SDL_GPU_SHADERFORMAT_MSL;
	constexpr auto DebugMode     = false;

	device = SDL_CreateGPUDevice(ShaderFormats, DebugMode, nullptr);
	if (!device) {
		LOG_ERR("SDLGPU: Error creating GPU device: %s", SDL_GetError());
		return false;
	}

	const auto shader_format = (SDL_GetGPUShaderFormats(device) &
	                            SDL_GPU_SHADERFORMAT_MSL)
	                                 ? GpuShaderTranslator::TargetFormat::Msl
	                                 : GpuShaderTranslator::TargetFormat::Spirv;

	if (!SDL_ClaimWindowForGPUDevice(device, window)) {
		LOG_ERR("SDLGPU: Error claiming window for GPU device: %s",
		        SDL_GetError());
		return false;
	}

	SetSwapchainParameters(SDL_GPU_PRESENTMODE_VSYNC);

	LOG_INFO("SDLGPU: Using '%s' GPU driver, %s shaders",
	         SDL_GetGPUDeviceDriver(device),
	         (shader_format == GpuShaderTranslator::TargetFormat::Msl)
	                 ? "Metal Shading Language"
	                 : "SPIR-V");

	// The shader manager only needs to load the shader sources and
	// metadata; we compile them ourselves
	ShaderManager::GetInstance().SetRenderBackend(RenderBackendType::SdlGpu);

	shader_pipeline = std::make_unique<GpuShaderPipeline>(device,
	                                                      shader_format,
	                                                      CanvasFormat);
	return true;
}

SdlGpuRenderer::~SdlGpuRenderer()
{
	if (device) {
		SDL_WaitForGPUIdle(device);

		shader_pipeline = {};

		if (input_texture.texture) {
			SDL_ReleaseGPUTexture(device, input_texture.texture);
		}
		if (input_texture.upload_buffer) {
			SDL_ReleaseGPUTransferBuffer(device,
			                             input_texture.upload_buffer);
		}
		if (canvas.texture) {
			SDL_ReleaseGPUTexture(device, canvas.texture);
		}

		SDL_ReleaseWindowFromGPUDevice(device, window);
		SDL_DestroyGPUDevice(device);
		device = nullptr;
	}
	if (window) {
		SDL_DestroyWindow(window);
		window = nullptr;
	}
}

void SdlGpuRenderer::SetSwapchainParameters(const SDL_GPUPresentMode new_present_mode)
{
	if (!SDL_SetGPUSwapchainParameters(device,
	                                   window,
	                                   SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
	                                   new_present_mode)) {
		LOG_ERR("SDLGPU: Error setting swapchain parameters: %s",
		        SDL_GetError());
		return;
	}
	present_mode = new_present_mode;

#if defined(MACOSX)
	// The output of the shader pipeline is in the Display P3 colour space
	// on Apple platforms (the only allowed 'color_space' setting), but SDL
	// tags the swapchain as sRGB; see `OpenGlRenderer::CreateSdlWindow()`
	set_metal_layer_display_p3_color_space(window);
#endif
}

SDL_Window* SdlGpuRenderer::GetWindow()
{
	return window;
}

DosBox::Rect SdlGpuRenderer::GetCanvasSizeInPixels()
{
	SDL_Rect canvas_size_px = {};
	SDL_GetWindowSizeInPixels(window, &canvas_size_px.w, &canvas_size_px.h);

	const auto r = to_rect(canvas_size_px);
	assert(r.HasPositiveSize());

	return r;
}

void SdlGpuRenderer::NotifyViewportSizeChanged(const DosBox::Rect viewport_size_px)
{
	// If the viewport size has changed, the canvas size might have
	// changed too.
	const auto canvas_size_px = GetCanvasSizeInPixels();

	// We always expect a valid canvas
	assert(!canvas_size_px.IsEmpty());

	curr_viewport_size_px = viewport_size_px;

	// The video mode hasn't changed, but the ShaderManager call expects it.
	const auto video_mode = VGA_GetCurrentVideoMode();

	if (video_mode.width <= 0 && video_mode.height <= 0) {
		// See `OpenGlRenderer::NotifyViewportSizeChanged()`
		return;
	}

	const auto new_descriptor = AutoShaderSwitcher::GetInstance().NotifyRenderParametersChanged(
	        curr_shader_descriptor, canvas_size_px, video_mode);

	HandleShaderAndPresetChangeViaNotify(new_descriptor);

	shader_pipeline->NotifyViewportSizeChanged(curr_viewport_size_px);
}

void SdlGpuRenderer::HandleShaderAndPresetChangeViaNotify(const ShaderDescriptor& new_descriptor)
{
	using enum SdlGpuRenderer::SetShaderResult;

	switch (MaybeSwitchShaderAndPreset(curr_shader_descriptor, new_descriptor)) {
	case Ok: curr_shader_descriptor = new_descriptor; break;
	case PresetError:
		LOG_ERR("RENDER: Error loading shader preset '%s'; using default preset",
		        new_descriptor.ToString().c_str());

		curr_shader_descriptor = new_descriptor;
		curr_shader_descriptor.preset_name.clear();
		break;

	case ShaderError:
		LOG_ERR("RENDER: Error setting shader '%s'",
		        new_descriptor.ToString().c_str());
		break;

	default: assertm(false, "Invalid SetShaderResult value");
	}
}

void SdlGpuRenderer::NotifyRenderSizeChanged(const int new_render_width_px,
                                             const int new_render_height_px)
{
	MaybeUpdateRenderSize(new_render_width_px, new_render_height_px);
}

void SdlGpuRenderer::MaybeUpdateRenderSize(const int new_render_width_px,
                                           const int new_render_height_px)
{
	// See `OpenGlRenderer::MaybeUpdateRenderSize()`
	if (new_render_width_px == 0 && new_render_height_px == 0) {
		// no-op
		return;
	}

	// Size hasn't changed, don't recreate the texture
	if (new_render_width_px == input_texture.width &&
	    new_render_height_px == input_texture.height) {
		// no-op
		return;
	}

	input_texture.width  = new_render_width_px;
	input_texture.height = new_render_height_px;

	RecreateInputTexture();

	shader_pipeline->NotifyRenderSizeChanged(input_texture.width,
	                                         input_texture.height,
	                                         input_texture.texture);
}

void SdlGpuRenderer::RecreateInputTexture()
{
	if (input_texture.texture) {
		SDL_ReleaseGPUTexture(device, input_texture.texture);
		input_texture.texture = nullptr;
	}
	if (input_texture.upload_buffer) {
		SDL_ReleaseGPUTransferBuffer(device, input_texture.upload_buffer);
		input_texture.upload_buffer = nullptr;
	}

	SDL_GPUTextureCreateInfo texture_info = {};

	texture_info.type   = SDL_GPU_TEXTURETYPE_2D;
	texture_info.format = InputTextureFormat;
	texture_info.usage  = SDL_GPU_TEXTUREUSAGE_SAMPLER;
	texture_info.width  = check_cast<Uint32>(input_texture.width);
	texture_info.height = check_cast<Uint32>(input_texture.height);

	texture_info.layer_count_or_depth = 1;
	texture_info.num_levels           = 1;

	input_texture.texture = SDL_CreateGPUTexture(device, &texture_info);
	if (!input_texture.texture) {
		LOG_ERR("SDLGPU: Error creating %dx%d input texture: %s",
		        input_texture.width,
		        input_texture.height,
		        SDL_GetError());
	}

	// Allocate host memory buffers for the texture data. The video card
	// emulation will write to these buffers, then we'll copy the data to
	// the texture in GPU memory via a transfer buffer before presenting
	// the frame.
	const auto num_pixels = static_cast<size_t>(input_texture.width) *
	                        static_cast<size_t>(input_texture.height);

	curr_framebuf.resize(num_pixels);
	last_framebuf.resize(num_pixels);

	input_texture.pitch = input_texture.width * BytesPerPixel;

	SDL_GPUTransferBufferCreateInfo transfer_info = {};

	transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
	transfer_info.size  = check_cast<Uint32>(num_pixels * BytesPerPixel);

	input_texture.upload_buffer = SDL_CreateGPUTransferBuffer(device,
	                                                          &transfer_info);
	if (!input_texture.upload_buffer) {
		LOG_ERR("SDLGPU: Error creating transfer buffer: %s",
		        SDL_GetError());
	}

	upload_pending = false;
}

void SdlGpuRenderer::MaybeRecreateCanvasTexture()
{
	int width_px  = 0;
	int height_px = 0;
	SDL_GetWindowSizeInPixels(window, &width_px, &height_px);

	if (width_px == canvas.width && height_px == canvas.height && canvas.texture) {
		return;
	}

	if (canvas.texture) {
		SDL_ReleaseGPUTexture(device, canvas.texture);
		canvas.texture = nullptr;
	}

	canvas.width  = width_px;
	canvas.height = height_px;

	if (width_px <= 0 || height_px <= 0) {
		return;
	}

	SDL_GPUTextureCreateInfo info = {};

	info.type   = SDL_GPU_TEXTURETYPE_2D;
	info.format = CanvasFormat;
	info.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER | SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
	info.width  = check_cast<Uint32>(width_px);
	info.height = check_cast<Uint32>(height_px);

	info.layer_count_or_depth = 1;
	info.num_levels           = 1;

	canvas.texture = SDL_CreateGPUTexture(device, &info);
	if (!canvas.texture) {
		LOG_ERR("SDLGPU: Error creating %dx%d canvas texture: %s",
		        width_px,
		        height_px,
		        SDL_GetError());
	}
}

void SdlGpuRenderer::StartFrame(uint32_t*& pixels_out, int& pitch_out)
{
	assert(!curr_framebuf.empty());

	pixels_out = curr_framebuf.data();
	if (pixels_out == nullptr) {
		return;
	}
	pitch_out = input_texture.pitch;
}

void SdlGpuRenderer::EndFrame()
{
	assert(!curr_framebuf.empty());
	assert(!last_framebuf.empty());

	// We need to copy the buffers. We can't just swap them because the VGA
	// emulation only writes the changed pixels to the framebuffer in each
	// frame.

	last_framebuf       = curr_framebuf;
	last_framebuf_dirty = true;
}

void SdlGpuRenderer::PrepareFrame()
{
	assert(!last_framebuf.empty());

	if (!last_framebuf_dirty || !input_texture.upload_buffer) {
		return;
	}

	// Cycling gives us a fresh buffer if the previous one is still being
	// uploaded
	constexpr auto Cycle = true;

	auto data = SDL_MapGPUTransferBuffer(device, input_texture.upload_buffer, Cycle);
	if (!data) {
		LOG_ERR("SDLGPU: Error mapping transfer buffer: %s", SDL_GetError());
		return;
	}

	std::memcpy(data, last_framebuf.data(), last_framebuf.size() * BytesPerPixel);

	SDL_UnmapGPUTransferBuffer(device, input_texture.upload_buffer);

	last_framebuf_dirty = false;
	upload_pending      = true;
}

void SdlGpuRenderer::PresentFrame()
{
	auto command_buffer = SDL_AcquireGPUCommandBuffer(device);
	if (!command_buffer) {
		LOG_ERR("SDLGPU: Error acquiring command buffer: %s",
		        SDL_GetError());
		return;
	}

	if (upload_pending && input_texture.texture) {
		auto copy_pass = SDL_BeginGPUCopyPass(command_buffer);

		SDL_GPUTextureTransferInfo source = {};

		source.transfer_buffer = input_texture.upload_buffer;
		source.pixels_per_row = check_cast<Uint32>(input_texture.width);
		source.rows_per_layer = check_cast<Uint32>(input_texture.height);

		SDL_GPUTextureRegion destination = {};

		destination.texture = input_texture.texture;
		destination.w       = check_cast<Uint32>(input_texture.width);
		destination.h       = check_cast<Uint32>(input_texture.height);
		destination.d       = 1;

		constexpr auto Cycle = false;
		SDL_UploadToGPUTexture(copy_pass, &source, &destination, Cycle);

		SDL_EndGPUCopyPass(copy_pass);

		upload_pending = false;
	}

	MaybeRecreateCanvasTexture();

	if (canvas.texture && shader_pipeline->IsPipelineComplete()) {
		shader_pipeline->Render(command_buffer, canvas.texture);
	}

	SDL_GPUTexture* swapchain_texture = nullptr;

	Uint32 swapchain_width_px  = 0;
	Uint32 swapchain_height_px = 0;

	if (!SDL_WaitAndAcquireGPUSwapchainTexture(command_buffer,
	                                           window,
	                                           &swapchain_texture,
	                                           &swapchain_width_px,
	                                           &swapchain_height_px)) {
		LOG_ERR("SDLGPU: Error acquiring swapchain texture: %s",
		        SDL_GetError());
	}

	// The swapchain texture is null if the window is minimised
	if (swapchain_texture && canvas.texture) {
		SDL_GPUBlitInfo blit = {};

		blit.source.texture = canvas.texture;
		blit.source.w       = check_cast<Uint32>(canvas.width);
		blit.source.h       = check_cast<Uint32>(canvas.height);

		blit.destination.texture = swapchain_texture;
		blit.destination.w       = swapchain_width_px;
		blit.destination.h       = swapchain_height_px;

		blit.load_op   = SDL_GPU_LOADOP_DONT_CARE;
		blit.flip_mode = SDL_FLIP_VERTICAL;
		blit.filter    = SDL_GPU_FILTER_NEAREST;

		SDL_BlitGPUTexture(command_buffer, &blit);
	}

	SDL_SubmitGPUCommandBuffer(command_buffer);

	// Optionally capture frame (the capture waits for the GPU to finish
	// rendering the frame)
	if (CAPTURE_IsCapturingPostRenderImage()) {
		GFX_CaptureRenderedImage();
	}
}

SdlGpuRenderer::SetShaderResult SdlGpuRenderer::SetShader(const std::string& symbolic_shader_descriptor)
{
	return SetShaderInternal(symbolic_shader_descriptor);
}

SdlGpuRenderer::SetShaderResult SdlGpuRenderer::SetShaderInternal(
        const std::string& new_symbolic_shader_descriptor)
{
	using enum SdlGpuRenderer::SetShaderResult;

	const auto new_descriptor = AutoShaderSwitcher::GetInstance().NotifyShaderChanged(
	        new_symbolic_shader_descriptor);

	const auto result = MaybeSwitchShaderAndPreset(curr_shader_descriptor,
	                                               new_descriptor);

	switch (result) {
	case Ok: {
		curr_shader_descriptor = new_descriptor;
		curr_symbolic_shader_descriptor = new_symbolic_shader_descriptor;
	} break;

	case PresetError: {
		curr_shader_descriptor = new_descriptor;
		curr_shader_descriptor.preset_name.clear();

		constexpr auto GlslExtension = ".glsl";
		auto descriptor = ShaderDescriptor::FromString(new_symbolic_shader_descriptor,
		                                               GlslExtension);
		descriptor.preset_name.clear();

		curr_symbolic_shader_descriptor = descriptor.ToString();
	} break;

	case ShaderError: break;

	default:
		assertm(false, "Invalid SetShaderResult value");
		return ShaderError;
	}

	return result;
}

void SdlGpuRenderer::ForceReloadCurrentShader()
{
	LOG_INFO("RENDER: Reloading current shader '%s'",
	         curr_shader_descriptor.ToString().c_str());

	const auto result = ShaderManager::GetInstance().ForceReloadShader(
	        curr_shader_descriptor);

	if (result) {
		const auto& [shader, preset] = *result;

		// The shader program is recompiled if the source has changed;
		// the current shader stays active if that fails
		if (shader_pipeline->SetMainShader(shader)) {
			main_shader_info = shader.info;
			shader_pipeline->SetMainShaderPreset(preset);
		}
	}
}

void SdlGpuRenderer::NotifyVideoModeChanged(const VideoMode& video_mode)
{
	const auto canvas_size_px = GetCanvasSizeInPixels();

	// We always expect a valid canvas and DOS video mode
	assert(!canvas_size_px.IsEmpty());
	assert(video_mode.width > 0 && video_mode.height > 0);

	curr_video_mode = video_mode;

	// Handle shader auto-switching
	const auto new_descriptor = AutoShaderSwitcher::GetInstance().NotifyRenderParametersChanged(
	        curr_shader_descriptor, canvas_size_px, video_mode);

	HandleShaderAndPresetChangeViaNotify(new_descriptor);

	shader_pipeline->NotifyVideoModeChanged(curr_video_mode);
}

SdlGpuRenderer::SetShaderResult SdlGpuRenderer::MaybeSwitchShaderAndPreset(
        const ShaderDescriptor& curr_descriptor, const ShaderDescriptor& new_descriptor)
{
	const auto changed_shader = (curr_descriptor.shader_name !=
	                             new_descriptor.shader_name);

	const auto changed_preset = (curr_descriptor.preset_name !=
	                             new_descriptor.preset_name);

	using enum SdlGpuRenderer::SetShaderResult;

	if (!changed_shader && !changed_preset) {
		// No change; report success
		return Ok;
	}

	if (changed_shader) {
		if (!SwitchShader(new_descriptor.shader_name)) {
			// Loading shader failed; report error
			return ShaderError;
		}
	}

	main_shader_preset = ShaderManager::GetInstance().LoadShaderPresetOrDefault(
	        new_descriptor);

	shader_pipeline->SetMainShaderPreset(main_shader_preset);

	curr_shader_descriptor.preset_name = main_shader_preset.name;

	MaybeUpdateRenderSize(input_texture.width, input_texture.height);
	return Ok;
}

bool SdlGpuRenderer::SwitchShader(const std::string& shader_name)
{
	const auto maybe_shader = ShaderManager::GetInstance().LoadShader(shader_name);
	if (!maybe_shader) {
		return false;
	}

	const auto& shader = *maybe_shader;

	if (!shader_pipeline->SetMainShader(shader)) {
		return false;
	}

	main_shader_info = shader.info;
	return true;
}

void SdlGpuRenderer::SetVsync(const bool is_enabled)
{
	auto supports = [&](const SDL_GPUPresentMode mode) {
		return SDL_WindowSupportsGPUPresentMode(device, window, mode);
	};

	const auto new_present_mode = [&] {
		if (is_enabled) {
			return SDL_GPU_PRESENTMODE_VSYNC;
		}
		if (supports(SDL_GPU_PRESENTMODE_IMMEDIATE)) {
			return SDL_GPU_PRESENTMODE_IMMEDIATE;
		}
		if (supports(SDL_GPU_PRESENTMODE_MAILBOX)) {
			return SDL_GPU_PRESENTMODE_MAILBOX;
		}
		return SDL_GPU_PRESENTMODE_VSYNC;
	}();

	if (new_present_mode != present_mode) {
		SetSwapchainParameters(new_present_mode);
	}
}

void SdlGpuRenderer::SetColorSpace(const ColorSpace color_space)
{
	shader_pipeline->SetColorSpace(color_space);
}

void SdlGpuRenderer::EnableImageAdjustments(const bool enable)
{
	shader_pipeline->EnableImageAdjustments(enable);
}

void SdlGpuRenderer::SetImageAdjustmentSettings(const ImageAdjustmentSettings& settings)
{
	shader_pipeline->SetImageAdjustmentSettings(settings);
}

void SdlGpuRenderer::SetDeditheringStrength(const float strength)
{
	shader_pipeline->SetDeditheringStrength(strength);
}

ShaderInfo SdlGpuRenderer::GetCurrentShaderInfo()
{
	return main_shader_info;
}

ShaderPreset SdlGpuRenderer::GetCurrentShaderPreset()
{
	return main_shader_preset;
}

std::string SdlGpuRenderer::GetCurrentSymbolicShaderDescriptor()
{
	return curr_symbolic_shader_descriptor;
}

ShaderDescriptor SdlGpuRenderer::GetCurrentShaderDescriptor()
{
	return curr_shader_descriptor;
}

RenderedImage SdlGpuRenderer::ReadPixelsPostShader(const DosBox::Rect output_rect_px)
{
	// Create new image
	RenderedImage image = {};

	image.params.width              = iroundf(output_rect_px.w);
	image.params.height             = iroundf(output_rect_px.h);
	image.params.double_width       = false;
	image.params.double_height      = false;
	image.params.pixel_aspect_ratio = {1};
	image.params.pixel_format       = PixelFormat::BGR24_ByteArray;

	constexpr auto BitsInByte = 8;

	image.pitch = image.params.width *
	              (get_bits_per_pixel(image.params.pixel_format) / BitsInByte);

	const auto image_size_bytes = check_cast<uint32_t>(image.params.height *
	                                                   image.pitch);

	image.image_data = new uint8_t[image_size_bytes];
	std::memset(image.image_data, 0, image_size_bytes);

	// The canvas has the same memory layout as the OpenGL backbuffer, so
	// the rows are read from the bottom up
	image.is_flipped_vertically = true;

	const auto x = iroundf(output_rect_px.x);
	const auto y = iroundf(output_rect_px.y);

	const auto width  = image.params.width;
	const auto height = image.params.height;

	if (!canvas.texture || x < 0 || y < 0 || width <= 0 || height <= 0 ||
	    x + width > canvas.width || y + height > canvas.height) {
		LOG_ERR("SDLGPU: Invalid capture rectangle %s",
		        output_rect_px.ToString().c_str());
		return image;
	}

	SDL_GPUTransferBufferCreateInfo transfer_info = {};

	transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
	transfer_info.size = check_cast<Uint32>(width * height * BytesPerPixel);

	auto transfer_buffer = SDL_CreateGPUTransferBuffer(device, &transfer_info);
	if (!transfer_buffer) {
		LOG_ERR("SDLGPU: Error creating transfer buffer: %s",
		        SDL_GetError());
		return image;
	}

	auto command_buffer = SDL_AcquireGPUCommandBuffer(device);
	auto copy_pass      = SDL_BeginGPUCopyPass(command_buffer);

	SDL_GPUTextureRegion source = {};

	source.texture = canvas.texture;
	source.x       = check_cast<Uint32>(x);
	source.y       = check_cast<Uint32>(y);
	source.w       = check_cast<Uint32>(width);
	source.h       = check_cast<Uint32>(height);
	source.d       = 1;

	SDL_GPUTextureTransferInfo destination = {};

	destination.transfer_buffer = transfer_buffer;
	destination.pixels_per_row  = check_cast<Uint32>(width);
	destination.rows_per_layer  = check_cast<Uint32>(height);

	SDL_DownloadFromGPUTexture(copy_pass, &source, &destination);
	SDL_EndGPUCopyPass(copy_pass);

	auto fence = SDL_SubmitGPUCommandBufferAndAcquireFence(command_buffer);
	if (fence) {
		constexpr auto WaitAll = true;
		SDL_WaitForGPUFences(device, WaitAll, &fence, 1);
		SDL_ReleaseGPUFence(device, fence);
	}

	constexpr auto Cycle = false;

	const auto data = static_cast<const uint8_t*>(
	        SDL_MapGPUTransferBuffer(device, transfer_buffer, Cycle));

	if (data) {
		// Convert BGRA to BGR
		const auto num_pixels = static_cast<size_t>(width) *
		                        static_cast<size_t>(height);

		for (size_t i = 0; i < num_pixels; ++i) {
			image.image_data[i * 3 + 0] = data[i * BytesPerPixel + 0];
			image.image_data[i * 3 + 1] = data[i * BytesPerPixel + 1];
			image.image_data[i * 3 + 2] = data[i * BytesPerPixel + 2];
		}
		SDL_UnmapGPUTransferBuffer(device, transfer_buffer);
	}

	SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

	return image;
}

uint32_t SdlGpuRenderer::MakePixel(const uint8_t red, const uint8_t green,
                                   const uint8_t blue)
{
	return ((blue << 0) | (green << 8) | (red << 16)) | (255 << 24);
}

#endif // C_SDL_GPU
