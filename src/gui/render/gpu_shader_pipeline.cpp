// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "private/gpu_shader_pipeline.h"

#if C_SDL_GPU

#include <array>
#include <cstring>

#include "gui/render/private/shader_manager.h"

#include "misc/support.h"
#include "utils/checks.h"
#include "utils/math_utils.h"

CHECK_NARROWING();

using GpuShaderTranslator::StageShader;
using GpuShaderTranslator::TargetFormat;

// ---------------------------------------------------------------------------
// GpuShaderProgram
// ---------------------------------------------------------------------------

static SDL_GPUShader* create_gpu_shader(SDL_GPUDevice* device,
                                        const StageShader& stage,
                                        const SDL_GPUShaderStage shader_stage,
                                        const TargetFormat format,
                                        const std::string& name)
{
	SDL_GPUShaderCreateInfo info = {};

	info.code_size  = stage.code.size();
	info.code       = stage.code.data();
	info.entrypoint = stage.entry_point.c_str();
	info.format = (format == TargetFormat::Msl) ? SDL_GPU_SHADERFORMAT_MSL
	                                            : SDL_GPU_SHADERFORMAT_SPIRV;
	info.stage = shader_stage;

	info.num_samplers = check_cast<Uint32>(stage.sampler_inputs.size());
	info.num_uniform_buffers = (stage.uniform_block_size_bytes > 0) ? 1 : 0;

	info.props = SDL_CreateProperties();
	SDL_SetStringProperty(info.props,
	                      SDL_PROP_GPU_SHADER_CREATE_NAME_STRING,
	                      name.c_str());

	auto shader = SDL_CreateGPUShader(device, &info);
	SDL_DestroyProperties(info.props);

	if (!shader) {
		LOG_ERR("SDLGPU: Error creating %s shader of '%s': %s",
		        (shader_stage == SDL_GPU_SHADERSTAGE_VERTEX) ? "vertex"
		                                                     : "fragment",
		        name.c_str(),
		        SDL_GetError());
	}
	return shader;
}

GpuShaderProgram::GpuShaderProgram(SDL_GPUDevice* _device, const std::string& name,
                                   const std::string& _source,
                                   const TargetFormat format)
        : device(_device),
          source(_source)
{
	auto result = GpuShaderTranslator::Translate(source, format);

	if (!result.shader) {
		LOG_ERR("SDLGPU: Error translating shader '%s':\n%s",
		        name.c_str(),
		        result.log.c_str());
		return;
	}

	translated = std::move(*result.shader);

	vertex_shader = create_gpu_shader(device,
	                                  translated.vertex,
	                                  SDL_GPU_SHADERSTAGE_VERTEX,
	                                  format,
	                                  name);

	fragment_shader = create_gpu_shader(device,
	                                    translated.fragment,
	                                    SDL_GPU_SHADERSTAGE_FRAGMENT,
	                                    format,
	                                    name);

	// The code is not needed anymore, only the reflection data
	translated.vertex.code   = {};
	translated.fragment.code = {};
}

GpuShaderProgram::~GpuShaderProgram()
{
	for (const auto& [_, pipeline] : pipelines) {
		SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
	}
	if (vertex_shader) {
		SDL_ReleaseGPUShader(device, vertex_shader);
	}
	if (fragment_shader) {
		SDL_ReleaseGPUShader(device, fragment_shader);
	}
}

bool GpuShaderProgram::IsValid() const
{
	return vertex_shader && fragment_shader;
}

const std::string& GpuShaderProgram::GetSource() const
{
	return source;
}

const StageShader& GpuShaderProgram::GetVertexStage() const
{
	return translated.vertex;
}

const StageShader& GpuShaderProgram::GetFragmentStage() const
{
	return translated.fragment;
}

