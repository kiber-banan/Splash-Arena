shader_type spatial;
// ============================================================
//  Поверхность воды (смотрим на неё снизу — из-под воды).
//  • 4 направленные волны: высота + аналитические производные,
//    поэтому нормаль считается точно, а не «на глаз»;
//  • бликующая каустика на самой плёнке;
//  • fresnel: под острым углом вода светлее и плотнее.
// ============================================================

render_mode blend_mix, cull_disabled;

uniform float wave_height : hint_range(0.0, 1.5) = 0.5;
uniform float wave_speed : hint_range(0.0, 3.0) = 0.8;
uniform float wave_scale : hint_range(0.05, 1.0) = 0.28;
uniform vec3 shallow_color : source_color = vec3(0.20, 0.72, 0.74);
uniform vec3 deep_color : source_color = vec3(0.02, 0.18, 0.30);
uniform float caustic_strength : hint_range(0.0, 2.0) = 0.9;

varying vec3 world_pos;
varying vec3 surf_normal;

// Четыре волны: возвращаем высоту и градиент (dh/dx, dh/dz).
void waves(vec2 p, float t, out float h, out vec2 grad) {
	h = 0.0;
	grad = vec2(0.0);

	vec2 d1 = normalize(vec2(1.0, 0.25));
	float f1 = wave_scale * 1.0;
	float a1 = 0.34;
	float ph1 = dot(p, d1) * f1 + t * 1.10;
	h += sin(ph1) * a1;
	grad += d1 * (f1 * cos(ph1) * a1);

	vec2 d2 = normalize(vec2(-0.4, 1.0));
	float f2 = wave_scale * 0.85;
	float a2 = 0.26;
	float ph2 = dot(p, d2) * f2 - t * 0.90;
	h += sin(ph2) * a2;
	grad += d2 * (f2 * cos(ph2) * a2);

	vec2 d3 = normalize(vec2(0.8, -0.7));
	float f3 = wave_scale * 2.30;
	float a3 = 0.10;
	float ph3 = dot(p, d3) * f3 + t * 1.90;
	h += sin(ph3) * a3;
	grad += d3 * (f3 * cos(ph3) * a3);

	vec2 d4 = normalize(vec2(0.2, 0.95));
	float f4 = wave_scale * 4.10;
	float a4 = 0.045;
	float ph4 = dot(p, d4) * f4 - t * 2.70;
	h += sin(ph4) * a4;
	grad += d4 * (f4 * cos(ph4) * a4);
}

// Классическая дешёвая каустика: три итерации «сложенной» сетки.
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
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h;
	vec2 grad;
	waves(wp.xz, TIME * wave_speed, h, grad);
	VERTEX.y += h * wave_height;
	world_pos = wp;
	surf_normal = normalize(vec3(-grad.x * wave_height, 1.0, -grad.y * wave_height));
}

void fragment() {
	float t = TIME * wave_speed * 0.9;
	float c = caustic_pattern(world_pos.xz * wave_scale * 1.6, t);

	vec3 nv = normalize(NORMAL);
	float fres = pow(1.0 - abs(dot(nv, normalize(VIEW))), 3.0);

	vec3 base = mix(deep_color, shallow_color, 0.35 + 0.65 * fres);
	ALBEDO = base;
	ALPHA = mix(0.40, 0.86, fres);
	ROUGHNESS = mix(0.35, 0.06, fres);
	METALLIC = 0.0;
	EMISSION = shallow_color * c * caustic_strength + base * 0.22;
	// Нормаль из производных волн: свет играет по гребням.
	NORMAL = normalize((VIEW_MATRIX * vec4(surf_normal, 0.0)).xyz);
}
