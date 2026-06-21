shader_type spatial;
render_mode unshaded, depth_prepass_alpha;

uniform float u_time : hint_range(0, 1000) = 0.0;
uniform float u_level : hint_range(0.0, 1.0) = 1.0;
uniform vec3 u_color_deep = vec3(0.176, 0.333, 0.431);
uniform vec3 u_color_shallow = vec3(0.216, 0.412, 0.490);
uniform vec3 u_shine_color = vec3(0.275, 0.510, 0.588);

void fragment() {
    float dist = length(UV * 2.0 - 1.0);

    float ripple1 = sin(dist * 12.0 - u_time * 3.0) * 0.5 + 0.5;
    float ripple2 = sin(dist * 8.0 - u_time * 2.0 + 1.5) * 0.5 + 0.5;
    float ripple = mix(ripple1, ripple2, 0.5);

    float ripple_strength = smoothstep(0.3, 1.0, dist) * 0.3;
    float ripple_mod = 1.0 + ripple * ripple_strength;

    float depth_mix = dist * 0.7 + ripple * ripple_strength * 0.5;
    vec3 base_color = mix(u_color_deep, u_color_shallow, clamp(depth_mix, 0.0, 1.0));

    float specular = pow(1.0 - dist, 4.0) * 0.4;
    base_color += u_shine_color * specular;

    float edge_fade = 1.0 - smoothstep(0.8, 1.0, dist);

    ALBEDO = base_color * ripple_mod;
    ALPHA = edge_fade * (0.4 + u_level * 0.4);
    EMISSION = base_color * ripple * ripple_strength * 0.15;
}