SDL_GPUGraphicsPipeline* GpuShaderProgram::GetPipeline(const SDL_GPUTextureFormat target_format)
{
	assert(IsValid());

	const auto key = static_cast<int>(target_format);

	if (const auto it = pipelines.find(key); it != pipelines.end()) {
		return it->second;
	}

	// A single vec2 vertex attribute at location 0 (`a_position`)
	SDL_GPUVertexBufferDescription vertex_buffer_desc = {};

	vertex_buffer_desc.slot       = 0;
	vertex_buffer_desc.pitch      = 2 * sizeof(float);
	vertex_buffer_desc.input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX;

	SDL_GPUVertexAttribute vertex_attribute = {};

	vertex_attribute.location    = 0;
	vertex_attribute.buffer_slot = 0;
	vertex_attribute.format      = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
	vertex_attribute.offset      = 0;

	SDL_GPUColorTargetDescription color_target_desc = {};
	color_target_desc.format                        = target_format;

	SDL_GPUGraphicsPipelineCreateInfo info = {};

	info.vertex_shader   = vertex_shader;
	info.fragment_shader = fragment_shader;

	info.vertex_input_state.vertex_buffer_descriptions = &vertex_buffer_desc;
	info.vertex_input_state.num_vertex_buffers    = 1;
	info.vertex_input_state.vertex_attributes     = &vertex_attribute;
	info.vertex_input_state.num_vertex_attributes = 1;

	info.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;

	info.rasterizer_state.fill_mode  = SDL_GPU_FILLMODE_FILL;
	info.rasterizer_state.cull_mode  = SDL_GPU_CULLMODE_NONE;
	info.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;

	info.target_info.color_target_descriptions = &color_target_desc;
	info.target_info.num_color_targets         = 1;

	auto pipeline = SDL_CreateGPUGraphicsPipeline(device, &info);
	if (!pipeline) {
		LOG_ERR("SDLGPU: Error creating graphics pipeline: %s",
		        SDL_GetError());
		return nullptr;
	}

	pipelines[key] = pipeline;
	return pipeline;
}

// ---------------------------------------------------------------------------
// GpuShaderPass
// ---------------------------------------------------------------------------

static void write_uniform(std::vector<uint8_t>& buffer, const StageShader& stage,
                          const std::string& name, const void* data,
                          const int num_components, const bool is_int)
{
	const auto it = stage.uniforms.find(name);
	if (it == stage.uniforms.end()) {
		return;
	}
	const auto& member = it->second;

	// Mismatching types are ignored, like in OpenGL (where they're errors)
	if (member.is_int != is_int || member.num_components != num_components) {
		return;
	}

	constexpr auto ComponentSize = sizeof(float);
	static_assert(sizeof(float) == sizeof(int32_t));

	const auto offset = static_cast<size_t>(member.offset_bytes);
	const auto size   = static_cast<size_t>(num_components) * ComponentSize;

	if (offset + size <= buffer.size()) {
		std::memcpy(buffer.data() + offset, data, size);
	}
}

void GpuShaderPass::SetUniformFloats(const std::string& name,
                                     const std::vector<float>& values)
{
	constexpr auto IsInt      = false;
	const auto num_components = check_cast<int>(values.size());

	write_uniform(vertex_uniforms,
	              program->GetVertexStage(),
	              name,
	              values.data(),
	              num_components,
	              IsInt);

	write_uniform(fragment_uniforms,
	              program->GetFragmentStage(),
	              name,
	              values.data(),
	              num_components,
	              IsInt);
}

void GpuShaderPass::SetUniformInt(const std::string& name, const int value)
{
	constexpr auto IsInt         = true;
	constexpr auto NumComponents = 1;

	const auto value_int32 = static_cast<int32_t>(value);

	write_uniform(vertex_uniforms,
	              program->GetVertexStage(),
	              name,
	              &value_int32,
	              NumComponents,
	              IsInt);

	write_uniform(fragment_uniforms,
	              program->GetFragmentStage(),
	              name,
	              &value_int32,
	              NumComponents,
	              IsInt);
}

// ---------------------------------------------------------------------------
// GpuShaderPipeline
// ---------------------------------------------------------------------------

GpuShaderPipeline::GpuShaderPipeline(SDL_GPUDevice* _device,
                                     const TargetFormat _shader_format,
                                     const SDL_GPUTextureFormat _canvas_format)
        : device(_device),
          shader_format(_shader_format),
          canvas_format(_canvas_format)
{
	// 32-bit float textures can't be filtered on many mobile GPUs, so we
	// use half floats there
#if defined(DOSBOX_PLATFORM_IOS)
	float_output_format = SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
#else
	float_output_format = SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT;
#endif

	CreateSamplers();
	CreateVertexBuffer();

	// The pipeline will be created lazily once we've received all necessary
	// information via notifications. IsPipelineComplete() will return true
	// when we're ready to create the pipeline.
}

