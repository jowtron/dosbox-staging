// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "private/gpu_shader_translator.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <string_view>

#include <glslang/Public/ResourceLimits.h>
#include <glslang/Public/ShaderLang.h>
#include <glslang/SPIRV/GlslangToSpv.h>
#include <spirv_cross/spirv_msl.hpp>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

namespace GpuShaderTranslator {

namespace {

// Name the original vertex shader `main()` is renamed to, so we can wrap it
// and flip the clip space Y coordinate it outputs
constexpr std::string_view VertexMainName = "dosbox_vertex_main";

constexpr auto UniformBlockName = "DosboxUniforms";

constexpr std::string_view InputTexturePrefix = "INPUT_TEXTURE_";

// Descriptor sets of the SPIR-V resources as expected by SDL_GPU
constexpr uint32_t VertexSamplerSet   = 0;
constexpr uint32_t VertexUniformSet   = 1;
constexpr uint32_t FragmentSamplerSet = 2;
constexpr uint32_t FragmentUniformSet = 3;

// The shaders are written for `#version 330 core`; this is only used if the
// source lacks a #version directive
constexpr int DefaultGlslVersion = 330;

std::string make_stage_source(const std::string& source, const bool is_vertex)
{
	constexpr std::string_view VersionTag = "#version ";

	std::string_view body     = source;
	std::string_view preamble = {};

	// "#version" has to come first, so split the source after its line
	if (const auto version_pos = body.find(VersionTag);
	    version_pos != std::string_view::npos) {

		if (const auto eol = body.find('\n', version_pos + VersionTag.size());
		    eol != std::string_view::npos) {

			preamble = body.substr(0, eol + 1);
			body.remove_prefix(eol + 1);
		}
	}

	std::string result(preamble);

	// Line continuations are a GLSL 4.20 feature, but OpenGL drivers
	// accept them in older versions too
	result += "#extension GL_ARB_shading_language_420pack : enable\n";

	// `sampler` is a type in Vulkan GLSL, but a valid identifier in OpenGL
	// GLSL (e.g., as a function parameter name)
	result += "#define sampler dosbox_sampler\n";

	// C++ alternative operator tokens are valid GLSL identifiers (e.g., the
	// xBR shaders define `and()` and `or()` functions), but they can't be
	// used as names in MSL. (`not` is left alone as it's a GLSL built-in
	// function).
	for (const auto name :
	     {"and", "or", "xor", "bitand", "bitor", "compl", "and_eq", "or_eq", "xor_eq", "not_eq"}) {
		result += std::string("#define ") + name + " dosbox_" + name + "\n";
	}

	if (is_vertex) {
		result += "#define VERTEX 1\n";
		result += "#define main ";
		result += VertexMainName;
		result += "\n";
	} else {
		result += "#define FRAGMENT 1\n";
	}

	// Keep the line numbers in error messages in sync with the file
	const auto num_preamble_lines = std::count(preamble.begin(),
	                                           preamble.end(),
	                                           '\n');

	result += "#line " + std::to_string(num_preamble_lines + 1) + "\n";
	result += body;

	if (is_vertex) {
		result += "\n#undef main\n";
		result += "void main()\n{\n\t";
		result += VertexMainName;
		result += "();\n\tgl_Position.y = -gl_Position.y;\n}\n";
	}
	return result;
}

std::once_flag glslang_init_flag = {};

std::unique_ptr<glslang::TShader> parse_stage(const EShLanguage stage,
                                              const std::string& source,
                                              std::string& log)
{
	auto shader = std::make_unique<glslang::TShader>(stage);

	const char* strings[] = {source.c_str()};
	shader->setStrings(strings, 1);

	constexpr int ClientInputSemanticsVersion = 100;

	shader->setEnvInput(glslang::EShSourceGlsl,
	                    stage,
	                    glslang::EShClientVulkan,
	                    ClientInputSemanticsVersion);

	shader->setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
	shader->setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);

	// Allow loose (non-block) uniforms, as used by OpenGL shaders; they're
	// gathered into a single uniform block
	shader->setEnvInputVulkanRulesRelaxed();
	shader->setGlobalUniformBlockName(UniformBlockName);
	shader->setGlobalUniformBinding(0);

	// OpenGL shaders don't need explicit locations and bindings
	shader->setAutoMapLocations(true);
	shader->setAutoMapBindings(true);

	const auto messages = static_cast<EShMessages>(EShMsgSpvRules |
	                                               EShMsgVulkanRules);

	constexpr auto ForwardCompatible = false;

	const auto parsed = shader->parse(GetDefaultResources(),
	                                  DefaultGlslVersion,
	                                  ForwardCompatible,
	                                  messages);

	const auto stage_name = (stage == EShLangVertex) ? "vertex" : "fragment";

