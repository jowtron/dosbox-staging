// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef DOSBOX_GPU_SHADER_PIPELINE_H
#define DOSBOX_GPU_SHADER_PIPELINE_H

#include "dosbox_config.h"

#if C_SDL_GPU

#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include <SDL3/SDL.h>

#include "gpu_shader_translator.h"
#include "gui/render/render.h"
#include "misc/video.h"
#include "shader.h"
#include "shader_common.h"
#include "utils/rect.h"

// A shader translated and compiled for the SDL_GPU device, plus the graphics
// pipelines created from it (one per render target format).
class GpuShaderProgram {
public:
	GpuShaderProgram(SDL_GPUDevice* device, const std::string& name,
	                 const std::string& source,
	                 const GpuShaderTranslator::TargetFormat format);

	~GpuShaderProgram();

	bool IsValid() const;

	const std::string& GetSource() const;

	const GpuShaderTranslator::StageShader& GetVertexStage() const;
	const GpuShaderTranslator::StageShader& GetFragmentStage() const;

	// Returns the graphics pipeline rendering into textures of the given
	// format (created on first use)
	SDL_GPUGraphicsPipeline* GetPipeline(const SDL_GPUTextureFormat target_format);

	// prevent copying
	GpuShaderProgram(const GpuShaderProgram&) = delete;
	// prevent assignment
	GpuShaderProgram& operator=(const GpuShaderProgram&) = delete;

private:
	SDL_GPUDevice* device = nullptr;

	std::string source = {};

	GpuShaderTranslator::TranslatedShader translated = {};

	SDL_GPUShader* vertex_shader   = nullptr;
	SDL_GPUShader* fragment_shader = nullptr;

	std::unordered_map<int, SDL_GPUGraphicsPipeline*> pipelines = {};
};

struct GpuShaderPass {
	ShaderInfo info = {};

	std::shared_ptr<GpuShaderProgram> program = {};

	// Input textures; contains at least one element
	std::vector<SDL_GPUTexture*> in_textures = {};

	// Output texture size for intermediate shader passes (width & height
	// only), or the position and size of the viewport for the final pass.
	DosBox::Rect out_viewport = {};

	// Output texture for intermediate passes; nullptr for the final pass
	// that's rendered into the canvas texture.
	SDL_GPUTexture* out_texture = nullptr;

	SDL_GPUTextureFormat out_format = SDL_GPU_TEXTUREFORMAT_INVALID;

	// Uniform data of the vertex and fragment stages
	std::vector<uint8_t> vertex_uniforms   = {};
	std::vector<uint8_t> fragment_uniforms = {};

	// Uniforms the shader doesn't have, or of a different type, are ignored
	void SetUniformFloats(const std::string& name,
	                      const std::vector<float>& values);
	void SetUniformInt(const std::string& name, const int value);
};

// The SDL_GPU equivalent of `ShaderPipeline`; it implements the exact same
// multi-pass pipeline (see `README.md`).
//
// All render targets have the same memory layout as their OpenGL
// counterparts (the bottom row comes first; see `GpuShaderTranslator`), so the
// final image in the canvas texture is upside down compared to the window.
//
class GpuShaderPipeline {

public:
	GpuShaderPipeline(SDL_GPUDevice* device,
	                  const GpuShaderTranslator::TargetFormat shader_format,
	                  const SDL_GPUTextureFormat canvas_format);
	~GpuShaderPipeline();

	bool IsPipelineComplete() const;

	void NotifyRenderSizeChanged(const int input_texture_width,
	                             const int input_texture_height,
	                             SDL_GPUTexture* input_texture);

	void NotifyViewportSizeChanged(const DosBox::Rect& viewport);
	void NotifyVideoModeChanged(const VideoMode& video_mode);

	// Translates and compiles the shader if it's not in the program cache
	// yet. Returns false if that fails.
	bool SetMainShader(const Shader& shader);

	void SetMainShaderPreset(const ShaderPreset& preset);

	void SetColorSpace(const ColorSpace color_space);
	void EnableImageAdjustments(const bool enable);
	void SetImageAdjustmentSettings(const ImageAdjustmentSettings& settings);
	void SetDeditheringStrength(const float strength);

	// Records the render passes into the command buffer; the final pass
	// renders into `canvas`.
	void Render(SDL_GPUCommandBuffer* command_buffer, SDL_GPUTexture* canvas);

	// prevent copying
	GpuShaderPipeline(const GpuShaderPipeline&) = delete;
	// prevent assignment
	GpuShaderPipeline& operator=(const GpuShaderPipeline&) = delete;

private:
	std::shared_ptr<GpuShaderProgram> GetOrCreateProgram(const Shader& shader);

	void CreateSamplers();
	void DestroySamplers();
	void CreateVertexBuffer();

	void LoadAndAddInternalPasses();
	void LoadAndAddInternalPassOrExit(const std::string& shader_name);

	void SetPassOutputSizes();
	void CreatePassOutputTextures();

	void CreatePipeline();
	void DestroyPipeline();

	GpuShaderPass& GetShaderPass(const std::string& name);

	std::pair<SDL_GPUTexture*, DosBox::Rect> GetPreviousPassOutputTextureAndViewport(
	        const std::vector<GpuShaderPass>::iterator pass) const;

	void UpdatePassTextureUniforms();
	void UpdateTextureUniforms(const std::vector<GpuShaderPass>::iterator pass);

	void RenderPass(SDL_GPUCommandBuffer* command_buffer,
	                const GpuShaderPass& pass, SDL_GPUTexture* target);

	SDL_GPUDevice* device = nullptr;

	GpuShaderTranslator::TargetFormat shader_format = {};

	SDL_GPUTextureFormat canvas_format = SDL_GPU_TEXTUREFORMAT_INVALID;
	SDL_GPUTextureFormat float_output_format = SDL_GPU_TEXTUREFORMAT_INVALID;

	SDL_GPUBuffer* vertex_buffer = nullptr;

	struct {
		bool dedithering_enabled = false;
	} config = {};

	struct {
		DosBox::Rect size       = {};
		SDL_GPUTexture* texture = nullptr;
	} input_texture = {};

	VideoMode video_mode  = {};
	DosBox::Rect viewport = {};

	std::optional<Shader> main_shader = {};

	// Translated and compiled shaders; keys are the shader names
	std::unordered_map<std::string, std::shared_ptr<GpuShaderProgram>> program_cache = {};

	// Samplers, one per (filter, wrap) combination. Indexed by
	// [TextureFilterMode][TextureWrapMode].
	static constexpr size_t NumFilterModes = 2;
	static constexpr size_t NumWrapModes   = 4;

	SDL_GPUSampler* samplers[NumFilterModes][NumWrapModes] = {};

	SDL_GPUSampler* GetSampler(const TextureFilterMode filter,
	                           const TextureWrapMode wrap) const;

	// ---------------------------------------------------------------------
	// Shader passes
	// ---------------------------------------------------------------------
	std::vector<GpuShaderPass> shader_passes = {};

	// Image adjustments pass params
	// -----------------------------
	ColorSpace color_space = {};

	ImageAdjustmentSettings image_adjustment_settings = {};

	bool enable_image_adjustments = false;

	void UpdateImageAdjustmentsPassUniforms();

	// Dedither pass params
	// --------------------
	float dedithering_strength = {};

	void UpdateDeditherPassUniforms();

	// Main shader pass params
	// -----------------------
	ShaderPreset main_shader_preset = {};

	void UpdateMainShaderPassUniforms();
};

#endif // C_SDL_GPU

#endif // DOSBOX_GPU_SHADER_PIPELINE_H
