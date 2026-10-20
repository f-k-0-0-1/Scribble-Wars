shader_type canvas_item;

uniform float damage_flash : hint_range(0.0, 1.0) = 0.0;

void fragment() {
    vec4 base_color = COLOR;
    base_color.rgb = mix(
        base_color.rgb,
        vec3(1.0, 0.0, 0.0),
        damage_flash
    );
    COLOR = base_color;
}