	if (const auto info = std::string_view(shader->getInfoLog()); !info.empty()) {
		log += std::string(stage_name) + " shader: " + std::string(info);
	}
	if (!parsed) {
		return {};
	}
	return shader;
}

void patch_decoration(const spirv_cross::Compiler& compiler,
                      std::vector<uint32_t>& spirv, const uint32_t id,
                      const spv::Decoration decoration, const uint32_t value,
                      bool& ok)
{
	uint32_t word_offset = 0;
	if (compiler.get_binary_offset_for_decoration(id, decoration, word_offset)) {
		spirv[word_offset] = value;
	} else {
		ok = false;
	}
}

std::unordered_map<std::string, uint32_t> get_output_locations(
        const std::vector<uint32_t>& spirv)
{
	const spirv_cross::Compiler compiler(spirv);

	std::unordered_map<std::string, uint32_t> locations = {};

	for (const auto& output : compiler.get_shader_resources().stage_outputs) {
		locations[output.name] = compiler.get_decoration(output.id,
		                                                 spv::DecorationLocation);
	}
	return locations;
}

// Returns the pass input index of a sampler named `INPUT_TEXTURE_<N>`
std::optional<int> to_input_index(const std::string& name)
{
	if (!name.starts_with(InputTexturePrefix)) {
		return {};
	}
	const auto digits = std::string_view(name).substr(InputTexturePrefix.size());
	if (digits.empty() ||
	    !std::all_of(digits.begin(), digits.end(), [](const char c) {
		    return c >= '0' && c <= '9';
	    })) {
		return {};
	}
	return std::stoi(std::string(digits));
}

// Rebinds the resources of a stage to SDL_GPU's conventions and records the
// uniform block layout and the sampler slots.
//
// `vertex_output_locations` is only used for the fragment stage.
//
bool rebind_stage(std::vector<uint32_t>& spirv, const bool is_vertex,
                  const std::unordered_map<std::string, uint32_t>& vertex_output_locations,
                  StageShader& out, std::string& log)
{
	const spirv_cross::Compiler compiler(spirv);
	const auto resources = compiler.get_shader_resources();

	auto ok = true;

	// Match the fragment inputs to the vertex outputs by name
	if (!is_vertex) {
		uint32_t next_free_location = 0;
		for (const auto& [_, location] : vertex_output_locations) {
			next_free_location = std::max(next_free_location,
			                              location + 1);
		}

		for (const auto& input : resources.stage_inputs) {
			const auto it = vertex_output_locations.find(input.name);

			const auto location = (it != vertex_output_locations.end())
			                            ? it->second
			                            : next_free_location++;

			patch_decoration(compiler,
			                 spirv,
			                 input.id,
			                 spv::DecorationLocation,
			                 location,
			                 ok);
		}
	}

	// Uniform block
	if (resources.uniform_buffers.size() > 1) {
		log += "uniform blocks are not supported\n";
		return false;
	}

	for (const auto& block : resources.uniform_buffers) {
		const auto& type = compiler.get_type(block.base_type_id);

		out.uniform_block_size_bytes = static_cast<int>(
		        compiler.get_declared_struct_size(type));

		for (uint32_t i = 0; i < type.member_types.size(); ++i) {
			const auto& member_type = compiler.get_type(
			        type.member_types[i]);

			const auto is_scalar_or_vector = (member_type.columns == 1 &&
			                                  member_type.array.empty());

			const auto is_float = (member_type.basetype ==
			                       spirv_cross::SPIRType::Float);

			const auto is_int = (member_type.basetype ==
			                     spirv_cross::SPIRType::Int);

			if (!is_scalar_or_vector || !(is_float || is_int)) {
				// Not settable from the pipeline; ignore
				continue;
			}

			UniformMember member = {};
			member.offset_bytes  = static_cast<int>(
			        compiler.type_struct_member_offset(type, i));
			member.num_components = static_cast<int>(member_type.vecsize);
			member.is_int = is_int;

			out.uniforms[compiler.get_member_name(block.base_type_id, i)] = member;
		}

		patch_decoration(compiler,
		                 spirv,
		                 block.id,
		                 spv::DecorationDescriptorSet,
		                 is_vertex ? VertexUniformSet : FragmentUniformSet,
		                 ok);

		patch_decoration(compiler, spirv, block.id, spv::DecorationBinding, 0, ok);
	}

	// Samplers: the `INPUT_TEXTURE_<N>` ones first in order of N, then any
	// others, which sample the first input (as unset sampler uniforms
	// default to texture unit 0 in OpenGL)
	auto samplers = resources.sampled_images;

	std::stable_sort(samplers.begin(),
	                 samplers.end(),
	                 [](const auto& a, const auto& b) {
		                 const auto a_index = to_input_index(a.name);
		                 const auto b_index = to_input_index(b.name);
		                 if (a_index && b_index) {
			                 return *a_index < *b_index;
		                 }
		                 return a_index.has_value() && !b_index.has_value();
	                 });

	for (uint32_t slot = 0; slot < samplers.size(); ++slot) {
		const auto& sampler = samplers[slot];

		out.sampler_inputs.push_back(
		        to_input_index(sampler.name).value_or(0));

		patch_decoration(compiler,
		                 spirv,
		                 sampler.id,
		                 spv::DecorationDescriptorSet,
		                 is_vertex ? VertexSamplerSet : FragmentSamplerSet,
		                 ok);

		patch_decoration(
		        compiler, spirv, sampler.id, spv::DecorationBinding, slot, ok);
	}

	if (!resources.storage_buffers.empty() ||
	    !resources.storage_images.empty() || !resources.separate_images.empty() ||
	    !resources.separate_samplers.empty() ||
	    !resources.push_constant_buffers.empty()) {
		log += "unsupported shader resource types\n";
		return false;
	}

	if (!ok) {
		log += "missing resource decorations\n";
	}
	return ok;
}

std::optional<std::string> to_msl(const std::vector<uint32_t>& spirv,
                                  std::string& entry_point, std::string& log)
{
	try {
		spirv_cross::CompilerMSL compiler(spirv);

		auto options = compiler.get_msl_options();

#if defined(__APPLE__) && TARGET_OS_IPHONE
		options.platform = spirv_cross::CompilerMSL::Options::iOS;
#else
		options.platform = spirv_cross::CompilerMSL::Options::macOS;
#endif
		// Use the binding decorations we set as the MSL [[texture(n)]],
		// [[sampler(n)]] and [[buffer(n)]] indices
		options.enable_decoration_binding = true;

		compiler.set_msl_options(options);

		auto source = compiler.compile();

		const auto& entry = compiler.get_entry_points_and_stages().front();

		entry_point = compiler.get_cleansed_entry_point_name(entry.name,
		                                                     entry.execution_model);
		return source;

	} catch (const spirv_cross::CompilerError& e) {
		log += std::string("SPIRV-Cross error: ") + e.what() + "\n";
		return {};
	}
}

std::vector<uint8_t> to_bytes(const std::vector<uint32_t>& words)
{
	std::vector<uint8_t> bytes(words.size() * sizeof(uint32_t));
	std::memcpy(bytes.data(), words.data(), bytes.size());
	return bytes;
}

} // namespace

