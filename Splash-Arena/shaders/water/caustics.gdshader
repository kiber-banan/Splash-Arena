shader_type spatial;
// ============================================================
//  Каустика на дне: свет, пробившийся сквозь поверхность и
//  собранный волнами в бегающие блики. Вешается на пол арены.
// ============================================================

render_mode blend_mix;

uniform vec3 sand_color : source_color = vec3(0.42, 0.45, 0.40);
uniform vec3 caustic_color : source_color = vec3(0.65, 0.95, 1.0);
uniform float caustic_scale : hint_range(0.02, 1.0) = 0.20;
uniform float caustic_speed : hint_range(0.0, 1.0) = 0.28;
uniform float caustic_strength : hint_range(0.0, 3.0) = 1.1;
uniform float caustic_fade_radius : hint_range(5.0, 500.0) = 260.0;

varying vec3 world_pos;

float caustic_pattern(vec2 p, float t) {
	vec2 i = p;
	float c = 1.0;
	for (int n = 0; n < 3; n++) {
		float ti = t * (1.0 - (3.5 / float(n + 1)));
		i = p + vec2(cos(ti - i.x) + sin(ti + i.y), sin(ti - i.y) + cos(ti + i.x));
		c += 1.0 / length(vec2(p.x / (sin(i.x + ti) * 0.5), p.y / (cos(i.y + ti) * 0.5)));
	}
	c /= 3.0;
	c = 1.17 - pow(c, 1.4);
	return clamp(pow(abs(c), 8.0), 0.0, 1.0);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME * caustic_speed * 2.0;
	float c = caustic_pattern(world_pos.xz * caustic_scale, t);
	// Свет сверху: к краям арены каустика слабее.
	float fade = 1.0 - clamp(length(world_pos.xz) / caustic_fade_radius, 0.0, 1.0);
	c *= 0.20 + 0.80 * fade;

	ALBEDO = sand_color;
	ROUGHNESS = 0.95;
	METALLIC = 0.0;
	EMISSION = caustic_color * c * caustic_strength;
}