GpuShaderPipeline::~GpuShaderPipeline()
{
	DestroyPipeline();

	main_shader   = {};
	program_cache = {};

	DestroySamplers();

	if (vertex_buffer) {
		SDL_ReleaseGPUBuffer(device, vertex_buffer);
		vertex_buffer = nullptr;
	}
}

std::shared_ptr<GpuShaderProgram> GpuShaderPipeline::GetOrCreateProgram(const Shader& shader)
{
	const auto& name = shader.info.name;

	if (const auto it = program_cache.find(name);
	    it != program_cache.end() && it->second->GetSource() == shader.source) {
		return it->second;
	}

	auto program = std::make_shared<GpuShaderProgram>(device,
	                                                  name,
	                                                  shader.source,
	                                                  shader_format);
	if (!program->IsValid()) {
		return {};
	}

	program_cache[name] = program;
	return program;
}

void GpuShaderPipeline::CreateVertexBuffer()
{
	// Vertex data of a single oversized triangle encompassing the viewport
	constexpr std::array<float, 2 * 3> VertexData = {
	        -1.0f,
	        -1.0f, // lower left
	        3.0f,
	        -1.0f, // lower right
	        -1.0f,
	        3.0f // upper left
	};

	constexpr auto DataSize = static_cast<Uint32>(sizeof(VertexData));

	SDL_GPUBufferCreateInfo buffer_info = {};

	buffer_info.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
	buffer_info.size  = DataSize;

	vertex_buffer = SDL_CreateGPUBuffer(device, &buffer_info);

	SDL_GPUTransferBufferCreateInfo transfer_info = {};

	transfer_info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
	transfer_info.size  = DataSize;

	auto transfer_buffer = SDL_CreateGPUTransferBuffer(device, &transfer_info);

	constexpr auto Cycle = false;

	auto data = SDL_MapGPUTransferBuffer(device, transfer_buffer, Cycle);
	std::memcpy(data, VertexData.data(), DataSize);
	SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

	auto command_buffer = SDL_AcquireGPUCommandBuffer(device);
	auto copy_pass      = SDL_BeginGPUCopyPass(command_buffer);

	SDL_GPUTransferBufferLocation source = {};
	source.transfer_buffer               = transfer_buffer;

	SDL_GPUBufferRegion destination = {};
	destination.buffer              = vertex_buffer;
	destination.size                = DataSize;

	SDL_UploadToGPUBuffer(copy_pass, &source, &destination, Cycle);

	SDL_EndGPUCopyPass(copy_pass);
	SDL_SubmitGPUCommandBuffer(command_buffer);

	SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);
}

static SDL_GPUFilter to_gpu_filter(const TextureFilterMode m)
{
	using enum TextureFilterMode;

	switch (m) {
	case NearestNeighbour: return SDL_GPU_FILTER_NEAREST;
	case Bilinear: return SDL_GPU_FILTER_LINEAR;
	default:
		assertm(false, "Invalid TextureFilterMode");
		return SDL_GPU_FILTER_LINEAR;
	}
}

static SDL_GPUSamplerAddressMode to_gpu_address_mode(const TextureWrapMode m)
{
	using enum TextureWrapMode;

	switch (m) {
	case Repeat: return SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
	case MirroredRepeat: return SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT;
	case ClampToEdge: return SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;

	// SDL_GPU has no border colour addressing mode
	case ClampToBorder: return SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;

	default:
		assertm(false, "Invalid TextureWrapMode");
		return SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
	}
}