Result Translate(const std::string& glsl_source, const TargetFormat format)
{
	std::call_once(glslang_init_flag, [] { glslang::InitializeProcess(); });

	Result result = {};

	auto vertex_shader = parse_stage(EShLangVertex,
	                                 make_stage_source(glsl_source, true),
	                                 result.log);

	auto fragment_shader = parse_stage(EShLangFragment,
	                                   make_stage_source(glsl_source, false),
	                                   result.log);

	if (!vertex_shader || !fragment_shader) {
		return result;
	}

	glslang::TProgram program = {};
	program.addShader(vertex_shader.get());
	program.addShader(fragment_shader.get());

	const auto messages = static_cast<EShMessages>(EShMsgSpvRules |
	                                               EShMsgVulkanRules);

	const auto linked = program.link(messages) && program.mapIO();

	if (const auto info = std::string_view(program.getInfoLog()); !info.empty()) {
		result.log += info;
	}
	if (!linked) {
		return result;
	}

	auto to_spirv = [&](const EShLanguage stage) {
		std::vector<uint32_t> spirv = {};

		glslang::SpvOptions options = {};
		options.disableOptimizer    = true;

		glslang::GlslangToSpv(*program.getIntermediate(stage), spirv, &options);
		return spirv;
	};

	auto vertex_spirv   = to_spirv(EShLangVertex);
	auto fragment_spirv = to_spirv(EShLangFragment);

	TranslatedShader translated = {};

	try {
		const auto vertex_output_locations = get_output_locations(vertex_spirv);

		constexpr auto IsVertex = true;

		if (!rebind_stage(vertex_spirv,
		                  IsVertex,
		                  vertex_output_locations,
		                  translated.vertex,
		                  result.log) ||
		    !rebind_stage(fragment_spirv,
		                  !IsVertex,
		                  vertex_output_locations,
		                  translated.fragment,
		                  result.log)) {
			return result;
		}

	} catch (const spirv_cross::CompilerError& e) {
		result.log += std::string("SPIRV-Cross error: ") + e.what() + "\n";
		return result;
	}

	if (format == TargetFormat::Spirv) {
		translated.vertex.code          = to_bytes(vertex_spirv);
		translated.vertex.entry_point   = "main";
		translated.fragment.code        = to_bytes(fragment_spirv);
		translated.fragment.entry_point = "main";

	} else {
		const auto vertex_msl = to_msl(vertex_spirv,
		                               translated.vertex.entry_point,
		                               result.log);

		const auto fragment_msl = to_msl(fragment_spirv,
		                                 translated.fragment.entry_point,
		                                 result.log);

		if (!vertex_msl || !fragment_msl) {
			return result;
		}

		translated.vertex.code.assign(vertex_msl->begin(),
		                              vertex_msl->end());
		translated.fragment.code.assign(fragment_msl->begin(),
		                                fragment_msl->end());
	}

	result.shader = std::move(translated);
	return result;
}

} // namespace GpuShaderTranslator
