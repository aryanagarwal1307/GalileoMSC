################################################################################
# Runtime benchmarking
################################################################################

"""
Create a generic timing spec for a sequential particle filter.

Required keyword arguments:
- label: name shown in the plot legend
- pf_model: the Gen model used by the particle filter
- gm_args_builder: builds the full model args from (T, sim, template)
- online_args: converts full model args into the per-step args function get_args(t)
- argdiffs: the argdiff tuple for particle_filter_step!
- rejuvenate!: function(state, t, particles, rejuv_moves)
"""
function make_pf_timing_spec(; label,
                                pf_model,
                                gm_args_builder,
                                online_args,
                                argdiffs,
                                rejuvenate!)
    return (
        label = label,
        pf_model = pf_model,
        gm_args_builder = gm_args_builder,
        online_args = online_args,
        argdiffs = argdiffs,
        rejuvenate! = rejuvenate!
    )
end

function _model_config(model_key::Symbol;
                       drift_std::Float64=1.5,
                       proposal_drift_std::Float64=0.25,
                       msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    if model_key in (:particle_filter, :particlefilter, :pf, :static)
        return (
            key = :particle_filter,
            label = "particle filter",
            pf_model = particle_filter_model,
            gm_args_builder = (T, sim, template) -> (T, sim, template),
            history_runner = inference_with_history,
            timing_spec = particle_filter_timing_spec(label="particle filter")
        )
    elseif model_key in (:drift, :drift_model)
        return (
            key = :drift,
            label = "drift model",
            pf_model = drift_model,
            gm_args_builder = (T, sim, template) -> (T, sim, template, drift_std),
            history_runner = (gm_args, obs, particles, rejuv_moves) ->
                drift_inference_with_history(gm_args, obs, particles, rejuv_moves;
                                             proposal_drift_std=proposal_drift_std),
            timing_spec = drift_timing_spec(label="drift model",
                                            drift_std=drift_std,
                                            proposal_drift_std=proposal_drift_std)
        )
    elseif model_key in (:msc, :msc_model, :collision_msc)
        return (
            key = :msc,
            label = "MSC v0",
            pf_model = msc_model,
            gm_args_builder = (T, sim, template) -> (T, sim, template, msc_params),
            history_runner = msc_inference_with_history,
            timing_spec = msc_timing_spec(label="MSC v0", params=msc_params)
        )
    else
        error("Unknown model key: $model_key. Use :particle_filter, :drift, or :msc.")
    end
end

_model_config(model_key::AbstractString;
              drift_std::Float64=1.5,
              proposal_drift_std::Float64=0.25,
              msc_params::MSCParams=DEFAULT_MSC_PARAMS) =
    _model_config(Symbol(model_key);
                  drift_std=drift_std,
                  proposal_drift_std=proposal_drift_std,
                  msc_params=msc_params)

function _model_config(config::NamedTuple;
                       drift_std::Float64=1.5,
                       proposal_drift_std::Float64=0.25,
                       msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    required = (:key, :label, :pf_model, :gm_args_builder, :history_runner, :timing_spec)
    all(key -> haskey(config, key), required) ||
        error("Custom model configs must include: $(join(string.(required), ", ")).")
    return config
end

function _resolve_model_configs(models;
                                drift_std::Float64=1.5,
                                proposal_drift_std::Float64=0.25,
                                msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    items = models isa AbstractVector ? models : [models]
    return [_model_config(item;
                          drift_std=drift_std,
                          proposal_drift_std=proposal_drift_std,
                          msc_params=msc_params) for item in items]
end

function timing_spec(model_key;
                     drift_std::Float64=1.5,
                     proposal_drift_std::Float64=0.25,
                     msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    if model_key isa NamedTuple && haskey(model_key, :pf_model)
        return model_key
    end
    return _model_config(model_key;
                         drift_std=drift_std,
                         proposal_drift_std=proposal_drift_std,
                         msc_params=msc_params).timing_spec
end

function _resolve_timing_specs(model_specs;
                               drift_std::Float64=1.5,
                               proposal_drift_std::Float64=0.25,
                               msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    items = model_specs isa AbstractVector ? model_specs : [model_specs]
    return [timing_spec(item;
                        drift_std=drift_std,
                        proposal_drift_std=proposal_drift_std,
                        msc_params=msc_params) for item in items]
end

function _scene_source_from_arg(scene_model, scene_args_builder, specs,
                                drift_std::Float64,
                                proposal_drift_std::Float64,
                                msc_params::MSCParams)
    if scene_model === nothing
        return (specs[1].pf_model, specs[1].gm_args_builder)
    elseif scene_model isa Symbol || scene_model isa AbstractString
        spec = timing_spec(scene_model;
                           drift_std=drift_std,
                           proposal_drift_std=proposal_drift_std,
                           msc_params=msc_params)
        return (spec.pf_model, spec.gm_args_builder)
    else
        isnothing(scene_args_builder) &&
            error("scene_args_builder is required when scene_model is a Gen function.")
        return (scene_model, scene_args_builder)
    end
end

function _merge_constraints(base_constraints, ground_truth_mass, object_id::Int)
    constraints = base_constraints === nothing ? Gen.choicemap() : base_constraints
    if ground_truth_mass !== nothing
        constraints[:latents => :obj => object_id => :mass] = Float64(ground_truth_mass)
    end
    return constraints
end

function _ground_truth_mass_from_trace(tr::Gen.Trace)
    try
        object_id = tracked_mass_object(get_args(tr)[3])
        return get_choices(tr)[:latents => :obj => object_id => :mass]
    catch
        return nothing
    end
end

function _resolve_ground_truth_mass(template, ground_truth_mass)
    return ground_truth_mass === nothing ? template_mass_ratio(template) : Float64(ground_truth_mass)
end

"""
Sample one shared bank of observation sequences.

The RNG is seeded inside this function so repeated calls with the same inputs
produce the same scenes. That gives a fair runtime comparison across models.
"""
function sample_shared_scene_bank(T::Int, sim, template;
                                  n_scenes::Int=10,
                                  scene_model=particle_filter_model,
                                  scene_args_builder=(T, sim, template) -> (T, sim, template),
                                  scene_constraints=nothing,
                                  ground_truth_mass=nothing,
                                  seed::Int=1)
    Random.seed!(seed)
    scenes = Vector{NamedTuple}(undef, n_scenes)
    scene_args = scene_args_builder(T, sim, template)
    actual_ground_truth_mass = _resolve_ground_truth_mass(template, ground_truth_mass)
    constraints = _merge_constraints(scene_constraints, actual_ground_truth_mass, tracked_mass_object(template))

    for scene_idx in 1:n_scenes
        true_trace, = Gen.generate(scene_model, scene_args, constraints)
        observed_positions = observations_from_trace(true_trace)
        obs = make_observations(observed_positions)

        scenes[scene_idx] = (
            scene_idx = scene_idx,
            true_trace = true_trace,
            ground_truth_mass = _ground_truth_mass_from_trace(true_trace),
            observed_positions = observed_positions,
            obs = obs,
            collision_time = detect_collision_time(true_trace)
        )
    end

    return scenes
end

function _run_timed_filter_pass(spec,
                                gm_args,
                                obs::Vector{Gen.ChoiceMap};
                                particles::Int=20,
                                rejuv_moves::Int=1,
                                measure::Bool=true)
    get_args = spec.online_args(gm_args)
    state = Gen.initialize_particle_filter(spec.pf_model, get_args(0), EmptyChoiceMap(), particles)
    step_times_s = zeros(length(obs))

    for (t, obs_t) in enumerate(obs)
        elapsed = @elapsed begin
            Gen.particle_filter_step!(state, get_args(t), spec.argdiffs, obs_t)
            Gen.maybe_resample!(state, ess_threshold=particles / 2)
            spec.rejuvenate!(state, t, particles, rejuv_moves)
        end

        if measure
            step_times_s[t] = elapsed
        end
    end

    return step_times_s
end

"""
Benchmark normalized per-step runtime for a single timing spec on a fixed scene bank.

Each scene is inferred `n_runs` times with a distinct seed. Timings are divided by
`particles * rejuv_moves` before being summarized.
"""
function benchmark_step_runtime(spec,
                                scenes,
                                T::Int,
                                sim,
                                template;
                                particles::Int=30,
                                rejuv_moves::Int=2,
                                n_runs::Int=1,
                                seed::Int=1,
                                warmup::Bool=true)
    particles > 0 || error("particles must be positive")
    n_runs > 0 || error("n_runs must be positive")
    rejuv_moves > 0 || error("rejuv_moves must be positive to normalize runtime")
    gm_args = spec.gm_args_builder(T, sim, template)

    if warmup && !isempty(scenes)
        _run_timed_filter_pass(spec, gm_args, scenes[1].obs;
                               particles=particles,
                               rejuv_moves=rejuv_moves,
                               measure=false)
    end

    step_times_s = Array{Float64}(undef, length(scenes), n_runs, T)
    collision_times = Vector{Union{Nothing,Int}}(undef, length(scenes))

    for (scene_idx, scene) in enumerate(scenes)
        for run_idx in 1:n_runs
            println(
                "Benchmarking $(spec.label), scene $scene_idx / $(length(scenes)), run $run_idx / $n_runs",
                ", collision_time = $(scene.collision_time)"
            )

            Random.seed!(seed + (scene_idx - 1) * n_runs + run_idx - 1)
            step_times_s[scene_idx, run_idx, :] = _run_timed_filter_pass(spec, gm_args, scene.obs;
                                                                        particles=particles,
                                                                        rejuv_moves=rejuv_moves,
                                                                        measure=true)
        end
        collision_times[scene_idx] = scene.collision_time
    end

    step_times_s ./= particles * rejuv_moves
    mean_ms = 1000.0 .* vec(mean(step_times_s; dims=(1, 2)))
    std_ms = 1000.0 .* vec(std(step_times_s; dims=(1, 2)))
    median_ms = 1000.0 .* [median(view(step_times_s, :, :, t)) for t in 1:T]
    q25_ms = 1000.0 .* [quantile(vec(view(step_times_s, :, :, t)), 0.25) for t in 1:T]
    q75_ms = 1000.0 .* [quantile(vec(view(step_times_s, :, :, t)), 0.75) for t in 1:T]

    return (
        label = spec.label,
        step_times_s = step_times_s,
        mean_ms = mean_ms,
        std_ms = std_ms,
        median_ms = median_ms,
        q25_ms = q25_ms,
        q75_ms = q75_ms,
        collision_times = collision_times
    )
end

"""
Plot normalized per-step inference time for one or more particle-filter models.

By default the line is the mean over scene-runs and the ribbon is +/- one std.
If summary=:median, the line is the median and the ribbon is the interquartile range.
"""
function plot_step_runtime_comparison(model_specs;
                                      T::Int,
                                      sim,
                                      template,
                                      scenes=nothing,
                                      n_scenes::Int=10,
                                      n_runs::Int=1,
                                      scene_model=nothing,
                                      scene_args_builder=nothing,
                                      scene_constraints=nothing,
                                      ground_truth_mass=nothing,
                                      particles::Int=30,
                                      rejuv_moves::Int=2,
                                      drift_std::Float64=1.5,
                                      proposal_drift_std::Float64=0.25,
                                      msc_params::MSCParams=DEFAULT_MSC_PARAMS,
                                      seed::Int=1,
                                      warmup::Bool=true,
                                      summary::Symbol=:mean)
    specs = _resolve_timing_specs(model_specs;
                                  drift_std=drift_std,
                                  proposal_drift_std=proposal_drift_std,
                                  msc_params=msc_params)
    source_model, source_args_builder = _scene_source_from_arg(scene_model, scene_args_builder, specs,
                                                               drift_std,
                                                               proposal_drift_std,
                                                               msc_params)

    scene_bank = isnothing(scenes) ? sample_shared_scene_bank(T, sim, template;
                                                              n_scenes=n_scenes,
                                                              scene_model=source_model,
                                                              scene_args_builder=source_args_builder,
                                                              scene_constraints=scene_constraints,
                                                              ground_truth_mass=ground_truth_mass,
                                                              seed=seed) : scenes

    results = [benchmark_step_runtime(spec, scene_bank, T, sim, template;
                                      particles=particles,
                                      rejuv_moves=rejuv_moves,
                                      n_runs=n_runs,
                                      seed=seed,
                                      warmup=warmup) for spec in specs]

    ts = 1:T
    p = Plots.plot(xlabel="filter step t",
                   ylabel="runtime per step (ms / particle / rejuvenation move)",
                   title="Normalized per-step particle-filter runtime",
                   legend=:topleft)

    for result in results
        if summary == :mean
            center = result.mean_ms
            ribbon = result.std_ms
        elseif summary == :median
            center = result.median_ms
            ribbon = (result.median_ms .- result.q25_ms, result.q75_ms .- result.median_ms)
        else
            error("summary must be :mean or :median")
        end

        Plots.plot!(p, ts, center;
                    ribbon=ribbon,
                    label=result.label,
                    lw=3,
                    marker=:circle,
                    ms=3)
    end

    return (
        plot = p,
        scenes = scene_bank,
        results = results
    )
end

################################################################################
# Mass-ratio history comparison
################################################################################

function run_mass_ratio_history_comparison(models;
                                           T::Int,
                                           sim,
                                           template,
                                           obs=nothing,
                                           observed_positions=nothing,
                                           scene_model=nothing,
                                           scene_args_builder=nothing,
                                           scene_constraints=nothing,
                                           ground_truth_mass=nothing,
                                           particles::Int=30,
                                           rejuv_moves::Int=2,
                                           drift_std::Float64=1.5,
                                           proposal_drift_std::Float64=0.25,
                                           msc_params::MSCParams=DEFAULT_MSC_PARAMS,
                                           seed::Int=1)
    configs = _resolve_model_configs(models;
                                     drift_std=drift_std,
                                     proposal_drift_std=proposal_drift_std,
                                     msc_params=msc_params)

    true_trace = nothing
    if obs === nothing
        if observed_positions === nothing
            Random.seed!(seed)
            source_model, source_builder = _scene_source_from_arg(scene_model, scene_args_builder, [configs[1].timing_spec],
                                                                  drift_std,
                                                                  proposal_drift_std,
                                                                  msc_params)
            actual_ground_truth_mass = _resolve_ground_truth_mass(template, ground_truth_mass)
            constraints = _merge_constraints(scene_constraints, actual_ground_truth_mass, tracked_mass_object(template))
            true_trace, = Gen.generate(source_model, source_builder(T, sim, template), constraints)
            observed_positions = observations_from_trace(true_trace)
        end
        obs = make_observations(observed_positions)
    end

    collision_time = if true_trace !== nothing
        detect_collision_time(true_trace)
    elseif observed_positions !== nothing
        # A caller-supplied observation sequence has no associated simulator
        # trajectory, so a noise-free collision time cannot be recovered here.
        detect_collision_time(observed_positions)
    else
        nothing
    end
    actual_ground_truth_mass = true_trace === nothing ? ground_truth_mass : _ground_truth_mass_from_trace(true_trace)
    results = Vector{NamedTuple}(undef, length(configs))

    for (idx, config) in enumerate(configs)
        gm_args = config.gm_args_builder(T, sim, template)
        history = config.history_runner(gm_args, obs, particles, rejuv_moves)
        results[idx] = (
            key = config.key,
            label = config.label,
            history = history,
            collision_time = collision_time
        )
    end

    return (
        results = results,
        true_trace = true_trace,
        ground_truth_mass = actual_ground_truth_mass,
        observed_positions = observed_positions,
        obs = obs,
        collision_time = collision_time
    )
end

function _history_label(item, idx)
    if item isa Pair
        return string(item.first)
    elseif hasproperty(item, :label)
        return string(getproperty(item, :label))
    else
        return "model $idx"
    end
end

function _history_value(item)
    if item isa Pair
        return item.second
    elseif hasproperty(item, :history)
        return getproperty(item, :history)
    else
        return item
    end
end

function _history_collision_time(item)
    hasproperty(item, :collision_time) ? getproperty(item, :collision_time) : nothing
end

function _is_history_vector(x)
    return x isa AbstractVector && !isempty(x) && hasproperty(x[1], :t)
end

function _msc_capsule_key(cap::CollisionMSC)
    a = min(cap.a, cap.b)
    b = max(cap.a, cap.b)
    return (:collision, a, b)
end

function _msc_capsule_label(key)
    kind, a, b = key
    if kind == :collision
        return "collision $a-$b"
    end
    return string(kind, " ", a, "-", b)
end

function _msc_capsule_activity_matrix(history)
    ts = [h.t for h in history]
    keys = Tuple{Symbol,Int,Int}[]
    seen = Set{Tuple{Symbol,Int,Int}}()

    for h in history
        for tr in h.traces
            for cap in extract_msc_capsules(tr, Int(h.t))
                key = _msc_capsule_key(cap)
                if !(key in seen)
                    push!(seen, key)
                    push!(keys, key)
                end
            end
        end
    end

    activity = zeros(length(keys), length(history))
    index = Dict{Tuple{Symbol,Int,Int},Int}()
    for (i, key) in enumerate(keys)
        index[key] = i
    end

    for (col, h) in enumerate(history)
        n_traces = length(h.traces)
        n_traces == 0 && continue

        for tr in h.traces
            active_keys = Set{Tuple{Symbol,Int,Int}}()
            for cap in extract_msc_capsules(tr, Int(h.t))
                push!(active_keys, _msc_capsule_key(cap))
            end
            for key in active_keys
                activity[index[key], col] += 1.0
            end
        end

        activity[:, col] ./= n_traces
    end

    return (
        ts = ts,
        labels = [_msc_capsule_label(key) for key in keys],
        activity = activity
    )
end

function _bin_mass_history(history, time_bin_size::Int)
    time_bin_size >= 1 || error("time_bin_size must be at least 1.")
    time_bin_size == 1 && return history

    sorted_history = sort(collect(history); by=h -> h.t)
    isempty(sorted_history) && return sorted_history

    binned = NamedTuple[]
    first_t = minimum([h.t for h in sorted_history])
    last_t = maximum([h.t for h in sorted_history])

    for bin_start in first_t:time_bin_size:last_t
        bin_stop = bin_start + time_bin_size - 1
        rows = [h for h in sorted_history if bin_start <= h.t <= bin_stop]
        isempty(rows) && continue

        push!(binned, (
            t = mean([h.t for h in rows]),
            mean = mean([h.mean for h in rows]),
            std = mean([h.std for h in rows]),
            q05 = mean([h.q05 for h in rows]),
            q25 = mean([h.q25 for h in rows]),
            q75 = mean([h.q75 for h in rows]),
            q95 = mean([h.q95 for h in rows])
        ))
    end

    return binned
end

function plot_mass_ratio_history(history;
                                 collision_time=nothing,
                                 use_quantiles=false,
                                 label="posterior mean",
                                 time_bin_size::Int=1)
    history = _bin_mass_history(history, time_bin_size)
    ts = [h.t for h in history]
    means = [h.mean for h in history]

    if use_quantiles
        lower = [h.q05 for h in history]
        upper = [h.q95 for h in history]
        yerr = (means .- lower, upper .- means)
    else
        stds = [h.std for h in history]
        yerr = stds
    end

    p = Plots.plot(
        ts, means;
        yerror=yerr,
        xlabel="time",
        ylabel="mass ratio",
        label=label,
        lw=2,
        marker=:circle
    )

    if collision_time !== nothing
        Plots.vline!(p, [collision_time], label="collision time", lw=2, ls=:dash)
    end

    return p
end

function plot_mass_ratio_history_comparison(history_results;
                                            collision_time=nothing,
                                            ground_truth_mass=nothing,
                                            use_quantiles::Bool=false,
                                            time_bin_size::Int=1,
                                            title::AbstractString="Posterior mass ratio over time")
    time_bin_size >= 1 || error("time_bin_size must be at least 1.")

    result_ground_truth_mass = if ground_truth_mass !== nothing
        ground_truth_mass
    elseif hasproperty(history_results, :ground_truth_mass)
        history_results.ground_truth_mass
    else
        nothing
    end

    items = hasproperty(history_results, :results) ? history_results.results : history_results
    items = items isa AbstractVector ? items : [items]

    p = Plots.plot(xlabel="time",
                   ylabel="mass ratio",
                   title=title,
                   legend=:topleft)

    for (idx, item) in enumerate(items)
        history = _bin_mass_history(_history_value(item), time_bin_size)
        label = _history_label(item, idx)
        ts = [h.t for h in history]
        means = [h.mean for h in history]

        if use_quantiles
            lower = [h.q05 for h in history]
            upper = [h.q95 for h in history]
            ribbon = (means .- lower, upper .- means)
        else
            ribbon = [h.std for h in history]
        end

        Plots.plot!(p, ts, means;
                    ribbon=ribbon,
                    label=label,
                    lw=3,
                    marker=:circle,
                    ms=3)
    end

    collision_times = if collision_time !== nothing
        [collision_time]
    else
        unique([_history_collision_time(item) for item in items if _history_collision_time(item) !== nothing])
    end

    for (idx, ct) in enumerate(collision_times)
        Plots.vline!(p, [ct], label=idx == 1 ? "collision time" : "", lw=2, ls=:dash)
    end

    if result_ground_truth_mass !== nothing
        Plots.hline!(p, [result_ground_truth_mass]; label="true mass ratio", lw=2, ls=:dot, color=:black)
    end

    return p
end

function _mass_variance_history(history, time_bin_size::Int)
    time_bin_size >= 1 || error("time_bin_size must be at least 1.")
    sorted_history = sort(collect(history); by=h -> h.t)
    isempty(sorted_history) && return NamedTuple[]

    if time_bin_size == 1
        return [(t = h.t, variance = h.std^2) for h in sorted_history]
    end

    binned = NamedTuple[]
    first_t = minimum([h.t for h in sorted_history])
    last_t = maximum([h.t for h in sorted_history])

    for bin_start in first_t:time_bin_size:last_t
        bin_stop = bin_start + time_bin_size - 1
        rows = [h for h in sorted_history if bin_start <= h.t <= bin_stop]
        isempty(rows) && continue

        push!(binned, (
            t = mean([h.t for h in rows]),
            variance = mean([h.std^2 for h in rows])
        ))
    end

    return binned
end

function plot_mass_ratio_variance_comparison(history_results;
                                             collision_time=nothing,
                                             time_bin_size::Int=1,
                                             title::AbstractString="Posterior mass-ratio variance over time")
    time_bin_size >= 1 || error("time_bin_size must be at least 1.")

    items = hasproperty(history_results, :results) ? history_results.results : history_results
    items = items isa AbstractVector ? items : [items]

    p = Plots.plot(xlabel="time",
                   ylabel="posterior variance",
                   title=title,
                   legend=:topright)

    for (idx, item) in enumerate(items)
        variance_history = _mass_variance_history(_history_value(item), time_bin_size)
        label = _history_label(item, idx)
        ts = [h.t for h in variance_history]
        variances = [h.variance for h in variance_history]

        Plots.plot!(p, ts, variances;
                    label=label,
                    lw=3,
                    marker=:circle,
                    ms=3)
    end

    collision_times = if collision_time !== nothing
        [collision_time]
    else
        unique([_history_collision_time(item) for item in items if _history_collision_time(item) !== nothing])
    end

    for (idx, ct) in enumerate(collision_times)
        Plots.vline!(p, [ct], label=idx == 1 ? "collision time" : "", lw=2, ls=:dash)
    end

    return p
end

function plot_capsule_activation_history(history_results;
                                         collision_time=nothing,
                                         show_switch::Bool=true,
                                         show_events::Bool=true,
                                         title::AbstractString="MSC capsule activation over time")
    items = if hasproperty(history_results, :results)
        history_results.results
    elseif _is_history_vector(history_results)
        [(label = "MSC v0", history = history_results, collision_time = collision_time)]
    else
        history_results
    end
    items = items isa AbstractVector ? items : [items]

    p = Plots.plot(xlabel="time",
                   ylabel="probability",
                   title=title,
                   legend=:topright,
                   ylims=(0, 1))

    plotted_any = false

    for (idx, item) in enumerate(items)
        history = _history_value(item)
        isempty(history) && continue
        hasproperty(history[1], :capsule_active_prob) || continue

        label = _history_label(item, idx)
        ts = [h.t for h in history]
        active_probs = [h.capsule_active_prob for h in history]
        Plots.plot!(p, ts, active_probs;
                    label="$(label) active",
                    lw=3,
                    marker=:circle,
                    ms=3)
        plotted_any = true

        if show_switch && hasproperty(history[1], :capsule_switch_prob)
            switch_probs = [h.capsule_switch_prob for h in history]
            Plots.plot!(p, ts, switch_probs;
                        label="$(label) switch",
                        lw=2,
                        ls=:dash)
        end

        if show_events && hasproperty(history[1], :capsule_birth_prob)
            birth_probs = [h.capsule_birth_prob for h in history]
            Plots.plot!(p, ts, birth_probs;
                        label="$(label) birth",
                        lw=2,
                        ls=:dot)
        end

        if show_events && hasproperty(history[1], :capsule_death_prob)
            death_probs = [h.capsule_death_prob for h in history]
            Plots.plot!(p, ts, death_probs;
                        label="$(label) death",
                        lw=2,
                        ls=:dashdot)
        end
    end

    plotted_any || error("No history entries with capsule_active_prob were found.")

    collision_times = if collision_time !== nothing
        [collision_time]
    else
        unique([_history_collision_time(item) for item in items if _history_collision_time(item) !== nothing])
    end

    for (idx, ct) in enumerate(collision_times)
        Plots.vline!(p, [ct], label=idx == 1 ? "collision time" : "", lw=2, ls=:dot)
    end

    return p
end

function plot_capsule_flame_graph(history_results;
                                  collision_time=nothing,
                                  title::AbstractString="MSC capsule flame graph")
    items = if hasproperty(history_results, :results)
        history_results.results
    elseif _is_history_vector(history_results)
        [(label = "MSC v0", history = history_results, collision_time = collision_time)]
    else
        history_results
    end
    items = items isa AbstractVector ? items : [items]

    plot_list = []

    for (idx, item) in enumerate(items)
        history = _history_value(item)
        isempty(history) && continue
        hasproperty(history[1], :capsule_active_prob) || continue
        hasproperty(history[1], :traces) || continue

        label = _history_label(item, idx)
        data = _msc_capsule_activity_matrix(history)
        item_title = length(items) == 1 ? title : "$title: $label"

        if isempty(data.labels)
            p = Plots.plot(data.ts, zeros(length(data.ts));
                           xlabel="time",
                           ylabel="capsule",
                           title=item_title,
                           legend=false,
                           ylims=(0, 1),
                           color=:white)
            if !isempty(data.ts)
                Plots.annotate!(p, mean(data.ts), 0.5, "no sampled active capsules")
            end
        else
            ys = collect(1:length(data.labels))
            p = Plots.heatmap(data.ts, ys, data.activity;
                              xlabel="time",
                              ylabel="capsule",
                              yticks=(ys, data.labels),
                              title=item_title,
                              color=:viridis,
                              clims=(0, 1),
                              colorbar_title="active probability",
                              legend=false)
        end

        item_collision_time = collision_time !== nothing ? collision_time : _history_collision_time(item)
        if item_collision_time !== nothing
            Plots.vline!(p, [item_collision_time]; label="", lw=2, ls=:dot, color=:white)
        end

        push!(plot_list, p)
    end

    isempty(plot_list) && error("No MSC history entries with traces were found.")
    length(plot_list) == 1 && return plot_list[1]
    return Plots.plot(plot_list...; layout=(length(plot_list), 1), size=(900, 260 * length(plot_list)))
end