void GpuShaderPipeline::CreateSamplers()
{
	using enum TextureFilterMode;
	using enum TextureWrapMode;

	constexpr TextureFilterMode filters[] = {NearestNeighbour, Bilinear};

	constexpr TextureWrapMode wraps[] = {Repeat,
	                                     MirroredRepeat,
	                                     ClampToEdge,
	                                     ClampToBorder};

	for (const auto filter : filters) {
		for (const auto wrap : wraps) {
			SDL_GPUSamplerCreateInfo info = {};

			info.min_filter     = to_gpu_filter(filter);
			info.mag_filter     = to_gpu_filter(filter);
			info.mipmap_mode    = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
			info.address_mode_u = to_gpu_address_mode(wrap);
			info.address_mode_v = to_gpu_address_mode(wrap);
			info.address_mode_w = to_gpu_address_mode(wrap);

			const auto f = static_cast<size_t>(filter);
			const auto w = static_cast<size_t>(wrap);

			samplers[f][w] = SDL_CreateGPUSampler(device, &info);
		}
	}
}

void GpuShaderPipeline::DestroySamplers()
{
	for (size_t f = 0; f < NumFilterModes; ++f) {
		for (size_t w = 0; w < NumWrapModes; ++w) {
			if (samplers[f][w]) {
				SDL_ReleaseGPUSampler(device, samplers[f][w]);
				samplers[f][w] = nullptr;
			}
		}
	}
}

SDL_GPUSampler* GpuShaderPipeline::GetSampler(const TextureFilterMode filter,
                                              const TextureWrapMode wrap) const
{
	// Shader passes only use nearest-neighbour and bilinear filtering
	const auto f = static_cast<size_t>(
	        (filter == TextureFilterMode::NearestNeighbour)
	                ? TextureFilterMode::NearestNeighbour
	                : TextureFilterMode::Bilinear);

	const auto w = static_cast<size_t>(wrap);

	assert(w < NumWrapModes);
	return samplers[f][w];
}

bool GpuShaderPipeline::IsPipelineComplete() const
{
	return (video_mode.width > 0 && video_mode.height > 0 &&
	        !input_texture.size.IsEmpty() && !viewport.IsEmpty() && main_shader);
}

void GpuShaderPipeline::NotifyViewportSizeChanged(const DosBox::Rect& new_viewport)
{
	if (viewport == new_viewport) {
		return;
	}

	viewport = new_viewport;

	if (IsPipelineComplete()) {
		DestroyPipeline();
		CreatePipeline();
	}
}

void GpuShaderPipeline::NotifyRenderSizeChanged(const int input_texture_width,
                                                const int input_texture_height,
                                                SDL_GPUTexture* new_input_texture)
{
	if ((ifloor(input_texture.size.w) == input_texture_width) &&
	    (ifloor(input_texture.size.h) == input_texture_height) &&
	    (input_texture.texture == new_input_texture)) {
		return;
	}

	input_texture.size    = {input_texture_width, input_texture_height};
	input_texture.texture = new_input_texture;

	if (IsPipelineComplete()) {
		DestroyPipeline();
		CreatePipeline();
	}
}

void GpuShaderPipeline::NotifyVideoModeChanged(const VideoMode& new_video_mode)
{
	if (video_mode == new_video_mode) {
		return;
	}

	video_mode = new_video_mode;

	if (IsPipelineComplete()) {
		DestroyPipeline();
		CreatePipeline();
	}
}

void GpuShaderPipeline::CreatePipeline()
{
	assert(IsPipelineComplete());

	LoadAndAddInternalPasses();

	SetPassOutputSizes();
	CreatePassOutputTextures();

	// Update uniforms
	UpdatePassTextureUniforms();
	UpdateMainShaderPassUniforms();
	UpdateImageAdjustmentsPassUniforms();

	if (config.dedithering_enabled) {
		UpdateDeditherPassUniforms();
	}
}

static GpuShaderPass make_pass(const Shader& shader,
                               std::shared_ptr<GpuShaderProgram> program)
{
	GpuShaderPass pass = {};

	pass.info    = shader.info;
	pass.program = std::move(program);

	auto make_buffer = [](const StageShader& stage) {
		return std::vector<uint8_t>(
		        static_cast<size_t>(stage.uniform_block_size_bytes), 0);
	};

	pass.vertex_uniforms   = make_buffer(pass.program->GetVertexStage());
	pass.fragment_uniforms = make_buffer(pass.program->GetFragmentStage());

	return pass;
}

