module GalileoMSC

using Accessors
using Distributions
using Gen
using LinearAlgebra
using PhyBullet
using PhySMC
using Plots
using PyCall
using Random
using Statistics

include("distributions/unsafe_fast_categorical.jl")
include("distributions/log_uniform.jl")
include("distributions/log_symmetric_peak.jl")
include("common.jl")
include("scenes.jl")
include("particle_filter_model.jl")
include("drift_model.jl")
include("msc_types.jl")
include("msc_helpers.jl")
include("capsules/collision.jl")
include("msc_model.jl")
include("plotting.jl")
include("visualization.jl")

export
    # common helpers
    observe,
    update_latents,
    sample_object,
    prior,
    make_observations,
    template_mass_ratio,
    mass_constraint,
    friction_constraint,
    set_friction_constraints!,
    observations_from_trace,
    true_positions_from_trace,
    detect_collision_time,
    trunc_norm,
    object_mass,
    object_lateral_friction,
    template_lateral_frictions,
    is_static_object,
    is_dynamic_object,
    dynamic_object_indices,
    static_object_indices,
    tracked_mass_object,
    unsafe_fast_categorical,
    # scenes
    ramp,
    create_ramp_simulation,
    sample_random_scene,
    simulate_scene_positions,
    # particle-filter model
    particle_filter_model,
    model,
    particle_filter_proposal,
    proposal,
    inference_procedure,
    inference_with_history,
    run_smoke_test,
    run_history_smoke_test,
    particle_filter_timing_spec,
    # drift model
    drift_model,
    drift_proposal,
    drift_inference_procedure,
    drift_inference_with_history,
    run_drift_smoke_test,
    drift_timing_spec,
    # MSC v0 model
    MSCParams,
    CollisionMSC,
    MSCState,
    MSCEventStats,
    LatentDelta,
    CapsuleDiff,
    DEFAULT_MSC_PARAMS,
    msc_capsule_id,
    msc_capsule_key,
    initial_msc_state,
    aggregate_capsule_diffs,
    apply_capsule_diffs,
    collision_survival_probability,
    msc_model,
    msc_proposal,
    msc_inference_procedure,
    msc_inference_with_history,
    extract_msc_capsules,
    summarize_msc_capsules,
    msc_timing_spec,
    # plotting
    make_pf_timing_spec,
    sample_shared_scene_bank,
    benchmark_step_runtime,
    plot_step_runtime_comparison,
    run_mass_ratio_history_comparison,
    plot_mass_ratio_history,
    plot_mass_ratio_history_comparison,
    plot_mass_ratio_variance_comparison,
    plot_friction_history_comparison,
    plot_capsule_activation_history,
    plot_capsule_flame_graph,
    timing_spec,
    # visualization
    scene_metadata,
    visualize_scene,
    plot_scene_trajectory,
    true_object_positions,
    particle_object_positions,
    particle_scene_limits,
    draw_scene_svg,
    save_particle_scene_gif

end
