const DEFAULT_STIMULI_CONFIG = normpath(joinpath(@__DIR__, "..", "stimuli", "config", "stimuli.toml"))

"""
    StimulusSpec(; condition_id, ramp_material, table_material, mass_ratio,
                 appearance_mass_ratio, congruent, obj_ramp_dims, obj_table_dims,
                 obj_frictions, restitution, obj_positions, slope,
                 table_ramp_intersection, physics_hz, video_fps, max_duration,
                 post_collision_duration, seed, enabled=true)

Validated, immutable configuration for one human-experiment stimulus.
`mass_ratio` is the physical ramp-object mass divided by the table-object mass,
with the table object normalized to 1.0. `appearance_mass_ratio` is the ratio
predicted by the visible materials, independently of the simulated masses.
Dimensions are full box dimensions in meters, durations are seconds, and slope
is rise/run. `obj_positions` uses the existing `ramp` placement parameters
(ramp first, table second), not world-space coordinates. Frequencies are integer Hz.
Materials describe appearance; this configuration layer does not apply textures.
`enabled` controls inclusion in batch exports; loading still validates all conditions.
"""
struct StimulusSpec
    condition_id::String
    ramp_material::String
    table_material::String
    mass_ratio::Float64
    appearance_mass_ratio::Float64
    congruent::Bool
    obj_ramp_dims::NTuple{3,Float64}
    obj_table_dims::NTuple{3,Float64}
    obj_frictions::NTuple{2,Float64}
    restitution::Float64
    obj_positions::NTuple{2,Float64}
    slope::Float64
    table_ramp_intersection::Float64
    physics_hz::Int
    video_fps::Int
    max_duration::Float64
    post_collision_duration::Float64
    seed::Int
    enabled::Bool

    function StimulusSpec(; condition_id::AbstractString,
                          ramp_material::AbstractString, table_material::AbstractString,
                          mass_ratio::Real, appearance_mass_ratio::Real, congruent::Bool,
                          obj_ramp_dims, obj_table_dims, obj_frictions,
                          restitution::Real, obj_positions, slope::Real,
                          table_ramp_intersection::Real, physics_hz::Integer,
                          video_fps::Integer, max_duration::Real,
                          post_collision_duration::Real, seed::Integer, enabled::Bool=true)
        isempty(strip(condition_id)) && throw(ArgumentError("condition_id must not be empty"))
        for material in (ramp_material, table_material)
            isempty(strip(material)) && throw(ArgumentError("material must not be empty"))
        end
        mass_ratio = Float64(mass_ratio)
        appearance_mass_ratio = Float64(appearance_mass_ratio)
        max_duration = Float64(max_duration)
        post_collision_duration = Float64(post_collision_duration)
        for (name, value) in (("mass_ratio", mass_ratio),
                              ("appearance_mass_ratio", appearance_mass_ratio),
                              ("physics_hz", physics_hz), ("video_fps", video_fps),
                              ("max_duration", max_duration),
                              ("post_collision_duration", post_collision_duration))
            _positive_finite(value, name)
        end
        physics_hz % video_fps == 0 ||
            throw(ArgumentError("physics_hz must be divisible by video_fps"))
        ramp_dims = _object_dimensions(obj_ramp_dims, "obj_ramp_dims")
        table_dims = _object_dimensions(obj_table_dims, "obj_table_dims")
        length(obj_frictions) == 2 || throw(ArgumentError("obj_frictions must contain two values"))
        frictions = (Float64(obj_frictions[1]), Float64(obj_frictions[2]))
        all(x -> isfinite(x) && x >= 0, frictions) ||
            throw(ArgumentError("frictions must be finite and nonnegative"))
        isfinite(restitution) && 0 <= restitution <= 1 ||
            throw(ArgumentError("restitution must be between 0 and 1"))
        length(obj_positions) == 2 || throw(ArgumentError("obj_positions must contain two values"))
        positions = (Float64(obj_positions[1]), Float64(obj_positions[2]))
        all(isfinite, positions) || throw(ArgumentError("obj_positions must be finite"))
        slope = Float64(slope)
        table_ramp_intersection = Float64(table_ramp_intersection)
        isfinite(slope) || throw(ArgumentError("slope must be finite"))
        isfinite(table_ramp_intersection) || throw(ArgumentError("table_ramp_intersection must be finite"))
        seed >= 0 || throw(ArgumentError("seed must be nonnegative"))
        congruent == isapprox(mass_ratio, appearance_mass_ratio) ||
            throw(ArgumentError("congruence must agree with physical and appearance mass ratios"))
        return new(String(condition_id), String(ramp_material), String(table_material),
                   mass_ratio, appearance_mass_ratio, congruent, ramp_dims, table_dims,
                   frictions, Float64(restitution), positions, slope, table_ramp_intersection,
                   Int(physics_hz), Int(video_fps), max_duration, post_collision_duration, Int(seed), enabled)
    end
end

"""
    load_stimuli(path=DEFAULT_STIMULI_CONFIG) -> Vector{StimulusSpec}

Load conditions in file order, merging each with `[defaults]`. Appearance ratios
are derived from positive relative masses in `[materials]`. Unknown materials,
duplicate condition IDs, invalid values, and unsupported condition keys fail
instead of silently changing the experiment. No scene or random state is created.
"""
function load_stimuli(path::AbstractString=DEFAULT_STIMULI_CONFIG)
    config = TOML.parsefile(path)
    materials = config["materials"]
    for (name, mass) in materials
        _positive_finite(Float64(mass), "material mass for $name")
    end
    specs = StimulusSpec[]
    ids = Set{String}()
    for condition in config["conditions"]
        values = merge(config["defaults"], condition)
        ramp_material = values["ramp_material"]
        table_material = values["table_material"]
        for material in (ramp_material, table_material)
            haskey(materials, material) || throw(ArgumentError("unknown material: $material"))
        end
        haskey(values, "appearance_mass_ratio") &&
            throw(ArgumentError("appearance_mass_ratio is derived from [materials]"))
        values["appearance_mass_ratio"] = Float64(materials[ramp_material]) / Float64(materials[table_material])
        spec = StimulusSpec(; (Symbol(key) => value for (key, value) in values)...)
        spec.condition_id in ids && throw(ArgumentError("duplicate condition_id: $(spec.condition_id)"))
        push!(ids, spec.condition_id)
        push!(specs, spec)
    end
    isempty(specs) && throw(ArgumentError("configuration must contain at least one condition"))
    return specs
end

"""
    stimulus_scene_kwargs(spec::StimulusSpec)

Return the physical scene keywords for `create_ramp_simulation(; ... )`.
Timing, rendering, stopping, and RNG seeding remain the stimulus runner's
responsibility; this function does not apply those settings or mutate global RNGs.
"""
function stimulus_scene_kwargs(spec::StimulusSpec)
    return (; mass_ratio=spec.mass_ratio, obj_frictions=spec.obj_frictions,
            obj_positions=spec.obj_positions, slope=spec.slope,
            tableRampIntersection=spec.table_ramp_intersection,
            restitution=spec.restitution, obj_ramp_dims=spec.obj_ramp_dims,
            obj_table_dims=spec.obj_table_dims)
end