void GpuShaderPipeline::LoadAndAddInternalPasses()
{
	if (config.dedithering_enabled) {
		// Resize the input image (the rendered image) to the size of
		// the video mode. This can perform width and/or halving.
		LoadAndAddInternalPassOrExit("integer-downscale");

		// Checkerboard dedither
		LoadAndAddInternalPassOrExit("checkerboard-dedither-linearize");
		LoadAndAddInternalPassOrExit("checkerboard-dedither-pass1");
		LoadAndAddInternalPassOrExit("checkerboard-dedither-pass2");
		LoadAndAddInternalPassOrExit("checkerboard-dedither-pass3");
	}

	// The image adjustments pass is always the first; it cannot be disabled
	// as it performs the colour space transforms as well.
	LoadAndAddInternalPassOrExit("image-adjustments");

	if (config.dedithering_enabled) {
		// Resize the image to the size of the rendered imge. This can
		// perform width and/or doubling.
		LoadAndAddInternalPassOrExit("integer-upscale");
	}

	// Main shader pass (e.g., a CRT shader, the sharp shader, an upscaler,
	// etc.)
	assert(main_shader);

	auto program = GetOrCreateProgram(*main_shader);

	// The program was created successfully in SetMainShader(), so this
	// can only fail if it has been evicted from the cache meanwhile, which
	// we never do
	assert(program);

	shader_passes.push_back(make_pass(*main_shader, program));
}

void GpuShaderPipeline::LoadAndAddInternalPassOrExit(const std::string& shader_name)
{
	const auto path = std_fs::path("_internal") / shader_name;

	const auto maybe_shader = ShaderManager::GetInstance().LoadShader(
	        path.string());

	if (!maybe_shader) {
		E_Exit("SDLGPU: Cannot load shader pass '%s' shader, exiting",
		       path.string().c_str());
	}

	auto program = GetOrCreateProgram(*maybe_shader);
	if (!program) {
		E_Exit("SDLGPU: Cannot compile shader pass '%s' shader, exiting",
		       path.string().c_str());
	}

	shader_passes.push_back(make_pass(*maybe_shader, program));
}

void GpuShaderPipeline::SetPassOutputSizes()
{
	for (auto it = shader_passes.begin(); it != shader_passes.end(); ++it) {
		auto& pass = *it;

		auto [width, height] = [&]() -> std::pair<float, float> {
			using enum ShaderOutputSize;
			switch (pass.info.output_size) {
			case Previous: {
				const auto [_, viewport] =
				        GetPreviousPassOutputTextureAndViewport(it);
				return {viewport.w, viewport.h};
			}

			case Rendered:
				return {input_texture.size.w, input_texture.size.h};

			case VideoMode:
				return {video_mode.width, video_mode.height};

			case Viewport: return {viewport.w, viewport.h};

			default:
				assertm(false, "Invalid ShaderOutputSize value");
				return {};
			}
		}();

		if (std::next(it) == shader_passes.end()) {
			// The last pass is rendered directly to the canvas
			pass.out_viewport = viewport;
		} else {
			pass.out_viewport = {width, height};
		}
	}
}

void GpuShaderPipeline::CreatePassOutputTextures()
{
	for (auto it = shader_passes.begin(); it != shader_passes.end(); ++it) {
		auto& pass = *it;

		// The last pass is rendered directly to the canvas, so we don't
		// need to create an output texture for it
		if (std::next(it) == shader_passes.end()) {
			pass.out_format = canvas_format;
			continue;
		}

		const auto& preset = pass.info.default_preset;

		pass.out_format = preset.settings.float_output_texture
		                        ? float_output_format
		                        : SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;

		SDL_GPUTextureCreateInfo info = {};

		info.type   = SDL_GPU_TEXTURETYPE_2D;
		info.format = pass.out_format;
		info.usage  = SDL_GPU_TEXTUREUSAGE_SAMPLER |
		              SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;

		info.width  = static_cast<Uint32>(pass.out_viewport.w);
		info.height = static_cast<Uint32>(pass.out_viewport.h);

		info.layer_count_or_depth = 1;
		info.num_levels           = 1;

		pass.out_texture = SDL_CreateGPUTexture(device, &info);
		if (!pass.out_texture) {
			LOG_ERR("SDLGPU: Error creating %dx%d pass output texture: %s",
			        info.width,
			        info.height,
			        SDL_GetError());
		}
	}
}

