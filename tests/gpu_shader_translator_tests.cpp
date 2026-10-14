// SPDX-FileCopyrightText:  2026-2026 The DOSBox Staging Team
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gui/render/private/gpu_shader_translator.h"

#include <gtest/gtest.h>

#include <fstream>
#include <regex>
#include <sstream>
#include <string>

#include "misc/std_filesystem.h"

using namespace GpuShaderTranslator;

namespace {

// The tests run in the source directory
const std_fs::path ShadersDir = "resources/shaders";

std::string read_file(const std_fs::path& path)
{
	std::ifstream file(path, std::ios::binary);
	std::stringstream buffer;
	buffer << file.rdbuf();
	return buffer.str();
}

std::string to_string(const std::vector<uint8_t>& code)
{
	return {code.begin(), code.end()};
}

// Returns the `[[user(locnN)]]` location of an MSL stage interface member
std::optional<int> get_msl_location(const std::string& msl, const std::string& name)
{
	const std::regex pattern(name + R"( \[\[user\(locn(\d+)\)\]\])");

	std::smatch match = {};
	if (std::regex_search(msl, match, pattern)) {
		return std::stoi(match[1]);
	}
	return {};
}

} // namespace

TEST(GpuShaderTranslator, TranslatesAllBundledShaders)
{
	auto num_shaders = 0;

	for (const auto& entry : std_fs::recursive_directory_iterator(ShadersDir)) {
		if (entry.path().extension() != ".glsl") {
			continue;
		}
		++num_shaders;

		const auto source = read_file(entry.path());

		for (const auto format : {TargetFormat::Msl, TargetFormat::Spirv}) {
			const auto result = Translate(source, format);

			EXPECT_TRUE(result.shader.has_value())
			        << entry.path() << ":\n"
			        << result.log;
		}
	}
	EXPECT_GT(num_shaders, 0);
}

TEST(GpuShaderTranslator, ReflectsUniforms)
{
	const auto result = Translate(read_file(ShadersDir / "_internal" /
	                                        "image-adjustments.glsl"),
	                              TargetFormat::Msl);
	ASSERT_TRUE(result.shader);

	const auto& uniforms = result.shader->fragment.uniforms;

	ASSERT_TRUE(uniforms.contains("COLOR_SPACE"));
	EXPECT_TRUE(uniforms.at("COLOR_SPACE").is_int);
	EXPECT_EQ(uniforms.at("COLOR_SPACE").num_components, 1);

	ASSERT_TRUE(uniforms.contains("BLACK_LEVEL_COLOR"));
	EXPECT_FALSE(uniforms.at("BLACK_LEVEL_COLOR").is_int);
	EXPECT_EQ(uniforms.at("BLACK_LEVEL_COLOR").num_components, 3);

	EXPECT_GT(result.shader->fragment.uniform_block_size_bytes, 0);
}

TEST(GpuShaderTranslator, MapsSamplersToInputs)
{
	const auto result = Translate(read_file(ShadersDir / "_internal" /
	                                        "checkerboard-dedither-pass2.glsl"),
	                              TargetFormat::Msl);
	ASSERT_TRUE(result.shader);

	EXPECT_EQ(result.shader->fragment.sampler_inputs, (std::vector<int>{0, 1}));
	EXPECT_TRUE(result.shader->vertex.sampler_inputs.empty());
}

TEST(GpuShaderTranslator, MatchesVaryingsByName)
{
	// The fragment stage declares the inputs in a different order
	const std::string source =
	        "#version 330 core\n"
	        "#if defined(VERTEX)\n"
	        "layout(location = 0) in vec2 a_position;\n"
	        "out vec2 first;\n"
	        "out vec4 second;\n"
	        "void main() {\n"
	        "    gl_Position = vec4(a_position, 0.0, 1.0);\n"
	        "    first = a_position;\n"
	        "    second = vec4(a_position, 1.0, 1.0);\n"
	        "}\n"
	        "#elif defined(FRAGMENT)\n"
	        "in vec4 second;\n"
	        "in vec2 first;\n"
	        "out vec4 FragColor;\n"
	        "void main() {\n"
	        "    FragColor = second + vec4(first, 0.0, 0.0);\n"
	        "}\n"
	        "#endif\n";

	const auto result = Translate(source, TargetFormat::Msl);
	ASSERT_TRUE(result.shader) << result.log;

	const auto vertex   = to_string(result.shader->vertex.code);
	const auto fragment = to_string(result.shader->fragment.code);

	for (const auto name : {"first", "second"}) {
		const auto vertex_location   = get_msl_location(vertex, name);
		const auto fragment_location = get_msl_location(fragment, name);

		ASSERT_TRUE(vertex_location.has_value()) << name;
		EXPECT_EQ(vertex_location, fragment_location) << name;
	}
}

TEST(GpuShaderTranslator, FlipsClipSpaceY)
{
	const auto result = Translate(read_file(ShadersDir / "interpolation" /
	                                        "sharp.glsl"),
	                              TargetFormat::Msl);
	ASSERT_TRUE(result.shader);

	const auto vertex = to_string(result.shader->vertex.code);
	EXPECT_NE(vertex.find("gl_Position.y = -"), std::string::npos);
}

TEST(GpuShaderTranslator, ReportsErrors)
{
	const std::string source =
	        "#version 330 core\n"
	        "#if defined(VERTEX)\n"
	        "void main() { gl_Position = undefined_variable; }\n"
	        "#elif defined(FRAGMENT)\n"
	        "out vec4 FragColor;\n"
	        "void main() { FragColor = vec4(1.0); }\n"
	        "#endif\n";

	const auto result = Translate(source, TargetFormat::Msl);

	EXPECT_FALSE(result.shader.has_value());
	EXPECT_NE(result.log.find("undefined_variable"), std::string::npos);
}