void GpuShaderPipeline::DestroyPipeline()
{
	for (auto& pass : shader_passes) {
		if (pass.out_texture) {
			SDL_ReleaseGPUTexture(device, pass.out_texture);
			pass.out_texture = nullptr;
		}
	}

	shader_passes.clear();
}

bool GpuShaderPipeline::SetMainShader(const Shader& shader)
{
	if (!GetOrCreateProgram(shader)) {
		return false;
	}

	main_shader        = shader;
	main_shader_preset = shader.info.default_preset;

	if (IsPipelineComplete()) {
		DestroyPipeline();
		CreatePipeline();
	}
	return true;
}

void GpuShaderPipeline::SetMainShaderPreset(const ShaderPreset& preset)
{
	main_shader_preset = preset;

	if (IsPipelineComplete()) {
		UpdateMainShaderPassUniforms();
	}
}

void GpuShaderPipeline::SetColorSpace(const ColorSpace _color_space)
{
	color_space = _color_space;

	if (IsPipelineComplete()) {
		UpdateImageAdjustmentsPassUniforms();
	}
}

void GpuShaderPipeline::EnableImageAdjustments(const bool enable)
{
	enable_image_adjustments = enable;

	if (IsPipelineComplete()) {
		UpdateImageAdjustmentsPassUniforms();
	}
}

void GpuShaderPipeline::SetImageAdjustmentSettings(const ImageAdjustmentSettings& settings)
{
	image_adjustment_settings = settings;

	if (IsPipelineComplete()) {
		UpdateImageAdjustmentsPassUniforms();
	}
}

void GpuShaderPipeline::SetDeditheringStrength(const float strength)
{
	dedithering_strength = strength;

	const auto enable_dedithering = (strength > 0.0f);

	if (!IsPipelineComplete()) {
		config.dedithering_enabled = enable_dedithering;
		return;
	}

	if (config.dedithering_enabled != enable_dedithering) {
		config.dedithering_enabled = enable_dedithering;

		DestroyPipeline();
		CreatePipeline();

	} else if (config.dedithering_enabled) {
		UpdateDeditherPassUniforms();
	}
}

void GpuShaderPipeline::Render(SDL_GPUCommandBuffer* command_buffer,
                               SDL_GPUTexture* canvas)
{
	assert(IsPipelineComplete());

	for (const auto& pass : shader_passes) {
		RenderPass(command_buffer,
		           pass,
		           pass.out_texture ? pass.out_texture : canvas);
	}
}

GpuShaderPass& GpuShaderPipeline::GetShaderPass(const std::string& name)
{
	for (auto& pass : shader_passes) {
		if (pass.info.pass_name == name) {
			return pass;
		}
	}
	assertm(false, "Invalid shader pass ID");

	// Just to make the compiler happy
	return *shader_passes.begin();
}

void GpuShaderPipeline::RenderPass(SDL_GPUCommandBuffer* command_buffer,
                                   const GpuShaderPass& pass, SDL_GPUTexture* target)
{
	if (!target) {
		return;
	}

	auto pipeline = pass.program->GetPipeline(pass.out_format);
	if (!pipeline) {
		return;
	}

	SDL_GPUColorTargetInfo color_target = {};

	color_target.texture     = target;
	color_target.clear_color = {0.0f, 0.0f, 0.0f, 1.0f};
	color_target.load_op     = SDL_GPU_LOADOP_CLEAR;
	color_target.store_op    = SDL_GPU_STOREOP_STORE;

	auto render_pass = SDL_BeginGPURenderPass(command_buffer, &color_target, 1, nullptr);

	SDL_BindGPUGraphicsPipeline(render_pass, pipeline);

	// Truncate like `glViewport()` does with its integer arguments
	SDL_GPUViewport viewport_px = {};

	viewport_px.x = static_cast<float>(static_cast<int>(pass.out_viewport.x));
	viewport_px.y = static_cast<float>(static_cast<int>(pass.out_viewport.y));
	viewport_px.w = static_cast<float>(static_cast<int>(pass.out_viewport.w));
	viewport_px.h = static_cast<float>(static_cast<int>(pass.out_viewport.h));

	viewport_px.min_depth = 0.0f;
	viewport_px.max_depth = 1.0f;

	SDL_SetGPUViewport(render_pass, &viewport_px);

	SDL_GPUBufferBinding vertex_binding = {};
	vertex_binding.buffer               = vertex_buffer;

	SDL_BindGPUVertexBuffers(render_pass, 0, &vertex_binding, 1);

	const auto filter_mode = pass.info.default_preset.settings.texture_filter_mode;

	auto make_sampler_bindings = [&](const StageShader& stage) {
		std::vector<SDL_GPUTextureSamplerBinding> bindings = {};

		for (auto input_index : stage.sampler_inputs) {
			const auto num_inputs = check_cast<int>(
			        pass.in_textures.size());
			if (input_index >= num_inputs) {
				input_index = 0;
			}

			const auto i = static_cast<size_t>(input_index);

			SDL_GPUTextureSamplerBinding binding = {};

			binding.texture = pass.in_textures[i];
			binding.sampler = GetSampler(filter_mode,
			                             pass.info.input_wrap_modes[i]);

			bindings.push_back(binding);
		}
		return bindings;
	};

	const auto& vertex_stage   = pass.program->GetVertexStage();
	const auto& fragment_stage = pass.program->GetFragmentStage();

	if (const auto bindings = make_sampler_bindings(vertex_stage);
	    !bindings.empty()) {
		SDL_BindGPUVertexSamplers(render_pass,
		                          0,
		                          bindings.data(),
		                          check_cast<Uint32>(bindings.size()));
	}
	if (const auto bindings = make_sampler_bindings(fragment_stage);
	    !bindings.empty()) {
		SDL_BindGPUFragmentSamplers(render_pass,
		                            0,
		                            bindings.data(),
		                            check_cast<Uint32>(bindings.size()));
	}

	if (!pass.vertex_uniforms.empty()) {
		SDL_PushGPUVertexUniformData(command_buffer,
		                             0,
		                             pass.vertex_uniforms.data(),
		                             check_cast<Uint32>(
		                                     pass.vertex_uniforms.size()));
	}
	if (!pass.fragment_uniforms.empty()) {
		SDL_PushGPUFragmentUniformData(
		        command_buffer,
		        0,
		        pass.fragment_uniforms.data(),
		        check_cast<Uint32>(pass.fragment_uniforms.size()));
	}

	// Apply shader by drawing an oversized triangle
	SDL_DrawGPUPrimitives(render_pass, 3, 1, 0, 0);

	SDL_EndGPURenderPass(render_pass);
}

void GpuShaderPipeline::UpdateTextureUniforms(const std::vector<GpuShaderPass>::iterator pass)
{
	pass->in_textures.clear();

	for (size_t i = 0; i < pass->info.input_ids.size(); ++i) {
		const auto pass_id = pass->info.input_ids[i];

		SDL_GPUTexture* in_texture   = nullptr;
		DosBox::Rect in_texture_size = {};

		if (pass_id == "Previous") {
			const auto [texture, viewport] =
			        GetPreviousPassOutputTextureAndViewport(pass);

			in_texture      = texture;
			in_texture_size = {viewport.w, viewport.h};

		} else {
			// Only specifying the outputs of previous passes is
			// valid as input for the current pass
			bool found = false;

			auto it = pass;
			while (it != shader_passes.begin()) {
				it = std::prev(it);

				const auto& p = *it;
				if (p.info.pass_name == pass_id) {
					in_texture      = p.out_texture;
					in_texture_size = p.out_viewport;

					found = true;
					break;
				}
			}
			if (!found) {
				LOG_ERR("RENDER: Invalid shader pass ID for input texture %zu: %s",
				        i,
				        pass_id.c_str());
				return;
			}
		}

		const auto in_texture_size_name = format_str("INPUT_SIZE_%d", i);

		pass->SetUniformFloats(in_texture_size_name,
		                       {in_texture_size.w, in_texture_size.h});

		pass->in_textures.emplace_back(in_texture);
	}

	const auto& out_viewport = pass->out_viewport;

	pass->SetUniformFloats("OUTPUT_START_OFFSET",
	                       {out_viewport.x, out_viewport.y});
	pass->SetUniformFloats("OUTPUT_SIZE", {out_viewport.w, out_viewport.h});
}

void GpuShaderPipeline::UpdatePassTextureUniforms()
{
	for (auto it = shader_passes.begin(); it != shader_passes.end(); ++it) {
		UpdateTextureUniforms(it);
	}
}

std::pair<SDL_GPUTexture*, DosBox::Rect> GpuShaderPipeline::GetPreviousPassOutputTextureAndViewport(
        const std::vector<GpuShaderPass>::iterator pass) const
{
	if (pass == shader_passes.begin()) {
		return {input_texture.texture, input_texture.size};

	} else {
		const auto prev_pass = std::prev(pass);

		return {prev_pass->out_texture, prev_pass->out_viewport};
	}
}

void GpuShaderPipeline::UpdateMainShaderPassUniforms()
{
	// The main shader is always the last pass
	auto& pass = shader_passes.back();

	for (const auto& [uniform_name, value] : main_shader_preset.params) {
		pass.SetUniformFloats(uniform_name, {value});
	}
}

void GpuShaderPipeline::UpdateImageAdjustmentsPassUniforms()
{
	auto& pass    = GetShaderPass("ImageAdjustments");
	const auto& s = image_adjustment_settings;

	pass.SetUniformInt("COLOR_SPACE", enum_val(color_space));
	pass.SetUniformInt("ENABLE_ADJUSTMENTS", enable_image_adjustments ? 1 : 0);
	pass.SetUniformInt("COLOR_PROFILE", enum_val(s.crt_color_profile));
	pass.SetUniformFloats("BRIGHTNESS", {s.brightness});
	pass.SetUniformFloats("CONTRAST", {s.contrast});
	pass.SetUniformFloats("GAMMA", {s.gamma});
	pass.SetUniformFloats("DIGITAL_CONTRAST", {s.digital_contrast});

	constexpr auto RgbMaxValue = 255.0f;

	pass.SetUniformFloats("BLACK_LEVEL_COLOR",
	                      {s.black_level_color.red / RgbMaxValue,
	                       s.black_level_color.green / RgbMaxValue,
	                       s.black_level_color.blue / RgbMaxValue});

	pass.SetUniformFloats("BLACK_LEVEL", {s.black_level});
	pass.SetUniformFloats("SATURATION", {s.saturation});

	pass.SetUniformFloats("COLOR_TEMPERATURE_KELVIN",
	                      {s.color_temperature_kelvin});

	pass.SetUniformFloats("COLOR_TEMPERATURE_LUMA_PRESERVE",
	                      {s.color_temperature_luma_preserve});

	pass.SetUniformFloats("RED_GAIN", {s.red_gain});
	pass.SetUniformFloats("GREEN_GAIN", {s.green_gain});
	pass.SetUniformFloats("BLUE_GAIN", {s.blue_gain});
}

void GpuShaderPipeline::UpdateDeditherPassUniforms()
{
	static const std::vector<std::string> names = {"CheckerboardDedither_Linearize",
	                                               "CheckerboardDedither_Pass1",
	                                               "CheckerboardDedither_Pass2",
	                                               "CheckerboardDedither_Pass3"};

	for (const auto& name : names) {
		auto& pass = GetShaderPass(name);

		// See `ShaderPipeline::UpdateDeditherPassUniforms()`
		pass.SetUniformFloats("CD_BLEND_OPTION", {1.0f});
		pass.SetUniformFloats("CD_USE_GAMMA", {1.0f});
		pass.SetUniformFloats("CD_BLEND_LEVEL", {dedithering_strength});
		pass.SetUniformFloats("CD_MITIG_NEIGHBOURS", {1.0f});
		pass.SetUniformFloats("CD_MITIG_LINES", {1.0f});
		pass.SetUniformFloats("CD_ADJUST_VIEW", {0.0f});
	}
}

#endif // C_SDL_GPU
